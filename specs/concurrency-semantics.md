# Concurrency semantics: behaviours before schedules

Status: draft 1, 2026-08-27. This document proposes a mathematical starting
point for concurrency. It does not change the completed scheduling experiment
or commit to a public concurrency API.

Reading order: after `denotational-design.md` and `async-experiments.md`;
before `verified-concurrency-experiment.md`.

## Question

What does a concurrent property quantify over, and what is a schedule relative
to that meaning?

The completed experiment correctly turned an uncontrolled scheduler decision
into generated, replayable input. That is an execution technique. The semantic
spec must now say which behaviours those decisions represent, which schedules
are equivalent, and what shrinking is allowed to remove.

## Concurrency and parallelism

Concurrency concerns multiple computations whose events may be ordered in more
than one valid way. Parallelism is simultaneous physical execution. A formal
or testing model can reason about concurrent outcomes through interleavings or
partial orders without running work simultaneously.

The controlled Swift scheduler serializes jobs deliberately. Its value is
control and replay of concurrency choices, not simulation of CPU timing or
memory-model effects.

## Proposed base denotation: labelled transition system

Start with:

```text
S       states
E       semantic events
initial subset S
step    subset S x E x S
observe : S or finite traces -> O
```

A finite execution is a valid path:

```text
s0 -e1-> s1 -e2-> ... -en-> sn
```

This relation supports nondeterminism and can be represented in Agda or TLA+.
It does not assume that Swift executor jobs are semantic events.

### Independence

An optional independence relation identifies adjacent events that neither
disable nor change one another's relevant observations. Executions related by
repeated swaps of independent adjacent events have the same partial-order
meaning.

This is the first approximation to a causality-aware semantic model. A full
event-structure or pomset API is postponed until the experiment demonstrates
that the labelled transition system plus independence is insufficient.

Built, in the example (`Independence.swift`): events on different subjects
are independent; the lexicographic normal form (swap adjacent independent
events into subject order) decides equivalence. Three independent accounts:
100 schedules, 17 traces, one class. Two withdrawals on one account: their
`check`/`commit` values differ by order, so they are dependent and the race
stays its own class. The relation is declared by the subject, not inferred
by the scheduler. Canonicalisation is not yet used by the generator or the
shrinker (Semantic shrinking, layer 5).

## Schedule

A schedule is a witness used by an interpreter to select one enabled event or
job at each choice point. It is not the concurrent behaviour itself.

In the existing scheduler, `Schedule.Deviation(choice:index:)` means "at this
runtime choice point, select this ready-queue index instead of the default."
That representation is compact and shrinkable, but it depends on:

- stable enqueue order;
- stable choice-point numbering;
- the controlled executor capturing all relevant jobs;
- the same runtime and program version producing corresponding ready sets.

The semantic adapter must map the executed job trace to named abstract events.
Lane names and opaque job identifiers are diagnostic data, not sufficient
proof of the abstract event performed.

## Observation

Concurrency properties compare observations, not implementation states. Useful
observations include:

- returned values and errors;
- externally visible state;
- ordered API-call histories;
- sets or multisets when order is intentionally unobservable;
- termination mode: completed, deadlocked/stuck, cancelled, runaway;
- logical time and emitted events.

Trace equality is appropriate only when the contract fixes order. When several
orders are legal, the model denotes an acceptance relation or set of traces.
This is already the distinction used by the async examples and should become
explicit vocabulary.

## Property classes

### Safety

Nothing bad occurs in any finite prefix. Invariants and forbidden observations
fit here. A single finite prefix refutes safety.

