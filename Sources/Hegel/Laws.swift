/// Laws: algebraic, conformance and categorical properties as named,
/// runnable suites.
///
/// The oldest property-based tests are laws — QuickCheck's first examples
/// were monoid and functor laws. A law here is a metamorphic relation with
/// more than one input: associativity relates three inputs' outputs,
/// `map(id) == id` is "transform the program, output unchanged". `Relation`
/// is the one-follow-up case; `Law` is the n-input case with a name, and
/// `Laws` is the catalog: `Laws.monoid`, `Laws.hashable`, `Laws.lens`, …
///
/// Design, in the order it matters:
///
/// - **Witnesses, not protocols.** Operations are closures (`op`,
///   `identity`, `get`/`set`), exactly as `Gen` is passed. There is no
///   "Lawful" protocol. Where a stdlib protocol supplies the operation
///   (`Equatable`, `Comparable`, `Collection`) the suite is generic over it
///   and needs only the generator.
/// - **Every comparison takes an equality witness**, `equal:`, defaulting
///   to `==` where the carrier is `Equatable`. For floating-point carriers
///   pass the library's own approximate equality (swift-numerics'
///   `isApproximatelyEqual`); there is no tolerance policy of ours.
/// - **One run per law.** `forAll(_ suite:)` runs each law as its own
///   `forAll` with the full `testCases` budget, its own shrink and its own
///   database entry, origin `file:line [suite/law]`. Two violated laws are
///   two distinct bugs in the report, and every law runs — it does not stop
///   at the first.
/// - **Each law owns its generator.** Laws in one suite have different
///   arities and different premise biases; a reflexivity failure shows
///   `a`, a transitivity failure `[a, b, c]`.
/// - **Premises are the caller's knowledge.** `a == b ⇒ hash(a) == hash(b)`
///   is only as strong as the generator's ability to produce two `==`
///   values. `equatable`/`hashable` take `equivalents:`, a generator of
///   equivalence classes, for exactly that; without it the default checks
///   all pairs of a small batch and finds the bug only when the generator's
///   domain is small enough to collide.
/// - **Laws that fail for a reason are output, not noise.** `Double` is not
///   a monoid under `+`; the suite's job is the minimal counterexample.
///
/// The catalog is the whole v1. Anything not here is a plain `forAll`.

// MARK: - Kernel

/// Thrown by catalog laws, and available for your own: a violation with a
/// message that lands in the failure report. The equation initializer
/// renders both sides: `(a + b) + c = 0.6000000000000001, a + (b + c) = 0.6`.
public struct LawViolated: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public init<T>(_ lhs: String, _ lhsValue: T, _ rhs: String, _ rhsValue: T) {
        message = "\(lhs) = \(lhsValue), \(rhs) = \(rhsValue)"
    }
    public var description: String { message }
}

/// One execution of a law: suite, law, the drawn inputs, the verdict. This
/// is the value the shrinker minimizes and what a failure displays.
public struct LawCase: CustomStringConvertible {
    public let suite: String
    public let law: String
    /// `String(describing:)` of the drawn value — a labeled tuple prints as
    /// `(a: 0.1, b: 0.2, c: 0.3)`.
    public let inputs: String
    public let violation: (any Error)?

    public var description: String {
        var lines = ["suite: \(suite)", "  law: \(law)", "  \(inputs)"]
        if let violation { lines.append("violated: \(violation)") }
        return lines.joined(separator: "\n")
    }
}

/// A named property over inputs the law draws itself. Type-erased over the
/// input type so a suite is a plain list; the input is kept as its
/// description for display, and the shrinker works on the choice sequence
/// underneath as always.
public struct Law: Sendable {
    public let name: String
    let cases: @Sendable (_ suite: String) -> Gen<LawCase>

    public init<A>(
        _ name: String, _ draw: Gen<A>,
        check: @escaping @Sendable (A) throws -> Void
    ) {
        self.name = name
        self.cases = { suite in
            Gen { tc in
                let value = try draw.run(tc)
                let inputs = String(describing: value)
                do {
                    try check(value)
                } catch HegelError.stopTest {
                    throw HegelError.stopTest
                } catch HegelError.assume {
                    throw HegelError.assume
                } catch {
                    return LawCase(suite: suite, law: name, inputs: inputs, violation: error)
                }
                return LawCase(suite: suite, law: name, inputs: inputs, violation: nil)
            }
        }
    }
}

/// A name over laws. Suites concatenate — `Laws.monoid(…) + Laws.commutative(…)`
/// is a commutative monoid — and `named(_:)` renames the sum.
public struct LawSuite: Sendable {
    public let name: String
    public let laws: [Law]

    public init(_ name: String, _ laws: [Law]) {
        self.name = name
        self.laws = laws
    }

    public func named(_ name: String) -> LawSuite { LawSuite(name, laws) }

    public static func + (lhs: LawSuite, rhs: LawSuite) -> LawSuite {
        LawSuite("\(lhs.name) + \(rhs.name)", lhs.laws + rhs.laws)
    }
}

