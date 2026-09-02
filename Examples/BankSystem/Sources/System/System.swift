import Ledger
import Teller
import Schedules
import os

// The composed code: the real `LedgerService` and two real `TellerSession`s
// connected by a network that delays (arrival picks any: every delivery is
// its own task, ordered by the scheduler, and a per-message delay on the
// fake clock lets a timer fire first), duplicates and drops (a drawn fault
// list by send index, as in Examples/TwoPhaseCommit). The bridge between
// the teller's and the ledger's types lives in the network, which is where
// it lives in a real system too. Instrumented at the granularity of one
// `Next_S` step, in one ordered log: each component records its own step
// synchronously inside its actor through the `observer` hooks, and the
// network records its faults synchronously where it decides them.

public struct Delays: Sendable, Equatable, CustomStringConvertible {
    public var ticks: [Int: Int]
    public init(_ ticks: [Int: Int] = [:]) { self.ticks = ticks }
    public var description: String {
        ticks.isEmpty ? "no delays" : ticks.sorted { $0.key < $1.key }.map { "message \($0.key) delayed \($0.value)" }.joined(separator: "; ")
    }
}

public struct Faults: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable { case drop, duplicate }
    public struct Fault: Sendable, Equatable {
        public var message: Int
        public var kind: Kind
        public init(message: Int, kind: Kind) { self.message = message; self.kind = kind }
    }
    public var faults: [Fault]
    public init(_ faults: [Fault] = []) { self.faults = faults }
    func kind(of index: Int) -> Kind? { faults.first { $0.message == index }?.kind }
    public var description: String {
        faults.isEmpty ? "honest network" : faults.map { "\($0.kind) message \($0.message)" }.joined(separator: "; ")
    }
}

public final class StepLog: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [SystemModel.Record]())
    public init() {}
    func record(_ r: SystemModel.Record) { lock.withLock { $0.append(r) } }
    public var records: [SystemModel.Record] { lock.withLock { $0 } }
}

/// The audit store the teller sessions write to, on its own lane.
actor AuditStore: Audit {
    let executor: ControlledSerialExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private(set) var lines: [String] = []
    init(executor: ControlledSerialExecutor) { self.executor = executor }
    func record(_ line: String) { lines.append(line) }
}

/// The network, and the bridge. `Wire.send` is synchronous (a socket
/// write), so the network is a class under a lock, not an actor; each
/// delivery is a task the scheduler orders.
public final class Network: Wire, @unchecked Sendable {
    struct State {
        var sent = 0
        var tasks: [Task<Void, Never>] = []
        var ledger: LedgerService?
        var tellers: [String: TellerSession] = [:]
        var log: [String] = []
        /// The bridge's table: which wire request each ledger id came from.
        var wireOf: [LedgerId: TellerRequest] = [:]
        /// The planted bug's counters.
        var fresh: [String: Int] = [:]
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    let scheduler: Scheduler
    let delays: Delays
    let faults: Faults
    let bug: Bridge.Bug?
    let steps: StepLog

    init(scheduler: Scheduler, delays: Delays, faults: Faults, bug: Bridge.Bug?, steps: StepLog) {
        self.scheduler = scheduler
        self.delays = delays
        self.faults = faults
        self.bug = bug
        self.steps = steps
    }

    func attach(ledger: LedgerService, tellers: [(String, TellerSession)]) {
        lock.withLock { s in
            s.ledger = ledger
            for (name, t) in tellers { s.tellers[name] = t }
        }
    }
    public var log: [String] { lock.withLock { $0.log } }

    /// The bridge, request side. Honest: the identity on `Teller × ℕ⁺`.
    private func forward(_ q: TellerRequest) -> LedgerRequest {
        lock.withLock { s in
            let id: LedgerId
            switch bug {
            case nil: id = Bridge.ledgerId(q.id)
            case .freshSeqPerCopy:
                s.fresh[q.id.teller, default: 0] += 1
                id = LedgerId(q.id.teller, s.fresh[q.id.teller]!)
            case .idWithoutTeller:
                id = LedgerId("t", q.id.n)
            }
            s.wireOf[id] = q
            return LedgerRequest(id, Bridge.acct, Bridge.ledgerReq(q.req))
        }
    }

    /// The bridge, reply side: the wire request a ledger arrival was.
    func wireRequest(for m: LedgerRequest) -> TellerRequest {
        lock.withLock { $0.wireOf[m.id]! }
    }

    /// What the network does to one message: a fault by send index,
    /// recorded as the `Next_S` step it is, then one task per copy.
    private func dispatch(_ m: Msg, _ deliver: @escaping @Sendable () async -> Void) {
        let (index, copies): (Int, Int) = lock.withLock { s in
            let index = s.sent
            s.sent += 1
            let copies: Int
            switch faults.kind(of: index) {
            case .drop: copies = 0
            case .duplicate: copies = 2
            case nil: copies = 1
            }
            let delay = delays.ticks[index] ?? 0
            s.log.append("\(index): \(m)\(copies == 1 ? "" : " ×\(copies)")\(delay > 0 ? " delayed \(delay)" : "")")
            return (index, copies)
        }
        switch copies {
        case 0: steps.record(SystemModel.Record(.drop(m)))
        case 2: steps.record(SystemModel.Record(.dup(m)))
        default: break
        }
        let delay = delays.ticks[index] ?? 0
        let clock = scheduler.clock
        for _ in 0..<copies {
            spawn {
                if delay > 0 { try? await clock.sleep(for: .seconds(delay)) }
                await deliver()
            }
        }
    }

