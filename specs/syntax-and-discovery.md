# Syntax and discovery: a property language for Swift programmers

Status: draft 1, 2026-08-27. The examples are notation sketches for review,
not accepted API. Semantic specs take precedence over any attractive spelling
in this document.

Reading order: after `denotational-design.md`, `generator-semantics.md`, and
`laws.md`.

## Question

How can Swift notation help people discover useful properties instead of only
making already-invented properties shorter?

The hard usability problem is usually the empty property body. Most users can
understand `forAll(.users) { user in ... }`; fewer know what generally true
statement belongs in the closure. Syntax should expose a vocabulary of known
property shapes and let autocomplete ask useful questions.

## Design principle

The blank closure is the last form a user should reach for. Every named form is
a question the library asks on the user's behalf.

Notation must mirror the mathematical composition described in
`denotational-design.md`. It must not expose runner phases, byte streams,
shrinker storage, or formal-backend details.

## Discovery ladder

The README should teach the following order.

1. **Named law:** does a familiar equation apply?
2. **Named relation:** how should output change under a meaningful follow-up?
3. **Enumeration:** have all compiler-known state/stimulus cases been stated?
4. **Usage model:** what sequences occur in real use?
5. **Model-based operation:** is there a genuinely simpler abstract model?
6. **Raw property:** only then write a bespoke `forAll` closure.

This is a ladder of property discovery, not an assurance ranking. A raw
property may be excellent; a bad model may be worse than a direct relation.

## Named laws

Law names should be textbook or domain names whose equations are documented.
The existing `Laws.*` catalog remains the implemented representation.

Subject-first syntax is worth testing because autocomplete can reveal the law
catalog at the point of intent:

```swift
try forAll(sort, is: .idempotent, on: .arrays(of: .int))
try forAll(reverse, is: .involution, on: .arrays(of: .int))
try forAll(encode, decode, are: .retraction, on: .users)
```

This would be a thin spelling over existing law suites, not a second execution
model. The README must choose one primary spelling if the facade is accepted.

Review questions:

- Does `forAll(f, is: ...)` read as a proposition or as an execution command?
- Can overload diagnostics remain understandable for unary, binary, and
  identity-bearing structures?
- Is the autocomplete gain large enough to justify a second construction
  spelling?

## Relations and observations

The common follow-up shape should make the changed input, observed output, and
expected relation visible:

```swift
Relation.monotone(\.params.angle,
                  by: 1...6,
                  observes: \.fajr,
                  as: .earlier)
```

Key paths are Swift conveniences for constructing updates and observations.
They are not the denotation: general closures remain necessary when the
abstract observation differs from stored representation.

The phrase `others: .fixed` is useful only when "others" is defined by an
explicit observation/equality witness. Reflection over all stored properties
must not be implied.

## Enumeration

Exhaustive pattern matching is the strongest native Swift notation available
for finite specification. The compiler, not a macro, identifies missing enum
cases:

```swift
let alarm = Enumeration<Alarm, Stimulus> { state, stimulus in
    switch (state, stimulus) {
    case (.disarmed, .arm):    .to(.armed)
    case (.armed, .trip):      .to(.triggered)
    case (.armed, .disarm):    .to(.disarmed)
    // Missing cases remain compiler diagnostics.
    }
}
```

One enumeration value may admit several interpretations: exhaustive checker,
operations for adversarial testing, usage transitions, diagram, and formal
artifact. Each interpretation needs a preservation statement; sharing a value
does not make all interpretations correct automatically.

## Model-based operations

Labelled closures are the teaching vocabulary:

```swift
Operation(
    "withdraw",
    args: ...,
    run: ...,
    model: ...,
    post: ...,
    equal: ==
)
```

The labels distinguish concrete execution, abstract transition, and
observation. A result builder would hide those phases and make ordinary local
bindings difficult. The existing no-builder decision remains.

Nullary sugar for `Args == Void` and direct `==` witnesses are appropriate
Swift conveniences because they remove ceremony without changing meaning.

## Raw drawing

Inside the clear-box form, context-first drawing is the preferred escape hatch:

```swift
try forAll { testCase in
    let user = try testCase.draw(.user)
    let permissions = try testCase.draw(.permissions(for: user))
    // bespoke proposition
}
```

A generic `draw(_:)` can replace nested `flatMap` without introducing builder
control-flow rules. `callAsFunction` may be an alias but should not become a
second documented idiom.