/// Checks every law of `suite`: one `forAll` run per law, origin
/// `file:line [suite/law]`. Every law runs; the `PropertyFailure` thrown at
/// the end carries one `Failure` per violated law (more if a law fails in
/// more than one way), each with its minimal `LawCase` as the
/// counterexample. A run-level error on any law is reported as the run
/// error, after the remaining laws have run.
public func forAll(
    _ suite: LawSuite,
    testCases: UInt64? = nil,
    seed: UInt64? = nil,
    database: String? = nil,
    settings: Settings = Settings(),
    output: ((String) -> Void)? = nil,
    origin explicitOrigin: String? = nil,
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    let base = explicitOrigin ?? "\(file):\(line)"
    var failures: [Failure] = []
    var runErrors: [String] = []
    for law in suite.laws {
        do {
            try forAll(
                law.cases(suite.name),
                testCases: testCases, seed: seed, database: database,
                settings: settings, output: output,
                origin: "\(base) [\(suite.name)/\(law.name)]",
                file: file, line: line
            ) { lawCase in
                if let violation = lawCase.violation { throw violation }
            }
        } catch let failure as PropertyFailure {
            if let runError = failure.runError {
                runErrors.append("\(law.name): \(runError)")
            } else {
                failures.append(contentsOf: failure.failures)
            }
        }
    }
    if !failures.isEmpty || !runErrors.isEmpty {
        throw PropertyFailure(
            failures: failures,
            runError: runErrors.isEmpty ? nil : runErrors.joined(separator: "; "))
    }
}

// MARK: - Catalog

/// The catalog. Every constructor returns a `LawSuite`; run it with
/// `forAll(_ suite:)`.
public enum Laws {}

// Helpers: equation checks and labeled-tuple generators. Labels are what the
// counterexample prints — `(a: 0.1, b: 0.2, c: 0.3)` — and what the equation
// strings refer to.

func requireEqual<T>(
    _ lhs: String, _ lhsValue: T, _ rhs: String, _ rhsValue: T,
    _ equal: (T, T) -> Bool
) throws {
    guard equal(lhsValue, rhsValue) else { throw LawViolated(lhs, lhsValue, rhs, rhsValue) }
}

func pair<T>(_ gen: Gen<T>) -> Gen<(a: T, b: T)> {
    zip(gen, gen).map { (a: $0.0, b: $0.1) }
}

func triple<T>(_ gen: Gen<T>) -> Gen<(a: T, b: T, c: T)> {
    zip(gen, gen, gen).map { (a: $0.0, b: $0.1, c: $0.2) }
}

/// A small batch, for laws with a premise over several values: all pairs
/// or triples of the batch are checked, so a small generator domain makes
/// the premise hold often. When `equivalents` is given, the batch is
/// sometimes one equivalence class from it.
func batch<T>(_ gen: Gen<T>, or equivalents: Gen<[T]>?) -> Gen<[T]> {
    let fresh = array(of: gen, count: 2...8)
    guard let equivalents else { return fresh }
    return oneOf([fresh, equivalents])
}

/// Every ordered pair of distinct indices.
func orderedPairs(_ n: Int) -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    for i in 0..<n { for j in 0..<n where i != j { out.append((i, j)) } }
    return out
}

/// Every ordered triple of distinct indices.
func orderedTriples(_ n: Int) -> [(Int, Int, Int)] {
    var out: [(Int, Int, Int)] = []
    for (i, j) in orderedPairs(n) { for k in 0..<n where k != i && k != j { out.append((i, j, k)) } }
    return out
}

// MARK: Algebraic structures

extension Laws {
    static func associativity<T>(
        _ gen: Gen<T>, _ label: String, _ op: @escaping @Sendable (T, T) -> T,
        equal: @escaping @Sendable (T, T) -> Bool
    ) -> Law {
        Law("associativity", triple(gen)) { t in
            try requireEqual(
                "(a \(label) b) \(label) c", op(op(t.a, t.b), t.c),
                "a \(label) (b \(label) c)", op(t.a, op(t.b, t.c)), equal)
        }
    }

    /// `op` is associative. `label` is how the failure prints the operation.
    public static func semigroup<T>(
        _ gen: Gen<T>, _ label: String, _ op: @escaping @Sendable (T, T) -> T,
        equal: @escaping @Sendable (T, T) -> Bool
    ) -> LawSuite {
        LawSuite("semigroup over \(T.self) (\(label))", [
            associativity(gen, label, op, equal: equal)
        ])
    }

    /// Associativity, left identity, right identity.
    public static func monoid<T>(
        _ gen: Gen<T>, _ label: String, _ op: @escaping @Sendable (T, T) -> T,
        identity: T, equal: @escaping @Sendable (T, T) -> Bool
    ) -> LawSuite where T: Sendable {
        LawSuite("monoid over \(T.self) (\(label))", [
            associativity(gen, label, op, equal: equal),
            Law("left identity", gen) { a in
                try requireEqual("\(identity) \(label) a", op(identity, a), "a", a, equal)
            },
            Law("right identity", gen) { a in
                try requireEqual("a \(label) \(identity)", op(a, identity), "a", a, equal)
            },
        ])
    }

