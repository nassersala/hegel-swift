import Foundation
import Testing
import HegelTesting
import Quicksort
import Schedules

@Suite struct OrderLattice {
    static let values = array(of: Gen<Int>.int(in: 0...5), count: 0...7)
    /// Arbitrary relations over 5 indices, sound or not: the lattice laws
    /// do not depend on soundness.
    static let orders: Gen<Order> = array(of: Hegel.zip(Gen<Int>.int(in: 0...4), Gen<Int>.int(in: 0...4)).map { Order.Pair($0, $1) }, count: 0...6)
        .map { Order(count: 5, pairs: Set($0)) }

    /// Join is a bounded semilattice, the CRDT contract.
    @Test(.propertyTesting) func joinIsASemilattice() {
        expectAll(Laws.semilattice(Self.orders, "join", { $0.join($1) }, identity: .bottom(5)), database: "")
    }

    /// Every propagator is sound and monotone: its fact is inside the true
    /// order, so joining it never leaves the true order.
    @Test(.propertyTesting) func propagatorsAreSoundAndMonotone() {
        expectAll(Self.values, database: "") { values in
            let truth = Order.of(values)
            for fact in Propagators.quicksort(values) + Propagators.mergesort(values) {
                let step = Order(count: values.count, pairs: fact)
                #expect(step <= truth)
                #expect(truth.join(step) == truth)
            }
        }
    }

    /// Both strategies reach the true order: the fixpoint is total and
    /// reads back as the sorted array.
    @Test(.propertyTesting) func bothStrategiesReachTheTrueOrder() {
        expectAll(Self.values, database: "") { values in
            for facts in [Propagators.quicksort(values), Propagators.mergesort(values)] {
                let fixpoint = facts.reduce(Order.bottom(values.count)) { $0.join(Order(count: values.count, pairs: $1)) }
                #expect(fixpoint == Order.of(values))
                #expect(fixpoint.isTotal)
                #expect(fixpoint.sorted(values) == values.sorted())
            }
        }
    }
}

/// The cell, under the controlled scheduler: one task per propagator,
/// the schedule drawn by hegel, some propagators fired twice.
actor Cell {
    let executor: ControlledSerialExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private(set) var order: Order
    private(set) var firings = 0
    init(count: Int, executor: ControlledSerialExecutor) { order = .bottom(count); self.executor = executor }
    func join(_ fact: Fact) { order = order.join(Order(count: order.count, pairs: fact)); firings += 1 }
}

func propagate(_ facts: [Fact], count: Int, redeliver: Set<Int> = [], policy: @escaping Scheduler.Policy) -> (Scheduler.Outcome, Order, firings: Int) {
    let scheduler = Scheduler()
    let cell = Cell(count: count, executor: scheduler.serialExecutor("cell"))
    let outcome = scheduler.run(policy: policy) {
        await withTaskGroup(of: Void.self) { group in
            for (i, fact) in facts.enumerated() {
                group.addTask { await cell.join(fact) }
                if redeliver.contains(i) { group.addTask { await cell.join(fact) } }
            }
        }
    }
    let box = SendableBox<(Order, Int)>((.bottom(count), 0))
    _ = scheduler.run(policy: Scheduler.fifo) { box.value = await (cell.order, cell.firings) }
    return (outcome, box.value.0, box.value.1)
}

extension Scheduled { @Suite struct Confluence {
    static let redeliveries = array(of: Gen<Int>.int(in: 0...7), count: 0...3).map { Set($0) }

    /// Confluence as a schedule property: every drawn firing order, with
    /// drawn redeliveries, reaches the same fixpoint, the true order.
    @Test(.propertyTesting) func anyScheduleAnyRedeliveryOneFixpoint() {
        expectAll(Hegel.zip(OrderLattice.values, Scheduled.ParallelQuicksort.schedules, Self.redeliveries), database: "") { values, schedule, redeliver in
            let (outcome, order, firings) = propagate(Propagators.quicksort(values), count: values.count, redeliver: redeliver, policy: schedule.policy)
            if case .completed = outcome {} else { Issue.record("\(outcome)") }
            #expect(order == Order.of(values))
            #expect(firings >= Propagators.quicksort(values).count)
        }
    }

