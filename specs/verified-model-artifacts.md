# Verified models: a prover writes the model, Hegel checks the code against it

Status: as built, 2026-08-27. Replaces the 2026-08-27 draft of the same
name (a JSON schema with digests and claim records, written before anything
existed). Two examples exist: `Examples/AgdaVerifiedModel` (finite table,
Agda) and `Examples/LeanVerifiedModel` (evaluator with a counter, Lean 4).
The second is the one that generalises; this spec describes it. The
previous `formal-backends.md` survey is in `specs/parked/`; what it decided
is one paragraph below.

## The idea

A `Command<SUT, Model>` has three closures that talk about the model:
`precondition: (Model) -> Bool`, `args: (Model, TestCase) -> Args`, and
`model: (inout Model, Args) -> Observed`. Nothing says those have to be
Swift. A verified model is one where they call into code a prover checked:

```swift
let commands: [Command<LoginViewModel, LeanModel>] = Stimulus.allCases.map { s in
    Command("\(s)",
            precondition: { $0.enabled(s) },       // otp_enabled, compiled from Lean
            run:   { screen in screen.handle(s) },
            model: { m in m.step(s) })             // otp_step, compiled from Lean
}
try forAll(sut: Gen { _ in LoginViewModel() }, model: LeanModel.initial,
           commands: commands, consistent: consistent)
```

Two kinds of model, one API: a plain model is Swift you trust by reading
it (`[Int]` for a deque); a verified model is an evaluator you trust by its
proofs. Hegel does the same thing with both: drive the real code, compare
after every step, shrink a disagreement to the shortest walk that shows it.

What transfers: if the Swift code refines the model on the walks Hegel
tried, it inherits the model's theorems on those walks. That is finite
evidence about the code and a proof about the model. The two are never
merged into one claim.

## Layers, as built

```
Lean source            structure S; enabled; step; theorems         proved by Lean
   │  @[export] wrappers, scalars only, encoders proved to round-trip
   ▼
C ABI                  otp_enabled, otp_step, otp_initial            emitted by `lake build`
   │  static lib + Lean runtime, linked into the TEST target only
   ▼
Swift test             LeanModel { enabled, step } calling the ABI   trusted encoding
   │  Command per stimulus; consistent = α over screen and counter
   ▼
forAll(sut:model:commands:consistent:)                               Hegel, finite evidence
   │
   ▼
LoginViewModel         the shipping code; links nothing from Lean    runs on the simulator
```

The app never sees the prover. The oracle is test-side. That is why the
screen can run on iOS while the Lean runtime exists only for macOS: the test
runs where the runtime is, and checks the same view model the app binds to.

## The contract

A producer emits an evaluator with this shape. Names are the example's;
the shape is the contract.

```c
uint64_t otp_initial(void);                                  // packed state
uint8_t  otp_enabled(state..., uint8_t stimulus);            // 1 = enabled
uint64_t otp_step(state..., uint8_t stimulus);               // packed (response, next state)
```

Rules:

- **Scalars only across the ABI.** Enums are tags, counters are fixed-width
  integers, results are packed words. No prover-runtime objects cross. The
  encoders live on the prover side and are proved to round-trip
  (`Screen.ofTag_tag` in the Lean example); the Swift decoders are trusted.
- **`enabled` and `step` are the model.** Applicability and transition,
  both from the prover. Swift writes nothing about the domain twice.
- **A finite model is the same contract with a table behind it.** The Agda
  door exports its six cells to JSON and Swift loads them into
  `Enumeration`, whose `commands(run:)` produces the same `Command`s. Tables
  are a special case, not the format.
- **The theorems come along as text.** Names of what was proved, in the
  README and, if the app explains itself, on the screen. Not in the
  artifact: Swift cannot check them, so listing them in a file adds nothing
  but a false sense of provenance.

## What is checked and what is trusted