    /// Monoid laws plus two-sided inverses.
    public static func group<T>(
        _ gen: Gen<T>, _ label: String, _ op: @escaping @Sendable (T, T) -> T,
        identity: T, inverse: @escaping @Sendable (T) -> T,
        equal: @escaping @Sendable (T, T) -> Bool
    ) -> LawSuite where T: Sendable {
        let m = monoid(gen, label, op, identity: identity, equal: equal)
        return LawSuite("group over \(T.self) (\(label))", m.laws + [
            Law("left inverse", gen) { a in
                try requireEqual("inverse(a) \(label) a", op(inverse(a), a), "\(identity)", identity, equal)
            },
            Law("right inverse", gen) { a in
                try requireEqual("a \(label) inverse(a)", op(a, inverse(a)), "\(identity)", identity, equal)
            },
        ])
    }

    /// `a op b == b op a`.
    public static func commutative<T>(
        _ gen: Gen<T>, _ label: String, _ op: @escaping @Sendable (T, T) -> T,
        equal: @escaping @Sendable (T, T) -> Bool
    ) -> LawSuite {
        LawSuite("commutative over \(T.self) (\(label))", [
            Law("commutativity", pair(gen)) { p in
                try requireEqual("a \(label) b", op(p.a, p.b), "b \(label) a", op(p.b, p.a), equal)
            }
        ])
    }

    /// `a op a == a` (`max`, union, intersection).
    public static func idempotent<T>(
        _ gen: Gen<T>, _ label: String, _ op: @escaping @Sendable (T, T) -> T,
        equal: @escaping @Sendable (T, T) -> Bool
    ) -> LawSuite {
        LawSuite("idempotent over \(T.self) (\(label))", [
            Law("idempotence", gen) { a in
                try requireEqual("a \(label) a", op(a, a), "a", a, equal)
            }
        ])
    }

    /// `f(f(a)) == f(a)` (`normalized`, `trimmed`, `sorted`).
    public static func idempotent<T>(
        _ gen: Gen<T>, _ label: String, _ f: @escaping @Sendable (T) -> T,
        equal: @escaping @Sendable (T, T) -> Bool
    ) -> LawSuite {
        LawSuite("idempotent over \(T.self) (\(label))", [
            Law("idempotence", gen) { a in
                try requireEqual("\(label)(\(label)(a))", f(f(a)), "\(label)(a)", f(a), equal)
            }
        ])
    }

    /// A bounded join-semilattice: a commutative, idempotent monoid. The
    /// sum `monoid + commutative + idempotent`, named — and the contract of
    /// a state-based CRDT: `merge` converges from any order, any grouping,
    /// any redelivery, starting from `identity`. Also `max` with `Int.min`,
    /// `Set.union` with `[]`, `||` with `false`.
    public static func semilattice<T>(
        _ gen: Gen<T>, _ label: String, _ op: @escaping @Sendable (T, T) -> T,
        identity: T, equal: @escaping @Sendable (T, T) -> Bool
    ) -> LawSuite where T: Sendable {
        (monoid(gen, label, op, identity: identity, equal: equal)
            + commutative(gen, label, op, equal: equal)
            + idempotent(gen, label, op, equal: equal))
            .named("bounded semilattice over \(T.self) (\(label))")
    }

    /// `f(f(a)) == a` (`reversed`, negate, conjugate, complement).
    public static func involution<T>(
        _ gen: Gen<T>, _ label: String, _ f: @escaping @Sendable (T) -> T,
        equal: @escaping @Sendable (T, T) -> Bool
    ) -> LawSuite {
        LawSuite("involution over \(T.self) (\(label))", [
            Law("involution", gen) { a in
                try requireEqual("\(label)(\(label)(a))", f(f(a)), "a", a, equal)
            }
        ])
    }

    /// `mul` distributes over `add`, on both sides.
    public static func distributive<T>(
        _ gen: Gen<T>, _ mulLabel: String, _ mul: @escaping @Sendable (T, T) -> T,
        over addLabel: String, _ add: @escaping @Sendable (T, T) -> T,
        equal: @escaping @Sendable (T, T) -> Bool
    ) -> LawSuite {
        LawSuite("distributive over \(T.self) (\(mulLabel) over \(addLabel))", [
            Law("left distributivity", triple(gen)) { t in
                try requireEqual(
                    "a \(mulLabel) (b \(addLabel) c)", mul(t.a, add(t.b, t.c)),
                    "(a \(mulLabel) b) \(addLabel) (a \(mulLabel) c)", add(mul(t.a, t.b), mul(t.a, t.c)),
                    equal)
            },
            Law("right distributivity", triple(gen)) { t in
                try requireEqual(
                    "(a \(addLabel) b) \(mulLabel) c", mul(add(t.a, t.b), t.c),
                    "(a \(mulLabel) c) \(addLabel) (b \(mulLabel) c)", add(mul(t.a, t.c), mul(t.b, t.c)),
                    equal)
            },
        ])
    }

