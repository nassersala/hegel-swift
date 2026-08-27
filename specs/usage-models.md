# Usage models: what to take from Cleanroom

Status: draft 1, 2026-08-21. Nothing here is built. Written to be read
and argued with in a later session; the "Open questions" are real.

## Why

Cleanroom software engineering (Mills, Linger, IBM, late 1980s; the
Markov-chain form is Whittaker & Thomason 1994) has five ideas. One of them
— statistical usage testing — asks a question hegel does not: *does this
sample resemble real use, and what does n failure-free cases then say about
reliability?* Hegel's sampling is built to find bugs, not to resemble use,
and it should stay that way. But the usage model itself (states,
transitions, probabilities from the operational profile) is a state
machine, which hegel already runs — and hegel runs it with a shrinker,
which Cleanroom never had. "The shortest realistic sequence of user actions
that breaks it" is a better bug report than either discipline produces
alone.

Three of the five ideas are worth taking; this spec says which and how.

| Cleanroom | Here | Take? |
|---|---|---|
| Black box → state box → clear box (specification by refinement) | laws/relations → rules/invariants → the code | Yes, as framing: the recommended order of writing properties |
| Intended functions (every control structure has one; verify against it) | per-rule postconditions — a model of each transition | Yes, `Rule` gains `postcondition:` |
| Statistical usage testing (usage model, random walks, certification) | `frequency`, `UsageModel`, two drivers, arc coverage, reliability bound | Yes, in that order, when an example pulls it |
| Defects as rare events; reliability growth across increments | distinct bugs per version from the example database | Later, with the certification function |
| No debugging; verify by reasoning | the minimal counterexample is an argument, not a stack trace | As a sentence, not a feature |

Not taken: team review process, no-unit-tests-by-developers, a separate
certification team, incremental planning by usage probability.

## Semantic interpretation (2026-08-27 addendum)

An operational usage profile has probability as part of its mathematical
meaning. For usage states `U`, it is a Markov kernel assigning a probability
distribution over permitted labeled transitions and successor states:

```text
K : U -> Distribution(Transition x U)
```

Integer weights are a finite representation of that kernel after
normalization. The same weights have two different interpretations in this
spec's two drivers:

- the representative driver samples the kernel and may support qualified
  statistical claims under its stated independence and stopping assumptions;
- the Hegel driver uses the transition support and weights as adversarial
  search guidance, with shrinking, mutation, reuse, boundary bias, and
  targeting. Its empirical frequencies are not the operational profile.

Thus `frequency` does not acquire probability semantics merely because a usage
model calls it. The `UsageModel` value carries the intended kernel; the driver
determines whether a run is a representative interpretation or a search
interpretation. See `specs/generator-semantics.md`.

The state-transition meaning is shared with `specs/model-based.md`: a usage
model adds an operational profile over permitted transitions, while an
`Operation` supplies the abstract/concrete refinement check. The unresolved
draw-source integration must not be solved by weakening this distinction.

`Rule.postcondition` below was superseded by `Operation.post` in
`specs/model-based.md`; retain it here as draft history, but do not implement it
as a parallel API.

## What hegel has and does not have

Has: stateful testing — `Rule<State>` (`name`, `precondition`, `step:
(inout State, TestCase) throws`), `Invariant<State>`, `forAll(initial:
rules:invariants:maximize:)`, `Pool`. Rules are transitions, invariants are
the spec. `Gen.bool(probability:)` is the only weighted primitive; `oneOf`
is uniform.

Does not have (checked against `hegel.h`): weighted rule selection — the
engine picks uniformly over a random subset of enabled rules per case;
weighted choice among generators; any notion of an operational profile; a
"representative sampling" mode. And the engine's distribution is
deliberately not representative: integer draws favor boundaries and small
values, the mutation machinery duplicates earlier spans, the reuse phase
replays past failures, targeting climbs scores. Turning phases off
(`HEGEL_PHASE_GENERATE` only) leaves the generation-time biases in place.
`hegel_backend_t` changes where bytes come from, not how they are
interpreted. A faithful representative mode would be an upstream feature;
this spec does not wait for it.

## Design rules

1. **One model, two drivers.** `Rule` and `Invariant` are values. The same
   usage model runs under hegel (adversarial: engine-biased draws,
   shrinking, targeting — for *finding*) and under a plain pseudo-random
   driver (representative: faithful to the profile — for *counting*). We
   do not make the engine be what it isn't, and we do not claim
   representativeness for a hegel run.
