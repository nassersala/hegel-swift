import Schedules
import os

// The code: a ledger actor and two teller actors exchanging messages
// through an in-memory network that delivers in any order (each delivery
// is its own task, so the order is the scheduler's choice) and loses
// nothing. Instrumented at the granularity of one `Next_2` step: the
// stepping actor records the step and its own state after it,
// synchronously, before any suspension.

public final class StepLog: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [Race.Record]())
    public init() {}
    func record(_ r: Race.Record) { lock.withLock { $0.append(r) } }
    public var records: [Race.Record] { lock.withLock { $0 } }
}

/// Per-message delay on the fake clock, by send index. Delay is not a step
/// of the relation (arrival picks any message); here it is what lets a
/// teller's timeout fire before its reply is back.
public struct Delays: Sendable, Equatable, CustomStringConvertible {
    public var ticks: [Int: Int]
    public init(_ ticks: [Int: Int] = [:]) { self.ticks = ticks }
    public var description: String {
        ticks.isEmpty ? "no delays" : ticks.sorted { $0.key < $1.key }.map { "message \($0.key) delayed \($0.value)" }.joined(separator: "; ")
    }
}

public protocol Node: Actor {
    func receive(_ m: Msg) async
}

public actor Network {
    public nonisolated let executor: ControlledSerialExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    let scheduler: Scheduler
    let delays: Delays
    private var sent = 0
    private var tasks: [Task<Void, Never>] = []
    public private(set) var log: [String] = []

    public init(scheduler: Scheduler, delays: Delays) {
        executor = scheduler.serialExecutor("net")
        self.scheduler = scheduler
        self.delays = delays
    }

    public func send(_ m: Msg, to node: any Node) {
        let index = sent
        sent += 1
        let delay = delays.ticks[index] ?? 0
        log.append("\(index): \(m)\(delay > 0 ? " delayed \(delay)" : "")")
        let clock = scheduler.clock
        spawn {
            if delay > 0 { try? await clock.sleep(for: .seconds(delay)) }
            await node.receive(m)
        }
    }

    public func spawn(_ body: @escaping @Sendable () async -> Void) {
        tasks.append(Task(executorPreference: scheduler.taskExecutor) { await body() })
    }

    public func drain() async {
        while !tasks.isEmpty {
            let batch = tasks
            tasks.removeAll()
            for t in batch { await t.value }
        }
    }
}

/// Something the ledger talks to on another lane: the suspension the
/// planted bug puts between the check and the debit.
public actor Audit {
    public nonisolated let executor: ControlledSerialExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    public private(set) var lines: [String] = []
    init(scheduler: Scheduler) { executor = scheduler.serialExecutor("audit") }
    func record(_ line: String) { lines.append(line) }
}

public actor Ledger: Node {
    public nonisolated let executor: ControlledSerialExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    public private(set) var bal: Int
    public private(set) var seen: [Id: Rep] = [:]
    let network: Network
    let audit: Audit
    let log: StepLog
    /// The planted bug: `await` between the overdraft check and the debit.
    let awaitInsideStep: Bool
    var tellers: [Teller] = []

    init(bal: Int, scheduler: Scheduler, network: Network, audit: Audit, log: StepLog, awaitInsideStep: Bool) {
        executor = scheduler.serialExecutor("ledger")
        self.bal = bal
        self.network = network
        self.audit = audit
        self.log = log
        self.awaitInsideStep = awaitInsideStep
    }

    func attach(_ tellers: [Teller]) { self.tellers = tellers }

    /// One `Arrive` step: Apply or Again, the reply put on the wire.
    public func receive(_ m: Msg) async {
        guard case .request(let i, let r) = m else { return }
        let out: Rep
        if let stored = seen[i] {
            out = stored
        } else {
            let (b, rep) = meaning(r, bal)               // the check, on the balance now
            if awaitInsideStep { await audit.record("checked \(i) \(r) at \(bal)") }
            bal = b                                       // the debit, on the balance checked
            seen[i] = rep
            out = rep
        }
        log.record(Race.Record(.arrive(m), bal: bal, reply: out))
        await network.send(.reply(i, out), to: tellers[i.teller])
        if !awaitInsideStep { await audit.record("applied \(i) \(r) → \(bal)") }
    }
}

