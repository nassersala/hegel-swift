# What the tester recovers of the modal types

Status: experiment, run 2026-09-03. `Examples/AboveTheCode/Sources/AboveTheCode/Causal.swift`,
`Tests/AboveTheCodeTests/CausalTests.swift`.

## Question

Lively RaTT (Bahr, Graulund, Møgelberg, POPL 2021) makes three failures
of reactive code type errors: a non-causal function, since a later value
cannot be advanced before the tick; a space leak, since only stable
values survive a tick; an unproductive stream, since every recursive
call is guarded by one. Swift cannot carry the modal type system, and
neither can Haskell without a compiler plugin. The wiki page
`connections/liveness-by-types-versus-liveness-by-testing.md` predicts
where a tester stands instead: safety properties are recovered as
refutations, liveness only as a bounded surrogate, and the bridge is
`timeout`. The experiment is that prediction, run.

For a developer: reactive code in Swift, a Combine pipeline or an
AsyncSequence chain, goes wrong in three ways no ordinary test catches.
It reads the future, it holds on to the past, or it stops producing.
Can a test find each, and what does the report say?

## The relation

Drawn first on a moving average over two samples, three ticks. The
variables read off the rows: `now`, `emitted`, and `held`, the input
ticks the function still keeps. A step is a read, an emit, or a tick.

```
Init:  now = 0 ∧ emitted = {}
Next:  Read(k):        k ≤ now
     ∨ Emit(k, held):  k = now ∧ k ∉ emitted ∧ held ⊆ k−W..k ∧ emitted′ = emitted ∪ {k}
     ∨ Tick:           now ∈ emitted ∧ now′ = now + 1
```

The three clauses are the three modalities. Read is the later modality,
Emit's `held` clause is the box modality with `W` the window the
function declares, and Tick's guard is guarded recursion as a safety
clause: a tick without an output is not a step. The clock is the
environment, run on the scheduler's fake clock, which advances only when
nothing is ready; that is what lets the run reach the state where the
tick came and the output had not.

## Subjects

Two the types would accept: the running average as a fold (window 0)
and the moving average holding one input (window 1). Four they would
refuse: a lookahead reading tick t+1 for tick t; the running average
keeping every sample; a function that at tick 1 waits for an input that
never comes; the same function polling for it instead of waiting. The
environment draws the inputs, whether the source runs one ahead, and a
schedule.

## Results

| The type would have refused | The report | Found at |
|---|---|---|
| advancing on the data, not the tick (the first draft of the accepted functions) | `read 1 @0: reads tick 1 at tick 0: the future` | 2 ticks, source ahead, default schedule |
| lookahead, source ahead | `read t+1 @t: the future` | every case |
| lookahead, source not ahead | `tick @t: tick t+1 with no output for tick t: unproductive` | every case |
| keeping every sample, window 0 | `emit 1 holding [0, 1] @1: holds tick 0 at tick 1` | 2 ticks |
| waiting for an input that never comes | `tick @1: unproductive`, then `.stuck` | 3 ticks, the tick before the stuck |
| polling for it | no moment refused; `.runaway` at every budget 24…64 steps | the budget, not the trace |

The accepted functions, once they advance on the tick, refine under 200
drawn schedules with every output the reference. Choice points are few,
at most two: the scheduler's contribution here is the fake clock, not
the interleavings.

## Findings

1. **The first refutation was of the accepted functions.** As first
   written, every function advanced when its next input arrived. Under a
   source one ahead, that reads the future, and the relation said so at
   step 2 on the default schedule. Advancing a later value under a tick
   is a synchronisation with the clock, not with the data, and Swift
   code that awaits the next element does the wrong one by default.
   Kept as `waitsForTick: false` and its test.
2. **One bug, two reports.** The lookahead is refused as the future when
   the source runs ahead and as an unproductive tick when it does not.
   The report depends on the environment, not the function, and both
   are the same clause's complement.
3. **Two of three guarantees come back whole.** Causality and space are
   safety properties; each is refuted by a shrunk trace at two ticks,
   with the reason the type error would have given.
4. **Productivity comes back as a bound.** Waiting forever is refused at
   the next tick, because the clock fires when the function idles.
   Polling forever never idles, so no tick fires and no moment is
   refused; the run reports only that a step budget ran out. No budget
   distinguishes not yet from never. That is the `timeout` of Diamonds
   as a test, and the `1` in its type is the `.runaway`.

## What this does not say

- Nothing about a real Combine or AsyncSequence pipeline. Six functions
  on a tape, one planted bug each.
- The budget here is scheduler steps, drawn from the accepted function's
  own step count. The escape tests in `Examples/ScheduleProperties` keep
  their wall-clock grace, because escaped work is off the scheduler and
  wall time is the only clock it has; the wiki's suggestion to draw that
  bound applies to work under control, which is this experiment.
- Whether a developer would state these three properties about their
  own pipeline is the skill's open question, E4, not this one.
- No TLA twin. The relation is three clauses and the finding is about
  the tester, not the state space.
