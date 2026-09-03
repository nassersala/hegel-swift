# Specifications

Status: index draft 1, 2026-08-27. This file records reading order and
document ownership; it does not make an unmarked draft proposal part of the
public API.

## Purpose

The specifications describe hegel-swift at four different levels that must
not be conflated:

1. mathematical meaning;
2. formal representation and proof;
3. executable interpretation and test strategy;
4. public Swift notation.

The meaning comes first. A runner, generator, transition table, Agda
datatype, TLA+ module, JSON file, or controlled scheduler may represent or
explore a meaning, but none becomes the meaning merely by being executable.

## Reading order

Read new design work in this order:

1. [`denotational-design.md`](denotational-design.md) — the mathematical
   foundation and common vocabulary.
2. [`generator-semantics.md`](generator-semantics.md) — domains, search,
   shrinking, replay, and the status of probability.
3. [`laws.md`](laws.md) — the implemented algebraic-law layer.
4. [`syntax-and-discovery.md`](syntax-and-discovery.md) — how the meanings
   become discoverable Swift notation.
5. [`usage-models.md`](usage-models.md) — operational profiles and weighted
   walks.
6. [`model-based.md`](model-based.md) — refinement against an abstract model.
7. [`concurrency-semantics.md`](concurrency-semantics.md) — behaviours,
   schedules, causality, safety, and liveness.
8. [`verified-model-artifacts.md`](verified-model-artifacts.md) — the boundary
   between a formal producer and a Hegel consumer.
9. [`formal-backends.md`](formal-backends.md) — Agda, TLA+, F*/Pulse, and Iris.
10. [`verified-concurrency-experiment.md`](verified-concurrency-experiment.md)
    — the next experiment that tests the combined design.

The remaining documents are application or experiment specifications. They
are evidence used by the design, not alternate semantic foundations.

## Status map

| File | Status | Owns |
|---|---|---|
| `denotational-design.md` | draft | mathematical vocabulary and layering |
| `generator-semantics.md` | draft | meaning of generation and status of shrinking |
| `syntax-and-discovery.md` | draft | novice path and Swift surface proposals |
| `verified-model-artifacts.md` | draft | formal-producer/Hegel-consumer contract |
| `formal-backends.md` | research decision draft | tool selection and non-claims |
| `concurrency-semantics.md` | draft | semantic account of concurrency |
| `verified-concurrency-experiment.md` | experiment draft | validation of the combined proposal |
| `laws.md` | implemented | law representation, catalog, and execution |
| `model-based.md` | draft | stateful model-based testing |
| `usage-models.md` | draft | statistical usage models |
| `async-experiments.md` | complete experiment | Swift async and schedule findings |
| `agent-envelope.md` | idea | metamorphic envelope around coding agents |
| `agent-repair-experiments.md` | experiment draft | value of minimal counterexamples to agents |
| `future-agentic-workflow-verification.md` | future investigation | verified workflow policy |
| `algorithm-search-experiments.md` | experiment draft | can the trace or a program search produce a sorting algorithm; Die Hard for sorting networks, Fung's grammar, refinement rounds |
| `calculation-by-refutation.md` | method, evaluated | a poor man's proof assistant: derive a data type from its correctness equation with the unknowns partial, Hegel finding each stuck goal by refutation; what it is not, the three stops where a person decides, the `stuckGoal` API |
| `joy-in-arabic.md` | experiment draft | Joy's semantics as the equation, a machine derived by refutation, then Kelley's and Hsu's layout ladder as refinements checked by von Thun's laws; Arabic script with harakat as modifiers and patterns as derived words, so the program reads in the order composition reads |

## Shared vocabulary

**Denotation** is an implementation-independent mathematical meaning.

**Representation** is a formal or program value used to describe a
denotation. Different representations may have the same meaning.

**Interpreter** computes, explores, renders, or executes a representation.

**Observation** maps concrete behaviour into the abstract values the
specification discusses.

**Refinement** is the relation saying that every observed concrete behaviour
is permitted by the abstract meaning.

**Model** is overloaded in ordinary usage. New specs must say one of
`denotation`, `formal representation`, `executable model`, or `TLC model`
when that distinction matters.

**Property** is a proposition. A property-testing run supplies finite evidence
and may refute the proposition with a counterexample; a successful finite run
is not a proof of an infinite proposition.

**Artifact** is a versioned representation passed between tools together with
provenance and scoped claims. An artifact is not a proof merely because it
lists theorem names.

## Document form

Every new design spec should contain, where applicable:

- status and date;
- the question it owns;
- definitions and mathematical contract;
- proposed decisions separated from established facts;
- public spelling only after the contract;
- reporting and failure semantics;
- non-goals;
- open questions;
- acceptance criteria or kill criteria;
- references.

Experiment records retain unsuccessful approaches and findings. An implemented
spec describes what was built and must not be silently rewritten as a future
proposal.

## Established project constraints

These constraints predate the new semantic drafts and remain in force unless a
later decision explicitly supersedes them:

- witnesses and values rather than new associated-type protocols;
- lowering onto the existing runner where the experiment shows that is honest;
- one small, shared vocabulary rather than a mini-language per feature;
- no result-builder or macro dependency for the core property language;
- few operators, with named operations preferred;
- equality and observation supplied explicitly when the carrier does not have
  the required standard witness;
- experiments precede public API commitments.

## Conflict rule

Mathematical meaning is owned by `denotational-design.md` and the relevant
domain spec. Existing implementation shape is owned by an implemented spec.
Public spelling is owned by `syntax-and-discovery.md` only after the semantic
spec has made the necessary decision. If two drafts disagree, the disagreement
remains an open question; neither wins by being newer.

## Immediate sequence

1. Review the three semantic drafts: denotational design, generators, and
   concurrency.
2. Resolve their marked decisions before changing public API.
3. Reconcile the existing laws, usage-model, and model-based drafts.
4. Run the verified-concurrency experiment.
5. Only then promote an artifact schema or new Swift syntax from draft to
   implementation plan.

