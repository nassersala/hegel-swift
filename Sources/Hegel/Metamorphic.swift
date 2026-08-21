/// Metamorphic testing: properties for code that has no oracle.
///
/// When you cannot say what `f(x)` should be, you can often say how `f`
/// must respond to a *change* of `x`: `sin(180 - x) == sin(x)`, a larger
/// twilight angle gives an earlier fajr, a filter with one more term returns
/// a subset. Chen, Cheung and Yiu (1998) called such a statement a
/// *metamorphic relation* (MR). The vocabulary used here is theirs, as
/// restated in Chen & Tse, "New Visions on Metamorphic Testing after a
/// Quarter of a Century of Inception" (ESEC/FSE 2021):
///
/// - the **source** input `x` and its output `f(x)`;
/// - the **follow-up** input `x'`, derived from `x` by the relation's
///   transform, and its output `f(x')`;
/// - the pair is a **metamorphic group**; the relation holds or is violated
///   for the group.
///
/// Here an MR is a value — a `Relation` — in the same witness style as
/// `Gen` and `Rule`: a name, a follow-up transform that may draw from the
/// `TestCase`, and a check over the group. `forAll(source:relations:subject:)`
/// draws a source input and one relation per test case (so the shrinker
/// also minimizes *which* relation), runs the subject on both inputs, and
/// on violation reports the minimal group: source, follow-up, both outputs.
/// Whatever the follow-up transform drew (an angle increment, a shift) is
/// part of the choice sequence and shrinks with everything else.
///
/// Composition of relations — a chain of follow-ups checked against the
/// original — is the stateful machine: rules as transforms, an invariant as
/// the relation. Nothing extra is needed for that.
public struct Relation<Input, Output>: Sendable {
    public let name: String
    /// Derives the follow-up input from the source. May draw relation
    /// parameters from the `TestCase`; throw `HegelError.assume` to reject a
    /// source the relation does not apply to (the case is INVALID, not a
    /// failure).
    public let followUp: @Sendable (Input, TestCase) throws -> Input
    /// The relation over the metamorphic group, in the order
    /// `(source, f(source), followUp, f(followUp))`. Throw to report a
    /// violation.
    public let relates: @Sendable (Input, Output, Input, Output) throws -> Void

    /// A relation stated over the whole group: inputs and outputs.
    public init(
        _ name: String,
        followUp: @escaping @Sendable (Input, TestCase) throws -> Input,
        relates: @escaping @Sendable (Input, Output, Input, Output) throws -> Void
    ) {
        self.name = name
        self.followUp = followUp
        self.relates = relates
    }

    /// A relation stated over the two outputs only, `(f(source), f(followUp))`
    /// — the common case.
    public init(
        _ name: String,
        followUp: @escaping @Sendable (Input, TestCase) throws -> Input,
        holds: @escaping @Sendable (Output, Output) throws -> Void
    ) {
        self.init(name, followUp: followUp) { _, sourceOutput, _, followUpOutput in
            try holds(sourceOutput, followUpOutput)
        }
    }
}

/// Thrown by the relation patterns below, and available for your own
/// relations: a violation with a message that lands in the failure report.
public struct RelationViolated: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// The direction of a monotone relation.
public enum Monotonicity: Sendable {
    /// `value(f(followUp)) >= value(f(source))`
    case nonDecreasing
    /// `value(f(followUp)) <= value(f(source))`
    case nonIncreasing
}

// MARK: - Relation patterns

extension Relation where Output: Equatable & SendableMetatype {
    /// The *symmetry* pattern (Zhou, Sun, Chen, Towey, TSE 2020): the output
    /// does not change under the follow-up transform. `sort(shuffle(xs)) ==
    /// sort(xs)`, `distance(a, b) == distance(b, a)`.
    public static func invariant(
        _ name: String,
        under followUp: @escaping @Sendable (Input, TestCase) throws -> Input
    ) -> Relation {
        Relation(name, followUp: followUp) { a, b in
            guard a == b else { throw RelationViolated("outputs differ") }
        }
    }
}

