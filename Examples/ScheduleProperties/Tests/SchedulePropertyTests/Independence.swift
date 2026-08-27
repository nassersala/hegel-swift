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
    static func normalForm(_ trace: [String]) -> [Step] { normalForm(events: Step.parse(trace).filter { $0.kind == .event }) }

    static func normalForm(events: [Step]) -> [Step] {
        var events = events
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

    /// Semantic shrinking, layer 5, as a post-pass on the report: the
    /// events that are dependent on the violating one (here: the same
    /// subject; the relation is subject-based, so the closure is one
    /// step). Everything else is outside the causal cone and is dropped
    /// from the explanation, not from the replayed trace.
    static func causalCone(of violation: Step, in events: [Step]) -> [Step] {
        events.filter { !independent($0, violation) }
    }
}

/// The failing event trace explained: its causal cone in normal form,
/// with the count of independent events left out. Operational
/// minimality stays what the shrinker achieved; this is presentation.
struct Explanation: CustomStringConvertible {
    let cone: [Step]
    let dropped: Int
    init(violation: TemporalViolation) {
        let events = violation.steps.filter { $0.kind == .event }
        let cone = Independence.causalCone(of: violation.steps[violation.step], in: events)
        self.cone = Independence.normalForm(events: cone)
        dropped = events.count - cone.count
    }
    var description: String {
        "causal cone (\(dropped) independent events dropped):\n" + cone.map { "  \($0)" }.joined(separator: "\n")
    }
}

/// A withdrawal and a transfer racing on A, a credit landing on B, and
/// an unrelated withdrawal on C: dependence on A, noise on B and C.
func transferRace(_ policy: @escaping Scheduler.Policy) -> (Scheduler.Outcome, trace: [String]) {
    let scheduler = Scheduler()
    let a = Account(name: "A", balance: 100, executor: scheduler.serialExecutor("A"))
    let b = Account(name: "B", balance: 100, executor: scheduler.serialExecutor("B"))
    let c = Account(name: "C", balance: 100, executor: scheduler.serialExecutor("C"))
    let auditor = Auditor(executor: scheduler.serialExecutor("auditor"))
    let outcome = scheduler.run(policy: policy) {
        async let x = a.withdraw(100, auditedBy: auditor)
        async let y = a.transfer(100, to: b, auditedBy: auditor)
        async let z = c.withdraw(10, auditedBy: auditor)
        _ = await (x, y, z)
    }
    return (outcome, scheduler.trace)
}

@Suite struct CausalExplanation {
    /// The transfer race is found by the solvency formula; the
    /// explanation is the A events only, B's credit and C's withdrawal
    /// dropped, while the replayed trace keeps them.
    @Test func theExplanationIsTheCausalCone() throws {
        do {
            try forAll(DrawnSchedules.schedules, seed: 3, database: "") { schedule in
                let (outcome, trace) = transferRace(schedule.policy)
                guard case .completed = outcome else { throw ScheduleError.didNotComplete(outcome, trace) }
                try check("G(✓commit ⇒ balance ≥ 0)", DrawnSchedules.solvent, over: trace)
            }
            Issue.record("the transfer race was not found")
        } catch let failure as PropertyFailure {
            let minimal = try replay(DrawnSchedules.schedules, blob: try #require(failure.failures.first?.reproduceBlob))
            let (_, trace) = transferRace(minimal.policy)
            do {
                try check("G(✓commit ⇒ balance ≥ 0)", DrawnSchedules.solvent, over: trace)
                Issue.record("the minimal schedule does not fail")
            } catch let violation as TemporalViolation {
                let explanation = Explanation(violation: violation)
                print("minimal schedule: \(minimal)\n\(explanation)")
                #expect(explanation.cone.allSatisfy { Independence.subject($0) == "A" })
                #expect(explanation.cone.map { $0.event.dropFirst().first! } == ["check", "check", "commit", "commit"])
                #expect(explanation.dropped == 3)  // B credit, C check, C commit
                #expect(Step.parse(trace).contains { Independence.subject($0) == "C" })
            }
        }
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

/// What the shrunk schedule's minimality is, in the spec's words
/// (`concurrency-semantics.md`, Schedule generation and Semantic
/// shrinking): generated vs consumed deviations, and whether the failing
/// event trace is its class representative. Operational minimality is
/// what hegel's shrinker achieves; causal minimality is not claimed.
struct Minimality: CustomStringConvertible {
    let generated: Int
    let consumed: Int
    let choicePoints: Int
    let isRepresentative: Bool

    init(_ schedule: Schedule, run: (@escaping Scheduler.Policy) -> (Scheduler, trace: [String])) {
        let (scheduler, trace) = run(schedule.policy)
        generated = schedule.deviations.count
        choicePoints = scheduler.choicePoints
        consumed = schedule.deviations.filter { $0.choice < scheduler.choicePoints }.count
        let events = Step.parse(trace).filter { $0.kind == .event }
        isRepresentative = events == Independence.normalForm(trace)
    }

    var description: String {
        "minimality: operational (fewest deviations); \(consumed) of \(generated) deviations consumed over \(choicePoints) choice points; "
            + (isRepresentative ? "event trace is its class representative" : "event trace is not in normal form")
    }
}