public actor Teller: Node {
    public nonisolated let executor: ControlledSerialExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    public nonisolated let k: Int
    public private(set) var state = TellerState()
    let network: Network
    let scheduler: Scheduler
    let log: StepLog
    let timeout: Duration
    var ledger: Ledger?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(k: Int, scheduler: Scheduler, network: Network, log: StepLog, timeout: Duration = .seconds(1)) {
        self.k = k
        executor = scheduler.serialExecutor("t\(k)")
        self.scheduler = scheduler
        self.network = network
        self.log = log
        self.timeout = timeout
    }

    func attach(_ ledger: Ledger) { self.ledger = ledger }

    /// The script, one request at a time (P5a): submit, then wait until
    /// `pend = –` before the next.
    func run(_ script: [Req]) async {
        for r in script {
            await submit(r)
            await settled()
        }
    }

    /// `Submit`: one step, then the copy goes on the wire and a timer starts.
    func submit(_ r: Req) async {
        precondition(state.pend == nil)
        state.pend = r; state.seq += 1; state.tries = 1; state.out = .none
        log.record(Race.Record(.submit(k, r), teller: state))
        await network.send(.request(Id(k, state.seq), r), to: ledger!)
        await startTimer(for: state.seq)
    }

    /// The timer is a network task so `drain` waits for it: a run ends
    /// only when every timer has fired, a stale one returning at once.
    private func startTimer(for seq: Int) async {
        let clock = scheduler.clock, timeout = timeout
        await network.spawn { [self] in
            try? await clock.sleep(for: timeout)
            await self.fire(seq)
        }
    }

    /// `Timeout` while tries < K, `GiveUp` at tries = K (P4b).
    func fire(_ seq: Int) async {
        guard let pend = state.pend, state.seq == seq else { return }
        if state.tries < Race.K {
            state.tries += 1
            log.record(Race.Record(.timeout(k), teller: state))
            await network.send(.request(Id(k, seq), pend), to: ledger!)
            await startTimer(for: seq)
        } else {
            state.pend = nil; state.tries = 0; state.out = .unknown
            log.record(Race.Record(.giveUp(k), teller: state))
            wake()
        }
    }

    /// `Deliver_k`: Take when it is the pending request's reply, else Ignore.
    public func receive(_ m: Msg) {
        guard case .reply(let i, let rep) = m else { return }
        if state.pend != nil && i == Id(k, state.seq) {
            state.pend = nil; state.tries = 0; state.out = .rep(rep)
            log.record(Race.Record(.deliver(k, m), teller: state))
            wake()
        } else {
            log.record(Race.Record(.deliver(k, m), teller: state))
        }
    }

    private func wake() {
        let ws = waiters; waiters = []
        for w in ws { w.resume() }
    }

    /// Registers and re-checks inside the continuation (the lost-wakeup shape).
    private func settled() async {
        await withCheckedContinuation { c in
            if state.pend == nil { c.resume() } else { waiters.append(c) }
        }
    }
}

public struct SystemRun: Sendable {
    public var outcome: Scheduler.Outcome
    public var records: [Race.Record]
    public var bal: Int
    public var tellers: [TellerState]
    public var network: [String]
    public var trace: [String]
    public var choices: [Scheduler.Choice]
    public var gaveUp: [Bool] { (0..<Race.tellers).map { k in records.contains { $0.step == .giveUp(k) } } }
    public var refinement: (violation: Race.Violation?, final: Race)
}

/// One run of the system under `policy`: balance `bal`, each teller its
/// script, the network delaying by `delays`.
public func runSystem(bal: Int, scripts: [[Req]], delays: Delays = Delays(), awaitInsideStep: Bool = false,
                      policy: @escaping Scheduler.Policy, maxSteps: Int = 10_000) -> SystemRun {
    precondition(scripts.count == Race.tellers)
    let scheduler = Scheduler()
    let log = StepLog()
    let network = Network(scheduler: scheduler, delays: delays)
    let audit = Audit(scheduler: scheduler)
    let ledger = Ledger(bal: bal, scheduler: scheduler, network: network, audit: audit, log: log, awaitInsideStep: awaitInsideStep)
    let tellers = (0..<Race.tellers).map { Teller(k: $0, scheduler: scheduler, network: network, log: log) }
    let outcome = scheduler.run(policy: policy, maxSteps: maxSteps) {
        await ledger.attach(tellers)
        for t in tellers { await t.attach(ledger) }
        for (t, script) in zip(tellers, scripts) { await network.spawn { await t.run(script) } }
        await network.drain()
    }
    let trace = scheduler.trace, choices = scheduler.choices
    final class Box: @unchecked Sendable { var bal = 0; var tellers: [TellerState] = []; var net: [String] = [] }
    let box = Box()
    _ = scheduler.run(policy: Scheduler.fifo) {
        box.bal = await ledger.bal
        for t in tellers { box.tellers.append(await t.state) }
        box.net = await network.log
    }
    let records = log.records
    return SystemRun(outcome: outcome, records: records, bal: box.bal, tellers: box.tellers, network: box.net,
                     trace: trace, choices: choices, refinement: Race.refines(records, bal: bal))
}
