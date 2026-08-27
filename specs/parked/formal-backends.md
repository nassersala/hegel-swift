# Formal backends: Agda, TLA+, F*/Pulse, and Iris

Status: research decision draft 1, 2026-08-27. This document assigns roles and
records non-claims. It does not commit Hegel to dependencies on any formal
tool.

Reading order: after `denotational-design.md` and
`verified-model-artifacts.md`.

## Question

Which formal tool should represent, explore, or prove which part of a Hegel
model?

There is no single strongest tool independent of the question. The relevant
distinction is not "formal versus informal" but the proposition, automation,
scope, and trusted base of the evidence produced.

## Summary decision

- **Agda first** for executable dependently typed models and constructive
  theorems that can produce finite artifacts.
- **TLA+ first** for rapid exploration of concurrent/distributed behaviours,
  fairness, and temporal counterexamples.
- **F*/Pulse/Steel** when the subject is an implementation with mutable shared
  state and refinement/separation-logic specifications.
- **Iris/Rocq** for research-grade higher-order concurrent separation logic,
  language soundness, weak memory, or reasoning beyond Pulse's practical
  envelope.
- **Hegel** for executing real Swift, searching inputs/schedules, replaying,
  and shrinking concrete refinement failures.

These roles overlap. They are workflow defaults, not expressiveness theorems.

## Comparison

| Need | Agda | TLA+/TLC | F*/Pulse/Steel | Iris/Rocq |
|---|---|---|---|---|
| mathematical dependent model | excellent | possible, different style | excellent | excellent |
| executable pure reference model | excellent | spec evaluation/model exploration | excellent | not primary |
| SMT-automated refinements | not built in | no | excellent | tactic/proof automation |
| bounded state exploration | build it or export | excellent | not primary | not primary |
| temporal safety/liveness notation | encode explicitly | excellent | specialized | specialized logics |
| shared-memory ownership proof | build a logic | not implementation-level | purpose-built | state of the art |
| session/protocol metatheory | demonstrated | behaviour-level model | protocol-indexed channels | Actris and related logics |
| direct Swift implementation proof | no standard bridge | no | no standard bridge | no standard bridge |
| small finite artifact export | good | traces/state graph with adapter | possible | possible, heavy |

## Agda

Agda is a dependently typed total programming language and proof assistant.
Indexed families, dependent functions/pairs, inductive relations, and
coinduction can represent protocols, valid traces, and invariants. Proofs are
programs checked by Agda's type checker.

Agda is strong when:

- the abstract model is naturally a total function or inductive relation;
- illegal states or transitions can be excluded by indices;
- an executable definition should be shared by proofs and artifact generation;
- the desired theorem is constructive and can be developed explicitly;
- protocol/session semantics are the subject.

Agda dependent pairs can express refinement-like values carrying evidence, but
plain Agda does not provide F*'s refinement subtyping and SMT-assisted
discharge. Agda also does not ship a general concurrent separation-logic
verifier for ordinary shared-memory programs. Such a logic can be formalized,
but doing so is a separate research project.

Agda has been used to mechanize session-typed concurrent calculi and obtain
preservation/progress properties. That establishes Agda's suitability as a
metalanguage for concurrency; it does not make its runtime a turnkey parallel
program verifier.

### Hegel role

The initial bridge is a safe formal module plus a separate exporter producing
a finite relation artifact. Later experiments may use a compiled pure
evaluator. Hegel tests Swift refinement; it does not import Agda proof terms.

## TLA+ and TLC

A TLA+ specification mathematically describes behaviours as state sequences
satisfying initial, next-state, and temporal formulas. TLC is an explicit-state
model checker/simulator for finite instances of that specification.

TLA+ is strong when:

- nondeterministic interleavings are central;
- the design question is global system behaviour rather than heap ownership;
- safety, deadlock, fairness, or liveness needs quick exploration;
- a finite counterexample trace is more valuable initially than an unbounded
  theorem;
- system parameters can be bounded meaningfully for model checking.

A successful TLC run is scoped to its finite model and configuration. TLA+
also has a proof system, but model checking and theorem proving must be reported
separately. A `TLC model` is a finite instance, not the denotation itself.

### Hegel role

A future adapter may import counterexample/behaviour traces or a finite
transition graph. The mapping from TLA+ values/actions to Swift operations is
still a reviewable refinement boundary. TLA+ should not be translated through
a bespoke Swift DSL until the concurrency experiment proves a need.

## F*, Steel, and Pulse

F* combines dependent and refinement types, an extensible effect system, SMT
automation, and program extraction. Refinements such as `x:int{x >= 0}` are
subtypes whose obligations are often discharged automatically.

SteelCore embeds an extensible concurrent separation logic in F*. Pulse is a
surface language embedded in F* with mutable state, concurrency, and proofs in
concurrent separation logic.

They are strong when:

- ownership of mutable resources is central;
- pre/postconditions and heap separation describe operations naturally;
- verified locks, atomic operations, channels, or fork/join libraries are the
  subject;
- an SMT-assisted program-verification workflow is desired.

