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

@Suite struct Confluence {
    static let redeliveries = array(of: Gen<Int>.int(in: 0...7), count: 0...3).map { Set($0) }

    /// Confluence as a schedule property: every drawn firing order, with
    /// drawn redeliveries, reaches the same fixpoint, the true order.
    @Test(.propertyTesting) func anyScheduleAnyRedeliveryOneFixpoint() {
        expectAll(Hegel.zip(OrderLattice.values, ParallelQuicksort.schedules, Self.redeliveries), database: "") { values, schedule, redeliver in
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
        try forAll(ParallelQuicksort.schedules, testCases: 50, database: "") { schedule in
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
}