2. **The profile is the caller's.** Transition probabilities come from the
   operational profile (logs, analytics, a guess written down). The
   library never invents weights.
3. **Same shape.** A usage model is one `Rule` whose step draws the next
   transition by weight. Nothing new in the engine protocol; the failure
   display is the existing `StatefulRun` trace, so a violation shrinks to
   the minimal walk.
4. **Numbers only where they mean something.** Arc coverage and the
   discriminant are reported for every driver (they are facts about the
   walks taken). The reliability bound is computed only from the
   representative driver's runs, and the doc says why.
5. **Small.** `frequency`, `UsageModel`, `Rule.postcondition`, two
   reporting functions. Anything else is the user's `forAll`.

## API

### `frequency`

```swift
/// Weighted choice. Shrinks toward the first generator, like `oneOf`.
public func frequency<A>(_ weighted: [(weight: Int, gen: Gen<A>)]) -> Gen<A>
```

One `drawInteger(in: 0..<total)` mapped over cumulative weights. Ten
lines; independent of everything else; should exist regardless.

### `Rule.postcondition`

```swift
public struct Rule<State>: Sendable {
    public let name: String
    public let precondition: @Sendable (State) -> Bool
    public let step: @Sendable (inout State, TestCase) throws -> Void
    /// The intended function of the step: given the state before and the
    /// state after, throw if the transition did not do what it claims.
    /// Checked before the invariants. Default: nothing.
    public let postcondition: @Sendable (_ before: State, _ after: State) throws -> Void
}
```

Invariants say "never in a bad state"; postconditions say "this operation
did what it claims" — the second catches two wrongs that preserve the
invariant. This is model-based testing's model, per rule. The step display
gains a `postcondition <name> failed` line, like invariants.

Open: should `postcondition` also see the drawn arguments? The step draws
them from the `TestCase` and they are not otherwise captured. Either the
step returns a value the postcondition receives (`step: (inout State,
TestCase) throws -> Args`, changing the signature) or the rule records
them itself in `State`. Decide when the first postcondition needs an
argument.

### `UsageModel`

```swift
/// A Markov usage model: a finite set of usage states, transitions with
/// weights from the operational profile, and what each transition does to
/// the system under test.
public struct UsageModel<Usage: Hashable & Sendable, State>: Sendable {
    public struct Transition: Sendable {
        public let name: String
        public let weight: Int
        public let to: Usage
        public let step: @Sendable (inout State, TestCase) throws -> Void
        public let postcondition: @Sendable (State, State) throws -> Void
    }
    public let initial: Usage
    public let transitions: [Usage: [Transition]]
    public let terminal: Set<Usage>      // walks end here (Cleanroom's "exit")

    /// The model as a single hegel rule over (usage, state): the step draws
    /// the next transition from the current usage state's weighted row.
    /// Under hegel this is an adversarial search interpretation, not a
    /// representative sample of the profile.
    public func rule() -> Rule<(usage: Usage, state: State)>
}
```

Hegel driver: `forAll(initial: (model.initial, s0), rules: [model.rule()],
invariants: …)` — everything else is the existing stateful runner.
Shrinking works because the transition choices are draws.

Representative driver:

```swift
/// Walks the model with a plain pseudo-random generator, faithful to the
/// weights, no engine heuristics. Returns every walk's trace and outcome.
public func walk<Usage, State>(
    _ model: UsageModel<Usage, State>, initial: State,
    invariants: [Invariant<State>], walks: Int, maxSteps: Int,
    using rng: inout some RandomNumberGenerator
) -> UsageReport<Usage>
```

Draws are `rng` here, not a `TestCase`, so `Transition.step` needs a draw
source that is either: an abstraction over `TestCase`/`RandomNumberGenerator`
(new type, invasive), or the representative driver wraps `rng` in a
`TestCase`-shaped object that does not talk to libhegel. Open question; the
second is likelier. If neither is acceptable, the representative driver's
steps take no arguments and the model is coarser under it — the honest
fallback.

### Reporting

```swift
public struct UsageReport<Usage: Hashable> {
    /// Each arc (from, transition) → times taken across all walks.
    public let arcCounts: [Arc<Usage>: Int]
    /// Arcs with fewer than k executions; empty means k-coverage.
    public func uncovered(below k: Int) -> [Arc<Usage>]
    /// Whittaker & Thomason's discriminant between the executed chain and
    /// the model chain: 0 when the empirical transition frequencies match
    /// the weights; the stopping criterion is "small enough".
    public let discriminant: Double
    /// Walks, failures, and — from the representative driver only — the
    /// failure-probability bound: zero failures in n walks ⇒ p < −ln α / n
    /// at confidence 1 − α (≈ 3/n at 95%). Nil under the hegel driver.
    public let reliability: ReliabilityBound?
}
```

