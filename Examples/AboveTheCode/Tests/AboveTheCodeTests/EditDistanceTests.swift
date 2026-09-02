import Testing
import Hegel
import HegelTesting
import Schedules
import AboveTheCode
import os

/// Edit distance as a relation over the order cells become known, checked
/// against a reference that does not use the recurrence, and three
/// refinements: the memoized recursion, the table, and a task per cell.
@Suite struct EditDistanceAboveTheCode {
    static let strings: Gen<String> = array(of: Gen<Character>.element(of: ["a", "b", "c"]), count: 0...4).map { String($0) }
    static let inputs: Gen<(String, String)> = Hegel.zip(strings, strings)

    /// The relation's own property: every drawn step enabled, Inv through
    /// every choice, every behaviour done in exactly (m+1)(n+1) steps with
    /// the reference's distance, and every cell the distance of the
    /// prefixes it names.
    @Test(.propertyTesting) func everyBehaviourGivesTheReferenceDistance() {
        expectAll(Self.inputs.flatMap { ab in EditModel.behaviour(ab.0, ab.1).map { (ab, $0) } }, database: "") { ab, run in
            let (a, b) = ab
            var s = EditModel(a, b)
            #expect(s.invariant)
            for step in run.steps {
                #expect(s.enabled(step))
                s.apply(step)
                #expect(s.invariant)
            }
            #expect(run.final.done)
            #expect(run.steps.count == run.final.cellCount)
            #expect(run.final.answer == editDistanceBySearch(a, b))
            for (c, v) in run.final.d {
                #expect(v == editDistanceBySearch(String(a.prefix(c.i)), String(b.prefix(c.j))), "\(c)")
            }
        }
    }

    /// The recursion and the table are the same steps, and in the written
    /// call order (up, left, diagonal) the recursion's post-order is
    /// row-major: the two traces are equal, not only equal as sets.
    @Test(.propertyTesting) func memoizedAndTableRefineTheRelation() {
        expectAll(Self.inputs, database: "") { a, b in
            let reference = editDistanceBySearch(a, b)
            var traces: [[EditModel.Step]] = []
            for compute in [editDistanceMemoized, editDistanceTable] {
                var recorded: [EditModel.Step] = []
                let distance = compute(a, b) { recorded.append($0) }
                let (violation, final) = EditModel.refines(recorded, from: a, b)
                #expect(violation == nil, "\(String(describing: violation))")
                #expect(final.done)
                #expect(final.answer == distance)
                #expect(distance == reference)
                #expect(recorded.count == final.cellCount)
                traces.append(recorded)
            }
            #expect(traces[0] == traces[1])
        }
    }

    // MARK: Under the controlled scheduler