    /// Two commutative, associative, idempotent operations satisfying
    /// absorption: `a ∨ (a ∧ b) == a` and `a ∧ (a ∨ b) == a`.
    public static func lattice<T>(
        _ gen: Gen<T>,
        join joinLabel: String, _ join: @escaping @Sendable (T, T) -> T,
        meet meetLabel: String, _ meet: @escaping @Sendable (T, T) -> T,
        equal: @escaping @Sendable (T, T) -> Bool
    ) -> LawSuite {
        func named(_ law: Law, _ suffix: String) -> Law {
            Law(law.name + " of " + suffix, law.cases)
        }
        let j = semigroup(gen, joinLabel, join, equal: equal).laws
            + commutative(gen, joinLabel, join, equal: equal).laws
            + idempotent(gen, joinLabel, join, equal: equal).laws
        let m = semigroup(gen, meetLabel, meet, equal: equal).laws
            + commutative(gen, meetLabel, meet, equal: equal).laws
            + idempotent(gen, meetLabel, meet, equal: equal).laws
        return LawSuite("lattice over \(T.self) (\(joinLabel), \(meetLabel))",
            j.map { named($0, joinLabel) } + m.map { named($0, meetLabel) } + [
                Law("absorption (\(joinLabel))", pair(gen)) { p in
                    try requireEqual(
                        "a \(joinLabel) (a \(meetLabel) b)", join(p.a, meet(p.a, p.b)), "a", p.a, equal)
                },
                Law("absorption (\(meetLabel))", pair(gen)) { p in
                    try requireEqual(
                        "a \(meetLabel) (a \(joinLabel) b)", meet(p.a, join(p.a, p.b)), "a", p.a, equal)
                },
            ])
    }

    /// `f(a opA b) == f(a) opB f(b)`; equality on the codomain.
    public static func homomorphism<A, B>(
        _ gen: Gen<A>, _ fLabel: String, _ f: @escaping @Sendable (A) -> B,
        from opALabel: String, _ opA: @escaping @Sendable (A, A) -> A,
        to opBLabel: String, _ opB: @escaping @Sendable (B, B) -> B,
        equal: @escaping @Sendable (B, B) -> Bool
    ) -> LawSuite {
        LawSuite("homomorphism \(fLabel): (\(A.self), \(opALabel)) → (\(B.self), \(opBLabel))", [
            Law("homomorphism", pair(gen)) { p in
                try requireEqual(
                    "\(fLabel)(a \(opALabel) b)", f(opA(p.a, p.b)),
                    "\(fLabel)(a) \(opBLabel) \(fLabel)(b)", opB(f(p.a), f(p.b)), equal)
            }
        ])
    }
}

extension Law {
    /// Renames a law, keeping its generator and check.
    init(_ name: String, _ cases: @escaping @Sendable (String) -> Gen<LawCase>) {
        self.name = name
        self.cases = cases
    }
}

// MARK: Round trips

extension Laws {
    /// `from(to(a)) == a`: `a` survives the trip through `B`. `Codable`
    /// round trips, `RawRepresentable`, `LosslessStringConvertible`, polar
    /// form. Most types are only a retraction into their encoding, not an
    /// isomorphism.
    public static func retraction<A, B>(
        _ gen: Gen<A>,
        to toLabel: String, _ to: @escaping @Sendable (A) -> B,
        from fromLabel: String, _ from: @escaping @Sendable (B) -> A,
        equal: @escaping @Sendable (A, A) -> Bool
    ) -> LawSuite {
        LawSuite("retraction of \(A.self) through \(B.self)", [
            Law("\(fromLabel) ∘ \(toLabel) = id", gen) { a in
                try requireEqual("\(fromLabel)(\(toLabel)(a))", from(to(a)), "a", a, equal)
            }
        ])
    }

    /// Both directions: `from(to(a)) == a` and `to(from(b)) == b`.
    public static func isomorphism<A, B>(
        _ genA: Gen<A>, _ genB: Gen<B>,
        to toLabel: String, _ to: @escaping @Sendable (A) -> B,
        from fromLabel: String, _ from: @escaping @Sendable (B) -> A,
        equalA: @escaping @Sendable (A, A) -> Bool,
        equalB: @escaping @Sendable (B, B) -> Bool
    ) -> LawSuite {
        let forward = retraction(genA, to: toLabel, to, from: fromLabel, from, equal: equalA)
        let backward = retraction(genB, to: fromLabel, from, from: toLabel, to, equal: equalB)
        return LawSuite("isomorphism \(A.self) ≅ \(B.self)", forward.laws + backward.laws)
    }
}

// MARK: Conformance laws

extension Laws {
    /// `Equatable`: reflexive, symmetric, transitive. Symmetry and
    /// transitivity are checked over all pairs and triples of a small batch;
    /// `equivalents` — classes of values that are all `==` but differently
    /// represented — is what makes their premises hold for large domains.
    public static func equatable<T: Equatable & SendableMetatype>(
        _ gen: Gen<T>, equivalents: Gen<[T]>? = nil
    ) -> LawSuite {
        let xs = batch(gen, or: equivalents)
        return LawSuite("Equatable conformance of \(T.self)", [
            Law("reflexive", gen) { a in
                guard a == a else { throw LawViolated("a == a is false") }
            },
            Law("symmetric", xs) { xs in
                for (i, j) in orderedPairs(xs.count) where xs[i] == xs[j] && !(xs[j] == xs[i]) {
                    throw LawViolated("\(xs[i]) == \(xs[j]) but not the reverse")
                }
            },
            Law("transitive", xs) { xs in
                for (i, j, k) in orderedTriples(xs.count)
                where xs[i] == xs[j] && xs[j] == xs[k] && !(xs[i] == xs[k]) {
                    throw LawViolated("\(xs[i]) == \(xs[j]) and \(xs[j]) == \(xs[k]) but \(xs[i]) != \(xs[k])")
                }
            },
        ])
    }