Stated as formulas: `Pred<State>` (`Sources/Hegel/TemporalLogic.swift`) is
linear temporal logic over a finite trace with PropRatt's operator set
(Nielsen, Kristiansen & Bahr, PADL 2026): atoms, `always`, `next`, weak
`until`, `prev`. The trace is the scheduler's step log plus semantic events
recorded at the subject boundary (`Scheduler.note`, decision 2), so a
formula speaks about `check`/`commit` events, not job ids. `eventually` and
strict `until` are deliberately absent: on a finite trace they can only be
refuted by an infinite one, so a passing test proves nothing. The escape
tests are the pattern: the safety half is a weak-until formula, the liveness
half ("the resumption comes back") is `.completed` within a wall-time grace,
a bounded surrogate and labelled as one. A weak-until formula passing on a
trace that ends `.stuck` is exactly "safety held, liveness unknown".

### Deadlock freedom

A nonterminal abstract state always has an enabled progress transition under
the stated environment assumptions. The scheduler's `.stuck` also covers work
escaping its control, so concrete stuckness must be classified before it is
reported as a semantic deadlock.

### Progress and termination

Enabled work can eventually complete. This requires assumptions about which
events are scheduled and is not implied by state safety.

### Liveness

Some desired event eventually occurs. Finite testing can find bounded
counterexamples or lassos in a model checker, but cannot generally establish
unbounded eventuality.

### Fairness

Continuously or repeatedly enabled actions are eventually selected, according
to weak or strong fairness. A randomized scheduler is not fair merely because
every ready index has positive draw probability.

### Atomicity and linearizability

Each completed concrete operation should correspond to an abstract atomic
operation placed between its invocation and response, preserving real-time
order. This is a relation between histories, not merely a final-state
invariant. The first experiment tests a simpler fixed operation history; a
general linearizability checker is future work.

## Schedule generation

The generator's intended support is the set of finite schedule policies within
declared bounds. Operationally, deviation lists may contain entries never
consulted because a run has fewer choice points. Reports should distinguish:

- generated deviations;
- deviations actually consumed;
- semantic events executed;
- maximum ready width and choice-point count;
- whether work escaped control.

Coverage instrumentation is evidence about exploration, not a probability or
fairness guarantee.

PCT (2026-08-27, `Schedules.PCT`): a second generator whose guarantee is a
probability, `1/(n·k^(d−1))` per run, under two readings fixed here: a task is
a Swift task (`JobInfo.task`, from `ExecutorJob.description`) and a step is a
choice point (the only places the scheduler chooses; `k = choicePoints`). The
guarantee is about preemptions at job boundaries, not about escaped work or
the fake clock. Measured on the two fixtures within the bound; see README.

## Semantic shrinking

A valid concurrent shrink must preserve the ability to interpret the schedule
and reproduce the failing observation.

Shrinking should progress in layers:

1. Remove unused deviations.
2. Remove deviations while retaining the same failure.
3. Move selections toward the deterministic default.
4. Simplify generated operation inputs.
5. When an independence model exists, remove events outside the causal cone of
   the failure or canonicalize equivalent interleavings.

The existing minimal deviation list is operationally useful. The stronger goal
is a minimal causal explanation. Documentation must not claim the latter until
event mapping and independence are implemented.

Layer 5 as a post-pass (2026-08-27, `Independence.swift`, `Explanation`):
the report shows the causal cone of the violating event (events not
independent of it; with the subject-based relation, the same subject) in
normal form, with the count of dropped events; the replayed trace is
unchanged. On the transfer fixture (race on A, credit on B, noise on C) the
cone is the four A events and three are dropped. Layers 1–4 remain the
choice-sequence shrinker's; canonicalisation inside the shrinker is not
built, and was not needed for the report.

## Time

Fake time is another interpreted input. Advancing to the earliest pending
timer is a scheduler policy that may collapse behaviours possible under a
different clock contract. Timed properties must specify:

- logical-time domain;
- tie semantics for simultaneous deadlines;
- cancellation semantics;
- whether time may advance while work is ready;
- observation tolerance, if any.

Real wall time is a harness limit, not semantic time.

## Formal roles

- Agda can define valid traces indexed by the transition relation and prove
  invariant preservation for every finite trace.