    /// A serial executor to hop to: an `await` that is a suspension and an
    /// enqueue under the scheduler, planted between a cell's read and its
    /// write.
    actor Hopper {
        let executor: ControlledSerialExecutor
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        init(executor: ControlledSerialExecutor) { self.executor = executor }
        func hop() {}
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    struct Run {
        let outcome: Scheduler.Outcome
        let distance: Int
        let steps: [EditModel.Step]
        let choicePoints: Int
    }

    static func run(_ a: String, _ b: String, waits: CellWaits, hop: Bool, policy: @escaping Scheduler.Policy) -> Run {
        let scheduler = Scheduler()
        let hopper = Hopper(executor: scheduler.serialExecutor("hopper"))
        let result = Box<(distance: Int, steps: [EditModel.Step])>((0, []))
        let planted: (@Sendable () async -> Void)? = hop ? { @Sendable in await hopper.hop() } : nil
        let outcome = scheduler.run(policy: policy) {
            let r = await parallelEditDistance(a, b, waits: waits, hop: planted)
            result.value = (r.distance, r.steps)
        }
        return Run(outcome: outcome, distance: result.value.distance, steps: result.value.steps,
                   choicePoints: scheduler.choicePoints)
    }

    static let schedules: Gen<Schedule> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...120), Gen<Int64>.int(in: 0...25))
            .map { Schedule.Deviation(choice: Int($0), index: Int($1)) },
        count: 0...10
    ).map(Schedule.init)

    static let inputsAndSchedules: Gen<(String, String, Schedule)> = Hegel.zip(strings, strings, schedules)

    struct DidNotComplete: Error { let outcome: Scheduler.Outcome }
    struct NotAStep: Error, CustomStringConvertible {
        let violation: EditModel.Violation
        var description: String { "not a Next step: \(violation)" }
    }

    static func checkRefines(_ run: Run, _ a: String, _ b: String) throws -> EditModel {
        guard case .completed = run.outcome else { throw DidNotComplete(outcome: run.outcome) }
        let (violation, final) = EditModel.refines(run.steps, from: a, b)
        if let violation { throw NotAStep(violation: violation) }
        return final
    }

    /// Waiting for every predecessor, or for the two the relation says
    /// suffice, refines under every drawn schedule, with or without a
    /// suspension between the read and the write. The split of one step
    /// into a read and a write is harmless because a written cell never
    /// changes; what a task read stays what the relation would read.
    @Test func waitingForThePredecessorsRefinesUnderEverySchedule() throws {
        for (waits, hop) in [(CellWaits.all, false), (.all, true), (.orthogonal, false), (.orthogonal, true)] {
            var maxChoices = 0
            try forAll(Self.inputsAndSchedules, testCases: 200, database: "") { a, b, schedule in
                let run = Self.run(a, b, waits: waits, hop: hop, policy: schedule.policy)
                let final = try Self.checkRefines(run, a, b)
                #expect(final.done)
                #expect(run.distance == editDistanceBySearch(a, b))
                #expect(run.steps.count == final.cellCount)
                maxChoices = max(maxChoices, run.choicePoints)
            }
            print("waits \(waits) hop \(hop): refines under 200 drawn schedules, up to \(maxChoices) choice points")
        }
    }

    /// Under the default schedule alone the planted bug passes: the
    /// depth-first default visits the cells row-major, and row-major is
    /// the one order in which "the cell to my left is done" holds.
    @Test(.propertyTesting) func theDefaultScheduleHidesTheBug() {
        expectAll(Self.inputs, database: "") { a, b in
            let run = Self.run(a, b, waits: .upOnly, hop: false, policy: Schedule().policy)
            let final = try Self.checkRefines(run, a, b)
            #expect(final.done)
            #expect(run.distance == editDistanceBySearch(a, b))
        }
    }

    /// Drawn schedules find it: the shortest input and the fewest
    /// deviations at which a cell is written while the cell to its left is
    /// not known. The refinement reports that step as not a step, before
    /// the distance is compared.
    @Test func waitingForTheRowAboveOnlyIsNotAStep() throws {
        do {
            try forAll(Self.inputsAndSchedules, seed: 1, database: "") { a, b, schedule in
                _ = try Self.checkRefines(Self.run(a, b, waits: .upOnly, hop: false, policy: schedule.policy), a, b)
            }
            Issue.record("the missing wait was never exploited")
        } catch let failure as PropertyFailure {
            let (a, b, minimal) = try replay(Self.inputsAndSchedules, blob: try #require(failure.failures.first?.reproduceBlob))
            let run = Self.run(a, b, waits: .upOnly, hop: false, policy: minimal.policy)
            let (violation, _) = EditModel.refines(run.steps, from: a, b)
            print("upOnly, a = \"\(a)\", b = \"\(b)\", schedule \(minimal): steps \(run.steps.map(\.description).joined(separator: ", ")); \(violation.map(\.description) ?? "refines"); distance \(run.distance), reference \(editDistanceBySearch(a, b))")
            let v = try #require(violation)
            #expect(minimal.deviations.count == 1)
            #expect(a.isEmpty)
            #expect(b.count == 1)
            #expect(v.reason == "predecessor (0,0) not known")
        }
    }

    /// Off the scheduler, on the real pool: the same code, the same check.
    @Test func onTheRealPoolItRefines() async {
        for (a, b) in [("", ""), ("kitten", "sitting"), ("abc", "cab"), ("", "abcd"), ("aaaa", "aa")] {
            let (distance, steps) = await parallelEditDistance(a, b)
            let (violation, final) = EditModel.refines(steps, from: a, b)
            #expect(violation == nil, "\(String(describing: violation))")
            #expect(final.done)
            #expect(distance == editDistanceBySearch(a, b))
            #expect(distance == editDistanceTable(a, b))
        }
    }
}
