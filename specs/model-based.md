# Model-based testing: the Hughes form as a first-class layer

Status: draft 2, 2026-08-26. Nothing here is built. Draft 1 (2026-08-25)
went through an outside review that found seven real problems; this draft
incorporates all of them. The "Open questions" are real. Reading order:
after `specs/laws.md` and `specs/usage-models.md` — this spec answers two
questions the latter left open and subsumes its `Rule.postcondition`
proposal.

## Why

Hughes (*How to Specify It!*, TFP 2019) measured five ways of writing
properties against planted bugs in one pure-function benchmark (a binary
search tree, eight buggy variants). On that benchmark, model-based tests —
an abstraction function to a simpler model, one commuting-square property
per operation — were a complete specification, found the most bugs per
property, and found them fastest (mean ~6 tests to failure vs ~60 for
metamorphic). That is one benchmark, not a universal ranking; what
generalizes is the shape, and his Q&A remark that the stateful form of the
same idea is how Quviq tested stateful code commercially (eqc_statem).

hegel has the mechanism (stateful `Rule`/`Invariant`) but not the
discipline. The pattern has now been hand-rolled three times — the OTP
enumeration experiment, Aaron Hsu's alarm port, `Examples/AgentProperties`
— and each rewrote the same ~30 lines: a combined state struct holding
tracked model + SUT, a hand-written comparison inside every step, an α
invariant checking the two have not drifted. Third rewrite is the signal.

Stateful PBT and model-based testing are different axes. Stateful is how
you drive: generated operation sequences against a mutable system.
Model-based is where the oracle comes from: a simpler abstract
implementation you compare against. Rules-and-invariants without a model
is Hypothesis's shape, and invariant-only properties were the weakest
scorer in Hughes's table (38%) because two wrongs can preserve an
invariant. The model says what each operation must make happen.

One sentence for the README: invariants say what must never happen; a
model says what each operation must make happen. (Rules are drivers, not
assertions.)

## Semantic interpretation (2026-08-27 addendum)

`specs/denotational-design.md` gives the general account: model-based testing
checks a commuting square or, for nondeterministic systems, an observational
refinement.

For model states `M`, arguments `A`, observations `O`, and successor states
`M'`, the abstract meaning of an operation family is a relation:

```text
T subset M x A x O x M'
```

The v1 `Operation` API below presents the deterministic special case with
closures: `model` computes the successor and either `post` or `equal` checks
the observation. `Operation` is therefore an executable presentation of the
relation, not the relation's mathematical definition.

The concrete SUT is related to `M` by an observation/abstraction boundary. The
draft's `consistent:` witness is the operational form of that boundary: it can
reject an illegal concrete state or report that concrete and abstract
observations have drifted. Direct equality between a SUT and its model is only
a special case.

One generated step investigates forward simulation:

1. `args` selects an abstractly permitted operation from the model alone;
2. `run` executes the concrete operation;
3. `model` advances the abstract state;
4. `post`/`equal` checks the operation observation;
5. `consistent` checks the concrete-to-abstract relation.

A successful finite Hegel run is evidence for refinement, not a proof for all
programs. A verified artifact may later supply the abstract relation, but the
mapping from artifact actions and observations to Swift closures remains a
small trusted test boundary. That adapter belongs to
`specs/verified-model-artifacts.md`; it is not added to v1 until the experiment
validates it.

Nondeterministic successor relations are intentionally outside this v1 API.
Forcing them through a deterministic closure would choose an oracle path too
early; add them only after a concrete example establishes selection and
shrinking semantics.

## Design rules

Same as `specs/laws.md`: one shape, witnesses not protocols, small.

1. **Lowering onto the existing runner; engine protocol untouched.**
   `Operation<SUT, Model>` lowers to `Rule<(sut: SUT, model: Model)>`
   (`operation.rule()`). The libhegel protocol does not change. One
   Swift-side change to `Rule` and the runner loop is required and
   accepted — see "The one runner change" below; it is backwards
   compatible and benefits plain rules too. `Rule` remains the right tool
   when there is no model.