    /// `Hashable`: `a == b ⇒ hash(a) == hash(b)`, the same law observed
    /// through `Set`, and `hash` being a function of the value. The bug this
    /// exists for is `==` ignoring a field that `hash(into:)` includes — the
    /// reverse (hashing a subset of what `==` compares) is legal and is not
    /// flagged. Pass `equivalents:` to make the premise hold; see
    /// `equatable`.
    public static func hashable<T: Hashable & SendableMetatype>(
        _ gen: Gen<T>, equivalents: Gen<[T]>? = nil
    ) -> LawSuite {
        let xs = batch(gen, or: equivalents)
        return LawSuite("Hashable conformance of \(T.self)", [
            Law("a == b ⇒ hash(a) == hash(b)", xs) { xs in
                for (i, j) in orderedPairs(xs.count)
                where i < j && xs[i] == xs[j] && xs[i].hashValue != xs[j].hashValue {
                    throw LawViolated(
                        "\(xs[i]) == \(xs[j]) but hashes differ: \(xs[i].hashValue), \(xs[j].hashValue)")
                }
            },
            Law("Set counts ==-distinct values", xs) { xs in
                var distinct = 0
                for i in xs.indices where !xs[..<i].contains(xs[i]) { distinct += 1 }
                try requireEqual("Set(xs).count", Set(xs).count, "==-distinct count", distinct, ==)
            },
            Law("hash is a function", gen) { a in
                try requireEqual("hash(a)", a.hashValue, "hash(a) again", a.hashValue, ==)
            },
        ])
    }

    /// `Comparable`: `<` is a strict total order consistent with `==`, and
    /// `sorted()` agrees. `Double` with NaN violates trichotomy.
    public static func comparable<T: Comparable & SendableMetatype>(_ gen: Gen<T>) -> LawSuite {
        let xs = batch(gen, or: nil)
        return LawSuite("Comparable conformance of \(T.self)", [
            Law("irreflexive", gen) { a in
                guard !(a < a) else { throw LawViolated("a < a") }
            },
            Law("asymmetric", pair(gen)) { p in
                guard !(p.a < p.b && p.b < p.a) else { throw LawViolated("a < b and b < a") }
            },
            Law("transitive", xs) { xs in
                for (i, j, k) in orderedTriples(xs.count)
                where xs[i] < xs[j] && xs[j] < xs[k] && !(xs[i] < xs[k]) {
                    throw LawViolated("\(xs[i]) < \(xs[j]) < \(xs[k]) but not \(xs[i]) < \(xs[k])")
                }
            },
            Law("trichotomy", pair(gen)) { p in
                let held = [p.a < p.b, p.a == p.b, p.b < p.a].filter { $0 }.count
                guard held == 1 else {
                    throw LawViolated("exactly one of a < b, a == b, b < a should hold; \(held) do")
                }
            },
            Law("sorted() is non-decreasing", xs) { xs in
                let sorted = xs.sorted()
                for i in sorted.indices.dropLast() where sorted[i + 1] < sorted[i] {
                    throw LawViolated("sorted() has \(sorted[i]) before \(sorted[i + 1])")
                }
            },
        ])
    }
}

extension Laws {
    /// Walks `k` steps from `startIndex`, bounded so a broken `index(after:)`
    /// cannot loop forever.
    static func stepped<C: Collection>(_ c: C, _ k: Int) -> C.Index {
        var i = c.startIndex
        for _ in 0..<k { i = c.index(after: i) }
        return i
    }