Arc coverage is the first honest answer to "how many test cases do I
need?" — not 100, but "until every arc the profile says matters has run k
times." The discriminant is Cleanroom's stopping rule. Both are facts about
the walks, so both are reported for either driver; the reliability bound is
only meaningful under the representative one and is nil otherwise.

### Framing (README, not API)

The order of writing properties, as box structures: the **black box**
first — laws and metamorphic relations, statements over inputs and outputs
with no state (`Laws.semilattice` for merge, a homomorphism for balances);
the **state box** next — rules, invariants, postconditions, a usage model
if there is a profile; the **clear box** is the code. The Tabs walkthrough
in the README (when written) follows this order and says so.

## Examples plan

1. **Core tests**: `frequency` distribution sanity (weights 3:1 land near
   3:1 under the representative driver; under hegel, no claim), the
   usage-model rule shrinking a seeded failing walk to its minimal trace, a
   postcondition catching a step that preserves the invariant and lies.
2. **AffordanceProperties**: the alarm model with a usage profile ("snooze
   10× more often than edit"); the same model under both drivers; arc
   coverage and discriminant printed; reliability bound from the
   representative run. This is where the README paragraph lands.
3. **Tabs** (the expense-splitting example, if it is written): the
   merge/edit/sync usage model; black box (semilattice, homomorphism) →
   state box (the model) → clear box, in that order, as the worked
   illustration of box structures.

## Non-goals

- No representative mode inside the hegel run; no claim that a hegel run's
  sample is the operational profile.
- No MTTF projection or reliability-growth tracking in v1; the bound above
  is one function, the rest is a chart someone else draws.
- No automatic profile extraction from logs.

## Experiment (2026-08-22, scratchpad, not in the repo)

A one-time-code login done Cleanroom-style: an enumeration table of 7
canonical states × 6 abstract stimuli (28 legal rows, 14 illegal cells, a
requirement tag per row); rules, a completeness check, a requirement-
coverage check and a weighted usage model all *derived* from the table;
a planted bug (resend resets the attempt counter). Findings:

- The completeness check catches a deleted cell (`locked.goodCode`) by name.
- Derived rules, engine-chosen: the bug is found 5/5 seeds at 200 cases and
  shrinks to the 6-step minimal walk `enterPhone → send → badCode →
  resend → badCode → badCode`, violation text naming the requirement
  ("expected lockOut (R7 three bad codes lock), got showError").
- The usage model as ONE weighted rule: found 2/5 seeds at 200 cases, 5/5
  at 1000 — profile-faithful sampling is worse at *finding*, exactly the
  two-drivers argument, now measured (resend is rare in the profile).
- Display gap: the usage rule's trace prints `usage × 6`; the drawn
  stimulus must be part of the step label. `Rule.step` cannot name what it
  drew — either the step returns a label, or `UsageModel.rule()` is a
  family of rules (one per stimulus, precondition by weight) so the
  existing display works. The second keeps the runner untouched.

Reshaped to Aaron Hsu's form (his LambdaConf 2025 talk, the Cleanroom
security alarm in APL): each canonical state **named by its sequence**
(`""`, `P`, `P.S`, `P.S.b`, `P.S.b.b`, …), one block per state listing
*every* stimulus with illegal cells inline, `response ⋄ →next` — so the
equivalence decisions (`P.S.r → P.S`: "resend keeps the count") are visible
on the page, and completeness is "every block has every stimulus and every
→next is a block", checked mechanically. Same bug, same 6-step walk, and the
trace now reads as the enumeration itself:
`Δ ▸ enterPhone, P ▸ send, P.S ▸ badCode, P.S.b ▸ resend, P.S.b ▸ badCode,
P.S.b.b ▸ badCode failed — expected lockOut (R7), got showError`. This is
the form the example should take: `spec: [Sequence: [Stimulus: Outcome]]`,
rules derived, nothing else.

## Aaron Hsu's security alarm, transcribed (from three screenshots of his talk)

Stimuli S (set), T (trip), B (bad digit), G (good digit), C (clear).
Responses Light_on, Light_off, Alarm_on, Alarm_off. Nine canonical
states, named by sequence; `∘∘∘` = illegal (Dyalog: deliberate error);
`→0` = exit. Cells in *italics* are not in the screenshots and are
inferred from the pattern — verify before using.

