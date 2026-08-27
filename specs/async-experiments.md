# Async: experiments in property-testing Swift concurrency

Status: complete, 2026-08-26. E0, E1 (five sweeps) and E2a–c built; E2's
kill criterion did not trigger; the hook was taken for E1's runtime only.
Findings: one debounce bug (filed, swift-async-algorithms#450), one debounce contract gap.
Exhaustive enumeration (675 single-source scripts) added as the floor. Each experiment
carries a kill criterion so a failed bet dies cheaply and leaves a written
finding instead of a half-integrated feature.

## Why

hegel-swift could pin `URL.standardized` to the byte because every run is a
function of a draw stream: same bytes, same test, shrinkable counterexample.
Concurrency breaks that contract. A race that fails one run in fifty gives
the shrinker nothing to hold: replaying the seed replays the *inputs*, and
the scheduler is free to interleave differently. Every property of concurrent
code is conditioned on a schedule the test does not control.

The way back is the same move the library always makes: turn the
uncontrolled thing into a drawn input. Other ecosystems did this and it
worked: loom (Rust) explores interleavings of modeled primitives, shuttle
(Rust, AWS) samples schedules with PCT, Coyote (.NET) serializes tasks under
a controlled scheduler, dejafu (Haskell) and PULSE (Erlang) did it first.
Swift has one entrant, PropertyTestingKit (below), which draws schedules
but does not shrink them. Two doors are open:

- `swift-async-algorithms` ships a deterministic validation runtime (a test
  clock and a controlled job queue) built for exactly this problem, and it
  is an Apple repo that takes issues and PRs.
- SE-0392 (custom actor executors) and SE-0417 (task executor preference)
  let test code decide which job runs next; SE-0329 clocks make time a
  fake. Both existing Swift implementations of controlled scheduling
  (below) bypass these and install the private
  `swift_task_enqueueGlobal_hook` instead; assume that is the real door.

Experiment 1 walks through the first door and should produce findings in
days. Experiment 2 builds the second door into hegel and is the distinctive
bet: schedules as shrinkable inputs.

## What exists today (checked 2026-08-26)

- hegel-swift has no `async` anywhere. All five `forAll` overloads
  (`Runner.swift` x2, `Laws.swift`, `Metamorphic.swift`, `Stateful.swift`)
  take synchronous closures. Async support is work item zero, not a detail.
- The engine is a C handle driven from one loop; draws are calls into
  libhegel. Suspension between draws is within its contract (threading
  note below); E0 confirms it empirically.
- `swift-async-algorithms` has `AsyncSequenceValidation` with a manual
  clock, used by its own tests as marble diagrams (`"a--b--c-|"`). It is
  a bare target, not a product: `Package.swift` exports only
  `AsyncAlgorithms` and `AsyncStreaming`. Its determinism comes from
  setting the global `swift_task_enqueueGlobal_hook` and calling
  `swift_job_run` via `@_silgen_name` (`Test.swift`). Using it means
  vendoring test-only code that depends on private runtime hooks and
  process-global state; tests that use it must run serialized.
- DoorDash's PropertyTestingKit already does schedule fuzzing in Swift:
  it captures jobs through `swift_task_enqueueGlobal_hook` (found by
  `dlsym`, fatal if absent), reads job fields via hardcoded arm64 ABI
  offsets (`CScheduleHooks/ScheduleHooks.c`), picks the next runnable job
  from fuzzer bytes, persists and replays schedules. Schedules are fixed
  64-byte blobs with length-preserving mutation; there is no shrinking to
  a minimal interleaving. It is the comparison target for E2 and the
  existence proof that broad capture needs the private hook.
- The engine's threading contract (`hegel.h`, "Threading") is exclusive
  use, not thread affinity: a test-case handle may be driven by one
  thread at a time and returns `HEGEL_E_CONCURRENT_USE` otherwise. A
  task that resumes on a different thread after `await` and then draws is
  within contract as long as draws are sequential.
- Failure reporting (`Runner.swift`, the `.failed` arm) recovers the
  counterexample by replaying the blob through the generator and prints
  that value only. Anything drawn later, while the property runs, is
  shrunk but never shown.

## E0: async `forAll` (prerequisite)

Goal:

```swift
try await forAll(events) { script in
    try await subject(script)
}
```

An overload of `forAll` whose property is `(A) async throws -> Void`, with
an async runner loop, for both core overloads (value and live `TestCase`)
or an explicit statement that the live form is excluded. The engine handle
stays on one task and draws stay sequential, which the header permits.

Decisions E0 makes:

- caller cancellation propagates (`CancellationError` is not a
  counterexample);
- a property that suspends forever hits a timeout with a clear error, not
  a hung test;
- `TestCase` stays non-`Sendable`; concurrent draws are not a feature.

Checks that E0 must pass before E1 starts:

- a failing async property shrinks to the same counterexample as its
  synchronous twin: same seed, equal reproduce blob (blob equality is the
  acceptance test, seed equality is not enough);
- `derandomize` and the example database behave identically through the
  async path;
- a property that suspends between two draws replays correctly.

Kill criterion: none expected; the header allows this. If a draw after a
thread hop fails anyway, record the exact error. Fallback: a controlled
executor can pump jobs from a synchronous `forAll`, the way
`AsyncSequenceValidation` exposes a synchronous entry point, so E0 failing
delays E1 and E2 rather than killing them.

Result (2026-08-26): built. `Runner.swift` now has an internal `Run`
helper shared by the sync and async loops, and async overloads of both
core `forAll`s (value and live `TestCase`) plus an async `expectAll`.
All three checks pass (`Tests/HegelTests/AsyncTests.swift`): the async
twin's reproduce blob is byte-equal to the sync twin's under the same
seed; a property that draws, resumes on a libdispatch thread, draws again
produces the same blob as its sync twin and the blob replays both draws;
`derandomize` gives one blob across sync and async runs. Decisions:
`CancellationError` propagates (checked before each case and rethrown from
the property); `timeout:` races the property against `Task.sleep` in a
task group and throws `PropertyTimeout`, which is also propagated rather
than classified. The timeout is cooperative: the group must wait for the
property's child to unwind before the engine's "one driver at a time"
contract lets the case be freed, so a body that ignores cancellation still
hangs. The live form is included; `TestCase` stays non-`Sendable`. No draw
after a thread hop failed; the header's contract held empirically.
Nothing here blocks E1.

## E1: laws for swift-async-algorithms on their deterministic clock

The tractable experiment. Everything runs on the validation runtime, so
failures shrink and replay like any hegel test.

Generator: finite event scripts, producer side and consumer side drawn
separately. Values are tagged `(source, ordinal)` so duplicates cannot
hide an ordering bug.

```swift
enum Event { case value(Int), delay(ticks: Int), failure, finish }
enum Demand { case next, wait(ticks: Int), cancel }
struct Script { var perSource: [[Event]]; var consumer: [Demand] }
```

Start with two operators, `merge` and `zip`, and grow only after their
laws are green. Laws are grouped by termination mode, because most of
them hold only under normal completion:

- Normal completion. `merge`: output is the bag union of inputs and each
  source's values appear in source order. `zip`: length is the min of
  input lengths, pair i is (aᵢ, bᵢ).
- Failure. A source failing early ends the output with that error; the
  prefix before it still satisfies the completion laws restricted to
  what was emitted.
- Cancellation, at a drawn consumer step. Terminates. Swift cancellation
  is cooperative, so the law is "at most one in-flight value after the
  cancel step, then nothing", with the boundary written down.
- Backpressure, later, for `buffer`. `buffer` is several policies:
  bounded keeps everything and blocks the producer, oldest/latest drop by
  design. Each policy gets its own law against the consumer timeline.
- Reference model, per operator. A tiny pure function over discrete ticks
  accepts or rejects an observed trace. It describes the set of legal
  emission ticks, values, and terminal events rather than producing one
  privileged trace: simultaneous `merge` emissions may have more than one
  valid order. `debounce` and `throttle` are not identity at zero delay and
  `merge`/`zip` have no one-source form, so there is no single "equals the
  sequential version" property; trace acceptance is the differential oracle.
- Metamorphic checks around that model: renaming source ids only renames the
  corresponding output tags; translating every input tick translates every
  output tick without changing values; when timed operators arrive, scaling
  delays and their interval together preserves the value trace; varying the
  schedule preserves schedule-insensitive results such as `merge`'s bag.

The executable model must earn the right to be an oracle. Before it tests the
real operator, exhaustively enumerate a small bounded script space and check
the model's own invariants, then run the upstream hand-written validation
diagrams through it. A mismatch is classified first as model, implementation,
or harness; a counterexample is not called an upstream bug until that triage
is complete.

Deliverable: `Examples/AsyncProperties` following the standard example
recipe (path dependency, `database: ""`, CI step). Findings go upstream as
issues with shrunk scripts, the #2198/#2207 route.

Decision on day one, not a kill criterion: vendor `AsyncSequenceValidation`
(private hook, global state, serialized tests) or not. Its public
`validate` entry point is programmatically usable, so the API is not the
obstacle. Reimplementing only a clock is not a substitute: the clock alone
does not capture the unstructured tasks the operators spawn internally.
If vendoring is refused, the laws wait for E2's executor.

Result (2026-08-26): built as `Examples/AsyncProperties`. Day-one
decision: vendored. The target is not a product, and the programmatic
seam needed (a consumer that records every `next()` including the past-
end one and the tick each demand was issued at) is only reachable inside
the module; `Vendor/AsyncSequenceValidation/Programmatic.swift` is the one
added file, everything else is byte-identical to tag 1.1.5 (the
`Locking.swift` symlink into `AsyncAlgorithms` had to be materialized).
The global hook forced one structural rule: every suite nests under one
`@Suite(.serialized)` parent, because Swift Testing runs sibling suites
in parallel and two diagrams at once produced empty traces. `Script`
renders to marble diagrams and shrinks to them; the smallest counter-
examples were `"-a|"`/`"x"` sized. Harness facts the model had to learn:
the consumer demands at `max(script tick, now)`, the cancel tick is itself
a demand point, an input with no values finishes on the first pull
regardless of trailing silence, cancelling during the consumer's sleep
must be recorded or the trace is cut short, and `#expect` inside plain
`forAll` does not shrink (use `expectAll`). Finding, triaged as
implementation-as-designed: failures are pull-driven. Merge's children
pull only on downstream demand, so `"a-bc|"`/`"AB^"`/`"xxxxx"` yields
`a@1 A@1 B@2 b@3 c@4 ^@5` (`c` emitted after the failure, delivered
before it), and sparser demand gives `… c@7 ^@9`; zip likewise does not
see a failure until it asks for the next pair. The "emitted no later
than the earliest failure" clause was removed from both models and the
trace is pinned in `ModelSelfChecks.failureIsPullDriven`. Both operators
pass every remaining law (16 tests, 3 consecutive green runs). Second round (same day, 10k scripts per law, differential against
executable models in `TimedModels.swift`): merge/zip exact timing hold;
`buffer` ×4 policies hold (limit 0 = passthrough for all three bounded
kinds, `AsyncBufferSequence.swift:108`); `_throttle` ×2 holds once the
model knew the completion flush sleeps to `lastEmit + interval`.
`debounce`: (1) BUG, upstream error dropped when no demand is outstanding
(`upstreamThrew`, `.waitingForDemand(_, .none, _, .none)` → `.finished`);
shrunk to `"a^"` k=1; real-clock repro; distinct from closed #269; draft
issue in `specs/issue-debounce-swallows-error.md`, pinned with
`withKnownIssue` in `DebounceSwallowsUpstreamError`. (2) Contract gap: a
value arriving with no demand outstanding is buffered and the upstream
paused, so it cannot be superseded; `"a-bc|"` k=2, consumer away → `b`
then `c`. The 10k debounce law therefore runs with a continuous consumer.
Third sweep (same day): `combineLatest`, `chunks(ofCount:or:)`,
`chunked(by:)` at 10k. Exact models hold with a continuous consumer and
no simultaneous cross-source events; `combineLatest` also holds under an
acceptance model with arbitrary demand. No new bug. The weak-spot probe
(error while no demand outstanding) is clean for both: `combineLatest`
keeps the error (`.upstreamThrew` state), `chunks` rides on merge. What
resists exact modelling is tie resolution: same-tick events across
sources, or a late consumer making events from different ticks
available in one pull, are ordered by job-hop count (base path through
`chain`+`map` loses to the signal; an error through the task group
loses to a value or an empty finish when the consumer waits, wins when
it arrives late). Pinned as facts, excluded from the laws.
Fourth sweep, cancellation (the excluded dimension): `Programmatic.run`
gained `persistentConsumer` (keep demanding after cancel), `Script.cancelling`
appends two demands after the cancel, `Model.cancellation` = at most one
flushed value then finish at the demanding tick, no hang, no error except
a source failure that predates the cancel. All seven shapes pass at 10k.
Characterization: every operator answers a cancelled task with `nil` at
the same tick and drops pending values; `chunked(by:)` flushes its
partial chunk first; `combineLatest` delivers a held pre-cancel failure
(pinned). No new bug.
Fifth round, the hook taken (as the vendored runtime already had): the
`WorkQueue` batch order is a `SchedulePolicy`; `runBatch` re-drains after
every item so newly ready jobs join the ready set (the spec's "dispatch
from the ready queue"; permuting within a batch alone changed nothing,
because hop-count ties are cross-batch); `run(schedule:)` takes a pick
function and reports choice points, ready width and a deviation log.
`TieSchedule` (deviations, empty = upstream order) is drawn by hegel.
Default order reproduces all 14 diagram self-checks. Instrumentation:
500/500 two-source scripts meet a choice point, width 3; the tie script
yields two traces. Laws under drawn schedules with ties allowed, 10k
each: merge/zip/combineLatest acceptance, cancellation for 7 shapes,
buffer no-loss (unbounded/bounded), chunks reassembly, debounce no-loss
(continuous consumer). All pass: no schedule-dependent bug in the
operators at this granularity. E2's claim is therefore demonstrated on a
real subject (order as drawn, shrinkable input) but produced no finding.
Harness lessons this round: the upstream driver's `2 × end` horizon
truncates operators that sleep past the inputs (throttle flush), so runs
now continue until the consumer terminates; an empty script returned
early with no trace. Not done: the exhaustive small-space model
enumeration; filing the issue (Nasser's call). Open: cancel laws (merge once,
buffer once) each failed a single time in a full 44-test run, never in
isolation (10k cases, 12 reruns, then 8 × the whole cancellation suite =
560k cancel scripts, all clean). It only happens after the other suites
have run in the same process, so suspect process-global state left by an
earlier run (the vendored runtime's `Context` statics, or a job that
escaped the hook window), not the operators.

## E2: schedules as shrinkable inputs

The bet. A serial executor whose "which ready job runs next" decision is a
`TestCase` draw. Then an interleaving is bytes, a race is a counterexample,
and shrinking a schedule is just shrinking. PropertyTestingKit already
draws the next job from bytes and replays it; what no Swift tool does is
shrink the schedule to a minimal interleaving a human reads. That is the
claim E2 has to earn, and PropertyTestingKit is the implementation to
compare against.

Requirements that hold across stages:

- the choice point is dispatch from the ready queue, not enqueue;
- jobs carry stable logical ids so a trace names them;
- the enqueue/ready-set trace is byte-identical under replay, not only
  the outcome;
- the scheduler has a step bound and distinguishes completion, clock
  advance, deadlock (ready set empty, work pending), runaway, and escaped
  work (a job enqueued somewhere we do not control);
- unstructured `Task {}` and `Task.detached` do not inherit SE-0417 task
  executor preference; structured children do. `merge` spawns an
  unstructured task internally (`MergeStorage.swift`), so an executor
  built on public API alone cannot route the operators E1 tests. Either
  the global hook is on the table from E2a, or E2's scope is code written
  against injectable executors and the operators are out.

Staged, each stage gating the next:

- E2a, determinism without hegel. A fixed-order executor plus a fake clock
  runs a known actor-reentrancy bug (the classic: an actor method that
  `await`s mid-body while a second call interleaves and breaks an
  invariant, e.g. a bank transfer that checks then debits). Target: the bug
  reproduces on every run under one schedule and never under another.
  This stage answers the honest question: which suspension points can we
  actually route? Actor hops onto executors we own, structured children
  of tasks we spawn, sleeps on our clock: yes. Unstructured tasks we did
  not spawn, libdispatch, real I/O: no, unless we take the global hook.
  Decide the hook question here, with PropertyTestingKit's shim as the
  worked example of what it costs (private ABI offsets, one process-wide
  scheduler). Without the hook, scope is programs written against
  injectable executors and clocks; that is loom's discipline too, and it
  is enough for actor protocols but not for swift-async-algorithms.
- E2b, hegel drives. Dispatch choice drawn from the engine. Same
  reproduce blob, same interleaving, trace byte-equal across runs; blob
  replay is the acceptance test, as in E0. Instrument the schedule generator
  before refining it, reporting the fraction of runs with at least two ready
  jobs, choice points and preemptions per run, maximum ready-set width,
  fake-clock advances, and unique trace hashes. If most generated runs contain
  no real choice point, tune the fixture or generator before claiming schedule
  exploration. PCT-style weighting
  (few random priority-change points rather than uniform choice) is the
  first refinement once uniform works; the PCT paper's guarantee is the
  reason shuttle finds bugs fast.
- E2c, shrinking. Seed the E2a bug behind a randomized schedule; the
  shrunk counterexample should be the minimal interleaving, a two or three
  step story a human reads. If shrinking produces noise instead of a
  story, the byte-to-schedule mapping is wrong (schedule choices must
  shrink toward "run to completion in spawn order", the boring schedule,
  the same way integers shrink toward zero).
  Prerequisite, decided before E2b: how the schedule reaches the failure
  report. Today the report replays the generator and prints the value;
  choices drawn during the property are shrunk and then invisible, which
  would make E2c shrink correctly and report the wrong thing. Options:
  pre-draw the schedule as part of the generated value; or record the
  trace and replay the full async property after shrinking; or extend
  `Failure` to carry the scheduler trace. Pick one, in that order of
  preference, and make the trace the thing the user reads.

Result (2026-08-26): built as `Examples/ScheduleProperties` with a
`Schedules` library target (public API only; no hook). E2a: FIFO breaks
the two-withdrawal invariant 50/50 runs with one trace, LIFO 0/50; the
fake clock orders sleepers and reports advances; a deadlock is `.stuck`.
Reach, measured: controlled = structured children,
`Task(executorPreference:)`, actors with our executor, actors with the
default executor (SE-0417 routes their jobs to the preferred task
executor — the `unownedExecutor` boilerplate question answers itself),
our clock. Escapes = `Task {}` (does not inherit the preference, as this
spec assumed), `Task.detached`, `MainActor`, real clocks, dispatch. In
each escaping case only the body leaves; the resumption returns to our
queue, so order stays deterministic and only wall time does not. The
hook question is therefore decided for now: not taken; scope is code
written against injectable executors and clocks (loom's discipline), and
the operators stay out until the hook is on the table.
E2b: policy consulted only at choice points (≥2 ready), 200/200 drawn
runs hit one, 4–8 per run, max width 2, 7 distinct traces on the fixture;
replay byte-stable (same seed → one blob → one trace across 3 runs).
E2c: the report question was settled by option 1, the schedule is the
generated value: `Schedule` = deviations `(choice, index)` from the
depth-first default, so empty is the boring schedule. The race shrinks to
exactly one deviation, "at choice point 2 run ready[0]", which is the
story (second withdrawal checks and hops; first withdrawal starts there;
both checks see 100). The test prints the trace by replaying the shrunk
schedule. Not done: PCT weighting, fake-clock cancellation, targeted
search.
PCT (2026-08-27): `Schedules.PCT` (priorities by task rank, change points at
choice-point numbers drawn from `0..<k`); task identity from
`ExecutorJob.description` (`ExecutorJob(id: N)`, stable across resumptions,
public API); step = choice point, so `k = choicePoints`; a PCT run is
restated as deviations by `Schedule(explaining:)`, so the report and shrinker
are unchanged. Runs to first failure, 20 seeds, uniform vs PCT(d=2):
twoWithdrawals (n=3, k=4) median 6 vs 3; the ThresholdCell lost wakeup
(n=6, k=24) median 72 vs 17. Both within the bound `n·k`. Fake-clock
cancellation (same day): `FakeClock.sleep` honours cancellation with
`withTaskCancellationHandler`; the timer is dropped (`cancel #id` trace line),
the sleeper throws `CancellationError` at once, and the clock does not advance
for it. Targeted search remains.

Deliverable if it survives: a `Schedules` module (name open) plus an
example; a writeup regardless, because a documented failure ("these
suspension points escape executor control, here is the list") is itself a
contribution nobody has written for Swift.

Kill criterion: E2a cannot make one honest race fully deterministic after
routing everything SE-0392/SE-0417 allow. Park the track, keep the list of
escaping points, revisit when the runtime grows hooks.

## Order and effort

E0 is days. E1 is roughly a week to first findings and ships an example
regardless. E2 is weeks and starts only after E1 lands, both because E1
funds the intuition (what schedules matter for operators) and because the
reputational route (issues and PRs on swift-async-algorithms) should not
wait on research infrastructure.

## Out of scope

- Stress-testing the concurrency runtime itself: unreproducible failures
  help nobody and cannot shrink.
- libdispatch (frozen), swift-nio (`EmbeddedEventLoop` is a fine target but
  a separate track with its own spec if pursued).
- ML frameworks (BNNS Graph, MLX): separate discussion, separate spec.

## Open questions

- Take the private `swift_task_enqueueGlobal_hook` or stay on public
  API? Decides both E1's vendoring and E2a's reach. The two existing
  Swift implementations both took it.
- How the schedule reaches the failure report (E2c prerequisite).
- Routing every actor in a test onto the controlled executor requires each
  actor to override `unownedExecutor`. Boilerplate per actor, or a macro,
  or accept "only actors written for testability"? E2a decides how much
  this hurts. Answered: it does not; default-executor actors follow the
  task executor preference. The override only buys a named lane in the trace.
- Interaction with targeted PBT (`tc.target`): schedule search guided by a
  coverage or novelty score is the natural follow-on; out of scope until
  E2c shrinks cleanly.

## References

- PropertyTestingKit (doordash-oss/PropertyTestingKit), "Schedule
  Fuzzing" section and `Sources/ScheduleControl`,
  `Sources/CScheduleHooks`. The nearest prior art; checked 2026-08-26.
- `swift-async-algorithms`, `Sources/AsyncSequenceValidation/Test.swift`
  for the hook and `swift_job_run` usage; `Package.swift` for products.
- loom (tokio-rs/loom); shuttle (awslabs/shuttle); Coyote (microsoft/coyote).
- Burckhardt et al., "A Randomized Scheduler with Probabilistic Guarantees
  of Finding Bugs" (PCT), ASPLOS 2010.
- Claessen et al., "Finding Race Conditions in Erlang with QuickCheck and
  PULSE", ICFP 2009. The direct ancestor of E2: QuickCheck drawing
  schedules.
- Walker et al., "déjà fu: A Concurrency Testing Library for Haskell",
  Haskell Symposium 2015.
- SE-0392 custom actor executors; SE-0417 task executor preference;
  SE-0329 clocks.
