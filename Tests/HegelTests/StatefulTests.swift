import Testing
@testable import Hegel

private struct CounterViolation: Error {}

@Suite struct StatefulTests {
    /// Preconditions gate rule selection: with "dec" guarded by `count > 0`,
    /// the count can never go negative no matter what the engine schedules.
    @Test func preconditionsGateRules() throws {
        try forAll(
            initial: Gen<Int> { _ in 0 },
            rules: [
                Rule("inc") { state, _ in state += 1 },
                Rule("dec", precondition: { $0 > 0 }) { state, _ in state -= 1 },
            ],
            invariants: [
                Invariant("non-negative") { state in
                    if state < 0 { throw CounterViolation() }
                }
            ],
            database: "")
    }

    /// Rules draw their own arguments, and HegelError.assume inside a step
    /// rejects just that step (it must not fail the property or count as a
    /// transition).
    @Test func assumeInsideARuleRejectsTheStep() throws {
        try forAll(
            initial: Gen<Int64> { _ in 0 },
            rules: [
                Rule("addEven") { state, tc in
                    let n = try tc.drawInteger(in: Int64(0)...10)
                    guard n % 2 == 0 else { throw HegelError.assume }
                    state += n
                }
            ],
            invariants: [
                Invariant("even") { state in
                    if state % 2 != 0 { throw CounterViolation() }
                }
            ],
            database: "")
    }

    /// The step budget is respected: with statefulStepCount 5, no run
    /// executes more than 5 rules.
    @Test func stepCountBoundsRuleExecutions() throws {
        try forAll(
            initial: Gen<Int> { _ in 0 },
            rules: [Rule("inc") { state, _ in state += 1 }],
            invariants: [
                Invariant("within budget") { state in
                    if state > 5 { throw CounterViolation() }
                }
            ],
            database: "",
            settings: Settings(statefulStepCount: 5))
    }

    /// End-to-end stateful shrinking against a known minimum: "count == 3
    /// violates" must shrink to exactly three incs and no decs, shown in
    /// the counterexample's rule trace.
    @Test func failingRunShrinksToMinimalRuleSequence() throws {
        do {
            try forAll(
                initial: Gen<Int> { _ in 0 },
                rules: [
                    Rule("inc") { state, _ in state += 1 },
                    Rule("dec", precondition: { $0 > 0 }) { state, _ in state -= 1 },
                ],
                invariants: [
                    Invariant("never three") { state in
                        if state == 3 { throw CounterViolation() }
                    }
                ],
                testCases: 300,
                database: "")
            Issue.record("property should have failed")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            #expect(trace.contains("initial: 0"))
            #expect(trace.components(separatedBy: "inc").count - 1 == 3)
            #expect(!trace.contains("dec"))
            #expect(trace.contains("invariant never three failed"))
        }
    }

    /// Pools: the engine picks which previously created value a rule
    /// reuses, and the binding's id-to-value bookkeeping stays consistent
    /// (drawn values were really created; consumed values don't come back).
    @Test func poolsHandOutOnlyLiveValues() throws {
        struct PoolState {
            var pool: Pool<Int64>
            var live: [Int64: Int] = [:]  // value -> live copies
        }
        struct PoolViolation: Error {}

        try forAll(
            initial: Gen<PoolState> { tc in PoolState(pool: try Pool(tc)) },
            rules: [
                Rule("create") { state, tc in
                    let value = try tc.drawInteger(in: Int64(0)...1000)
                    try state.pool.add(value, tc)
                    state.live[value, default: 0] += 1
                },
                Rule("borrow", precondition: { !$0.pool.isEmpty }) { state, tc in
                    let value = try state.pool.draw(tc)
                    guard state.live[value, default: 0] > 0 else { throw PoolViolation() }
                },
                Rule("consume", precondition: { !$0.pool.isEmpty }) { state, tc in
                    let value = try state.pool.draw(tc, consume: true)
                    guard let n = state.live[value], n > 0 else { throw PoolViolation() }
                    state.live[value] = n - 1
                },
            ],
            database: "")
    }

    /// The displayed counterexample is the violating run, not a replay
    /// truncated at the default step count: a violation reachable only
    /// after 80 steps under `statefulStepCount: 200` must print with its
    /// `violated:` line and all its steps. (It used to replay the blob under
    /// default settings, overrun at 50 steps, and show a passing run.)
    @Test func counterexampleBeyondTheDefaultStepCountShowsItsViolation() throws {
        struct TooMany: Error {}
        do {
            try forAll(
                initial: .constant(0),
                rules: [Rule("inc") { n, _ in n += 1 }],
                invariants: [Invariant("n < 80") { n in if n >= 80 { throw TooMany() } }],
                testCases: 300, seed: 1, database: "",
                settings: Settings(statefulStepCount: 200))
            Issue.record("expected the property to fail")
        } catch let failure as PropertyFailure {
            let shown = try #require(failure.failures.first?.counterexample)
            #expect(shown.contains("violated: TooMany()"))
            #expect(shown.split(separator: "\n").filter { $0.hasSuffix("inc") }.count == 80)
        }
    }
}
