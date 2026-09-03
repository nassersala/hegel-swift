# Generator semantics: domains, search, shrinking, and probability

Status: draft 1, 2026-08-27. This document proposes semantic distinctions for
the existing `Gen` representation. It does not propose changing `Gen`'s shape
before those distinctions are tested against the engine.

Reading order: after `denotational-design.md`; before `usage-models.md` and
`syntax-and-discovery.md`.

## Question

What mathematical claim does `forAll(g)` make, and which parts of `Gen` are
meaning versus counterexample-search machinery?

The ambiguity matters. Two generators may produce the same values with
different frequencies. Two shrinkers may find different minimal witnesses for
the same property. A usage model may claim a real probability while an
adversarial generator merely searches one branch more aggressively.

## Proposed separation

The draft separates three projections that the current `Gen` value packages
together operationally.

1. **Domain/support** `Support(g) subset A`: values that the generator is
   intended to witness.
2. **Search interpretation:** how the engine uses draws, phases, targeting,
   reuse, and branch weights to seek examples in that domain.
3. **Diagnostic interpretation:** how a failing execution is replayed and
   simplified to another failing witness.

The first is the proposed denotation relevant to an ordinary universal
property. The second and third are operational strategies. They affect bug
finding and explanation but not which proposition the user wrote.

This choice is especially honest for hegel: the engine is not a stable IID
sampler. Boundary-biased primitives, mutation, reuse of earlier failures, and
targeting mean that a single context-free probability measure is not generally
the semantics of a full run.

## Meaning of `forAll`

For a generator `g : Gen<A>` and property predicate `P`, the intended
proposition is:

```text
for every a in Support(g), P(a)
```

A failing run returns a finite witness `a` for which `P(a)` is false. A
successful run returns finite search evidence. It does not establish the
universal proposition unless the domain was exhaustively enumerated under a
trusted completeness argument.

The name `forAll` therefore names the proposition, not the strength of the
runner's evidence.

## Candidate semantic laws

The following laws are stated extensionally over support.

### Constant

```text
Support(constant(a)) = {a}
```

### Map

```text
Support(map(g, f)) = { f(a) | a in Support(g) }
```

Mapping identity preserves support; mapping a composition equals composing
the mappings extensionally.

### Zip

For independent component generators:

```text
Support(zip(g1, ..., gn)) = Support(g1) x ... x Support(gn)
```

Parameter packs remove an implementation arity ceiling; they do not change
this meaning.

### Flat map

```text
Support(flatMap(g, k)) = union { Support(k(a)) | a in Support(g) }
```

Dependence affects the domain, not merely sampling order.

### One-of and frequency

```text
Support(oneOf(gs))       = union Support(gs)
Support(frequency(wgs))  = union Support(g) for positive-weight branches
```

Under the proposed ordinary-property denotation, changing positive weights
does not change support. It changes the search interpretation.

Zero and negative weights require an API decision. The draft recommends
rejecting non-positive entries rather than assigning them surprising support
semantics.

### Filtering and assumptions

For a decidable predicate `Q`:

```text
Support(filter(g, Q)) = { a in Support(g) | Q(a) }
```

Operational rejection can still make parts of that intended domain
practically unreachable. Instrumentation must report excessive rejection; a
mathematical equation does not guarantee an effective search.

## Shrinking

Shrinking is not part of the truth conditions of the property. It is a
diagnostic search for a simpler witness after failure.

A shrinker should satisfy:

1. **Reproduction:** the reported value actually reproduces the observed
   failure under the recorded test environment.
2. **Domain preservation:** the value remains in the intended domain.
3. **Failure preservation:** accepted shrink steps still refute the property.
4. **Well-founded progress:** the simplicity order cannot descend forever.
5. **Honest minimality:** documentation says "locally minimal under this
   shrink strategy" unless global minimality is established.

For stateful and concurrent tests, validity and causality are part of domain
preservation. Deleting arbitrary bytes or schedule entries is not a semantic
shrink if it creates an impossible execution.

