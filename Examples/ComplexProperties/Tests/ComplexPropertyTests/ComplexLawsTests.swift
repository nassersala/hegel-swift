import Testing
import Hegel
import ComplexModule
import RealModule

// Laws on swift-numerics' Complex<Double>. Equality is the library's own
// `isApproximatelyEqual` (relative tolerance, no absolute tolerance) — not a
// tolerance of ours — and that choice is part of what the laws test: it
// accepts a few ulps of rounding and rejects cancellation, so a law that
// fails below fails because ℂ over doubles is not a field, not because the
// tolerance is wrong.

typealias C = Complex<Double>

let approx: @Sendable (C, C) -> Bool = { $0.isApproximatelyEqual(to: $1) }
let approxReal: @Sendable (Double, Double) -> Bool = { $0.isApproximatelyEqual(to: $1) }

/// Log-uniform reals: a mantissa in ±10 at a scale from 1e-12 to 1e3, so
/// every case mixes magnitudes across fifteen decades. Cancellation lives
/// here and the generator does not hide it.
let reals: Gen<Double> = zip(Gen<Double>.double(in: -10...10), Gen<Int>.int(in: -12...3))
    .map { m, e in m * Double.pow(10.0, e) }
let complexes = zip(reals, reals).map { C($0, $1) }
/// Away from zero, so reciprocals and phases are well-conditioned.
let nonzero = complexes.filter { $0.length > 1e-3 }
/// Arguments where `exp` does not overflow.
let expArguments = zip(Gen<Double>.double(in: -10...10), Gen<Double>.double(in: -100...100)).map { C($0, $1) }
let angles = Gen<Double>.double(in: -100...100)
/// The whole finite double plane, for the edge-of-representation probe.
let anyComplex = zip(Gen<Double>.double(), Gen<Double>.double()).map { C($0, $1) }