Checked by the prover: totality of `step`, the invariant, the theorems, the
encoder round-trips. Checked by Hegel: the Swift code refines the evaluator
on the walks it ran, including α after every step and, for a screen, that
its affordances equal `enabled`. Trusted: the prover's C emission and
runtime, the Swift-side tag decoding, the `run:` adapter, the SwiftUI layer.
Say all three lists wherever the word "verified" appears.

## Producers

Any prover that can emit the ABI is a backend. What decides fit is
extraction, not logic strength:

| producer | evaluator Swift can link | table |
|---|---|---|
| Lean 4 | yes: `lake build` to C, static lib, links directly (`libInit`, `libleanrt`, `libuv`, `libgmp`, ~17 MB, macOS arm64 from the toolchain) | yes |
| Agda | GHC binary only; external process, not linkable | yes (done) |
| F* | KaRaMeL to C; untried | yes |
| TLA+/TLC | no evaluator; bounded state graph or traces | bounded instance only |

Lean first for anything with a counter. Agda for tables it already has.
TLA+ when the concurrency lane needs a model checker, not before. Iris,
Pulse and the like verify implementations, not models; they are not
producers here.

## Findings from the two examples

- Lean rejected the first invariant (`attempts ≤ 3`; not preserved on the
  code screen at 3). The prover corrected the spec before any test ran.
- α with the counter caught the Swift screen keeping `attempts` after
  sign-in; no response shows it. Observation-only model-based testing
  would have passed.
- The observation-only minimum for the resend bug is 5 steps; with α it is
  3. The enumeration form's 6 included a no-op `enterPhone`.
- The door's hand-listed `cells` was the gap in the Agda example: coverage
  checking proves `step` total, not that an exporter enumerated every
  input. The block-form `Enumeration.problems()` now checks the loaded
  table's completeness on the Swift side.
- The affordance property against Lean's `enabled` catches a planted UI bug
  (Back hidden on the locked screen) at the step the lock is reached:
  `back looks disabled but Lean says legal in locked/3`, four steps.
- SPM does not notice new source files in a path dependency; stale
  `Hegel.swiftmodule` in an example's `.build` reads as "cannot find type".
  Clean the example's `.build/arm64-apple-macosx`.

## Concurrency: relations, schedules as the resolver

The stateful form needs a deterministic `step`. A concurrent model is a
relation: several events enabled at once. What was built (`Lean/Bank`,
`ConcurrencyTests.swift`) resolves it without a new API: the *schedule* is
Hegel's drawn input (as in `ScheduleProperties`), the run produces a trace
of semantic events recorded at the subject's boundary, and refinement is
"the trace is a path of the relation and the model's final observation is
the subject's". So `enabled`/`step` over the ABI are enough; no successor
selection inside `model:`, because the subject already chose.

Results: the safe actor refines the safe relation under 300 schedules and
inherits `safe_paths_nonneg` on them; the unsafe actor refines the unsafe
relation, so the race is a behaviour the model admits (Lean's
`unsafe_race`), not a refinement failure; the invariant property shrinks to
one deviation with the event trace as explanation. Instrumentation at the
guard and the debit is synchronous and preserved the race for the three
fixed policies. This answers the parked verified-concurrency draft's
question at its E4 stage with Lean instead of Agda; its kill criteria did
not fire (no ABI assumptions, no executor queues in the model, ~60 lines
of Lean for the domain).

## Not done

- The prover runtime for iOS, so a test could run on the simulator. Not
  needed: the oracle is test-side.
- Nondeterministic models inside `Command` (the stateful form drawing the
  successor). The concurrency section shows the schedule-resolved form
  instead; the `Command` form still waits for an example.
- Dumping Lean's answers over the finite reachable space to JSON so the
  app could show "Lean says" live. Cute, second artifact to maintain.
- Provenance (source digests, tool versions in the artifact). Add when two
  people regenerate the same model on different machines and disagree.

## References

- `Examples/LeanVerifiedModel/README.md`, `Examples/AgdaVerifiedModel/README.md`.
- `specs/model-based.md` for `Command` and the driver.
- Hoare, *Proof of correctness of data representations*, 1972 (the
  simulation square the whole thing draws).