    /// Different schedules do fire in different orders; the fixpoint does
    /// not notice.
    @Test func schedulesDifferFixpointDoesNot() throws {
        let values = [3, 1, 4, 1, 5, 9, 2, 6]
        var traces = Set<[String]>(), fixpoints = Set<Order>()
        try forAll(Scheduled.ParallelQuicksort.schedules, testCases: 50, database: "") { schedule in
            let scheduler = Scheduler()
            let cell = Cell(count: values.count, executor: scheduler.serialExecutor("cell"))
            let facts = Propagators.quicksort(values)
            _ = scheduler.run(policy: schedule.policy) {
                await withTaskGroup(of: Void.self) { group in for fact in facts { group.addTask { await cell.join(fact) } } }
            }
            traces.insert(scheduler.trace.filter { $0.hasPrefix("run") })
            let box = SendableBox<Order>(.bottom(values.count))
            _ = scheduler.run(policy: Scheduler.fifo) { box.value = await cell.order }
            fixpoints.insert(box.value)
        }
        print("propagator quicksort over 50 schedules: \(traces.count) distinct firing orders, \(fixpoints.count) fixpoint")
        #expect(traces.count > 1)
        #expect(fixpoints.count == 1)
    }
} }

// MARK: - The two halves meet

extension Scheduled { @Suite struct LamportOnTheLattice {
    /// Every behaviour of Lamport's relation, projected to facts, is a
    /// propagator run reaching a total order that reads back sorted —
    /// and equals the true order when values are distinct (ties are
    /// learned in one direction only, by the tag). The moving-data
    /// algorithm refines the knowledge-accumulating one.
    @Test(.propertyTesting) func everyLamportBehaviourIsAPropagatorRun() {
        let runs = OrderLattice.values.flatMap { values in
            Lamport.behaviour(Propagators.tagged(values)).map { (values, $0.steps) }
        }
        expectAll(runs, database: "") { values, steps in
            let n = values.count
            let facts = Propagators.facts(of: steps, count: n)
            let fixpoint = facts.reduce(Order.bottom(n)) { $0.join(Order(count: n, pairs: $1)) }
            let truth = Order.of(values)
            #expect(fixpoint <= truth)
            #expect(fixpoint.isTotal)
            if n > 0 { #expect(fixpoint.sorted(values) == values.sorted()) }
            if Set(values).count == n { #expect(fixpoint == truth) }
        }
    }

    /// The concrete Hoare quicksort and the parallel one too, under any
    /// schedule: same projection, same conclusion.
    @Test(.propertyTesting) func concreteQuicksortsProjectToTheLattice() {
        expectAll(Hegel.zip(OrderLattice.values, Scheduled.ParallelQuicksort.schedules), database: "") { values, schedule in
            let tagged = Propagators.tagged(values)
            for steps in [quicksort(tagged).steps, parallelQuicksort(tagged, policy: schedule.policy).steps] {
                let fixpoint = Propagators.facts(of: steps, count: values.count)
                    .reduce(Order.bottom(values.count)) { $0.join(Order(count: values.count, pairs: $1)) }
                #expect(fixpoint <= Order.of(values))
                #expect(fixpoint.isTotal)
            }
        }
    }
} }

// MARK: - Threshold reads and deadlock

/// A cell with threshold reads: `read(when:)` suspends until the order
/// satisfies the threshold. Continuations resume through the controlled
/// scheduler, so a schedule decides who wakes when.
actor ThresholdCell {
    let executor: ControlledSerialExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private(set) var order: Order
    private var waiters: [(threshold: @Sendable (Order) -> Bool, continuation: CheckedContinuation<Order, Never>)] = []
    init(count: Int, executor: ControlledSerialExecutor) { order = .bottom(count); self.executor = executor }

    func join(_ fact: Fact) {
        order = order.join(Order(count: order.count, pairs: fact))
        let ready = waiters.filter { $0.threshold(order) }
        waiters.removeAll { $0.threshold(order) }
        for w in ready { w.continuation.resume(returning: order) }
    }

    /// The check must be repeated inside the continuation body: the body
    /// runs as its own job on the actor, after the task has suspended, and
    /// another job (a `join`) can run in between. Checking only before
    /// suspending is a lost wakeup; hegel found it under the schedule
    /// "at choice point 4 run ready[1]; 6: ready[1]; 7: ready[1]" on
    /// `[0, 0, 0, 0, 0, 0]` (`Regression.lostWakeup`).
    func read(when threshold: @escaping @Sendable (Order) -> Bool) async -> Order {
        if threshold(order) { return order }
        return await withCheckedContinuation { continuation in
            if threshold(order) { continuation.resume(returning: order) } else { waiters.append((threshold, continuation)) }
        }
    }
}

/// Runs the threshold mergesort: one task per node, `dropping` nodes never
/// spawned (a lost propagator). Returns the outcome, the order, and the
/// comparison count.
func thresholdMergesort(_ values: [Int], dropping: Set<Int> = [], grace: Duration = .milliseconds(20), policy: @escaping Scheduler.Policy) -> (Scheduler.Outcome, Order, comparisons: Int) {
    let n = values.count
    let scheduler = Scheduler()
    let cell = ThresholdCell(count: n, executor: scheduler.serialExecutor("cell"))
    let comparisons = SendableBox(0)
    let nodes = MergeNode.tree(n)
    let outcome = scheduler.run(policy: policy, grace: grace) {
        await withTaskGroup(of: Void.self) { group in
            for (i, node) in nodes.enumerated() where !dropping.contains(i) {
                group.addTask {
                    let order = await cell.read { $0.isTotal(on: node.l) && $0.isTotal(on: node.r) }
                    let (fact, c) = node.merge(values, given: order)
                    comparisons.value += c
                    await cell.join(fact)
                }
            }
        }
    }
    let box = SendableBox<Order>(.bottom(n))
    _ = scheduler.run(policy: Scheduler.fifo) { box.value = await cell.order }
    return (outcome, box.value, comparisons.value)
}

extension Scheduled { @Suite struct ThresholdReads {
    static let values = array(of: Gen<Int>.int(in: 0...9), count: 2...16)