## Replay and the example database

Seeds, draw spans, reproduce blobs, and stored examples are operational
evidence. They must preserve the following contract:

- the same versioned generator and environment decode a reproduce blob to the
  same displayed counterexample;
- a reported failure is recoverable without relying on unrecorded scheduler or
  clock nondeterminism;
- schema or generator changes that invalidate replay fail clearly rather than
  silently producing another value.

Replay stability is a public usability contract even though replay data is not
the denotation.

## Probability belongs in two different places

### Search weights

Weights passed to an adversarial Hegel generator say where to spend search
effort. They do not imply that generated test cases are representative of
production use or IID samples from the displayed ratios.

### Usage probabilities

A statistical usage model assigns a Markov kernel or operational profile as
part of its mathematical meaning. A representative driver may then make
qualified statistical claims, subject to its assumptions.

The APIs may reuse a low-level weighted-choice implementation, but the
documentation and result types must not reuse the claim. In particular,
`frequency` in an ordinary `Gen` is search policy; transition probabilities in
a certified usage run are model data.

## Enumeration

Finite enumeration is a separate interpretation of a domain. If an
`Enumeration<A>` carries a complete, duplicate-insensitive presentation of a
finite set, a runner can check every member.

The completeness statement is an obligation of the enumeration constructor or
formal producer. An array named `allCases` is not automatically a proof when
the source domain is larger than the compiler-enforced cases.

## Consequences for syntax proposals

- Ranges and arrays may convert to generators because they have natural finite
  or bounded supports; conversion must not suggest uniformity unless the
  implementation promises it.
- Array-literal `Gen` syntax is ambiguous between a collection of values and a
  weighted/branching search strategy and should not be accepted merely because
  it is short.
- Dictionary literals cannot faithfully represent repeated equal weights or
  preserve ordered shrink preference; weighted tuples are semantically safer.
- Leading-dot static constructors and parameter-pack `zip` are surface
  improvements compatible with the support semantics.
- A scalar literal as `Gen.constant` risks hiding the distinction between a
  value and a generator in overload diagnostics; test it for comprehension
  before adopting it.

## Proposed decisions

1. Use support/domain as the ordinary denotation relevant to `forAll`.
2. Treat branch weights, targeting, mutation, and reuse as search policy unless
   an API explicitly constructs a statistical usage model.
3. Treat shrinking and replay as diagnostic interpretations with explicit
   contracts, not as the property's meaning.
4. Reserve statistical reliability claims for a representative driver whose
   assumptions and sample count are reported.
5. Describe successful Hegel runs as evidence, never as proof, outside trusted
   finite enumeration.

## Open questions

1. Does the public concept need a separate `Domain<A>` value, or is the
   denotational distinction documentation-only while `Gen<A>` remains the
   witness?
2. Can every existing combinator state useful support laws in the presence of
   throwing draws and `assume`?
3. What version information is sufficient to make reproduce blobs honest
   across generator changes?
4. Should the public name `frequency` make its search-only meaning explicit,
   leaving `UsageModel` probabilities under a different name?
5. Which instrumentation reveals severe under-sampling without implying a
   probability guarantee?

## Non-goals

- Retrofitting a probability monad over the libhegel engine.
- Claiming a canonical uniform distribution over arbitrary Swift values.
- Defining a globally optimal shrink order for every type.
- Making statistical certification an accidental property of ordinary
  `forAll`.

## Acceptance criteria

- Every public generator combinator can state its support effect.
- Search weighting and usage probability cannot be confused in examples or
  reports.
- The existing sync, async, stateful, and schedule replay tests satisfy the
  diagnostic contracts.
- An independent reviewer can explain why two same-support generators may
  differ operationally without denoting different ordinary properties.

## References

- `specs/usage-models.md` for representative and adversarial drivers.
- `specs/async-experiments.md` for replay under suspension and drawn schedules.
- Koen Claessen and John Hughes, *QuickCheck: A Lightweight Tool for Random
  Testing of Haskell Programs*, ICFP 2000.