| state | S | T | B | C | G |
|---|---|---|---|---|---|
| Δ_ | Light_on → Δ_S_ | ∘∘∘ →0 | ∘∘∘ →0 | ∘∘∘ →0 | ∘∘∘ →0 |
| Δ_S_ | → Δ_S_ | Alarm_on → Δ_S_T_ | → Δ_S_B_ | → Δ_S_ | → Δ_S_G_ |
| Δ_S_T_ | → Δ_S_T_ | → Δ_S_T_ | → Δ_S_T_B_ | → Δ_S_T_ | → Δ_S_T_G_ |
| Δ_S_B_ | *→ Δ_S_B_* | *Alarm_on → Δ_S_T_B_* | *→ Δ_S_B_* | *→ Δ_S_* | *→ Δ_S_B_* |
| Δ_S_G_ | *→ Δ_S_G_* | *Alarm_on → Δ_S_T_B_* | *→ Δ_S_B_* | *→ Δ_S_* | *→ Δ_S_G_G_* |
| Δ_S_T_B_ | → Δ_S_T_B_ | → Δ_S_T_B_ | → Δ_S_T_B_ | → Δ_S_T_ | **∘∘∘ ⋄ → Δ_S_G_G_** |
| Δ_S_T_G_ | → Δ_S_T_G_ | → Δ_S_T_G_ | → Δ_S_T_B_ | → Δ_S_T_ | → Δ_S_T_G_G_ |
| Δ_S_G_G_ | → Δ_S_G_G_ | Alarm_on → Δ_S_T_B_ | → Δ_S_B_ | → Δ_S_ | Light_off → Δ_ |
| Δ_S_T_G_G_ | → Δ_S_T_G_G_ | → Δ_S_T_G_G_ | → Δ_S_T_B_ | → Δ_S_T_ | Alarm_off ⋄ Light_off → Δ_ |

Readings worth keeping:

- Δ_S_G_G_ and Δ_S_T_G_G_ are distinct states for exactly the enumeration
  reason: same history shape, different future (third G gives Light_off
  vs Alarm_off ⋄ Light_off). Equivalence is about the future, not the
  past.
- A trip during code entry (Δ_S_G_G_ T → Δ_S_T_B_) *invalidates* the
  partial entry — the user must Clear. A design decision, visible in the
  table, that a hand-written implementation would make by accident.
- **The cell in bold** (Δ_S_T_B_ G: `∘∘∘ ⋄ →Δ_S_G_G_`) is, as
  screenshotted, both illegal and a transition — and a transition to a
  state that drops the trip and counts a bad digit as two good ones. Most
  likely a placeholder left in the demo. Two of our derived checks flag
  it mechanically: (1) an `Outcome` is `.illegal` *or* `.respond(then:)`,
  never both — the type makes the contradiction unrepresentable; (2) an
  illegal cell needs a justification that the stimulus cannot occur
  (control not on screen) — on a keypad, G after B can always occur, so
  the cell cannot be illegal. Cleanroom says only humans can verify the
  spec; this is the part a machine can do, and it found one in the
  canonical example.

This is the example to port: nine states × five stimuli as an exhaustive
`switch`, the bold cell corrected to `→ Δ_S_T_B_` and the correction cited
as a requirement note, a planted implementation bug, the shrunk walk.

## Open questions

- `Rule.postcondition` and access to the drawn arguments (above).
- The draw source for `Transition.step` under the representative driver
  (above). This is the one design decision that could change the shape.
- Whether `UsageModel` should reuse `Rule` directly (a transition is a rule
  plus a weight and a target usage state) or stay its own type. Reusing
  `Rule` would let an existing stateful suite gain a profile by adding
  weights; that is attractive and may be the right answer.
- Whether to ask upstream (hegeldev/hegel-rust) for weighted rule selection
  and a representative-sampling flag. Worth filing as a question regardless
  of what we build; their answer changes how much of this stays in Swift.

## References

- Mills, Dyer, Linger, *Cleanroom Software Engineering*, IEEE Software 1987.
- Whittaker & Thomason, *A Markov Chain Model for Statistical Software
  Testing*, IEEE TSE 1994 — usage chains, the testing chain, the
  discriminant as stopping criterion.
- Prowell, Trammell, Linger, Poore, *Cleanroom Software Engineering:
  Technology and Process* (1999) — box structures, intended functions.
- Musa, *Operational Profiles in Software-Reliability Engineering*, IEEE
  Software 1993 — where the weights come from.
- `specs/laws.md` — the same "same shape, witnesses, small" rules apply.