2. **Arguments and applicability depend only on the model, never the
   SUT.** Quviq's discipline, widened from draft 1's "precondition sees
   Model": argument *generation* is model-dependent too (remove an
   existing key, transfer at most the modeled balance, pick a previously
   created handle). Needing the SUT to decide what is legal or drawable
   means the model is too weak; the signatures make it unrepresentable.
3. **Args are a phase, not a burial.** Drawn arguments are separate from
   the step so that (a) the postcondition sees them, (b) the trace prints
   them, (c) rejection (`assume`) can be confined to the drawing phase.
   This closes both open questions in `specs/usage-models.md`: "should
   `postcondition` see the drawn arguments?" and the `usage × 6` display
   gap.
4. **Model has value semantics.** Stated, not checked: `modelBefore`
   means "before" only if assigning copies. A reference-typed model
   aliases across steps and across test cases; the docs say so the way
   the runner's snapshot comment says it for `State`.
5. **α runs on the initial state and after every successful step.** It is
   what caught the monitor bugs in AgentProperties, and transient drift
   is invisible at end-of-run. Sampling is future work if an example
   demonstrates a real cost.
6. **The trap is documentation, not API.** Hughes's warning — the model
   ends up resembling the implementation — is answered in the README
   (model-based first when a genuinely simpler model exists; metamorphic
   as the second string), not with machinery.

## The one runner change: dynamic step descriptions

Draft 1 promised traces like `pushBack(47)` and claimed the runner
untouched. Both cannot hold: rule names are registered with libhegel
before execution and the Swift-side trace appends the static `rule.name`
after each successful step (`Sources/Hegel/Stateful.swift`). The engine
never sees step descriptions — the `steps` array is ours — so the fix is
Swift-side only:

```swift
public struct Rule<State>: Sendable {
    // unchanged: name, precondition, step
    /// Optional: what this step should be called in the displayed trace,
    /// decided after the step ran (so it can name drawn arguments).
    /// nil (the default) keeps today's behavior: the static name.
    public let describeStep: (@Sendable (State) -> String)?
}
```

The runner loop appends `describeStep?(state) ?? rule.name`. Existing
rules are untouched; the engine still registers static names (its view is
selection indices, not display). `Operation.rule()` supplies
`describeStep` from the operation's own record of the last drawn args and
observed value. Display of observed values needs its own witness — see
`describe:`/`describeObserved:` below; `-> -3` in a trace comes from the
observed formatter, not the args formatter.

This is the first thing to build, because everything about the display
promise depends on it.

## API

### The stateful form: `Operation`

```swift
/// One operation family of a model-based stateful test: draw arguments
/// (from the model), run the real system, advance the abstract model,
/// compare what happened with what the model says must happen.
public struct Operation<SUT, Model>: Sendable {
    public let name: String
    // Args and Observed are per-operation generics on the initializers,
    // erased into the lowered rule's closures.

    public init<Args: Sendable, Observed: Sendable>(
        _ name: String,
        precondition: @escaping @Sendable (Model) -> Bool = { _ in true },
        args: @escaping @Sendable (Model, TestCase) throws -> Args,
        run: @escaping @Sendable (inout SUT, Args) throws -> Observed,
        model: @escaping @Sendable (inout Model, Args) -> Void,
        post: @escaping @Sendable (_ modelBefore: Model, _ args: Args, _ observed: Observed) throws -> Void,
        describe: @escaping @Sendable (Args) -> String = { "\($0)" },
        describeObserved: @escaping @Sendable (Observed) -> String? = { _ in nil }
    )

    /// The lowering. The engine never learns about Operation.
    public func rule() -> Rule<(sut: SUT, model: Model)>
}
```

Three semantic conveniences (the review's call; the `Laws` overload
precedent):

1. **Explicit post** — the designated form above.
2. **Expected-result equality** — the model op returns the expected
   observation; equality is an explicit witness, consistent with `Laws`:
   `model: (inout Model, Args) -> Observed`, plus
   `equal: (Observed, Observed) -> Bool` (with an `Observed: Equatable`
   overload omitting it).
3. **Effect-only** — `run` returns `Void` (which cannot conform to
   `Equatable`, so this is its own form, not a default): no `post`, the
   comparison is carried entirely by α and invariants.

