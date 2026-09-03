import Testing
import HegelTesting
import Schedules
import AboveTheCode

/// What the tester recovers of what the modal types gave. Six stream
/// functions on the tape under the controlled scheduler and its fake
/// clock; the relation in `Causal.swift` is what the later modality, the
/// box modality and guarded recursion would have said about each. Two
/// the types would accept refine under every drawn schedule; the four
/// they would refuse are each reported, and the report for the last one
/// is the gap: a step budget, not a verdict.
@Suite struct AboveCausal {
    struct Run {
        let outcome: Scheduler.Outcome
        let moments: [Causal.Moment]
        let outputs: [Int: Int]
        let choicePoints: Int
        var steps: Int {
            switch outcome {
            case .completed(let s, _), .stuck(let s): return s
            case .runaway: return Int.max
            }
        }
    }

    static func run(_ f: StreamFunction, inputs x: [Int], prefetch: Bool, policy: @escaping Scheduler.Policy,
                    maxSteps: Int = 10_000, waitsForTick: Bool = true) -> Run {
        let scheduler = Scheduler()
        let clock = scheduler.clock
        let tape = Tape()
        let outcome = scheduler.run(policy: policy, maxSteps: maxSteps) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await f.run(on: tape, ticks: x.count, waitsForTick: waitsForTick) }
                group.addTask { await drive(tape, inputs: x, prefetch: prefetch, clock: clock) }
            }
        }
        return Run(outcome: outcome, moments: tape.moments, outputs: tape.outputs, choicePoints: scheduler.choicePoints)
    }

    static func inputs(_ count: ClosedRange<UInt64>) -> Gen<[Int]> { array(of: Gen<Int>.int(in: 0...100), count: count) }

    static let schedules: Gen<Schedule> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...80), Gen<Int64>.int(in: 0...8))
            .map { Schedule.Deviation(choice: Int($0), index: Int($1)) },
        count: 0...6
    ).map(Schedule.init)

    static func cases(ticks: ClosedRange<UInt64>) -> Gen<(x: [Int], prefetch: Bool, schedule: Schedule)> {
        Hegel.zip(inputs(ticks), Gen<Bool>.bool, schedules).map { (x: $0, prefetch: $1, schedule: $2) }
    }

    struct DidNotComplete: Error { let outcome: Scheduler.Outcome }
    struct NotAStep: Error, CustomStringConvertible {
        let violation: Causal.Violation
        var description: String { "not a Next step: \(violation)" }
    }

    static func checkRefines(_ run: Run, window: Int) throws -> Causal {
        guard case .completed = run.outcome else { throw DidNotComplete(outcome: run.outcome) }
        let (violation, final) = Causal.refines(run.moments, window: window)
        if let violation { throw NotAStep(violation: violation) }
        return final
    }

    /// The two the types would accept: under every drawn schedule, with
    /// and without a source running ahead, every recorded moment is a
    /// step, the run completes, and every output is the reference.
    @Test(arguments: [StreamFunction.runningAverage, .movingAverage])
    func theTypedOnesRefineUnderEverySchedule(f: StreamFunction) throws {
        var maxChoices = 0
        try forAll(Self.cases(ticks: 1...6), testCases: 200, database: "") { x, prefetch, schedule in
            let run = Self.run(f, inputs: x, prefetch: prefetch, policy: schedule.policy)
            let final = try Self.checkRefines(run, window: f.window)
            #expect(final.emitted.count == x.count)
            for t in x.indices { #expect(run.outputs[t] == f.reference(x, at: t), "tick \(t) of \(x)") }
            maxChoices = max(maxChoices, run.choicePoints)
        }
        print("\(f): refines under 200 drawn schedules, up to \(maxChoices) choice points")
    }

    /// The finding of the first run, kept. As first written the functions
    /// advanced when their next input arrived, and the running average,
    /// which the types accept, was refused at step 2 under a source one
    /// ahead: it read tick 1 at tick 0. Advancing on the data is reading
    /// the future; advancing on the tick is the later modality. Found on
    /// the default schedule, at two ticks.
    @Test func advancingOnTheDataIsTheFuture() throws {
        do {
            try forAll(Self.cases(ticks: 1...6), seed: 1, database: "") { x, prefetch, schedule in
                let run = Self.run(.runningAverage, inputs: x, prefetch: prefetch, policy: schedule.policy, waitsForTick: false)
                _ = try Self.checkRefines(run, window: 0)
            }
            Issue.record("advancing on the data refined")
        } catch let failure as PropertyFailure {
            let (x, prefetch, minimal) = try replay(Self.cases(ticks: 1...6), blob: try #require(failure.failures.first?.reproduceBlob))
            let run = Self.run(.runningAverage, inputs: x, prefetch: prefetch, policy: minimal.policy, waitsForTick: false)
            let v = try #require(Causal.refines(run.moments, window: 0).violation)
            print("runningAverage advancing on the data, x = \(x), prefetch \(prefetch), \(minimal): \(v)")
            #expect(x.count == 2 && prefetch && minimal.deviations.isEmpty)
            #expect(v.moment == Causal.Moment(.read(1), at: 0))
        }
    }

    /// The later modality. The lookahead reads tick t + 1 to produce
    /// tick t. With the source one ahead, the read is served at tick t
    /// and the relation refuses it as the future; without, the read
    /// blocks, the clock ticks with no output for t, and the relation
    /// refuses the tick. Same bug, two reports, and which one depends on
    /// the environment, not on the function.
    @Test(.propertyTesting) func theLookaheadReadsTheFutureOrStallsTheTick() {
        var reports: Set<String> = []
        expectAll(Self.cases(ticks: 2...6), testCases: 200, database: "") { x, prefetch, schedule in
            let run = Self.run(.lookahead, inputs: x, prefetch: prefetch, policy: schedule.policy)
            let (violation, _) = Causal.refines(run.moments, window: StreamFunction.lookahead.window)
            let v = try #require(violation, "\(run.moments)")
            reports.insert(String(v.reason.prefix(prefetch ? 5 : 4)))
            if prefetch {
                #expect(v.reason.hasPrefix("reads tick"), "\(v)")
                #expect(v.moment.kind == .read(v.state.now + 1))
            } else {
                #expect(v.reason.hasSuffix("unproductive"), "\(v)")
                #expect(v.moment.kind == .tick)
            }
        }
        #expect(reports == ["reads", "tick"])
    }

    /// The box modality. The running average that keeps every sample
    /// declares window 0 and is refused at its second output, which
    /// holds tick 0 at tick 1. The shortest story is two ticks.
    @Test func keepingEverythingIsRefusedAtTheSecondOutput() throws {
        do {
            try forAll(Self.cases(ticks: 1...6), seed: 1, database: "") { x, prefetch, schedule in
                let run = Self.run(.keepsEverything, inputs: x, prefetch: prefetch, policy: schedule.policy)
                _ = try Self.checkRefines(run, window: StreamFunction.keepsEverything.window)
            }
            Issue.record("keepsEverything refined")
        } catch let failure as PropertyFailure {
            let (x, prefetch, minimal) = try replay(Self.cases(ticks: 1...6), blob: try #require(failure.failures.first?.reproduceBlob))
            let run = Self.run(.keepsEverything, inputs: x, prefetch: prefetch, policy: minimal.policy)
            let v = try #require(Causal.refines(run.moments, window: 0).violation)
            print("keepsEverything, x = \(x), prefetch \(prefetch), \(minimal): \(v)")
            #expect(x.count == 2)
            #expect(v.moment.kind == .emit(1, held: [0, 1]))
            #expect(v.reason.hasPrefix("holds tick 0 at tick 1"))
        }
    }

    /// Guarded recursion, first half. The function that waits at tick 1
    /// for an input that never comes idles; the fake clock fires only
    /// then, so the next tick is the first step the relation refuses:
    /// tick 2 with no output for tick 1. The run ends stuck, and the
    /// report came before that.
    @Test(.propertyTesting) func stallingIsRefusedAtTheNextTick() {
        expectAll(Self.cases(ticks: 3...6), testCases: 40, database: "") { x, prefetch, schedule in
            let run = Self.run(.stalls, inputs: x, prefetch: prefetch, policy: schedule.policy)
            if case .stuck = run.outcome {} else { Issue.record("expected stuck, got \(run.outcome)") }
            let v = try #require(Causal.refines(run.moments, window: 0).violation)
            #expect(v.moment == Causal.Moment(.tick, at: 1), "\(v)")
            #expect(v.reason.hasSuffix("unproductive"))
        }
    }

    /// Guarded recursion, second half, and the gap. The function that
    /// polls for that input never idles, so the clock never fires and
    /// no tick is ever refused: every recorded moment is a step. All the
    /// run can say is that the budget ran out, and no budget separates
    /// "not yet" from "never". The type checker would have said never.
    @Test(.propertyTesting) func spinningIsOnlyAStepBudget() {
        var budgets: [Int] = []
        expectAll(Self.cases(ticks: 2...6), testCases: 100, database: "") { x, prefetch, schedule in
            let good = Self.run(.runningAverage, inputs: x, prefetch: prefetch, policy: schedule.policy)
            let budget = good.steps * 4
            let run = Self.run(.spins, inputs: x, prefetch: prefetch, policy: schedule.policy, maxSteps: budget)
            #expect(run.outcome == .runaway, "\(run.outcome)")
            let (violation, final) = Causal.refines(run.moments, window: 0)
            #expect(violation == nil, "\(String(describing: violation))")
            #expect(final.now == 1 && final.emitted == [0], "\(final)")
            budgets.append(budget)
        }
        print("spins: runaway at every budget in \(budgets.min() ?? 0)...\(budgets.max() ?? 0) steps, no moment refused")
    }
}
