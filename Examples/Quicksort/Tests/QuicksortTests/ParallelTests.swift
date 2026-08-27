import Testing
import HegelTesting
import Quicksort
import Schedules

/// The worklist quicksort with one task per range: `U` is the set of
/// live tasks, and "pick any range" is the scheduler's choice of which
/// task runs next. Partitions happen inside one actor, so the controlled
/// scheduler serializes them; what varies with the schedule is their
/// order, which is what the relation is about. (Physical parallelism of
/// the writes is out of scope, as `concurrency-semantics.md` says.)
actor Sorter {
    let executor: ControlledSerialExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private(set) var a: [Int]
    private(set) var steps: [Lamport.Step] = []

    init(_ a: [Int], executor: ControlledSerialExecutor) {
        self.a = a
        self.executor = executor
    }

    /// Hoare partition of `r`, recorded; `nil` for a one-element range.
    func partition(_ r: Lamport.Range) -> Int? {
        guard r.b < r.t else { steps.append(.drop(r)); return nil }
        let pivot = a[(r.b + r.t) / 2]
        var i = r.b - 1, j = r.t + 1
        while true {
            repeat { i += 1 } while a[i] < pivot
            repeat { j -= 1 } while a[j] > pivot
            if i >= j { steps.append(.partition(r, p: j, after: Array(a[r.b...r.t]))); return j }
            a.swapAt(i, j)
        }
    }
}

func parallelQuicksort(_ input: [Int], policy: @escaping Scheduler.Policy) -> (outcome: Scheduler.Outcome, sorted: [Int], steps: [Lamport.Step]) {
    let scheduler = Scheduler()
    let sorter = Sorter(input, executor: scheduler.serialExecutor("sorter"))
    let outcome = scheduler.run(policy: policy) {
        guard !input.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            @Sendable func sort(_ r: Lamport.Range, _ group: inout TaskGroup<Void>) {
                group.addTask {
                    guard let p = await sorter.partition(r) else { return }
                    await withTaskGroup(of: Void.self) { inner in
                        sort(Lamport.Range(r.b, p), &inner)
                        sort(Lamport.Range(p + 1, r.t), &inner)
                    }
                }
            }
            sort(Lamport.Range(0, input.count - 1), &group)
        }
    }
    // The result is read after `run` returns; the actor is quiescent.
    let box = SendableBox<([Int], [Lamport.Step])>(([], []))
    _ = scheduler.run(policy: Scheduler.fifo) { box.value = await (sorter.a, sorter.steps) }
    return (outcome, box.value.0, box.value.1)
}

final class SendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Two steps are independent iff their ranges are disjoint: they touch
/// disjoint slices of `A` and different elements of `U`. A child's range
/// is inside its parent's, so parent before child is kept.
enum RangeIndependence {
    static func range(_ s: Lamport.Step) -> Lamport.Range {
        switch s { case .partition(let r, _, _): return r; case .drop(let r): return r }
    }
    static func independent(_ x: Lamport.Step, _ y: Lamport.Step) -> Bool {
        let r = range(x), s = range(y)
        return r.t < s.b || s.t < r.b
    }
    /// Lexicographic normal form: swap adjacent independent steps into
    /// range order until nothing moves.
    static func normalForm(_ steps: [Lamport.Step]) -> [Lamport.Step] {
        var steps = steps
        var swapped = true
        while swapped {
            swapped = false
            for i in steps.indices.dropLast() where independent(steps[i], steps[i + 1]) && range(steps[i + 1]) < range(steps[i]) {
                steps.swapAt(i, i + 1)
                swapped = true
            }
        }
        return steps
    }
}

@Suite struct ParallelQuicksort {
    static let arrays = array(of: Gen<Int>.int(in: 0...9), count: 2...8)
    static let schedules: Gen<Schedule> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...40), Gen<Int64>.int(in: 0...7))
            .map { Schedule.Deviation(choice: Int($0), index: Int($1)) },
        count: 0...8
    ).map(Schedule.init)

    /// Every schedule's step sequence is a behaviour of the relation.
    @Test(.propertyTesting) func everyScheduleRefinesTheRelation() {
        expectAll(Hegel.zip(Self.arrays, Self.schedules), database: "") { a, schedule in
            let (outcome, sorted, steps) = parallelQuicksort(a, policy: schedule.policy)
            if case .completed = outcome {} else { Issue.record("\(outcome)") }
            let (violation, final) = Lamport.refines(steps, from: a)
            #expect(violation == nil, "\(String(describing: violation))")
            #expect(final.done)
            #expect(sorted == a.sorted())
        }
    }

    /// Schedules differ in the order of partitions on disjoint ranges,
    /// and in nothing else: many step sequences, one equivalence class,
    /// which is also the recursive quicksort's behaviour.
    @Test func schedulesAreOneClass() throws {
        let a = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3]
        var raw = Set<[Lamport.Step]>(), classes = Set<[Lamport.Step]>()
        try forAll(Self.schedules, testCases: 100, database: "") { schedule in
            let steps = parallelQuicksort(a, policy: schedule.policy).steps
            raw.insert(steps)
            classes.insert(RangeIndependence.normalForm(steps))
        }
        print("parallel quicksort over 100 schedules: \(raw.count) distinct step sequences, \(classes.count) class")
        #expect(raw.count > 1)
        #expect(classes.count == 1)
        #expect(classes.first == RangeIndependence.normalForm(quicksort(a).steps))
    }
}