Nullary sugar: `args:` omitted when `Args == Void`.

Rejection semantics, tightened at this layer (the runner rolls back a
mid-rule `assume` to a value snapshot and already documents that
reference state is the author's problem):

- `assume` (filtering) is permitted in `args` — nothing has run yet;
  the lowered rule rethrows it before touching the SUT.
- `assume` escaping `run` or `post` is misuse and is converted into a
  violation naming the operation, not a rejection — a reference-typed
  SUT may already have executed.
- An expected SUT error is not a violation: capture it as the `Observed`
  value (`Result`-shaped) and let `post` assert on it.

### The driver

The initial SUT and its model are one generated value — a non-empty SUT
must arrive paired with the model that describes it, and a fresh model
per test case is what makes reference-model aliasing impossible to
observe even when rule 4 is violated:

```swift
public func forAll<SUT, Model>(
    initial: Gen<(sut: SUT, model: Model)>,
    operations: [Operation<SUT, Model>],
    /// α: recompute the model from the SUT; throws to report both
    /// illegality ("this SUT state abstracts to nothing") and drift.
    /// Checked on the initial pair and after every successful step.
    consistent: (@Sendable (SUT, Model) throws -> Void)? = nil,
    invariants: [Invariant<(sut: SUT, model: Model)>] = [],
    // ... the usual: testCases, seed, database, settings, maximize, file, line
) throws
```

Sugar for the common empty start: `forAll(sut: Gen<SUT>, model: Model,
...)` wrapping the pair — valid only because a fresh model value is
copied per case; the doc says why.

α as drafted in v1 (`(SUT) -> Model` compared by `==`) fails twice: no
equality witness for an unconstrained `Model`, and the motivating agent α
is partial (an illegal effects log has no abstraction). A throwing
consistency witness covers both — `alpha` in AgentProperties becomes

```swift
consistent: { agent, model in
    guard let s = alpha(agent.tools.effects) else { throw Mismatch("effects are not a legal walk") }
    guard s == model.state else { throw Mismatch("α(effects) = \(s), model is \(model.state)") }
}
```

An `abstraction:` + `equal:` convenience can wrap the total-α case.

### Usage, the backlog example

swift-collections `Deque` vs `Array`, with a model-dependent draw:

```swift
let pushBack = Operation<Deque<Int>, [Int]>(
    "pushBack",
    args: { _, tc in try Gen.int(in: -100...100).run(tc) },
    run:   { deque, x in deque.append(x) },
    model: { array, x in array.append(x) })          // effect-only form

let removeExisting = Operation<Deque<Int>, [Int]>(  // args need the model
    "removeExisting",
    precondition: { !$0.isEmpty },
    args: { model, tc in try Gen.int(in: 0...Int64(model.count - 1)).run(tc) },
    run:   { deque, i in deque.remove(at: Int(i)) },
    model: { array, i in array.remove(at: Int(i)) },
    equal: ==)                                       // expected-result form

try forAll(initial: Gen { _ in (sut: Deque<Int>(), model: []) },
           operations: [pushBack, pushFront, popFirst, removeExisting],
           consistent: { deque, array in
               guard Array(deque) == array else { throw Mismatch("Deque \(Array(deque)) vs model \(array)") }
           },
           testCases: 500)
```

Failure display, via `describeStep` (a consistent bug this time — the
planted SUT bug is `popFirst` returning the *last* element):

```text
initial: sut Deque([]), model []
  pushBack(47)
  pushFront(-3)
  popFirst() -> 47 failed
violated: popFirst: popped Optional(47), model head was Optional(-3)
```

### The pure form: one catalog entry

Hughes's commuting square for pure operations is an equation, so it is a
`Laws` citizen. It meets the catalog bar (textbook equation: Hoare 1972's
simulation diagram; a Swift idiom: testing against a reference type; an
example that pulls it: Deque-vs-Array or the BST). Equality is an
explicit witness, as everywhere in `Laws`:

```swift
expectAll(Laws.abstraction(
    zip(trees, keys, values), "insert",
    real:  { t, k, v in insert(k, v, t) },
    model: { l, k, v in listInsert(k, v, l) },
    via: toList,
    equal: ==))
// toList(insert(k, v, t)) == listInsert(k, v, toList(t))
```

`Laws.homomorphism` is the binary-op special case and stays.

### Enumeration derives operations

An enumeration table (see `specs/usage-models.md`,
`Examples/AgentProperties`) is the degenerate model: finite states,
transition function a lookup, args trivial, post compares the response.

```swift
let spec = Enumeration<State, Stimulus, Response>(policy)
spec.problems()                    // completeness, named cells
spec.walk(plan, from: .initial)    // the gate
spec.monitor()                     // the runtime walk
spec.operations(run: { screen, stimulus in screen.handle(stimulus) })
```

`operations()` must return a deterministically ordered array (sorted by
state, then stimulus): the engine addresses rules by index, and
AgentProperties already learned that dictionary-derived order breaks
pinned seeds across processes.

## What this replaces in specs/usage-models.md

- `Rule.postcondition` (the "intended function" per rule): subsumed.
  `Operation.post` is the same idea with access to args and the observed
  result, which that spec left open. Do not build `Rule.postcondition`.
- The step-label display question: answered by `describeStep` (the one
  runner change) + `describe`/`describeObserved`.
- `UsageModel` reuse stays **future work**, not a claim. Draft 1's "add
  weights and gain a profile" overpromised: the representative (plain
  RNG) driver still cannot execute a model-dependent `args` without a
  hegel `TestCase`, and uniform rule selection is still the engine's.
  That spec's open draw-source question is unchanged by this layer.

