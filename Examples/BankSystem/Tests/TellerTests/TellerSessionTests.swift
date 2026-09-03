import Testing
import Hegel
import HegelTesting
import Schedules
import os
@testable import Teller

/// Step 6 and 6a: the actor under drawn schedules. The drawn input is a
/// scenario (requests, what the network does to each copy, stray replies)
/// and a schedule; the check is that every recorded state pair is a
/// `Next_T` step with the recorded emission.
@Suite struct TellerSessionUnderSchedules {
    struct Copy: Sendable, CustomStringConvertible {
        let dropped: Bool
        let delay: Int
        let duplicated: Bool
        var description: String { dropped ? "drop" : "\(delay)s\(duplicated ? " ×2" : "")" }
    }
    struct Stray: Sendable, CustomStringConvertible {
        let delay: Int
        let id: Id
        var description: String { "\(id) at \(delay)s" }
    }
    /// The network's script: copy k on the wire gets `copies[k mod n]`.
    struct Scenario: Sendable, CustomStringConvertible {
        let requests: [Req]
        let copies: [Copy]
        let strays: [Stray]
        var description: String { "requests \(requests), copies \(copies), strays \(strays)" }
    }

    static let scenarios: Gen<Scenario> = Gen { tc in
        let requests = try tc.drawCollection(count: 1...2) { () -> Req in
            let n = Int(try tc.drawInteger(in: Int64(1)...9))
            return try tc.drawBool() ? .wd(n) : .dep(n)
        }
        let copies = try tc.drawCollection(count: 1...4) {
            Copy(dropped: try tc.drawBool(probability: 0.3), delay: Int(try tc.drawInteger(in: Int64(0)...3)),
                 duplicated: try tc.drawBool(probability: 0.2))
        }
        let strays = try tc.drawCollection(count: 0...2) {
            Stray(delay: Int(try tc.drawInteger(in: Int64(0)...3)),
                  id: Id(teller: try tc.drawBool(probability: 0.2) ? "u" : "t", n: Int(try tc.drawInteger(in: Int64(0)...3))))
        }
        return Scenario(requests: requests, copies: copies, strays: strays)
    }

