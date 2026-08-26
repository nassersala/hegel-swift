# Agent envelope: laws and relations with a coding agent as the subject

Status: idea, 2026-08-22. Nothing built; no spec-level decisions yet.
Written so the idea survives the session.

See also `specs/future-agentic-workflow-verification.md` (written the same day by
another session): the agent as an untrusted *planner* whose proposed workflow is
verified before tools run. That is the complementary direction — constrain what
the agent may do; this one measures where what it does is lawful.

## The idea

In `Examples/ComplexProperties` we did not make ℂ-over-doubles a field; we
found *where* it behaves like one (log-uniform magnitudes, away from zero,
`exp` bounded, `isApproximatelyEqual`) and the shrinker drew the edge.
Do the same to a coding agent: treat `agent(task) -> code` as the subject,
state metamorphic relations (there is no oracle), find the domain where
they hold, and **operate only inside that domain** — decompose tasks until
each piece is inside the envelope, the way `exp` arguments stay under 10.

Second reading, for API design rather than measurement: a lawful-by-
construction API — a closed algebra whose every composition is lawful
(`Gen` combinators shrink correctly by construction; `LawSuite +`; a sync
library whose only merge is a semilattice join) — so an agent can assemble
an unhelpful thing but not a wrong one. "Illegal compositions
unrepresentable", one level above illegal states.

## Relations (each is a `Relation`, each gives one edge of the envelope)

| change that should not matter | pattern | a failure means |
|---|---|---|
| rename identifiers in the task | invariant (naturality) | sensitive to names |
| add an irrelevant file/function to the context | invariant | distractible; shrinker gives the *smallest* distraction |
| "review and fix" already-correct code | idempotent (laws passed unchanged) | cannot leave good code alone |
| add *relevant* context | monotone (laws passed do not decrease) | more context hurts past N |
| summarize the task, re-expand, run | retraction | a constraint is lost in the round trip |

Not determinism: the agent is randomized (like ECDSA); relations are stated
up to equivalence.

## The equality witness

Two outputs are "the same" if they pass the same law suite:
`equal: { a, b in laws(a) == laws(b) }` — lawful equivalence, the catalog
as the `isApproximatelyEqual` of code. For a task like "sum a list": the
homomorphism law, `total([]) == 0`, `total([x]) == x`.

## Plan (cheapest first)

- Phase A: MultiPL-E Swift (HumanEval translated to Swift, 164 tasks), a
  local model. Hand-assign law suites to the ~40–60 tasks with algebraic
  shape (sum → homomorphism, sort → idempotent + permutation-invariant,
  reverse → involution, dedupe → idempotent, encode/decode → retraction).
  Relations: rename, paraphrase docstring, irrelevant helper in prompt,
  reorder examples. Report ReCode-style Robust Pass@1 (comparable), plus
  what ReCode cannot: minimal breaking perturbation per task (the
  envelope), and law-pass vs test-pass disagreement (laws as a third
  oracle next to HumanEval and EvalPlus tests). HumanEval is memorized, so
  rename/paraphrase measures memorized-vs-understood; rerun on
  LiveCodeBench (fresh) and compare envelopes.
- Phase B: SWE-bench Verified subset, an agent harness, relations on the
  *issue text* (paraphrase, rename, plausible irrelevant stack trace,
  reorder repro steps), tests unchanged; shrink to the minimal issue
  perturbation that flips resolve → fail. Per-agent envelope.
- Phase C: trajectories (Terminal-bench / SWE-agent logs) as state
  machines: tool calls are rules, invariants ("never deletes outside the
  repo", "never leaves passing tests failing"), a usage profile of what
  good trajectories do; the shrinker finds the shortest violating
  trajectory. Pure `specs/usage-models.md`.

## Prior art to cite

ReCode (Wang et al., ACL 2023) — prompt perturbations, Robust Pass, fixed
perturbation set, no minimization. EvalPlus / HumanEval+ — the benchmark's
own tests are weak. MultiPL-E — Swift tasks. Vikram et al. 2023 — can LLMs
write property-based tests. Chen & Tse 2021 — MT vocabulary.

## Guardrails that belong in an agent's instructions, not the library

- On a failing law, a change to the generator, the equality witness, or
  the case budget is a design change — surface it, do not commit it.
- A passing premise law without a correlated generator is a claim about
  the generator, not the code.
- Before writing a unit test, ask which law this is; if it has a name, use
  the name.
- A minimal counterexample on a design question (e.g. which edit wins on
  merge) is a question for the human, not a fix.

## Cost

Every case is a model call; shrinking is many. Small local model first.