## Pool

Draft 1 said `Pool` "should just work"; false for a fixed `Gen<Args>`.
With model-dependent `args(Model, TestCase)` it becomes *possible* — a
`Pool` held in the model (or created per case and threaded through it)
can be drawn from inside `args`, and the `Pool` doc comment names
model-based testing as its classic use. Still: not claimed for v1.
Verify with an example (the "previously created handle" operation) and
only then document the pattern.

## Examples plan

Validation order per the review — the primitive before the adapter, so
`Enumeration.operations()` cannot conceal weaknesses in `Operation`:

1. `Rule.describeStep` + runner-loop change, with a test that a plain
   rule's display is unchanged and an argued step prints its args.
2. `Operation` + the three initializer forms + `forAll(initial:...)`;
   Deque-vs-Array with one planted SUT bug shrinking to a short labeled
   trace, a `consistent:` drift catch, and a deliberate-failure test
   pinning the known minimal counterexample.
3. Port `Examples/AgentProperties`'s `cellRules` + `effectsLegal`
   directly onto `Operation` — no adapter. The diff of that port is the
   review artifact for this spec. If it is not cleaner than the
   hand-rolled version, stop.
4. `Enumeration` + `operations()`; port the OTP example.
5. `Laws.abstraction` on the Deque pair, pure form.
6. README: the black box → state box → clear box order gains its middle:
   laws/relations (black), operations against a model — an enumeration
   when finite (state), the code (clear). Plus the one-sentence rule and
   Hughes's second-string guidance, scoped to his benchmark.

## Result (2026-08-27)