/// Runs a suite expected to fail; returns one counterexample per violated law.
private func counterexamples(_ suite: LawSuite, testCases: UInt64 = 300) throws -> [String] {
    do {
        try forAll(suite, testCases: testCases, database: "")
    } catch let failure as PropertyFailure {
        return try failure.failures.map { try #require($0.counterexample) }
    }
    Issue.record("expected \(suite.name) to fail")
    return []
}

@Suite struct ComplexFieldLaws {
    /// Under relative tolerance the field laws hold for independent draws:
    /// `*` is a commutative monoid, `+` is commutative with identity 0,
    /// reciprocals invert away from 0, `*` distributes over `+`. Rounding
    /// is a few ulps and the tolerance absorbs it.
    @Test func multiplicationIsACommutativeMonoid() throws {
        try forAll(
            (Laws.monoid(complexes, "*", *, identity: 1, equal: approx)
                + Laws.commutative(complexes, "*", *, equal: approx)).named("commutative monoid over ℂ (*)"),
            database: "")
    }

    @Test func additionIsCommutativeWithIdentityZero() throws {
        let identity = Laws.monoid(complexes, "+", +, identity: 0, equal: approx).laws.filter { $0.name.contains("identity") }
        try forAll(
            Laws.commutative(complexes, "+", +, equal: approx) + LawSuite("additive identity over ℂ", identity),
            database: "")
    }

    @Test func reciprocalsInvertAwayFromZero() throws {
        try forAll(
            LawSuite("multiplicative inverse over ℂ∖0", [
                Law("z * (1 / z) = 1", nonzero) { z in
                    guard approx(z * (1 / z), 1) else { throw LawViolated("z * (1 / z)", z * (1 / z), "1", C(1)) }
                }
            ]),
            database: "")
    }

    @Test func multiplicationDistributesOverAdditionForIndependentDraws() throws {
        try forAll(Laws.distributive(complexes, "*", *, over: "+", +, equal: approx), database: "")
    }

    /// Associativity of `+` also passes for independent draws — and is
    /// false. It fails when `a + b` cancels exactly and `c` is small
    /// relative to `a`; independent draws almost never produce `b == -a`.
    /// That is a premise in disguise, and the generator is the caller's
    /// knowledge: drawing `b = -a` finds it at once. Both are shown.
    @Test func additionIsAssociativeForIndependentDrawsAndNotWhenASummandCancels() throws {
        try forAll(Laws.semigroup(complexes, "+", +, equal: approx), database: "")
        let found = try counterexamples(
            LawSuite("semigroup over ℂ (+), b = -a", [
                Law("associativity", zip(complexes, complexes).map { (a: $0, c: $1) }) { t in
                    let lhs = (t.a + -t.a) + t.c, rhs = t.a + (-t.a + t.c)
                    guard approx(lhs, rhs) else { throw LawViolated("(a + -a) + c", lhs, "a + (-a + c)", rhs) }
                }
            ]))
        let c = try #require(found.first)
        #expect(c.hasPrefix("suite: semigroup over ℂ (+), b = -a\n  law: associativity\n"))
        #expect(c.contains("violated: (a + -a) + c = "))
    }

    /// The cancellation law that fails for independent draws: `(a + b) - b`
    /// loses `a` when `a` is small against `b`. The minimal counterexample
    /// is a tiny `a` against an integer `b`.
    @Test func subtractionDoesNotInvertAdditionUnderCancellation() throws {
        let found = try counterexamples(
            LawSuite("subtraction over ℂ", [
                Law("(a + b) - b = a", zip(complexes, complexes).map { (a: $0, b: $1) }) { p in
                    guard approx((p.a + p.b) - p.b, p.a) else { throw LawViolated("(a + b) - b", (p.a + p.b) - p.b, "a", p.a) }
                }
            ]))
        let c = try #require(found.first)
        #expect(c.hasPrefix("suite: subtraction over ℂ\n  law: (a + b) - b = a\n"))
        #expect(c.contains("violated: (a + b) - b = "))
    }
}

@Suite struct ComplexStructureLaws {
    /// `|zw| = |z||w|`: `length` is a homomorphism from (ℂ, *) to (ℝ, *).
    @Test func lengthIsMultiplicative() throws {
        try forAll(
            Laws.homomorphism(complexes, "length", { $0.length }, from: "*", *, to: "*", *, equal: approxReal),
            database: "")
    }

    /// Conjugation is a ring automorphism and an involution — exactly, no
    /// tolerance needed: it only flips a sign.
    @Test func conjugationIsARingAutomorphism() throws {
        try forAll(
            (Laws.homomorphism(complexes, "conj", { $0.conjugate }, from: "+", +, to: "+", +)
                + Laws.homomorphism(complexes, "conj", { $0.conjugate }, from: "*", *, to: "*", *)
                + Laws.involution(complexes, "conj", { $0.conjugate })).named("conjugation over ℂ"),
            database: "")
    }

    /// `exp(a + b) = exp(a) exp(b)` and Euler's formula.
    @Test func expIsAHomomorphismFromAdditionToMultiplication() throws {
        try forAll(
            Laws.homomorphism(expArguments, "exp", { C.exp($0) }, from: "+", +, to: "*", *, equal: approx),
            database: "")
    }

    @Test func eulersFormula() throws {
        try forAll(
            LawSuite("Euler", [
                Law("exp(iθ) = cos θ + i sin θ", angles) { θ in
                    let lhs = C.exp(C(0, θ)), rhs = C(Double.cos(θ), Double.sin(θ))
                    guard approx(lhs, rhs) else { throw LawViolated("exp(iθ)", lhs, "cos θ + i sin θ", rhs) }
                }
            ]),
            database: "")
    }

    /// Polar form is a retraction: cartesian → polar → cartesian returns
    /// the value (away from 0, where phase is arbitrary).
    @Test func polarFormIsARetraction() throws {
        try forAll(
            Laws.retraction(nonzero, to: "polar", { $0.polar }, from: "Complex(length:phase:)", { C(length: $0.length, phase: $0.phase) }, equal: approx),
            database: "")
    }
}

@Suite struct ComplexBranchCuts {
    /// `sqrt(z²) = z` only where the principal square root lives. The
    /// minimal counterexample is not unique, so the seed is pinned; across
    /// seeds the shrinker lands on three:
    ///
    /// - `(-0.0, 1.0)`: squares to `(-1.0, -0.0)`, and the *signed zero*
    ///   imaginary part picks the other side of the cut — `sqrt` gives
    ///   `(0.0, -1.0)`. The smallest negative real part there is.
    /// - `(-1.0, 0.0)`: the textbook case, `sqrt(1) = 1`.
    /// - `(0.0, 7.6e-160)`: a different reason — `z²` underflows into the
    ///   subnormals and loses digits, so `sqrt` cannot get back to `z`.
    @Test func squareRootDoesNotInvertSquaringAcrossTheBranchCut() throws {
        let suite = Laws.retraction(complexes, to: "square", { $0 * $0 }, from: "sqrt", { C.sqrt($0) }, equal: approx)
        do {
            try forAll(suite, testCases: 300, seed: 1, database: "")
            Issue.record("expected the branch cut to fail")
        } catch let failure as PropertyFailure {
            let c = try #require(failure.failures.first?.counterexample)
            #expect(c == """
                suite: retraction of Complex<Double> through Complex<Double>
                  law: sqrt ∘ square = id
                  (-0.0, 1.0)
                violated: sqrt(square(a)) = (0.0, -1.0), a = (-0.0, 1.0)
                """)
        }
    }

    /// `log(exp(z)) = z` only for `Im z` in (−π, π]: past it the principal
    /// log comes back reduced mod 2πi. The shrinker lands on the smallest
    /// integer past π.
    @Test func logDoesNotInvertExpPastPi() throws {
        let found = try counterexamples(
            Laws.retraction(expArguments, to: "exp", { C.exp($0) }, from: "log", { C.log($0) }, equal: approx))
        let c = try #require(found.first)
        #expect(c.contains("law: log ∘ exp = id\n  (0.0, 4.0)\nviolated: log(exp(a)) = "))
    }
}

@Suite struct ComplexEdges {
    /// swift-numerics' model has one point at infinity: every non-finite
    /// value is `.infinity`, `1 / 0` is infinity and `1 / infinity` is 0, so
    /// `1 / (1 / z) = z` even holds at zero. Where the model is observable
    /// is the edge of the finite range: `1 / z` for the largest finite `z`
    /// underflows, and its reciprocal is infinity.
    @Test func reciprocalIsAnInvolutionExceptAtTheEdgeOfTheRepresentation() throws {
        try forAll(Laws.involution(nonzero, "reciprocal", { 1 / $0 }, equal: approx), database: "")
        let found = try counterexamples(Laws.involution(anyComplex, "reciprocal", { 1 / $0 }, equal: approx))
        let c = try #require(found.first)
        #expect(c.contains("law: involution"))
        #expect(c.contains("violated: reciprocal(reciprocal(a)) = inf, a = "))
    }

    /// A conditioning probe, not a theorem check: a polynomial built from
    /// drawn roots evaluates to ~0 at each root *relative to the size of its
    /// terms there* (Σ|cₖ||r|ᵏ, the scale Horner's error bound is stated
    /// in). Relative to the value itself it would never pass; the scale is
    /// the claim. Its first run failed at a single root 0, and the reason
    /// was ours: RealModule's real-exponent `pow(0.0, 0.0)` is NaN — it
    /// follows IEEE 754 `powr`, `exp(y log x)`, and says so — while the
    /// integer-exponent `pow(0.0, 0)` is 1, the one a polynomial wants.
    @Test func polynomialFromRootsVanishesAtThemRelativeToItsTerms() throws {
        let roots = array(of: complexes, count: 1...4)
        try forAll(roots, database: "") { rs in
            // Coefficients of ∏(x − rᵢ), lowest degree first.
            var coefficients: [C] = [1]
            for r in rs {
                var next = [C](repeating: 0, count: coefficients.count + 1)
                for (k, c) in coefficients.enumerated() {
                    next[k + 1] += c
                    next[k] -= c * r
                }
                coefficients = next
            }
            for r in rs {
                var value: C = 0, scale = 0.0
                for c in coefficients.reversed() { value = value * r + c }
                for (k, c) in coefficients.enumerated() { scale += c.length * Double.pow(r.length, k) }
                guard value.length <= 1e-9 * max(scale, .leastNormalMagnitude) else {
                    throw LawViolated("|p(r)| / Σ|cₖ||r|ᵏ at r = \(r)", value.length / scale, "≤", 1e-9)
                }
            }
        }
    }
}
