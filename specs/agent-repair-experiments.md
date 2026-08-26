# Agent repair: does a minimal concurrent counterexample help?

Status: downstream experiment plan, 2026-08-26. Nothing here is built. This
study starts only after `async-experiments.md` E2c can replay a concurrent
failure and render its shrunk schedule as a short readable trace.

## Question

Property-based testing is useful to a coding agent only if its feedback makes
the implementation loop converge faster. For schedule-sensitive bugs, test
whether deterministic replay and schedule shrinking materially improve an
agent's ability to produce a correct repair.

The claim is deliberately comparative:

> Given the same faulty program and executable property, an agent supplied a
> minimal replayable interleaving repairs the bug more often, or with less
> work, than an agent supplied only a flaky failure or an unshrunk schedule.

This is an evaluation of E2's output, not a prerequisite for the scheduler and
not part of the async implementation spec.

## Fixtures

Build three to five small Swift fixtures with seeded, independently reviewed
concurrency defects. Candidates:

- actor reentrancy: check, `await`, then commit while a second call interleaves;
- cancellation cleanup: a producer or continuation survives cancellation;
- finish/send ordering: a terminal event races an in-flight value;
- a small two-actor protocol whose locally valid steps violate a global
  invariant under one interleaving.

Each fixture has:

- one intended defect and a known repair;
- an executable property stated only in public behavior;
- at least one failing schedule and at least one non-failing schedule;
- a regression suite that rejects weakened properties, disabled concurrency,
  hard-coded fixture answers, and unrelated behavioral changes.

Keep fixtures small enough that diagnosis, rather than repository navigation,
dominates the task. The agent may edit the implementation but not the property,
test harness, scheduler, or regression tests.

## Experimental arms

For the same fixture and property, give a fresh agent session one of:

1. **Outcome only.** The input and log from an observed failure, without a
   schedule that reliably reproduces it.
2. **Replayable schedule.** The input, reproduce blob, and original unshrunk
   schedule trace.
3. **Minimal schedule.** The input, reproduce blob, and E2c's shrunk readable
   interleaving.

All arms receive the same task description, repository state, tools, repair
budget, and permission to run tests. Do not let an earlier arm's diagnosis or
patch leak into a later session. Randomize arm order and repeat across several
agent sampling seeds; rotate fixtures across arms rather than drawing a
conclusion from one favorite example.

## Protocol

1. Validate the seeded bug and all three feedback packages before the study.
2. Start from a clean copy of the faulty fixture for each trial.
3. Give the agent its assigned feedback and ask it to diagnose and repair the
   implementation.
4. Stop at a fixed attempt or elapsed-time budget.
5. Evaluate the patch with hidden regression tests and replay the discovered
   schedule repeatedly. Reject any patch that edits or bypasses the oracle.
6. Retain the conversation, commands, patches, test outcomes, and timing as the
   trial record.

Pin the agent model and tool configuration for a study run. If the agent itself
changes materially, report results by model version rather than pooling them.

## Measures

Primary:

- correct repair within budget;
- number of agent/test iterations to the first correct repair.

Secondary:

- elapsed time and tool calls;
- patch size and unrelated changes;
- regressions introduced;
- whether the final explanation identifies the actual ordering constraint;
- reproduction attempts wasted on a failure that did not recur.

Report per-fixture results as well as aggregates. A minimal trace may help an
actor-reentrancy bug and add little to an obvious cancellation bug; that
difference is a finding, not noise to average away.

## Validity checks

- The unshrunk and shrunk arms must encode the same failure, not merely throw
  the same error type.
- The minimal trace must actually be smaller by a declared measure: logical
  jobs, choice points, and clock advances, reported separately.
- A human reviewer who knows the fixture but not the assigned arm classifies
  repairs against the hidden oracle.
- Pilot for ceiling and floor effects. If every arm repairs every fixture, or
  none repairs any fixture, change the fixtures or budget before collecting the
  study.
- Treat a model, harness, or scheduler defect as an invalid trial, not an agent
  failure.

## Deliverable and kill criterion

Deliver the fixtures, immutable feedback packages, trial records, scoring
script, and a short comparison report. Preserve negative results.

Kill the study if E2c cannot provide byte-stable replay and a demonstrably
smaller trace, or if a pilot cannot distinguish feedback quality from fixture
difficulty. That failure does not invalidate schedule testing; it only means
the proposed agent-benefit claim was not measured cleanly.