## Swift niceties to prototype

Prototype only after their semantic contracts are written:

1. Parameter-pack `zip`, removing the arity ceiling while preserving product
   support.
2. Generic `TestCase.draw(_:)`, enabling dependent top-down construction.
3. Leading-dot static constructors for combinators in typed argument position.
4. Conservative conversion from integer ranges and finite collections.
5. Key-path update and observation helpers.
6. `Duration` for deadlines.
7. Regex-literal overloads using public Swift regex facilities only.

Literal conformances require more skepticism. Array literals can mean a value
collection, equal-weight alternatives, or a usage profile. Dictionary literals
lose duplicate equal weights. Scalar literals may degrade type diagnostics.
Economy is not character count alone.

## Notational principles

The APL discussion contributes evaluation criteria, not a request to imitate
APL glyphs.

- **Ease of solution expression:** common property shapes have direct forms.
- **Suggestivity:** writing one law or relation exposes nearby alternatives.
- **Subordinate detail:** seeds, runner phases, and storage remain available
  but visually secondary.
- **Economy:** a small vocabulary spans laws, models, and usages.
- **Macro over micro:** users state relationships among whole behaviours, not
  loops over cases.
- **Data over control flow:** finite transition tables and relations are values
  where they clarify the whole system.
- **Structure over names:** composition carries context so temporary names do
  not dominate examples.
- **Uniformity:** one shared language is preferable to feature-specific DSL
  islands.
- **Comprehension over comfort:** familiar-looking syntax is rejected if its
  semantics cannot be predicted or changed confidently.

Implicit behaviour is acceptable only when it follows a stable mathematical
structure. Hidden defaults that change evidence or assurance claims are not
notational economy.

## Working constraints

- No result builder in the core property language.
- No macro required to express or run a property.
- At most a deliberately tiny operator vocabulary; named forms are primary.
- Values and witnesses rather than a hierarchy of `Lawful` or `ModelBased`
  protocols.
- Free-function and static-member duplicates exist only when both have a clear
  reading context; the README chooses one canonical form.
- Compiler exhaustiveness is welcome magic because its rules are Swift's own.

## Usability evaluation

Do not decide syntax only by expert review. Run small comprehension tasks with
Swift programmers who have not used property-based testing.

Measure whether a reader can:

1. say the proposition in plain language;
2. identify the generated domain;
3. predict which parts shrink;
4. distinguish abstract model from concrete subject;
5. find a named property shape through autocomplete;
6. interpret a failure without reading implementation docs;
7. modify the example to express a nearby property.

Compare at least the current API, the proposed facade, and a raw closure. The
goal is property discovery and accurate comprehension, not subjective visual
preference alone.

## Proposed decisions

1. Keep `forAll` as the proposition-oriented runner vocabulary, while allowing
   `expectAll` to remain the Swift Testing reporting wrapper for suites.
2. Test subject-first law spelling as a facade, not a replacement semantic
   layer.
3. Make exhaustive `switch` enumeration the headline state-box notation.
4. Prefer labelled `Operation` construction and generic `draw` over builders.
5. Adopt parameter packs and leading-dot constructors before ambiguous literal
   conformances.
6. Require every convenience to state which mathematical structure licenses
   its implicit behaviour.

## Open questions

1. Can one `forAll` family remain discoverable without overload ambiguity once
   laws, ranges, models, and artifacts are accepted?
2. Should named law facades be values passed to `forAll` instead of labeled
   overloads?
3. Is there one key-path relation family broad enough to justify public API?
4. Should `GenConvertible` be public, underscored, or avoided in favor of
   overloads on known standard types?
5. Which proposed spelling survives novice comprehension tests?

## Non-goals

- Recreating APL, QuickCheck's applicative operators, or a theorem-prover DSL.
- Hiding equality, preconditions, or observation choices to make examples
  shorter.
- Requiring Swift Testing macros to use the core library.
- Promising that syntax can invent an absent domain model or property.

## Acceptance criteria

- Every README-level form maps to a denotation in the semantic specs.
- The primary beginner path contains no unexplained engine vocabulary.
- Autocomplete exposes named property shapes at a useful point.
- Compiler errors for the facade are no worse than the underlying APIs.
- Comprehension evaluation favors the new spelling on both discovery and
  accurate prediction.

## References

