# Laws: algebraic and categorical properties in hegel-swift

Status: implemented 2026-08-21 (`Sources/Hegel/Laws.swift`,
`Tests/HegelTests/LawsTests.swift`, `Examples/ComplexProperties`, the
`Binding` lens in `Examples/AffordanceProperties`). This document is the
design as built; where the build departed from draft 2, the "As built"
section at the end says how and why.

## Why

The oldest property-based tests are laws: QuickCheck's first examples were
monoid and functor laws. hegel-swift has the machinery (`forAll` over tuples)
but not the vocabulary: a user has to remember that `Hashable` needs
`a == b ⇒ hash(a) == hash(b)`, that a lens has three laws, that a custom
`Collection` has to keep `count`, `indices`, `index(after:)` and `distance`
consistent. The Laws layer is that vocabulary as a catalog of named,
runnable suites.

It is not orthogonal to the rest of the library:

- A law is a metamorphic relation with more than one input. Associativity
  relates three inputs' outputs; `map id = id` is "transform the program,
  output unchanged"; a naturality square is a relation between two paths.
  `Relation` is the one-follow-up case, `forAll(zip(…))` is the n-input case,
  `Laws` adds names and a catalog.
- The security relations are laws seen through an API. Diffie–Hellman is
  scalar multiplication commuting, observed through
  `sharedSecretFromKeyAgreement`; "any mutation is rejected" is the *absence*
  of structure that a MAC must have. The same vocabulary states laws that
  must hold and laws that must fail.
- Floating point is a non-field and the catalog has to say so in its design
  (an explicit equality witness), not hide it behind an epsilon.

## Design rules

1. **One shape.** A law is a name, a generator, and a check that throws.
   `Rule`, `Invariant`, `Relation`, `Law` are this shape with different
   bookkeeping; `forAll` is the only runner and the failure display is the
   same everywhere.
2. **Witnesses, not protocols.** Operations are passed as closures (`op`,
   `identity`, `map`, `get`/`set`), exactly as `Gen` is passed. No
   "Lawful" protocol, no higher-kinded emulation. Where a stdlib protocol
   already supplies the operation (`Equatable`, `Comparable`, `Collection`)
   the suite is generic over it and needs only the generator.
3. **Math names are the documentation.** `Laws.monoid` means associativity,
   left identity, right identity, and the failure says which. We do not
   invent names; where a law has a textbook name the suite uses it.
4. **Every observational comparison uses an explicit equality witness,**
   defaulting to `==` where the carrier is `Equatable`. Single-carrier
   suites take one `equal:`; `lens`, `isomorphism`, `homomorphism` take one
   per carrier they compare. For floating-point carriers the caller passes
   the library's own approximate equality (swift-numerics'
   `isApproximatelyEqual`), not a magic tolerance of ours.
5. **Laws that fail for a reason are first-class output.** `Double` is not a
   monoid under `+`; `sqrt(z*z) == z` is false across the branch cut. The
   suite's job is the minimal counterexample, and the README shows those as
   deliberately as it shows passes.
6. **Premises are the caller's knowledge.** A law with a premise
   (`a == b ⇒ …`) is only as strong as the generator's ability to make the
   premise true. Where independent draws cannot, the suite takes a
   correlated generator (`equivalents:`, an equivalence class) from the
   caller and the doc says what the default does and does not find.
7. **Small.** The catalog below is the whole v1. Anything not listed is a
   plain `forAll` the user writes.

## Execution model

**One `forAll` run per law.** A suite of n laws is n runs, each with the
full `testCases` budget, its own shrink, and its own database entry. The
origin is `file:line [suite/law]`, so two violated laws are two distinct
bugs in the report (the runner keys distinct bugs on origin plus thrown
error type, `Runner.swift`; one run per suite would make every violated law
the same bug). This differs from `forAll(source:relations:subject:)`, which
draws one relation per case: there the relations share one source
generator and the choice shrinks; here each law has its own generator and
the user wants every violated law named. Cost: `collection` is ~9 runs;
measure `swift test` time and revisit if it matters.

