# Experiment: an Agda-verified concurrent model against scheduled Swift

Status: experiment draft 1, 2026-08-27. Nothing in this document is built.
The experiment must finish before any general verified-concurrency API is
proposed.

Reading order: after `concurrency-semantics.md`,
`verified-model-artifacts.md`, and the completed E2 section of
`async-experiments.md`.

## Question

Can one mathematical concurrency model be:

1. formalized and proved in Agda;
2. exported without a hand-translated transition oracle;
3. interpreted by the existing controlled Swift scheduler;
4. used by Hegel to find and shrink a concrete actor-reentrancy violation?

The result should reveal the trust boundary and semantic gaps, not merely make
the existing race test pass through a larger toolchain.

## Subject

Reuse `Examples/ScheduleProperties`:

- one account starts with balance 100;
- two concurrent operations each attempt to withdraw 100;
- the unsafe operation checks the balance, suspends for an audit, then commits;
- the safe operation checks and commits before suspension;
- the controlled scheduler selects among ready Swift jobs.

The current planted failure reaches balance -100 when both unsafe operations
pass their checks before either commit. The existing Hegel property shrinks the
operational policy to one deviation at choice point 2.

## Mathematical model

Use a finite labelled transition system.

### State

```text
AccountState:
  balance : integer
  taskA   : Phase
  taskB   : Phase
  audit   : abstract audit state, only if observable

Phase:
  notStarted
  readyToCheck
  rejected
  checked
  waitingForAudit
  readyToCommit
  committed
```

The precise phase split should match semantic suspension/atomicity boundaries,
not every Swift executor job.

### Events

At minimum:

```text
start(task)
checkPass(task)
checkReject(task)
audit(task)
commitUnsafe(task)
commitSafe(task)
finish(task, result)
```

If an event is internal and has no bearing on enabledness, observation, or
causality, omit it.

### Observations

- each withdrawal's returned Boolean;
- final balance;
- semantic event history;
- termination classification.

Opaque executor job identifiers remain diagnostic and are not formal events.

## Formal definitions

The safe Agda module should define:

- finite task, phase, and event types;
- initial state;
- enabled-event predicate;
- unsafe transition relation;
- safe transition relation;
- valid finite traces indexed by the selected transition relation;
- observation function;
- finite enumerations used by export, together with completeness evidence.

Prefer an inductive relation when several events may be enabled. Do not force
the model into a deterministic `step` function by adding a scheduler to the
denotation.

## Proof obligations

### Safe safety theorem

For every finite valid safe trace from the initial state:

```text
balance >= 0
```

Stronger desirable theorem: total committed withdrawal amount never exceeds
the initial balance.

### Safe completion result

For every completed trace in which both tasks finish under the stated progress
assumption:

- exactly one withdrawal succeeds;
- the final balance is 0.

Keep the progress/fairness assumption explicit; it is not part of the safety
induction.

### Unsafe counterexample

Construct a valid finite unsafe trace in which:

- both checks pass before either commit;
- both commits occur;
- the final balance is -100.

This is an existence witness, not a theorem that every schedule fails.

### Export adequacy

Prove or structurally establish that every exported state/event transition is
derived from the formal relation and every transition in the declared finite
scope is exported.

## Artifact

Export the finite relation profile from `verified-model-artifacts.md`:

- source and artifact digests;
- state/event/observation dictionaries;
- initial state;
- safe and unsafe transition relations, or separate artifacts;
- structured proof claims and assumptions;
- complete finite enumeration claim;
- named unsafe witness trace.

Keep IO/FFI outside the Agda `--safe` module. Generation must fail if the safe
module does not type-check.

## Swift semantic instrumentation

Add test-only event recording at the operation boundary so a run records
events such as `checkPass(A)` and `commit(A)`. Do not infer these events from
`#17@account` or ready-queue positions.

Instrumentation must not add a suspension or change actor isolation. Validate
that the original uninstrumented and instrumented subjects have the same final
results and scheduler choice structure for a fixed set of policies.

Task identity must be stable and assigned by the harness, not inferred from
enqueue order after the fact.

## Hegel interpretations

### Model-trace generation

Generate valid abstract event choices from the artifact and interpret them as
a scheduler policy where possible. Record when multiple concrete job choices
map to one semantic event or when an abstract event cannot be selected
directly.

### Existing deviation generation

Continue generating `Schedule.Deviation` lists and map the observed semantic
trace back to the artifact relation. This is the minimum viable route because
the current scheduler already supports it.

The experiment should compare both directions before choosing a future API.

### Refinement property

For every scheduled Swift run:

1. its semantic event trace is valid in the corresponding artifact relation;
2. its observed returns/final balance are permitted by the abstract trace;
3. the safe implementation preserves the proved invariant;
4. the unsafe implementation exposes the named violation under some generated
   schedule.

The Agda theorem is about the abstract safe relation. Hegel is what detects a
failure of the Swift-to-abstract refinement.

## Shrinking target

Retain the existing operational acceptance target:

- one consumed schedule deviation is sufficient to expose the unsafe race;
- replay is byte-stable;
- the semantic trace contains the causal pattern "both checks before either
  commit."

Do not claim a globally minimal causal trace merely because the deviation list
has length one. As an optional second result, remove semantically irrelevant
events from the displayed explanation while retaining the full replay trace.

## Optional TLA+ comparison

After the Agda/Hegel path works, encode the same labelled transition relation
in TLA+ and ask TLC, under small finite constants, to:

- find the unsafe balance counterexample;
- check the safe balance invariant;
- report deadlock under the selected completion model;
- state any fairness assumptions used for completion.