- Conal Elliott, *Denotational Design with Type Class Morphisms*.
- John Hughes, *How to Specify It!*, Trends in Functional Programming 2019.
- `specs/laws.md`, `specs/model-based.md`, and `specs/usage-models.md`.
- APL notation principles discussed from the talk transcript supplied during
  the 2026-08-27 design session; exact bibliographic attribution remains an
  editorial open item.


## Prototyped 2026-09-03: signature laws

The stuck verdict prototyped the same day has its own page,
[`calculation-by-refutation.md`](calculation-by-refutation.md). This
section keeps the syntax half: a law whose free variables come from the
closure signature.

`Sources/Hegel/Signature.swift`:

- `DefaultGen`, a protocol with `static var gen: Gen<Self>`.
- Conformances: `Int` in `-100...100`, `Bool`, `String` as ASCII of length
  `0...8`, `Array where Element: DefaultGen` of length `0...8`, `Optional
  where Wrapped: DefaultGen` with nil first. No floating point, no
  dictionaries: a default there would be a decision (NaN, infinity,
  duplicate keys), and the `GenConvertible` conversions refuse the same
  ones for the same reason.
- `forAll(testCases:seed:database:settings:_:)` at arity 1 to 4, the
  property's parameter types naming the generators. Each lowers onto the
  ordinary `forAll` over `zip(A.gen, B.gen, …)`.

The undo equation as a signature law, the entry recording the deleted text
and `undo` total (`Tests/HegelTests/SignatureTests.swift`):

```swift
try forAll { (e: Edit, d: Doc, h: [Entry]) in
    let got = meaning(undo(record(e, d, h)))(meaning(e)(d))
    if got != d { throw LawViolated("undo(e)(e(d)) = \(got.debugDescription), d = \(d.debugDescription)") }
}
```

The signature law and the explicit form under the same seed
(`shrinksToTheSameCounterexampleAsTheExplicitForm`), same counterexample
and same reproduce blob:

```
signature form:
(insert(at: 0, "0"), "", [])
explicit form:
(insert(at: 0, "0"), "", [])
```

### The Arbitrary tension and the decision

`Gen.swift` opens with the stance: there is deliberately no `Arbitrary`
conformance to write; a generator is a value you construct, name, compose
and pass explicitly, and a type can have as many generators as it has
meanings. `DefaultGen` is exactly the conformance that stance refuses, so
the terms are stated in `Signature.swift` and repeated here.

- It is a default, not a meaning. It is consulted only when the call site
  names no generator at all. Any explicit `Gen` argument wins
  (`SignatureTests.anExplicitGeneratorWins`); the form with a generator is
  unchanged and stays the canonical one.
- It is sugar. `forAll { (e: Edit, d: Doc, h: [Entry]) in … }` is
  `forAll(zip(Edit.gen, Doc.gen, [Entry].gen)) { e, d, h in … }`, the same
  run, shrink and blob. There is no second execution model and no
  reflection: the compiler reads the types off the closure and the
  conformance supplies a `Gen` value.
- A type keeps every generator it has. `Edit.gen` is one more named value
  alongside any others; conforming names the one a bare signature draws
  from and takes nothing away.
- The name says its status. `Arbitrary` claims a random value of the type
  is a meaningful thing to ask for, and the stance says it is not.
  `DefaultGen` claims a default, which is all there is. The compiler error
  for a type without one, "does not conform to protocol `DefaultGen`",
  says what to add or that a generator should be passed.
- It is not `GenConvertible`. That protocol converts a value (a range) to
  a generator; this one needs a generator from a type with no value in
  hand, so the requirement is static. The two are kept apart rather than
  merged so neither gains a case it cannot honour.

What the stance loses: the library now ships one opinion about `Int`,
`String`, `Array` and `Optional`, and a reader who sees `(n: Int)` has to
know it means `-100...100`. That is a hidden default of the kind the
notational principles warn about, and it is the whole cost.

### Verdict

**Signature laws stay an experiment.** The form is real Swift and reads
well, and the test shows it is the explicit form to the byte. But it saves
one argument at the cost of the library's one stated stance, and on the
undo subject the saving is nil: `Edit` and `Entry` needed generators
written anyway, and the conformance is those generators with a fixed name.
The place it would pay is a law over standard types alone, which the law
catalog already covers with a generator argument. Keep the file, keep the
tests, do not document it in the README until a comprehension task shows
a novice reads `(n: Int)` as a domain and not as "any Int".