**Each law owns its generator.** Laws in one suite have different arities
(reflexive takes `a`, transitive takes `(a, b, c)`) and different premise
biases; a suite-wide tuple would show `b` and `c` as noise on a reflexivity
failure and could not bias per law. The displayed value is a `LawCase`
(below), built exactly as `MetamorphicGroup` is, so the `Law` type is
erased over its input type and suites are plain lists.

**Function inputs are named values.** Where a law draws functions
(`functor`), they are drawn from an enum with a description — `.add(3)`,
`.negate` — so the counterexample prints.

## API

```swift
/// A named property over inputs the law draws itself.
public struct Law: Sendable {
    public let name: String
    public init<A>(
        _ name: String, _ draw: Gen<A>,
        check: @escaping @Sendable (A) throws -> Void)
    // the law as a generator of displayable cases, given the suite name
    let cases: @Sendable (_ suite: String) -> Gen<LawCase>
}

/// A suite is a name over laws. Suites concatenate:
/// `Laws.monoid(…) + Laws.commutative(…)`.
public struct LawSuite: Sendable {
    public let name: String        // "monoid over Double (+)"
    public let laws: [Law]
    public init(_ name: String, _ laws: [Law])
    public func named(_ name: String) -> LawSuite
    public static func + (lhs: LawSuite, rhs: LawSuite) -> LawSuite
}

/// What a failure displays and the shrinker minimizes: suite, law, the
/// drawn inputs (String(describing:) of a labeled tuple), the violation.
public struct LawCase: CustomStringConvertible {
    public let suite: String
    public let law: String
    public let inputs: String
    public let violation: (any Error)?
}

/// Thrown by catalog laws; available for user-written laws. The equation
/// initializer renders both sides: "(a + b) + c = X, a + (b + c) = Y".
public struct LawViolated: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String)
    public init<T>(_ lhs: String, _ lhsValue: T, _ rhs: String, _ rhsValue: T)
}

/// One run per law. Runs every law — it does not stop at the first
/// violated one — catches each run's PropertyFailure, and throws one
/// PropertyFailure whose `failures` are the union, one per violated law.
public func forAll(
    _ suite: LawSuite,
    testCases: UInt64? = nil, seed: UInt64? = nil, database: String? = nil,
    settings: Settings = Settings(),
    file: StaticString = #fileID, line: UInt = #line
) throws

public enum Laws { /* constructors below */ }
```

Failure display:

```
suite: monoid over Double (+)
  law: associativity
  (a: 0.1, b: 0.2, c: 0.3)
violated: (a + b) + c = 0.6000000000000001, a + (b + c) = 0.6
```

The operator label (`+`) cannot be recovered from a closure; every
constructor that takes an operation takes a label before it —
`Laws.monoid(gen, "+", +, identity: 0)` — used only in the display. Carrier
type comes from `String(describing: T.self)`. Every constructor has a
general form with `equal:` and an overload without it for `Equatable`
carriers (the overload omits the parameter rather than defaulting it, so
an explicit `equal:` never resolves ambiguously).

`HegelTesting` gets `expectAll(_ suite:)` and
`expectAll(source:relations:subject:)`: both run the throwing `forAll` and
record one issue per distinct bug with its counterexample and blob. Law
checks and relations throw rather than `#expect`, so neither needs the
interception layer the plain `expectAll` has.

## Catalog (v1)

Each entry: constructor, laws, carrier requirements, notes.

### Conformance laws (the practically valuable ones)

**`Laws.equatable(gen, equivalents: Gen<[T]>? = nil)`** — `T: Equatable`
- reflexive: `a == a`
- symmetric: `a == b ⇒ b == a`
- transitive: `a == b ∧ b == c ⇒ a == c`

  With independent draws the premises rarely hold and copies only retest
  reflexivity. Default: draw a batch of ~8 and check every pair/triple, so
  small-domain generators make `==` collisions likely. The thing that
  actually finds bugs is `equivalents:` — a class of values that are all
  `==` but differently represented (`Set` in two insertion orders,
  `"e\u{301}"` vs `"é"`, a struct with a cached field) — and that is the
  caller's knowledge. Symmetry draws a pair from the class, transitivity a
  triple (`a, b, c` distinct representatives where the class has three),
  so one parameter serves both premises. The doc says so.

