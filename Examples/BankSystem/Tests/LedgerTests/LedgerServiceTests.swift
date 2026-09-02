import Testing
import Hegel
import HegelTesting
import Schedules
import Ledger

/// Step 6: the service as code, recorded at one arrival, replayed against
/// the relation. The synchronous core first; then the actor under drawn
/// schedules, with the classic bug planted (skill 6a) and removed.
@Suite struct LedgerServiceRefinement {
    /// The synchronous core: one call is one arrival, every consecutive
    /// pair of recorded states is a Next_L step, the reply is `out`.
    @Test(.propertyTesting) func theCoreRefinesTheRelation() {
        expectAll(Scenario.gen(), database: "") { s in
            var core = LedgerCore(accounts: s.accounts, initial: s.b0)
            var recorded: [(arrival: Request, state: LedgerModel)] = []
            for m in s.arrivals {
                let rep = core.handle(m)
                #expect(rep == core.model.out)
                recorded.append((m, core.model))
            }
            let (violation, final) = LedgerModel.refines(recorded, from: s.initial)
            #expect(violation == nil, "\(violation!)")
            #expect(final == core.model)
        }
    }

    // MARK: The actor under drawn schedules

    struct Run {
        let outcome: Scheduler.Outcome
        let recorded: [(arrival: Request, state: LedgerModel)]
        let replies: [Request: Set<Rep>]
        let final: LedgerModel?
        let journal: [String]
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// Every arrival as its own task, the order of arrival and of every
    /// suspension the schedule's choice.
    static func deliver(_ s: Scenario, _ policy: @escaping Scheduler.Policy, journalBeforeCommit: Bool) -> Run {
        let scheduler = Scheduler()
        let log = ArrivalLog()
        let journal = Journal(executor: scheduler.serialExecutor("journal"))
        let ledger = LedgerService(executor: scheduler.serialExecutor("ledger"), accounts: s.accounts, initial: s.b0,
                                   journal: journal, log: log, journalBeforeCommit: journalBeforeCommit)
        let replies = Box<[Request: Set<Rep>]>([:])
        let final = Box<LedgerModel?>(nil)
        let lines = Box<[String]>([])
        let arrivals = s.arrivals
        let outcome = scheduler.run(policy: policy) {
            await withTaskGroup(of: (Request, Rep?).self) { group in
                for m in arrivals { group.addTask { (m, await ledger.handle(m)) } }
                for await (m, rep) in group { if let rep { replies.value[m, default: []].insert(rep) } }
            }
            final.value = await ledger.state
            lines.value = await journal.lines
        }
        return Run(outcome: outcome, recorded: log.entries, replies: replies.value, final: final.value, journal: lines.value)
    }

    static let schedules: Gen<Schedule> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...40), Gen<Int64>.int(in: 0...7))
            .map { Schedule.Deviation(choice: Int($0), index: Int($1)) },
        count: 0...6
    ).map(Schedule.init)

    /// Small traces so the schedule space is small: up to two requests per
    /// teller, each delivered up to twice.
    static let inputs: Gen<(Scenario, Schedule)> =
        Hegel.zip(Scenario.gen(requestsPerTeller: 0...2, copies: 0...2), schedules)

    struct DidNotComplete: Error { let outcome: Scheduler.Outcome }

    static func checkRefines(_ s: Scenario, _ run: Run) throws -> LedgerModel {
        guard case .completed = run.outcome else { throw DidNotComplete(outcome: run.outcome) }
        let (violation, final) = LedgerModel.refines(run.recorded, from: s.initial)
        if let violation { throw violation }
        return final
    }

    /// Check and commit as one synchronous step: the actor refines the
    /// relation under every drawn schedule, its final state is the last
    /// recorded one, every copy of a request got one reply, the same one.
    @Test func theActorRefinesUnderEverySchedule() throws {
        var runs = 0
        try forAll(Self.inputs, testCases: 300, database: "") { s, schedule in
            let run = Self.deliver(s, schedule.policy, journalBeforeCommit: false)
            let final = try Self.checkRefines(s, run)
            #expect(run.final == final)
            #expect(run.recorded.count == s.arrivals.count)
            #expect(run.journal.count == s.arrivals.count)
            for (m, reps) in run.replies { #expect(reps.count == 1 && reps.first == final.seen[m.id]) }
            runs += 1
        }
        print("actor refines: \(runs) runs")
    }

    /// The planted bug: an await between `i ∉ dom seen` and the commit.
    /// Some schedule runs a copy's check while the first copy is at the
    /// journal; both commit; the second commit is not a step of Next_L
    /// (Again leaves bal unchanged; the code debited again). The shrunk
    /// input is the smallest: one request delivered twice, one deviation.
    @Test func awaitBetweenCheckAndCommitIsNotAStep() throws {
        do {
            try forAll(Self.inputs, seed: 1, database: "") { s, schedule in
                _ = try Self.checkRefines(s, Self.deliver(s, schedule.policy, journalBeforeCommit: true))
            }
            Issue.record("the suspension was never exploited")
        } catch let failure as PropertyFailure {
            let (s, schedule) = try replay(Self.inputs, blob: try #require(failure.failures.first?.reproduceBlob))
            let run = Self.deliver(s, schedule.policy, journalBeforeCommit: true)
            let (violation, _) = LedgerModel.refines(run.recorded, from: s.initial)
            print("planted await, \(s), schedule \(schedule):\n  recorded \(run.recorded.map { "\($0.arrival) → \($0.state)" }.joined(separator: "; "))\n  \(violation.map(\.description) ?? "no violation")")
            #expect(schedule.deviations.count == 1)
            #expect(s.arrivals.count == 2)
            #expect(s.arrivals[0].id == s.arrivals[1].id)
            #expect(violation?.index == 1)
            #expect(violation?.recorded.seen.count == 1 && violation?.expected.bal == violation?.before.bal)
        }
    }

    /// The same bug with the drawing's numbers: balance 10, wd 4 twice
    /// under t·1, the copy debited again to 2 where the relation says 6.
    @Test func drawingFUnderThePlantedAwait() throws {
        let m = Request(Id("t", 1), "a", .withdraw(4))
        let s = Scenario(accounts: ["a"], b0: 10, honest: [m], arrivals: [m, m])
        var witness: (Schedule, Run)?
        try forAll(Self.schedules, testCases: 100, database: "") { schedule in
            let run = Self.deliver(s, schedule.policy, journalBeforeCommit: true)
            if witness == nil, run.final?.bal["a"] == 2 { witness = (schedule, run) }
        }
        let (schedule, run) = try #require(witness)
        print("drawing F with the await: schedule \(schedule); final \(run.final!); replies \(run.replies)")
        #expect(run.final?.seen[Id("t", 1)] == .ok(2))
        let (violation, _) = LedgerModel.refines(run.recorded, from: s.initial)
        #expect(violation?.index == 1)
        #expect(violation?.expected.bal["a"] == 6)
        // And without the await, no schedule reaches it.
        try forAll(Self.schedules, testCases: 100, database: "") { schedule in
            let run = Self.deliver(s, schedule.policy, journalBeforeCommit: false)
            let final = try Self.checkRefines(s, run)
            #expect(final.bal["a"] == 6)
            #expect(run.replies[m] == [.ok(6)])
        }
    }
}