    static func collectionLaws<C: Collection & SendableMetatype>(_ gen: Gen<C>) -> [Law] where C.Element: Equatable & SendableMetatype {
        let withOffset: Gen<(c: C, k: Int)> = Gen { tc in
            let c = try gen.run(tc)
            return (c: c, k: Int(try tc.drawInteger(in: 0...Int64(c.count))))
        }
        let withRange: Gen<(c: C, i: Int, j: Int)> = Gen { tc in
            let c = try gen.run(tc)
            let i = Int(try tc.drawInteger(in: 0...Int64(c.count)))
            let j = Int(try tc.drawInteger(in: Int64(i)...Int64(c.count)))
            return (c: c, i: i, j: j)
        }
        return [
            Law("count matches iteration", gen) { c in
                var n = 0
                for _ in c { n += 1 }
                try requireEqual("count", c.count, "elements iterated", n, ==)
            },
            Law("indices and subscripts match iteration", gen) { c in
                try requireEqual("indices.map { c[$0] }", c.indices.map { c[$0] }, "Array(c)", Array(c), ==)
            },
            Law("index(after:) reaches endIndex in count steps", gen) { c in
                var i = c.startIndex
                var n = 0
                while i != c.endIndex && n <= c.count { i = c.index(after: i); n += 1 }
                guard i == c.endIndex else { throw LawViolated("endIndex not reached after \(n) steps") }
                try requireEqual("steps to endIndex", n, "count", c.count, ==)
            },
            Law("distance(from: startIndex, to: endIndex) == count", gen) { c in
                try requireEqual(
                    "distance(from: startIndex, to: endIndex)", c.distance(from: c.startIndex, to: c.endIndex),
                    "count", c.count, ==)
            },
            Law("index(_:offsetBy:) matches repeated index(after:)", withOffset) { t in
                let direct = t.c.index(t.c.startIndex, offsetBy: t.k)
                let walked = stepped(t.c, t.k)
                guard direct == walked else {
                    throw LawViolated("index(startIndex, offsetBy: k)", direct, "k × index(after:)", walked)
                }
                try requireEqual("distance(from: startIndex, to: index)", t.c.distance(from: t.c.startIndex, to: direct), "k", t.k, ==)
            },
            Law("slicing matches iteration", withRange) { t in
                let slice = Array(t.c[stepped(t.c, t.i)..<stepped(t.c, t.j)])
                try requireEqual("Array(c[i..<j])", slice, "Array(c)[i..<j]", Array(Array(t.c)[t.i..<t.j]), ==)
            },
        ]
    }

    static func bidirectionalLaws<C: BidirectionalCollection & SendableMetatype>(_ gen: Gen<C>) -> [Law] where C.Element: Equatable & SendableMetatype {
        let withOffset: Gen<(c: C, k: Int)> = Gen { tc in
            let c = try gen.run(tc)
            return (c: c, k: Int(try tc.drawInteger(in: 0...Int64(c.count))))
        }
        return collectionLaws(gen) + [
            Law("index(before:) inverts index(after:)", withOffset) { t in
                guard t.k < t.c.count else { return }
                let i = stepped(t.c, t.k)
                let back = t.c.index(before: t.c.index(after: i))
                guard back == i else {
                    throw LawViolated("index(before: index(after: i))", back, "i", i)
                }
            },
            Law("index(_:offsetBy:) from endIndex matches repeated index(before:)", withOffset) { t in
                let direct = t.c.index(t.c.endIndex, offsetBy: -t.k)
                var walked = t.c.endIndex
                for _ in 0..<t.k { walked = t.c.index(before: walked) }
                guard direct == walked else {
                    throw LawViolated("index(endIndex, offsetBy: -k)", direct, "k × index(before:)", walked)
                }
            },
            Law("distance is antisymmetric", withOffset) { t in
                let i = stepped(t.c, t.k)
                try requireEqual(
                    "distance(from: startIndex, to: i)", t.c.distance(from: t.c.startIndex, to: i),
                    "-distance(from: i, to: startIndex)", -t.c.distance(from: i, to: t.c.startIndex), ==)
            },
        ]
    }

    /// `Collection` (read-only): `count`, `indices`, `index(after:)`,
    /// `index(_:offsetBy:)`, `distance` and slicing agree with iteration.
    public static func collection<C: Collection & SendableMetatype>(_ gen: Gen<C>) -> LawSuite where C.Element: Equatable & SendableMetatype {
        LawSuite("Collection conformance of \(C.self)", collectionLaws(gen))
    }

    /// `Collection` laws plus `index(before:)` inverting `index(after:)`,
    /// negative offsets, and antisymmetric `distance`.
    public static func bidirectionalCollection<C: BidirectionalCollection & SendableMetatype>(_ gen: Gen<C>) -> LawSuite
    where C.Element: Equatable & SendableMetatype {
        LawSuite("BidirectionalCollection conformance of \(C.self)", bidirectionalLaws(gen))
    }

    /// The same laws as `bidirectionalCollection`, run against the
    /// conformance's own `index(_:offsetBy:)` and `distance` overrides. (The
    /// O(1) requirement is not testable and is not claimed.)
    public static func randomAccessCollection<C: RandomAccessCollection & SendableMetatype>(_ gen: Gen<C>) -> LawSuite
    where C.Element: Equatable & SendableMetatype {
        LawSuite("RandomAccessCollection conformance of \(C.self)", bidirectionalLaws(gen))
    }
}

extension Laws {
    /// `AdditiveArithmetic`: `+` is a commutative monoid with identity
    /// `.zero`, and `-` inverts it. Uses the trapping operators: bound the
    /// generator for fixed-width integers, or use `fixedWidthRing`.
    public static func additiveArithmetic<T: AdditiveArithmetic & Sendable & SendableMetatype>(
        _ gen: Gen<T>, equal: @escaping @Sendable (T, T) -> Bool = { $0 == $1 }
    ) -> LawSuite {
        let m = monoid(gen, "+", { $0 + $1 }, identity: .zero, equal: equal)
        let c = commutative(gen, "+", { $0 + $1 }, equal: equal)
        return LawSuite("AdditiveArithmetic conformance of \(T.self)", m.laws + c.laws + [
            Law("subtraction inverts addition", pair(gen)) { p in
                try requireEqual("(a + b) - b", (p.a + p.b) - p.b, "a", p.a, equal)
            }
        ])
    }