**`Laws.hashable(gen, equivalents: Gen<[T]>? = nil)`** — `T: Hashable`
- `a == b ⇒ hash(a) == hash(b)` over all pairs of a batch, and over every
  pair of `equivalents` when given
- observed through `Set`: `Set([a, b]).count == (a == b ? 1 : 2)` — the
  same law as users feel it (the dictionary key that vanishes)
- `hash` is a function: `a.hashValue == a.hashValue` twice in one process
  (catches `hash(into:)` that reads mutable or random state; `Hasher`'s
  seed is per-process and not settable)

  The bug this exists for: `==` ignores a field that `hash(into:)`
  includes. The reverse — hashing a subset of what `==` compares — is legal
  (collisions, not a violation) and the suite must not flag it. Without
  `equivalents:` the default finds the bug only when the non-ignored fields
  collide. As built: over the full `Int` range the default *did* find it,
  because the engine draws boundary and small values often enough that two
  keys collide at 0 — an engine bias, not a guarantee; both forms are in
  the core tests and report the same two laws with the same minimal class.

**`Laws.comparable(gen)`** — `T: Comparable`
- irreflexive: `!(a < a)`
- asymmetric: `a < b ⇒ !(b < a)`
- transitive (batch, as above)
- trichotomy: exactly one of `a < b`, `a == b`, `b < a`
- `sorted()` is non-decreasing under `<`

  `Double` with NaN violates trichotomy; that is the documented demo
  failure, `(a: 0.0, b: nan)`. `Gen.double(in:)` defaults to
  `allowNaN: false`, and libhegel rejects `allowNaN` together with bounds,
  so the demo draws `.double(allowNaN: true)` over the default range and
  the passing `Double` suite draws a bounded range — both are shown.

**`Laws.collection(gen)`** — `C: Collection, C.Element: Equatable`, read-only
- `count == number of elements iterated`
- `indices` walks the same elements as iteration
- `index(after:)` from `startIndex` reaches `endIndex` in exactly `count` steps
- `distance(from: startIndex, to: endIndex) == count`
- `index(startIndex, offsetBy: k)` equals k applications of `index(after:)`,
  `k` drawn in `0...count`
- `c[i]` for `i` in `indices` matches the k-th iterated element
- `c[i..<j]` yields the elements between, `i <= j` drawn from `indices`
- `BidirectionalCollection`: `index(before:)` inverts `index(after:)`;
  `distance(from: i, to: j) == -distance(from: j, to: i)`
- `RandomAccessCollection`: `index(_:offsetBy:)` and `distance` give the
  same answers as the stepwise forms. (Complexity is not testable; the
  suite does not claim it.)

  Three constructors: `collection`, `bidirectionalCollection`,
  `randomAccessCollection`. `RangeReplaceableCollection` is v1.1.

**`Laws.retraction(gen, to:from:)`**, **`Laws.isomorphism(gen, genB, to:from:)`**,
**`Laws.involution(gen, f)`**
- retraction: `from(to(a)) ≈ a` (`Codable` round trip, `RawRepresentable`,
  `LosslessStringConvertible`, polar ↔ cartesian)
- isomorphism: both directions; two carriers, two equalities
- involution: `f(f(a)) ≈ a` — `reversed`, negate, conjugate, complement

  Stated separately: most types are only a retraction into their encoding.
  `codable(gen)` is not a constructor; it is the README example of
  `retraction`.

**`Laws.additiveArithmetic(gen)`** — `T: AdditiveArithmetic`, uses `+`/`-`
- `+` is a commutative monoid with identity `.zero`
- `(a + b) - b == a`

  For carriers that trap on overflow the caller bounds the generator; the
  doc says so. For `Double` the laws fail under `==` and the
  counterexamples are the demo.

**`Laws.fixedWidthRing(gen)`** — `T: FixedWidthInteger`, uses `&+ &- &*`
- `&+` is an abelian group with identity `0`, inverse `0 &- a`
- `&*` is a monoid with identity `1`; distributes over `&+`

  The non-wrapping operators are not laws on these carriers (they trap);
  the spec states the ring that actually holds.