    /// `Wire`: a teller's request.
    public func send(_ q: TellerRequest) {
        dispatch(.request(q)) { [self] in
            let ledger = lock.withLock { $0.ledger! }
            let lm = forward(q)
            guard let rep = await ledger.handle(lm) else { return }
            reply(TellerReply(id: q.id, rep: Bridge.tellerRep(rep)))
        }
    }

    /// The ledger's reply, addressed to the teller in its identity.
    private func reply(_ r: TellerReply) {
        dispatch(.reply(r)) { [self] in
            guard let session = lock.withLock({ $0.tellers[r.id.teller] }) else { return }
            await session.deliver(r)
        }
    }

    func spawn(_ body: @escaping @Sendable () async -> Void) {
        let task = Task(executorPreference: scheduler.taskExecutor) { await body() }
        lock.withLock { $0.tasks.append(task) }
    }

    /// Waits until every task, including the ones they spawn, is done.
    func drain() async {
        while true {
            let batch: [Task<Void, Never>] = lock.withLock { s in
                let b = s.tasks
                s.tasks.removeAll()
                return b
            }
            if batch.isEmpty { return }
            for t in batch { await t.value }
        }
    }
}

public struct SystemRun: Sendable {
    public var outcome: Scheduler.Outcome
    public var records: [SystemModel.Record]
    public var ledger: LedgerModel?
    public var tellers: [Session]
    public var results: [[Out]]
    public var network: [String]
    public var trace: [String]
    public var choices: [Scheduler.Choice]
    public var refinement: (violation: SystemModel.Violation?, final: SystemModel)
}

/// One run of the composed system under `policy`: balance `bal`, each
/// teller its script (one request at a time, P5a: submit, wait for the
/// outcome, next), the network delaying by `delays` and faulting by
/// `faults`, the bridge with `bug` planted or not.
public func runSystem(bal: Int, scripts: [[TellerReq]], delays: Delays = Delays(), faults: Faults = Faults(),
                      bug: Bridge.Bug? = nil, policy: @escaping Scheduler.Policy, maxSteps: Int = 10_000) -> SystemRun {
    precondition(scripts.count == SystemModel.tellers)
    let scheduler = Scheduler()
    let steps = StepLog()
    let network = Network(scheduler: scheduler, delays: delays, faults: faults, bug: bug, steps: steps)
    let journal = Journal(executor: scheduler.serialExecutor("journal"))
    let audit = AuditStore(executor: scheduler.serialExecutor("audit"))
    let arrivals = ArrivalLog { [network, steps] m, state in
        steps.record(SystemModel.Record(.arrive(network.wireRequest(for: m)), ledger: state))
    }
    let ledger = LedgerService(executor: scheduler.serialExecutor("ledger"), accounts: [Bridge.acct], initial: bal,
                               journal: journal, log: arrivals)
    let tellers = SystemModel.tellerNames.enumerated().map { k, name in
        TellerSession(teller: name, executor: scheduler.serialExecutor(name), wire: network, audit: audit,
                      clock: scheduler.clock, timeout: .seconds(1), timers: scheduler.taskExecutor,
                      trace: Trace { [steps] r in
                          let step: Step
                          switch r.step {
                          case .submit(let req): step = .submit(k, req)
                          case .timeout: step = .timeout(k)
                          case .giveUp: step = .giveUp(k)
                          case .reply(let reply): step = .deliver(k, reply)
                          }
                          steps.record(SystemModel.Record(step, kind: r.kind, emitted: r.emitted, teller: r.state))
                      })
    }
    network.attach(ledger: ledger, tellers: Array(zip(SystemModel.tellerNames, tellers)))
    let box = Results(tellers.count)
    let outcome = scheduler.run(policy: policy, maxSteps: maxSteps) {
        await withTaskGroup(of: Void.self) { group in
            for (k, (t, script)) in zip(tellers, scripts).enumerated() {
                group.addTask(executorPreference: scheduler.taskExecutor) {
                    for r in script {
                        _ = await t.submit(r)
                        let out = await t.outcome()
                        box.append(k, out)
                    }
                }
            }
        }
        await network.drain()
        let l = await ledger.state
        var ts: [Session] = []
        for t in tellers { ts.append(await t.state) }
        box.finish(ledger: l, tellers: ts)
    }
    let records = steps.records
    return SystemRun(outcome: outcome, records: records, ledger: box.ledger, tellers: box.tellers, results: box.results,
                     network: network.log, trace: scheduler.trace, choices: scheduler.choices,
                     refinement: SystemModel.refines(records, bal: bal))
}

/// The run's results, written from the scheduler's jobs.
final class Results: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<(ledger: LedgerModel?, tellers: [Session], results: [[Out]])>
    init(_ n: Int) { lock = OSAllocatedUnfairLock(initialState: (nil, [], Array(repeating: [], count: n))) }
    func append(_ k: Int, _ out: Out) { lock.withLock { $0.results[k].append(out) } }
    func finish(ledger: LedgerModel, tellers: [Session]) { lock.withLock { $0.ledger = ledger; $0.tellers = tellers } }
    var ledger: LedgerModel? { lock.withLock { $0.ledger } }
    var tellers: [Session] { lock.withLock { $0.tellers } }
    var results: [[Out]] { lock.withLock { $0.results } }
}