- TLA+/TLC can explore bounded interleavings and check temporal properties
  under explicit fairness assumptions.
- Pulse/Steel or Iris can prove ownership/resource properties of a
  shared-memory implementation.
- Hegel executes actual Swift under a controlled interpreter and shrinks
  concrete mismatches.

No one role subsumes the others.

## Proposed decisions

1. Use a labelled transition relation as the first mathematical concurrency
   representation.
2. Add semantic event names/instrumentation at the subject boundary rather
   than interpreting opaque Swift job IDs as operations.
3. Treat schedules as interpreter witnesses and deviation lists as one
   operational representation.
4. State safety, deadlock, liveness, fairness, and linearizability separately.
5. Add independence only as an optional formal relation in the first
   experiment; do not build a general event-structure API yet.
6. Report operational minimality until causal minimization is demonstrated.

## Open questions

1. Can semantic event instrumentation remain test-only and non-invasive for
   arbitrary actor code?
2. How should a nondeterministic abstract model choose its successor while
   retaining reproducible shrinking?
3. Is schedule equivalence worth canonicalizing before the generator has
   operation-level events?
4. What is the smallest useful fairness vocabulary for TLA+ interoperation?
5. Which Swift memory-model behaviours cannot be exercised by the serialized
   controlled executor?

## Non-goals

- Claiming to simulate physical parallelism or weak memory.
- Treating `.stuck` as proof of semantic deadlock without classification.
- A general linearizability engine in the first experiment.
- A universal scheduler capable of capturing detached or foreign work.
- Proving liveness from successful finite property tests.

## Acceptance criteria

Status as of 2026-08-27, against `Examples/ScheduleProperties`:

- Every schedule example separates abstract event, executor job, and choice
  witness. **Met**: `event` lines (subject, name, value), `run #id@lane`
  lines, and `Schedule.Deviation` are three kinds in the trace and the
  `Step` parser.
- The withdrawal experiment maps a failing Swift trace to a valid abstract
  trace without relying only on job IDs. **Met**: the race is
  `G(✓commit ⇒ balance ≥ 0)` and `G(✓check ⇒ X(¬✓check W ✓commit))` over
  the event steps; job ids do not appear in either formula.
- Safety and completion claims state their fairness/bound assumptions.
  **Met for the escape tests** (weak-until formula plus `.completed` within
  a named wall-time grace); the drawn-schedule tests assume nothing beyond
  the generator's bounds and say so in `generatorInstrumentation`.
- Shrinking reports exactly which notion of minimality it achieved.
  **Met**: `Minimality` prints operational minimality, generated vs consumed
  deviations over the run's choice points, and whether the failing event
  trace is its class representative. Causal minimality is not claimed.
- The same abstract model admits both Agda proof and Hegel execution
  interpretations. **Open**: see `verified-concurrency-experiment.md`.

## References

- `specs/async-experiments.md`.
- Nielsen, Kristiansen & Bahr, "Property-Based Testing for Asynchronous
  FRP Using LTL" (PropRatt), PADL 2026: the operator set and the safety-only
  stance; generated clocks are the same move as generated schedules.
- Bahr & Hutton, "Calculating Compilers for Concurrency", ICFP 2023: the
  labelled transition system above is their setting without its algebra;
  codensity choice trees give bind/choice/parallel laws over the same LTS,
  which is what would let a formula be checked against a calculated meaning
  rather than an enumerated trace, and what an independence relation needs
  to be more than a swap rule. Not adopted yet; the citation marks the gap.
- `Examples/ScheduleProperties`.
- Leslie Lamport, *The TLA+ Hyperbook*:
  <https://lamport.azurewebsites.net/tla/hyperbook.html>
- Peter Thiemann, *Intrinsically-Typed Mechanized Semantics for Session
  Types*: <https://arxiv.org/abs/1908.02940>