### Algebraic structures

**`Laws.semigroup(gen, op, label)`**, **`Laws.monoid(…, identity:)`**,
**`Laws.group(…, identity:, inverse:)`**, **`Laws.commutative(gen, op, label)`**,
**`Laws.idempotent(gen, op, label)`** (`op(a, a) == a`; unary form
`f(f(a)) == f(a)` for `normalize`, `trimmed`, `sorted`),
**`Laws.distributive(gen, mul, over: add, labels)`**, **`Laws.lattice(gen, join:, meet:)`**
- The usual equations; `equal:` on all of them.
- **`Laws.semilattice(gen, label, op, identity:)`** = `monoid + commutative +
  idempotent`, named: a bounded join-semilattice, the state-based CRDT
  merge contract (Shapiro et al. 2011). Added after the first use-case
  walkthrough composed exactly this by hand.
- Structures are sums of suites: `commutativeMonoid = monoid + commutative`,
  `group = monoid + inverse`, `lattice = two idempotent commutative
  semigroups + absorption`. The catalog names are conveniences over `+`.
- Ready-made carriers in tests: `String`/`Array` concatenation (monoid, not
  commutative), `Set` union/intersection (lattice, idempotent), `min`/`max`
  (lattice), `Int` `&+` (group), `Optional` with `??` (monoid, `nil` is the
  two-sided identity).

**`Laws.homomorphism(gen, f, from: opA, to: opB, labels)`** — `f(opA(a, b)) ≈ opB(f(a), f(b))`, equality on the codomain
- `count` from `(Array, +)` to `(Int, +)`; conjugation on ℂ;
  `String.utf8.count` is a homomorphism, `String.count` is not (grapheme
  merging: `"e" + "\u{301}"`) — a good demo.
- The security use is the negation: a MAC must *not* be one. That is an
  existence claim (there is a pair where the sides differ), stated as
  `#expect(throws: PropertyFailure.self) { try forAll(Laws.homomorphism(…)) }`
  — the runner wraps violations, so what the test catches is the
  `PropertyFailure`, not a `LawViolated`.
  (For a 256-bit tag, "every pair differs" is also true to 2⁻²⁵⁶; the
  README says existence and lets the reader notice.)

### Functor laws (endomorphisms only)

Swift has no higher-kinded types. A single `map` closure cannot express
`F<A> → F<B>`, so the suite is over endomorphisms `A → A` on a concrete
container and is labeled as such. It still finds a `map` that evaluates
twice, drops elements, or reorders.

**`Laws.functor(gen: Gen<F>, map: (F, (Int) -> Int) -> F)`** — `F: Equatable`, element fixed to `Int`
- identity: `map(id) == id`
- composition: `map(g ∘ f) == map(g) ∘ map(f)`

  `f`, `g` drawn from `enum Endo: CustomStringConvertible { add(Int),
  mul(Int), negate, abs }`, every case total on `Int`: `&+`, `&*`,
  `0 &- x`, and `abs` as `x < 0 ? 0 &- x : x` (plain `-x`/`abs(x)` trap on
  `Int.min`). The counterexample prints `f: add(3), g: negate`.

**`Laws.monad`** — v1.1. Kleisli arrows cannot be drawn generically; the
constructor needs a per-container `arrows: [(Int) -> F]` and a display
story for them. Specify after `functor` is in.

**Naturality** — not a constructor; documented as a `Relation`:
`Array(opt.map(f)) == Array(opt).map(f)`. The example shows one.

**`Gen` itself** — a test, not a constructor: `gen.map(f).map(g)` and
`gen.map(g ∘ f)` replayed from the same blob produce equal values;
`flatMap` associativity likewise. The choice-sequence model makes functor
laws checkable by equality, which is rare; this is documentation of the
model as much as a test.

### Optics

