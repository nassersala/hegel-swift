import CHegel

/// One rule of a stateful test: a named state transition the engine can
/// choose. Like `Gen`, a rule is a witness — a value, not a conformance.
public struct Rule<State>: Sendable {
    public let name: String
    /// Whether the rule may run in the current state. A selected rule whose
    /// precondition fails is reported rejected (it doesn't count toward the
    /// step budget) and the engine picks again.
    public let precondition: @Sendable (State) -> Bool
    /// Performs the transition. Draw rule arguments from the `TestCase`;
    /// throw `HegelError.assume` to reject the drawn arguments, any other
    /// error to fail the property.
    public let step: @Sendable (inout State, TestCase) throws -> Void

    public init(
        _ name: String,
        precondition: @escaping @Sendable (State) -> Bool = { _ in true },
        step: @escaping @Sendable (inout State, TestCase) throws -> Void
    ) {
        self.name = name
        self.precondition = precondition
        self.step = step
    }
}

/// A named invariant, checked on the initial state and after every rule.
/// Throw to fail the property.
public struct Invariant<State>: Sendable {
    public let name: String
    public let check: @Sendable (State) throws -> Void

    public init(_ name: String, check: @escaping @Sendable (State) throws -> Void) {
        self.name = name
        self.check = check
    }
}

/// What one stateful test case did: the initial state (rendered before any
/// rule ran — note a reference-typed State shows its post-run content), the
/// executed rule sequence, and the violation (if any). This is the value
/// the shrinker minimizes — a failing run shrinks to the shortest rule
/// sequence (with the smallest draws) that still violates.
public struct StatefulRun<State>: CustomStringConvertible {
    public let initialDescription: String
    public let final: State
    public let steps: [String]
    public let violation: (any Error)?

    public var description: String {
        var lines = ["initial: \(initialDescription)"]
        lines.append(contentsOf: steps.map { "  \($0)" })
        if let violation { lines.append("violated: \(violation)") }
        return lines.joined(separator: "\n")
    }
}

/// Runs a stateful property: the engine picks which rule runs next (from
/// those whose preconditions hold), how many steps each case takes (up to
/// `Settings.statefulStepCount`, default 50), and shrinks failing runs to
/// a minimal rule sequence.
public func forAll<State>(
    initial: Gen<State>,
    rules: [Rule<State>],
    invariants: [Invariant<State>] = [],
    testCases: UInt64? = nil,
    seed: UInt64? = nil,
    database: String? = nil,
    settings: Settings = Settings(),
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    precondition(!rules.isEmpty, "stateful testing requires at least one rule")

    let machine = Gen<StatefulRun<State>> { tc in
        var steps: [String] = []
        var state = try initial.run(tc)
        let initialDescription = String(describing: state)

        var sm: OpaquePointer?
        try withCStringArray(rules.map(\.name)) { ruleNames, ruleCount in
            try withCStringArray(invariants.map(\.name)) { invariantNames, invariantCount in
                try check(
                    hegel_new_state_machine(
                        tc.ctx.raw, tc.raw,
                        ruleNames, ruleCount,
                        invariantNames, invariantCount,
                        &sm),
                    tc.ctx.lastError)
            }
        }
        defer { _ = hegel_state_machine_free(tc.ctx.raw, sm) }

        func checkInvariants() throws {
            for invariant in invariants {
                do { try invariant.check(state) } catch {
                    steps.append("invariant \(invariant.name) failed")
                    throw error
                }
            }
        }

        do {
            try checkInvariants()
            while true {
                var index: Int64 = 0
                try tc.call(hegel_state_machine_next_rule(tc.ctx.raw, tc.raw, sm, &index))
                if index == HEGEL_STATE_MACHINE_DONE { break }
                let rule = rules[Int(index)]

                guard rule.precondition(state) else {
                    try tc.call(hegel_state_machine_rule_rejected(tc.ctx.raw, tc.raw, sm))
                    continue
                }
                // Span the rule's draws so the shrinker deletes whole steps.
                try tc.call(hegel_start_span(
                    tc.ctx.raw, tc.raw, UInt64(HEGEL_LABEL_STATEFUL_RULE.rawValue)))
                do {
                    try rule.step(&state, tc)
                    _ = hegel_stop_span(tc.ctx.raw, tc.raw, false)
                } catch HegelError.assume {
                    // The rule rejected its drawn arguments: discard the
                    // span and tell the engine the step didn't count.
                    _ = hegel_stop_span(tc.ctx.raw, tc.raw, true)
                    try tc.call(hegel_state_machine_rule_rejected(tc.ctx.raw, tc.raw, sm))
                    continue
                } catch {
                    _ = hegel_stop_span(tc.ctx.raw, tc.raw, true)
                    steps.append("\(rule.name) failed")
                    throw error
                }
                steps.append(rule.name)
                try checkInvariants()
            }
        } catch HegelError.stopTest {
            throw HegelError.stopTest
        } catch HegelError.assume {
            throw HegelError.assume
        } catch {
            // A genuine violation: package it into the run's value so the
            // shrunk counterexample can display the offending rule trace.
            return StatefulRun(
                initialDescription: initialDescription, final: state,
                steps: steps, violation: error)
        }
        return StatefulRun(
            initialDescription: initialDescription, final: state,
            steps: steps, violation: nil)
    }

    try forAll(
        machine, testCases: testCases, seed: seed, database: database,
        settings: settings, origin: "\(file):\(line)",
        file: file, line: line
    ) { run in
        if let violation = run.violation { throw violation }
    }
}

// MARK: - Pools

/// An engine-managed pool of previously generated values: libhegel chooses
/// (and shrinks) which value a rule reuses, and the choice stays stable
/// while other additions shrink away. The classic use is model-based
/// testing where rules operate on objects earlier rules created.
///
/// Create one per test case (typically in the initial state or lazily in a
/// rule); drive it only from that test case's thread.
public final class Pool<Value> {
    private let ctx: Context
    private let raw: OpaquePointer
    private var values: [Int64: Value] = [:]

    /// Creates an empty pool on `testCase`.
    public init(_ testCase: TestCase) throws(HegelError) {
        var pool: OpaquePointer?
        try check(
            hegel_new_pool(testCase.ctx.raw, testCase.raw, &pool),
            testCase.ctx.lastError)
        self.ctx = testCase.ctx
        self.raw = pool!
    }

    deinit {
        _ = hegel_pool_free(ctx.raw, raw)
    }

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }

    /// Adds `value` to the pool.
    public func add(_ value: Value, _ testCase: TestCase) throws(HegelError) {
        var id: Int64 = 0
        try check(
            hegel_pool_add(testCase.ctx.raw, testCase.raw, raw, &id),
            testCase.ctx.lastError)
        values[id] = value
    }

    /// Draws one of the previously added values — the engine chooses which.
    /// An empty pool surfaces as `HegelError.assume` (the step/case is
    /// rejected), so guard rules with a precondition like `!pool.isEmpty`
    /// when that churn matters.
    public func draw(_ testCase: TestCase, consume: Bool = false) throws(HegelError) -> Value {
        var id: Int64 = 0
        try check(
            hegel_pool_generate(testCase.ctx.raw, testCase.raw, raw, consume, &id),
            testCase.ctx.lastError)
        guard let value = consume ? values.removeValue(forKey: id) : values[id] else {
            preconditionFailure("libhegel chose id \(id) which this pool never recorded")
        }
        return value
    }
}