    /// With every node present: completes under every schedule, reaches a
    /// total order that reads back sorted, and costs at most n⌈log₂ n⌉
    /// comparisons — the threshold is what makes the merge cheap.
    @Test(.propertyTesting) func completesCheaplyUnderEverySchedule() {
        expectAll(Hegel.zip(Self.values, Scheduled.ParallelQuicksort.schedules), database: "") { values, schedule in
            let (outcome, order, comparisons) = thresholdMergesort(values, grace: .seconds(2), policy: schedule.policy)
            guard case .completed = outcome else { Issue.record("\(outcome), order total: \(order.isTotal)"); return }
            #expect(order <= Order.of(values))
            #expect(order.isTotal)
            #expect(order.sorted(values) == values.sorted())
            let n = values.count
            #expect(comparisons <= n * Int((Double(n)).log2().rounded(.up)))
        }
    }

    /// Drop one non-root node and every schedule deadlocks: its parent
    /// waits for a threshold nobody will reach. Liveness has a
    /// counterexample here and `.stuck` is it — the finite surrogate that
    /// `TemporalLogic` cannot express, and that TLC would prove absent
    /// under WF only with all propagators present. (Drop the root and
    /// nobody waits: the run completes with the order not total. hegel's
    /// first counterexample to "drop any node" was exactly `[0, 0]`, whose
    /// only node is the root.)
    @Test(.propertyTesting) func aLostPropagatorDeadlocks() {
        let cases = Self.values.filter { $0.count >= 3 }.flatMap { values in
            Gen<Int>.int(in: 1...(MergeNode.tree(values.count).count - 1)).map { (values, $0) }
        }
        expectAll(Hegel.zip(cases, Scheduled.ParallelQuicksort.schedules), testCases: 60, database: "") { pair, schedule in
            let (values, dropped) = pair
            let (outcome, order, _) = thresholdMergesort(values, dropping: [dropped], policy: schedule.policy)
            if case .stuck = outcome {} else { Issue.record("expected .stuck, got \(outcome)") }
            #expect(!order.isTotal)
        }
    }

    /// Drop the root: no one is waiting on it, so the run completes, and
    /// what it knows is exactly the two halves, each total, never joined.
    @Test func droppingTheRootCompletesWithoutKnowing() {
        let values = [3, 1, 4, 1, 5, 9, 2, 6]
        let (outcome, order, _) = thresholdMergesort(values, dropping: [0], policy: Scheduler.fifo)
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        #expect(!order.isTotal)
        #expect(order.isTotal(on: [0, 1, 2, 3]) && order.isTotal(on: [4, 5, 6, 7]))
    }
} }

extension Double { func log2() -> Double { Foundation.log2(self) } }