**`Laws.lens(stateGen, valueGen, get:, set:, equalState:, equalValue:)`**
- get-put: `set(s, get(s)) ≈ s`
- put-get: `get(set(s, v)) ≈ v` — universal over `v`, no premise
- put-put: `set(set(s, v1), v2) ≈ set(s, v2)`

  SwiftUI hook: every hand-written `Binding(get:set:)` is a lens, modeled
  as `set: (S, V) -> S` by copying the state, building the binding over the
  copy, assigning `wrappedValue`. `Binding<String>` over an `Int` with
  `set: { value = Int($0) ?? 0 }` fails put-get at `""` — the
  text-field-resets bug. `WritableKeyPath` passes.

**`Laws.prism`** — deferred; no Swift idiom needs it yet.

## Examples plan

1. **Core tests (`Tests/HegelTests/LawsTests.swift`)**: every suite on a
   stdlib carrier that passes, plus the deliberate failures pinned with
   their minimal counterexamples: `Double` `+` associativity (pin whatever
   the shrinker produces), `Double` comparable with NaN, `String.count` not
   a homomorphism, a `Hashable` conformance whose `==` ignores a field that
   `hash(into:)` includes — shown failing with `equivalents:` and noted as
   not found without it.
2. **`Examples/ComplexProperties`** on swift-numerics `Complex<Double>` —
   the algebra showcase, with `equal:` = `isApproximatelyEqual`. This is
   the example that exercises the kernel (equality witnesses, failing
   laws, suite composition), so it ships with v1.
   - field laws (associativity, commutativity, distributivity, inverses
     except 0), `|zw| = |z||w|`, conjugation as a ring automorphism
     (`Laws.homomorphism` twice, `Laws.involution`), `exp(a+b) = exp(a)exp(b)`,
     Euler `exp(iθ) = cos θ + i sin θ`, polar ↔ cartesian
     (`Laws.retraction`)
   - laws that fail for a reason, pinned: `sqrt(z*z) == z` (branch cut —
     three minimal counterexamples across seeds: `(-0.0, 1.0)`, where the
     signed zero imaginary part of `z²` picks the other side of the cut;
     `(-1.0, 0.0)`; and `(0.0, 7.6e-160)`, where `z²` underflows into the
     subnormals — pinned with a seed), `log(exp(z)) == z` (mod 2πi —
     `(0.0, 4.0)`, the smallest integer past π)
   - cancellation, as found: `(a + b) - b = a` fails for independent
     draws (a tiny `a` against an integer `b`). Associativity of `+` and
     distributivity *pass* for independent draws, at 300 and at 3000 —
     they need `a + b` to cancel exactly, and independent draws almost
     never give `b == -a`. That is a premise in disguise (rule 6): the
     example states associativity a second time with `b = -a` drawn, and
     that fails at once. The generator is log-uniform across fifteen
     decades (mantissa × 10ᵏ, k ∈ −12…3), not bounded to hide anything.
   - swift-numerics' canonical model: non-finite values compare and print
     as one point at infinity (raw storage is not collapsed). As found:
     `1/(1/z) ≈ z` holds at 0 (`1/0` is infinity, `1/infinity` is 0) and
     fails at `greatestFiniteMagnitude`, whose reciprocal underflows.
   - A conditioning probe: a polynomial from drawn roots evaluates to ~0
     at each root relative to Σ|cₖ||r|ᵏ. Passes; its first run failed at
     root 0 because RealModule's real-exponent `pow(0.0, 0.0)` is NaN
     (IEEE `powr`, documented) — the integer-exponent `pow` is the one a
     polynomial wants.
3. **AffordanceProperties addition**: `Laws.lens` on a SwiftUI `Binding`,
   passing for `WritableKeyPath`, failing for the `Int`↔`String` binding at
   the minimal string.

## v1.1 (after the kernel is proven)

- `Laws.rangeReplaceable(gen, element)`, `Laws.monad`.
- **SecurityProperties additions**, corrected from draft 1: DH as a
  `Relation` (two typed paths agree — not `Laws.commutative`, whose op must
  be closed); CryptoKit Ed25519 signing is randomized by Apple's
  documentation, so the law is "signature is *not* a function of the
  message" on CryptoKit and "is" on swift-crypto — pin whichever the
  platform shows, as with the URL quirk; ECDSA likewise; "a MAC is not a
  homomorphism" as the existence claim above.

## Non-goals (v1)