Compare the abstract counterexample with the Agda witness and Hegel's concrete
shrunk trace. This is a tool-comparison result, not a requirement for the first
success.

Done 2026-08-27, ahead of E4, because E3's semantic boundary (the `event`
trace) existed. `Examples/ScheduleProperties/TLA/Bank.tla` encodes the
relation of `Lean/Bank/Model.lean` (tasks a, b; phases idle, checked, done;
events checkPass, checkFail, commit; `Safe` constant selects the variant).
TLC, `Amount = Initial = 100`, `-deadlock`, weak fairness on `Next`:

| | TLC (`Bank.tla`) | Lean (`Bank/Model.lean`) | Hegel (`ScheduleTests`) |
|---|---|---|---|
| unsafe, `Solvent` (`balance >= 0`) | violated, 5 states: checkPass a, checkPass b, commit a (0), commit b (-100); 12 distinct states | `unsafe_race`: the same four events reach `⟨-100, done, done⟩` | `G(✓commit ⇒ balance ≥ 0)` fails at step 23 under one deviation: check 100, check 100, commit 0, commit -100 |
| unsafe, mechanism | `NoDoubleCheck` violated in 3 states: both tasks checked | — | `G(✓check ⇒ X(¬✓check W ✓commit))` fails under the same deviation |
| safe, both invariants | hold over the complete state space (5 states) | `safe_paths_nonneg` for every path | hold under every drawn schedule |
| termination `<>[]AllDone` | holds under `WF_vars(Next)` for both variants; no deadlock | not stated | not testable; `.completed` within the step bound is the surrogate |

`Transfer.tla` is the mixed-dependence fixture (withdrawal and transfer
racing on A, credit on B, unrelated withdrawal on C): 79 distinct states,
depth 8; `Solvent` violated in 5 states with C never touched (breadth-first
search reaches the violation before any independent event, so TLC's
counterexample is the causal cone without a relation); termination under
weak fairness, no deadlock. Hegel on the same fixture, 200 drawn schedules:
39 distinct traces, 3 equivalence classes under the subject relation (w
commits first and t's check fails; t first and w's fails; both check), 1
class failing. The relation reduces what testing must cover from 39 to 3;
TLC covers all 79 states regardless.

The three counterexamples are the same abstract trace. TLC's is exhaustive
over interleavings and adds what testing cannot: termination under a stated
fairness assumption and the absence of deadlock. The Lean theorem covers
every path of the safe relation; TLC covers every state of both, for these
constants. Hegel is the only one of the three that ran Swift. Run with
`TLA/run.sh` (needs a Java runtime and `tla2tools.jar`).

## Stages

### E0: semantic model on paper

Write the state/event relation and map one existing Swift failure trace by
hand. Stop if meaningful events cannot be separated from opaque job mechanics.

### E1: Agda relation and proofs

Type-check the safe invariant and unsafe witness without export or Swift.

### E2: complete finite artifact

Generate and validate a deterministic artifact from checked source. Prove or
check enumeration completeness.

### E3: Swift event adapter

Record stable semantic events under the existing scheduler and validate that
instrumentation does not alter the race.

### E4: Hegel conformance and shrinking

Run unsafe and safe subjects, persist/replay failures, and compare traces to
the artifact.

### E5: optional TLA+ comparison

Run only after E4 has produced a clear semantic boundary.

## Measures

- Agda source/proof size and check time;
- artifact size and reproducibility;
- number of handwritten mapping lines in Swift;
- proportion of generated schedules reaching semantic choice points;
- unique semantic traces versus unique executor traces;
- unsafe cases to first failure;
- shrunk consumed deviations and semantic events;
- safe cases and explored semantic arc coverage;
- mismatch categories: model, adapter, scheduler escape, subject.

## Acceptance criteria

1. The safe Agda module checks with `--safe` and no postulates.
2. Export IO is isolated and does not redefine the transition relation.
3. Finite enumeration completeness is checked, not asserted in prose.
4. A clean checkout can regenerate an artifact with identical semantic digest.
5. Swift semantic instrumentation is stable and does not introduce the race.
6. Hegel finds the planted unsafe violation and shrinks it to one consumed
   deviation or a stronger semantic explanation.
7. The fixed Swift implementation conforms for the declared test budget and
   bounded semantic coverage; the report does not call that a proof.
8. Every report names formal claims, assumptions, artifact identity, and
   concrete replay data.

## Kill criteria

Stop or narrow the integration if:

- abstract events can be mapped only through Swift runtime ABI/job-layout
  assumptions;
- instrumentation changes the choice structure materially;
- the Agda model must reproduce executor queues rather than domain events;
- the artifact duplicates a hand-maintained transition implementation;
- "verified" cannot be explained without combining bounded tests and
  unbounded theorems into one claim;
- the formal layer adds more model code than the domain and reveals no reusable
  boundary.

Record a failed stage as a finding. The existing schedule experiment remains
valuable even if the formal bridge is killed.

## Non-goals

- General Swift concurrency verification.
- Weak-memory modelling.
- A production artifact API.
- A full linearizability checker.
- Proving the Swift compiler/runtime or controlled executor correct.
- Requiring TLA+ for the Agda/Hegel result.

## Deliverables

- Agda safe model and proofs;
- isolated exporter and versioned finite artifact;
- artifact validator;
- test-only semantic event adapter;
- Hegel unsafe and safe conformance properties;
- minimal replayable failure report;
- experiment findings appended to this document;
- optional TLA+ module and comparison note.