    /// The ring a fixed-width integer actually is: `&+` an abelian group
    /// with inverse `0 &- a`, `&*` a monoid distributing over `&+`. The
    /// non-wrapping operators trap and are not laws on these carriers.
    public static func fixedWidthRing<T: FixedWidthInteger & Sendable & SendableMetatype>(_ gen: Gen<T>) -> LawSuite {
        let add = group(gen, "&+", { $0 &+ $1 }, identity: 0, inverse: { 0 &- $0 }, equal: ==)
        let addC = commutative(gen, "&+", { $0 &+ $1 }, equal: ==)
        let mul = monoid(gen, "&*", { $0 &* $1 }, identity: 1, equal: ==)
        let dist = distributive(gen, "&*", { $0 &* $1 }, over: "&+", { $0 &+ $1 }, equal: ==)
        return (add + addC + mul + dist).named("ring over \(T.self) (&+, &*)")
    }
}

// MARK: Functor (endomorphisms)

extension Laws {
    /// A drawn `Int → Int` function, total on `Int` (wrapping arithmetic)
    /// and printable in a counterexample.
    public enum Endo: Sendable, CustomStringConvertible {
        case add(Int), mul(Int), negate, abs

        public func callAsFunction(_ x: Int) -> Int {
            switch self {
            case .add(let k): x &+ k
            case .mul(let k): x &* k
            case .negate: 0 &- x
            case .abs: x < 0 ? 0 &- x : x
            }
        }

        public var description: String {
            switch self {
            case .add(let k): "add(\(k))"
            case .mul(let k): "mul(\(k))"
            case .negate: "negate"
            case .abs: "abs"
            }
        }

        public static let gen: Gen<Endo> = oneOf([
            Gen<Int>.int(in: -10...10).map { .add($0) },
            Gen<Int>.int(in: -10...10).map { .mul($0) },
            element(of: [.negate, .abs]),
        ])
    }

    /// Functor laws over endomorphisms: Swift has no higher-kinded types,
    /// so `map` is `(F, (Int) -> Int) -> F` on one concrete container with
    /// element `Int`, and the laws are `map(id) == id` and
    /// `map(g ∘ f) == map(g) ∘ map(f)` for drawn `f`, `g` (`Endo`). Enough to
    /// find a `map` that evaluates twice, drops or reorders.
    public static func functor<F>(
        _ gen: Gen<F>,
        map: @escaping @Sendable (F, @escaping @Sendable (Int) -> Int) -> F,
        equal: @escaping @Sendable (F, F) -> Bool
    ) -> LawSuite {
        let composed: Gen<(fa: F, f: Endo, g: Endo)> =
            zip(gen, Endo.gen, Endo.gen).map { (fa: $0.0, f: $0.1, g: $0.2) }
        return LawSuite("functor over \(F.self)", [
            Law("identity", gen) { fa in
                try requireEqual("map(id)(fa)", map(fa) { $0 }, "fa", fa, equal)
            },
            Law("composition", composed) { t in
                let f = t.f, g = t.g
                try requireEqual(
                    "map(g ∘ f)(fa)", map(t.fa) { g(f($0)) },
                    "map(g)(map(f)(fa))", map(map(t.fa) { f($0) }) { g($0) }, equal)
            },
        ])
    }
}

// MARK: Optics

extension Laws {
    /// The three lens laws over `get: S → V`, `set: (S, V) → S`: get-put,
    /// put-get (universal over `v`, no premise), put-put. Every
    /// `WritableKeyPath` is a lens; so is every hand-written SwiftUI
    /// `Binding(get:set:)`, modeled as `set` by copying the state and
    /// assigning through the binding.
    public static func lens<S, V>(
        _ states: Gen<S>, _ values: Gen<V>,
        get: @escaping @Sendable (S) -> V,
        set: @escaping @Sendable (S, V) -> S,
        equalState: @escaping @Sendable (S, S) -> Bool,
        equalValue: @escaping @Sendable (V, V) -> Bool
    ) -> LawSuite {
        let sv: Gen<(s: S, v: V)> = zip(states, values).map { (s: $0.0, v: $0.1) }
        let svv: Gen<(s: S, v1: V, v2: V)> = zip(states, values, values).map { (s: $0.0, v1: $0.1, v2: $0.2) }
        return LawSuite("lens \(S.self) → \(V.self)", [
            Law("get-put", states) { s in
                try requireEqual("set(s, get(s))", set(s, get(s)), "s", s, equalState)
            },
            Law("put-get", sv) { t in
                try requireEqual("get(set(s, v))", get(set(t.s, t.v)), "v", t.v, equalValue)
            },
            Law("put-put", svv) { t in
                try requireEqual("set(set(s, v1), v2)", set(set(t.s, t.v1), t.v2), "set(s, v2)", set(t.s, t.v2), equalState)
            },
        ])
    }
}

// MARK: - Equatable conveniences