extension Relation {
    /// The *change direction* pattern: some comparable aspect of the output
    /// moves one way (or stays) under the follow-up transform. "A larger
    /// fajr angle gives an earlier (or equal) fajr" is
    /// `.monotone("…", followUp: …, \.fajr, .nonIncreasing)`.
    public static func monotone<V: Comparable & SendableMetatype>(
        _ name: String,
        followUp: @escaping @Sendable (Input, TestCase) throws -> Input,
        _ value: @escaping @Sendable (Output) -> V,
        _ direction: Monotonicity
    ) -> Relation {
        Relation(name, followUp: followUp) { a, b in
            let (va, vb) = (value(a), value(b))
            switch direction {
            case .nonDecreasing:
                guard vb >= va else {
                    throw RelationViolated("expected non-decreasing, got \(va) then \(vb)")
                }
            case .nonIncreasing:
                guard vb <= va else {
                    throw RelationViolated("expected non-increasing, got \(va) then \(vb)")
                }
            }
        }
    }
}

// MARK: - Groups

/// One execution of a relation: the metamorphic group plus its verdict.
/// This is the value the shrinker minimizes, and what a failure displays.
/// Outputs are `nil` when the subject threw before producing them; the
/// follow-up is `nil` when the source execution already failed.
public struct MetamorphicGroup<Input, Output>: CustomStringConvertible {
    public let relation: String
    public let source: Input
    public let sourceOutput: Output?
    public let followUp: Input?
    public let followUpOutput: Output?
    public let violation: (any Error)?

    public var description: String {
        func show<T>(_ value: T?) -> String {
            value.map { String(describing: $0) } ?? "<none: subject threw>"
        }
        var lines = ["relation: \(relation)"]
        lines.append("  source:       \(source)")
        lines.append("  follow-up:    \(show(followUp))")
        lines.append("  f(source):    \(show(sourceOutput))")
        lines.append("  f(follow-up): \(show(followUpOutput))")
        if let violation { lines.append("violated: \(violation)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Runner

/// Checks metamorphic relations of `subject` over generated source inputs.
///
/// Per test case: draw a source from `source`, draw one of `relations`,
/// compute `subject(source)`, derive the follow-up, compute
/// `subject(followUp)`, and check the relation. A violation shrinks to the
/// minimal metamorphic group — smallest source, smallest relation parameters,
/// first-listed violating relation — displayed as source, follow-up, and both
/// outputs.
///
/// `HegelError.assume` thrown anywhere (the source generator, the subject,
/// the follow-up transform) rejects the case. Any other error thrown by the
/// subject is a violation: a subject that crashes on an input it accepted
/// for the source, or on a follow-up it should accept, is a finding.
public func forAll<Input, Output>(
    source: Gen<Input>,
    relations: [Relation<Input, Output>],
    testCases: UInt64? = nil,
    seed: UInt64? = nil,
    database: String? = nil,
    settings: Settings = Settings(),
    file: StaticString = #fileID,
    line: UInt = #line,
    subject: @escaping @Sendable (Input) throws -> Output
) throws {
    precondition(!relations.isEmpty, "metamorphic testing requires at least one relation")

    let groups = Gen<MetamorphicGroup<Input, Output>> { tc in
        let x = try source.run(tc)
        // One relation per case, chosen by the engine: diversity across the
        // run for free, and the choice shrinks toward the first relation.
        let relation = relations.count == 1
            ? relations[0]
            : relations[Int(try tc.drawInteger(in: 0...Int64(relations.count - 1)))]

        var fx: Output?
        var x2: Input?
        var fx2: Output?
        func group(_ violation: (any Error)?) -> MetamorphicGroup<Input, Output> {
            MetamorphicGroup(
                relation: relation.name, source: x, sourceOutput: fx,
                followUp: x2, followUpOutput: fx2, violation: violation)
        }
        do {
            let sourceOutput = try subject(x)
            fx = sourceOutput
            let followUp = try relation.followUp(x, tc)
            x2 = followUp
            let followUpOutput = try subject(followUp)
            fx2 = followUpOutput
            try relation.relates(x, sourceOutput, followUp, followUpOutput)
        } catch HegelError.stopTest {
            throw HegelError.stopTest
        } catch HegelError.assume {
            throw HegelError.assume
        } catch {
            return group(error)
        }
        return group(nil)
    }

    try forAll(
        groups, testCases: testCases, seed: seed, database: database,
        settings: settings, origin: "\(file):\(line)",
        file: file, line: line
    ) { group in
        if let violation = group.violation { throw violation }
    }
}