- No automatic derivation of generators from conformances (no `Arbitrary`).
- No higher-kinded abstraction; `functor` over endomorphisms of one
  concrete container is the design, not a stopgap.
- No tolerance policy of our own; `equal:` comes from the caller or the
  library under test.
- No prism/traversal/iso optics beyond `lens`.

## Open questions

- Batch size for the all-pairs premise laws is 2…8; whether 16 finds more
  on realistic carriers is unmeasured.
- `LawSuite +` names the sum `"A + B"`; `named(_:)` renames. Whether
  constructors should take an optional name instead is a matter of taste.

## As built

- Run-per-law cost is not visible: the 21 core law tests (≈60 runs) take
  ~50 ms in total; no change to libhegel needed.
- `LawViolated` is a message with an equation initializer, not
  `lhs`/`rhs`/`detail` fields — the rendering was the point.
- `LawSuite.name` carries carrier and label (`"monoid over Double (+)"`),
  assembled by the constructor.
- Conformance and `Equatable`-convenience constructors require
  `SendableMetatype` (Swift 6.2): protocol requirements are dispatched
  inside `@Sendable` closures. Same constraint `Metamorphic.swift` already
  uses.
- Tuples print strings with `debugDescription`, so the `String.count`
  counterexample displays as `(a: "e", b: "\u{0301}")`.
- The SwiftUI `Binding` lens runs under `MainActor.assumeIsolated` from a
  `@MainActor` suite (`Binding` is main-actor-isolated on current SDKs).

## Verification

- `swift test` at the root: every suite passes on its stdlib carrier; every
  pinned failure shrinks to the documented minimal counterexample, with a
  seed where the counterexample is not unique; a suite with two violated
  laws reports two bugs.
- `swift test --package-path Examples/ComplexProperties`: laws pass under
  `isApproximatelyEqual` where they hold; the branch-cut and cancellation
  failures are pinned with their minimal counterexamples.
- The README section shows one passing suite, one deliberately failing one,
  and the `Binding` lens failure, in the existing register.
- CI steps for the new example package.

## Changes from draft 1

- One run per law (was one engine-chosen law per case); each law owns its
  generator; `Law` is type-erased, suites concatenate.
- `LawCase` / `LawViolated` as the display and error types; operator labels
  are caller-supplied.
- Equality witness stated per comparison, not per suite.
- `equivalents: Gen<[T]>` (an equivalence class, serving pairs and
  triples) on `equatable`/`hashable`; all-pairs batch default; the `Set`
  observation; the pinned `Hashable` bug reoriented (`==` ignores, `hash`
  includes).
- `additiveArithmetic` (`+`) and `fixedWidthRing` (`&+`) split.
- `functor` restricted to endomorphisms and named so; drawn functions are
  a printable enum; `monad` to v1.1.
- `involution` added; `rangeReplaceable` to v1.1.
- `lens` takes two equalities; put-get has no premise.
- Complex: cancellation failures expected and reported, not hidden; the
  Riemann-sphere item phrased as swift-numerics' canonical model.
- Security additions to v1.1 with DH, Ed25519, and MAC framings corrected.
- `expectAll(suite)` is real bridging work; `Relation` overload alongside.
- Dropped "`Optional ?? ` monoid on the left", "O(1)-consistent".
- Draft 2 review: `forAll(suite)` aggregates every run's `PropertyFailure`;
  negated laws catch `PropertyFailure`; NaN demo uses `allowNaN: true`;
  `Endo` cases are total on `Int`.

## References

- Claessen & Hughes, *QuickCheck* (ICFP 2000) — monoid/functor laws as the
  first PBT examples.
- `quickcheck-classes` (Haskell), `cats-laws` / discipline (Scala) — the
  catalog shape this follows.
- Foster et al., *Combinators for bidirectional tree transformations*
  (lens laws).
- swift-numerics `Complex` and `isApproximatelyEqual`.
- Chen & Tse, ESEC/FSE 2021 — laws as metamorphic relations over several
  inputs.
- Apple CryptoKit, `Curve25519.Signing.PrivateKey.signature(for:)` —
  randomized signatures.