    static let schedules: Gen<Schedule> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...40), Gen<Int64>.int(in: 0...7))
            .map { Schedule.Deviation(choice: Int($0), index: Int($1)) },
        count: 0...8
    ).map(Schedule.init)

    static let inputs: Gen<(Scenario, Schedule)> = Hegel.zip(scenarios, schedules)

    /// The audit store on its own lane, so a call is a suspension.
    actor AuditLog: Audit {
        let executor: ControlledSerialExecutor
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        private(set) var lines: [String] = []
        init(executor: ControlledSerialExecutor) { self.executor = executor }
        func record(_ line: String) { lines.append(line) }
    }

    /// The lossy network with a stand-in ledger behind it (copies do not
    /// count twice, so a copy gets the stored reply). Not the Ledger
    /// component: it only makes replies for the teller to take.
    final class Net: Wire, @unchecked Sendable {
        struct State {
            var session: TellerSession?
            var sent: [Request] = []
            var seen: [Id: Rep] = [:]
            var bal = 10
        }
        private let lock = OSAllocatedUnfairLock(initialState: State())
        let scenario: Scenario
        let clock: FakeClock
        let taskExecutor: ControlledTaskExecutor

        init(scenario: Scenario, clock: FakeClock, taskExecutor: ControlledTaskExecutor) {
            self.scenario = scenario
            self.clock = clock
            self.taskExecutor = taskExecutor
        }

        func attach(_ session: TellerSession) { lock.withLock { $0.session = session } }
        var sent: [Request] { lock.withLock { $0.sent } }

        func send(_ q: Request) {
            let (copy, reply, session): (Copy, Reply, TellerSession?) = lock.withLock { s in
                let copy = scenario.copies[s.sent.count % scenario.copies.count]
                s.sent.append(q)
                let rep: Rep
                if let r = s.seen[q.id] {
                    rep = r
                } else {
                    switch q.req {
                    case .dep(let n): s.bal += n; rep = .ok(s.bal)
                    case .wd(let n) where n <= s.bal: s.bal -= n; rep = .ok(s.bal)
                    case .wd: rep = .refused(s.bal)
                    }
                    s.seen[q.id] = rep
                }
                return (copy, Reply(id: q.id, rep: rep), s.session)
            }
            guard !copy.dropped, let session else { return }
            for _ in 0..<(copy.duplicated ? 2 : 1) { deliver(reply, after: copy.delay, to: session) }
        }

        func startStrays() {
            guard let session = lock.withLock({ $0.session }) else { return }
            for stray in scenario.strays {
                deliver(Reply(id: stray.id, rep: .ok(0)), after: stray.delay, to: session)
            }
        }

        private func deliver(_ reply: Reply, after delay: Int, to session: TellerSession) {
            Task(executorPreference: taskExecutor) { [clock] in
                try? await clock.sleep(for: .seconds(delay))
                await session.deliver(reply)
            }
        }
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    struct Run {
        let outcome: Scheduler.Outcome
        let records: [Session.Record]
        let sent: [Request]
        let results: [Out]
    }

    static func run(_ scenario: Scenario, _ schedule: Schedule, bug: TellerSession.Bug?) -> Run {
        let scheduler = Scheduler()
        let net = Net(scenario: scenario, clock: scheduler.clock, taskExecutor: scheduler.taskExecutor)
        let audit = AuditLog(executor: scheduler.serialExecutor("audit"))
        let session = TellerSession(teller: "t", executor: scheduler.serialExecutor("teller"), wire: net, audit: audit,
                                    clock: scheduler.clock, timeout: .seconds(1), timers: scheduler.taskExecutor, bug: bug)
        net.attach(session)
        let results = Box<[Out]>([])
        let outcome = scheduler.run(policy: schedule.policy) {
            net.startStrays()
            for r in scenario.requests {
                _ = await session.submit(r)
                results.value.append(await session.outcome())
            }
        }
        return Run(outcome: outcome, records: session.trace.records, sent: net.sent, results: results.value)
    }

    struct DidNotComplete: Error { let outcome: Scheduler.Outcome }

    static func checkRefines(_ run: Run) throws -> Session {
        guard case .completed = run.outcome else { throw DidNotComplete(outcome: run.outcome) }
        let (violation, final) = Session.refines(run.records, from: Session(teller: "t"))
        if let violation { throw violation }
        return final
    }

    /// The step-whole session refines the relation under every drawn
    /// scenario and schedule: the run completes, every recorded pair is
    /// a step, the bound formula holds on the recorded trace, a request
    /// ends taken or unknown, unknown only after exactly K copies.
    @Test func refinesUnderEveryDrawnScenarioAndSchedule() throws {
        try forAll(Self.inputs, testCases: 300, database: "") { scenario, schedule in
            let run = Self.run(scenario, schedule, bug: nil)
            let final = try Self.checkRefines(run)
            #expect(final.pend == nil)
            #expect(run.results.count == scenario.requests.count)
            let trace = [Session.Moment(kind: nil, state: Session(teller: "t"))]
                + run.records.map { Session.Moment(kind: $0.kind, state: $0.state) }
            #expect(evaluate(Session.bound, over: trace))
            for (j, result) in run.results.enumerated() {
                let copies = run.sent.filter { $0.id == Id(teller: "t", n: j + 1) }
                #expect(copies.count <= Session.K)
                #expect(copies.allSatisfy { $0.req == scenario.requests[j] })
                switch result {
                case .none: Issue.record("request \(j + 1) ended with no outcome")
                case .unknown: #expect(copies.count == Session.K)
                case .taken(let rep):
                    #expect(run.records.contains { $0.kind == .take && $0.step == .reply(Reply(id: Id(teller: "t", n: j + 1), rep: rep)) })
                }
            }
        }
    }

    /// The planted bug in the timer: check, then the audit write, then
    /// the resend. Predicted: a reply taken in the gap leaves `pend = –`
    /// and the resend is a Timeout at a state where none is enabled. The
    /// shrinker found a shorter one at one deviation: the reply is taken
    /// and the next request submitted in the gap, and the resend puts a
    /// copy of the old request on the wire while counting it as a try of
    /// the new one; the relation emits `q(t·2, r)`, the code `q(t·1, r)`.
    @Test func awaitBetweenTimeoutCheckAndResendIsNotAStep() throws {
        let (scenario, schedule, run) = try Self.shrunkFailure(bug: .awaitBeforeResend)
        let (violation, _) = Session.refines(run.records, from: Session(teller: "t"))
        let v = try #require(violation)
        print("await before resend, \(scenario); \(schedule): \(run.records.map(\.description).joined(separator: " ")); first non-step: \(v)")
        #expect(schedule.deviations.count == 1)
        #expect(v.record.kind == .timeout)
        #expect(v.before.pend == nil || v.record.emitted?.id != v.before.pendingId)
    }

    /// The planted bug in the inbox: match the identity, then the audit
    /// write, then the commit. Found at one deviation with a duplicated
    /// reply: both copies match `t·1`, the first is taken and the next
    /// request submitted in the gap, and the second copy's commit answers
    /// request `t·2` with request `t·1`'s reply. The relation says Ignore,
    /// the code says Take.
    @Test func awaitBetweenIdentityCheckAndTakeIsNotAStep() throws {
        let (scenario, schedule, run) = try Self.shrunkFailure(bug: .awaitBeforeTake)
        let (violation, _) = Session.refines(run.records, from: Session(teller: "t"))
        let v = try #require(violation)
        print("await before take, \(scenario); \(schedule): \(run.records.map(\.description).joined(separator: " ")); first non-step: \(v)")
        #expect(schedule.deviations.count == 1)
        #expect(v.record.kind == .take)
        #expect(v.before.kind(of: v.record.step) == .ignore)
    }

    static func shrunkFailure(bug: TellerSession.Bug) throws -> (Scenario, Schedule, Run) {
        do {
            try forAll(Self.inputs, testCases: 500, seed: 4, database: "") { scenario, schedule in
                _ = try Self.checkRefines(Self.run(scenario, schedule, bug: bug))
            }
            throw NotFound()
        } catch let failure as PropertyFailure {
            let (scenario, schedule) = try replay(Self.inputs, blob: try #require(failure.failures.first?.reproduceBlob))
            return (scenario, schedule, Self.run(scenario, schedule, bug: bug))
        }
    }
    struct NotFound: Error {}
}