Concurrent separation logic primarily supplies local safety and resource
reasoning. Deadlock freedom, fairness, and termination require additional
logics or obligations; they must not be inferred from the phrase "separation
logic" alone.

### Hegel role

Pulse could eventually produce a verified reference implementation or monitor
against which Swift is tested. It is not the first model-authoring dependency
for a library aimed at ordinary Swift programmers.

## Iris and Rocq

Iris is a higher-order concurrent separation-logic framework implemented and
verified in Rocq. It supports sophisticated invariants, ghost state,
logical-relations proofs, refinement, and ecosystems for languages and memory
models.

It is strong when:

- the verification target is a fine-grained concurrent algorithm or language;
- higher-order shared state or weak memory matters;
- a new program logic is being constructed;
- the proof investment is justified by the research or assurance target.

### Hegel role

Iris is a possible producer of high-assurance claims and reference artifacts,
not a planned end-user dependency. Its main value to Hegel now is conceptual:
separate local resource correctness from global temporal behaviour and from
empirical implementation conformance.

## Refinement means two things here

Avoid terminology collisions:

- **refinement type:** a type restricted by a logical predicate, prominent in
  F*;
- **implementation refinement:** every observed concrete behaviour is allowed
  by an abstract specification.

Hegel model-based testing investigates the second. A formal backend may use the
first to prove an implementation of the second.

## Backend-independent policy

1. Start from a denotation, not a tool's preferred syntax.
2. Record exact propositions, assumptions, bounds, and tool versions.
3. Keep evidence kinds distinct in artifacts and reports.
4. Minimize handwritten translation between the checked definition and the
   Hegel oracle.
5. Treat the concrete-to-abstract observation map as part of the trusted
   refinement boundary.
6. Do not require formal tools for ordinary Hegel use; formal artifacts are an
   assurance layer.
7. Do not advertise end-to-end Swift verification without a formal Swift
   semantics, verified compiler chain, and proof connecting them.

## Proposed workflow by question

### Pure or finite abstract model

Use Agda to define and prove the model, export a finite artifact, and let Hegel
test the Swift implementation.

### Concurrent protocol design

Use TLA+/TLC to explore bounded behaviours early. If an unbounded theorem is
required, formalize the selected semantics in Agda or use TLAPS as appropriate.
Hegel replays analogous behaviours against Swift and shrinks concrete failures.

### Shared-memory implementation primitive

Use Pulse/Steel or Iris when ownership and interference are the actual proof
subject. Hegel remains useful for Swift conformance and integration behaviour.

### Usage/reliability claim

Use a mathematically stated operational profile and representative driver.
Formal tools can prove properties of the transition model; they do not make an
adversarial Hegel run statistically representative.

## Proposed decisions

1. Keep the artifact contract backend-neutral.
2. Treat Agda as the default experimental producer, not a gate on every Hegel
   model.
3. Add TLA+ only through a concrete concurrency experiment with scoped TLC
   claims.
4. Keep Pulse/Iris in a separate implementation-verification lane until a
   Swift-relevant shared-memory example justifies integration work.
5. Use qualified labels such as `Agda-proved under ...` or `TLC-checked for
   N=...`, never an unqualified assurance badge.

## Open questions

1. Should the concurrency experiment implement both Agda and TLA+ models or
   sequence them as separate experiments?
2. Which formal source locations and digests are stable enough for artifact
   provenance?
3. Is there a small proof-certificate format worth checking independently in
   Swift, or is provenance sufficient for the intended use?
4. What formal semantics of the observation adapter would be required for a
   stronger end-to-end claim?

## Non-goals

- Ranking proof assistants by general expressiveness.
- Reimplementing separation logic in Agda for the first experiment.
- Generating arbitrary Swift from TLA+, Agda, or Pulse.
- Marketing property tests as formal proofs.

## References

- Agda, *What is Agda?*:
  <https://agda.readthedocs.io/en/latest/getting-started/what-is-agda.html>
- Peter Thiemann, *Intrinsically-Typed Mechanized Semantics for Session
  Types*: <https://arxiv.org/abs/1908.02940>
- Nikhil Swamy et al., *SteelCore: An Extensible Concurrent Separation Logic
  for Effectful Dependently Typed Programs*:
  <https://fstar-lang.org/papers/steelcore/steelcore.pdf>
- F* tutorial, *Pulse: Proof-oriented Programming in Concurrent Separation
  Logic*: <https://fstar-lang.org/tutorial/book/pulse/pulse.html>
- F* tutorial, *Primitive Effect Refinements*:
  <https://fstar-lang.org/tutorial/book/part4/part4_pure.html>
- Iris project: <https://iris-project.org/>
- Jonas Kastberg Hinrichsen et al., *Deadlock-Free Separation Logic: Linearity
  Yields Progress for Dependent Higher-Order Message Passing*:
  <https://doi.org/10.1145/3632889>
- Leslie Lamport, *The TLA+ Hyperbook*:
  <https://lamport.azurewebsites.net/tla/hyperbook.html>