Built as specified, one rename: `Operation` collides with
`Foundation.Operation` in any file that imports Foundation (the door
consumer did), so the type is `Command<SUT, Model>` and the driver
parameter is `commands:`. The state is a `Modelled<SUT, Model>` struct
rather than a labeled tuple so it can print as `sut X, model Y`. Nullary
steps print as `name`; argued steps as `name(args)`; observed values as
`name(args) -> value`. `Rule.describeStep` is public; the runner uses an
internal label-returning step underneath (`LabeledStepFailure` carries the
label through a throw). Validation order followed: describeStep, then
`Command` against a queue in the library tests (popsLast shrinks at seed 1
to `push(0) push(1) pop -> Optional(1) failed`; a `clear` that leaves one
element is caught only by `consistent`), then the ports. The Agda door
consumer went from a hand-rolled `Harness` + `rules(_:)` to `commands(_:)`
over the same table, and gained the transported theorem
(`open-only-when-unlocked` checked in `post`); the planted bug shrinks to
`open -> opened failed`. `Examples/DequeProperties` checks
swift-collections' `Deque<Int>` against `[Int]` with a model-dependent
`removeAt` (500 cases pass); a planted popFirst-pops-last wrapper shrinks
to two pushes and a popFirst. `Enumeration<State, Stimulus, Response>` built the same day
(`Sources/Hegel/Enumeration.swift`): `Cell` = `.respond(Response, then:)`
or `.illegal`; switch form (cells evaluated once at init, completeness by
the compiler) and block form (`problems()`: missing state, missing
stimulus, undefined next, unreachable); `walk`; `commands(run:equal:)`
one per legal cell in `allCases` order, named `state ▸ stimulus`. The OTP
login from the 2026-08-22 experiment is the library test and shrinks at
seed 1 to exactly the six-step walk. The door consumer now loads its JSON
into the block form (`problems()` is the artifact completeness check) and
transports the theorem as an invariant over a SUT that records its last
observation. Nullary command labels dropped the `()` so cells read
`Δ ▸ enterPhone -> none`. Lean evaluator (same day, `Examples/LeanVerifiedModel`): the login with
a `Nat` counter in Lean 4.33, `Inv` + three theorems proved, `@[export]`
scalar wrappers, `lake build Otp:static` → `libotp_Otp.a` linked with
`libInit.a libleanrt.a libuv.a libgmp.a` via `unsafeFlags`; a `Command`
per stimulus whose `precondition:`/`model:` call the C. Lean rejected the
naive invariant; α found a counter-after-sign-in mismatch no response
shows; resend bug shrinks to 5 steps by observation, 3 with α. The
verified-model lane therefore works past finite tables; the evaluator
mode, not the table, is the one to spec. Not done: `Laws.abstraction`, the
AgentProperties port (its cells also count fired effects, which needs the
explicit-post form; not cleaner yet), `Pool` inside `args`.

## Open questions

- **Naming.** `Operation` vs the industry's `Command`. Draft says
  `Operation` (an operation *family* that draws concrete instances;
  aligns with the pure form); review concurred. Weakly held still.
- **`describeStep` shape.** `(State) -> String` reading the operation's
  recorded last step, vs the lowered rule capturing a box the step
  writes. The box is uglier and keeps `State` clean; decide in
  implementation.
- **How many α conveniences.** `consistent:` is the primitive; is
  `abstraction:`+`equal:` sugar worth its surface on day one, or added
  when the second example wants it?
- **Expected-SUT-error ergonomics.** `Result`-shaped `Observed` is the
  stated answer; is a `throwsExpected:` convenience needed, or is
  `Result { try ... }` in `run` enough? Wait for an example.
- **`Pool` pattern.** As above: possible via model-dependent args,
  unverified, undocumented until exercised.

## Non-goals

- No second stateful engine; no change to the libhegel protocol; `Rule`
  gains exactly one optional field with a nil default.
- No `Modelable` protocol; models are plain values and closures.
- No parallel command generation / linearizability checking in v1 (the
  runner is synchronous).
- No automatic model synthesis; the model is the caller's, like the
  profile in `specs/usage-models.md`.
- No representative-driver integration for `UsageModel` via this layer;
  that spec's open question stays open.

## References

- John Hughes, *How to Specify It! A Guide to Writing Properties of Pure
  Functions* (TFP 2019) — the five kinds measured on the BST benchmark;
  model-based strongest there, metamorphic second.
- C. A. R. Hoare, *Proving Correctness of Data Representations* (Acta
  Informatica 1972) — the abstraction function and commuting diagram.
- Arts, Hughes, Johansson, Wiger, *Testing Telecoms Software with Quviq
  QuickCheck* (Erlang Workshop 2006) — eqc_statem: state-dependent
  argument generation, precondition / next_state / postcondition
  against a model.
- quickcheck-state-machine (Haskell), ScalaCheck `Commands`,
  proptest-state-machine (Rust), fast-check model-based — the same
  shape, independently converged on.
- `specs/usage-models.md` — the open questions this spec closes and the
  one it explicitly leaves open; `specs/laws.md` — the design rules, the
  overload precedent, explicit equality witnesses;
  `Examples/AgentProperties` — the third hand-rolled instance and the
  direct port target.