// The same constructors with `==` as the equality witness. Stated as
// separate overloads without an `equal:` parameter, so a call that passes
// `equal:` explicitly resolves to the general form without ambiguity.

extension Laws {
    public static func semigroup<T: Equatable & SendableMetatype>(
        _ gen: Gen<T>, _ label: String, _ op: @escaping @Sendable (T, T) -> T
    ) -> LawSuite {
        semigroup(gen, label, op, equal: ==)
    }

    public static func monoid<T: Equatable & Sendable & SendableMetatype>(
        _ gen: Gen<T>, _ label: String, _ op: @escaping @Sendable (T, T) -> T, identity: T
    ) -> LawSuite {
        monoid(gen, label, op, identity: identity, equal: ==)
    }

    public static func group<T: Equatable & Sendable & SendableMetatype>(
        _ gen: Gen<T>, _ label: String, _ op: @escaping @Sendable (T, T) -> T,
        identity: T, inverse: @escaping @Sendable (T) -> T
    ) -> LawSuite {
        group(gen, label, op, identity: identity, inverse: inverse, equal: ==)
    }

    public static func commutative<T: Equatable & SendableMetatype>(
        _ gen: Gen<T>, _ label: String, _ op: @escaping @Sendable (T, T) -> T
    ) -> LawSuite {
        commutative(gen, label, op, equal: ==)
    }

    public static func idempotent<T: Equatable & SendableMetatype>(
        _ gen: Gen<T>, _ label: String, _ op: @escaping @Sendable (T, T) -> T
    ) -> LawSuite {
        idempotent(gen, label, op, equal: ==)
    }

    public static func idempotent<T: Equatable & SendableMetatype>(
        _ gen: Gen<T>, _ label: String, _ f: @escaping @Sendable (T) -> T
    ) -> LawSuite {
        idempotent(gen, label, f, equal: ==)
    }

    public static func involution<T: Equatable & SendableMetatype>(
        _ gen: Gen<T>, _ label: String, _ f: @escaping @Sendable (T) -> T
    ) -> LawSuite {
        involution(gen, label, f, equal: ==)
    }

    public static func semilattice<T: Equatable & Sendable & SendableMetatype>(
        _ gen: Gen<T>, _ label: String, _ op: @escaping @Sendable (T, T) -> T, identity: T
    ) -> LawSuite {
        semilattice(gen, label, op, identity: identity, equal: ==)
    }

    public static func distributive<T: Equatable & SendableMetatype>(
        _ gen: Gen<T>, _ mulLabel: String, _ mul: @escaping @Sendable (T, T) -> T,
        over addLabel: String, _ add: @escaping @Sendable (T, T) -> T
    ) -> LawSuite {
        distributive(gen, mulLabel, mul, over: addLabel, add, equal: ==)
    }

    public static func lattice<T: Equatable & SendableMetatype>(
        _ gen: Gen<T>,
        join joinLabel: String, _ join: @escaping @Sendable (T, T) -> T,
        meet meetLabel: String, _ meet: @escaping @Sendable (T, T) -> T
    ) -> LawSuite {
        lattice(gen, join: joinLabel, join, meet: meetLabel, meet, equal: ==)
    }

    public static func homomorphism<A, B: Equatable & SendableMetatype>(
        _ gen: Gen<A>, _ fLabel: String, _ f: @escaping @Sendable (A) -> B,
        from opALabel: String, _ opA: @escaping @Sendable (A, A) -> A,
        to opBLabel: String, _ opB: @escaping @Sendable (B, B) -> B
    ) -> LawSuite {
        homomorphism(gen, fLabel, f, from: opALabel, opA, to: opBLabel, opB, equal: ==)
    }

    public static func retraction<A: Equatable & SendableMetatype, B>(
        _ gen: Gen<A>,
        to toLabel: String, _ to: @escaping @Sendable (A) -> B,
        from fromLabel: String, _ from: @escaping @Sendable (B) -> A
    ) -> LawSuite {
        retraction(gen, to: toLabel, to, from: fromLabel, from, equal: ==)
    }

    public static func isomorphism<A: Equatable & SendableMetatype, B: Equatable & SendableMetatype>(
        _ genA: Gen<A>, _ genB: Gen<B>,
        to toLabel: String, _ to: @escaping @Sendable (A) -> B,
        from fromLabel: String, _ from: @escaping @Sendable (B) -> A
    ) -> LawSuite {
        isomorphism(genA, genB, to: toLabel, to, from: fromLabel, from, equalA: ==, equalB: ==)
    }

    public static func functor<F: Equatable & SendableMetatype>(
        _ gen: Gen<F>,
        map: @escaping @Sendable (F, @escaping @Sendable (Int) -> Int) -> F
    ) -> LawSuite {
        functor(gen, map: map, equal: ==)
    }

    public static func lens<S: Equatable & SendableMetatype, V: Equatable & SendableMetatype>(
        _ states: Gen<S>, _ values: Gen<V>,
        get: @escaping @Sendable (S) -> V,
        set: @escaping @Sendable (S, V) -> S
    ) -> LawSuite {
        lens(states, values, get: get, set: set, equalState: ==, equalValue: ==)
    }
}
