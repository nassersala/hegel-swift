import Testing
import Hegel
import HegelTesting
import Schedules

/// `concurrency-semantics.md`, Independence: adjacent events that neither
/// disable nor change one another's observations may be swapped, and
/// executions related by such swaps have the same partial-order meaning.
/// With semantic events in the trace the relation is concrete: two
/// events on different accounts are independent; two on the same
/// account are not. The normal form is the lexicographic one (Mazurkiewicz
/// traces): swap adjacent independent events into account order until no
/// swap applies. Two schedules are equivalent iff their event traces
/// have the same normal form.
enum Independence {
    /// An event step's subject, the first word after `event`.
    static func subject(_ step: Step) -> String? { step.kind == .event ? step.event.first : nil }

    static func independent(_ a: Step, _ b: Step) -> Bool {
        guard let x = subject(a), let y = subject(b) else { return false }
        return x != y
    }

    /// Lexicographic normal form of the event steps of a trace.
    static func normalForm(_ trace: [String]) -> [Step] {
        var events = Step.parse(trace).filter { $0.kind == .event }
        var swapped = true
        while swapped {
            swapped = false
            for i in events.indices.dropLast() where independent(events[i], events[i + 1]) && subject(events[i + 1])! < subject(events[i])! {
                events.swapAt(i, i + 1)
                swapped = true
            }
        }
        return events
    }
}

/// One withdrawal on each of three accounts that never touch each
/// other: every interleaving is one behaviour. (Two withdrawals on one
/// account are not: their `check`/`commit` values depend on the order,
/// and the relation says so — that variant of this fixture fails the
/// one-class property at the first deviation.)
func threeAccounts(_ policy: @escaping Scheduler.Policy) -> (Scheduler.Outcome, trace: [String]) {
    let scheduler = Scheduler()
    let a = Account(name: "A", balance: 100, executor: scheduler.serialExecutor("A"))
    let b = Account(name: "B", balance: 100, executor: scheduler.serialExecutor("B"))
    let c = Account(name: "C", balance: 100, executor: scheduler.serialExecutor("C"))
    let auditor = Auditor(executor: scheduler.serialExecutor("auditor"))
    let outcome = scheduler.run(policy: policy) {
        async let x = a.withdraw(30, auditedBy: auditor)
        async let y = b.withdraw(40, auditedBy: auditor)
        async let z = c.withdraw(20, auditedBy: auditor)
        _ = await (x, y, z)
    }
    return (outcome, scheduler.trace)
}

@Suite struct EquivalentSchedules {
    /// Every drawn schedule is the default schedule up to independent
    /// swaps: one equivalence class, however many distinct raw traces.
    @Test func independentAccountsMakeOneClass() throws {
        let canonical = Independence.normalForm(threeAccounts(Schedule().policy).trace)
        var raw = Set<[String]>(), classes = Set<[Step]>()
        try forAll(DrawnSchedules.schedules, testCases: 100, database: "") { schedule in
            let (outcome, trace) = threeAccounts(schedule.policy)
            guard case .completed = outcome else { throw ScheduleError.didNotComplete(outcome, trace) }
            let form = Independence.normalForm(trace)
            raw.insert(trace); classes.insert(form)
            if form != canonical { throw ScheduleError.notEquivalent(form, canonical) }
        }
        print("three accounts over 100 schedules: \(raw.count) distinct traces, \(classes.count) equivalence class")
        #expect(raw.count > 1)
        #expect(classes.count == 1)
    }

    /// Same-account events are dependent, so the racing and the default
    /// schedule on one account are different behaviours, not the same
    /// class: the relation does not erase the bug.
    @Test func dependentEventsStayOrdered() {
        let racing = Schedule(deviations: [.init(choice: 2, index: 0)])
        #expect(Independence.normalForm(twoWithdrawals(racing.policy).trace)
            != Independence.normalForm(twoWithdrawals(Schedule().policy).trace))
    }
}
