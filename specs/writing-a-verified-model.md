# Writing a verified model

Status: as built, 2026-08-27, from the two Lean models in
`Examples/LeanVerifiedModel` (`Lean/Otp`, a login with a counter;
`Lean/Bank`, two concurrent withdrawals as a relation). Replaces the
2026-08-27 `denotational-design.md` draft, now in `specs/parked/`; that draft
put denotational design on the library side, and it belongs here, on the
prover side. Read with `specs/verified-model-artifacts.md`, which owns the
contract between the model and Hegel.

> Specify the meaning first, then show the implementation is a homomorphism
> of it. (Conal Elliott, *Denotational Design with Type Class Morphisms*.)

That sentence is the whole method. The prover checks the second half for the
model; Hegel checks it, as finite evidence, for the Swift code.

## 1. Choose the meaning before the code

Three moves, in order. Elliott does them for every design; the stack
machine is the short example (*Calculating Compilers Categorically*).

**What is the thing, essentially?** Write the state as the smallest
structure that decides the future. A counter is a `Nat`, not three states
named `oneBad`, `twoBad`, `locked`; the enumeration form (`Enumeration`,
Swift side) is for when you have already made that decision and the states
are finite. Elliott's stack computation is `∀z. (a, z) → (b, z)`: the
accumulator changes, the stack `z` is untouched, and "untouched" is not a
theorem to prove later but the type itself. Look for the invariant that can
be a type; it costs nothing after that.

```lean
structure S where
  screen : Screen
  attempts : Nat
```

**What known thing is it like?** Write the resemblance as equations, not
prose. "A stack function is a function with a stack along for the ride" is
`stackFun f = first f`, and then one equation per operation:
`stackFun (g ∘ f) = stackFun g ∘ stackFun f`. Here the known thing is the
Swift code's meaning as a function or relation on `S`, and the equations
are step 2's invariant and step 3's theorems. If no resemblance to something
already understood presents itself, the state is still wrong.

**Solve, and read the failures.** With the equations written, the
definitions are what makes them hold. Try the simplest candidate first;
when it fails, the failure says what is missing (the chain rule needs `f`
itself, so carry `f`; `first (first f)` needs the middle out of the way, so
push and pop). The prover solves; Hegel checks a solution. Cockx's rule for
the prover side is the same: when induction gets stuck, generalize the
statement (`reverse-acc xs [] ≡ …` is unprovable; `reverse-acc xs ys ≡ …`
goes through), then specialize.

Then decide who chooses the next step:

- the system: write a function, `step : S → Stim → S × Resp`, total on
  enabled stimuli (`Otp`);
- the environment (a scheduler, a network, a user racing another user):
  write a relation, `enabled : S → Event → Bool` and `step : S → Event → S`,
  and leave "which enabled event fires" out of the model (`Bank`). The
  schedule is Hegel's drawn input; the model must not contain a scheduler.

Do not put the implementation's structure in the model. `Bank` has phases
and a balance, not executor queues; `Otp` has a counter, not a text field.
If the model needs the implementation to decide what is legal, the model is
too weak.

## 2. State the invariant and prove it preserved

The invariant is a predicate over states. Prove it on the initial state and
preserved by every enabled step:

```lean
def Inv (s : S) : Prop := s.attempts ≤ limit ∧ (s.screen = .code → s.attempts < limit)
theorem inv_initial : Inv initial := ...
theorem inv_preserved (s x) (h : Inv s) : Inv (step s x).1 := ...
```

Expect the prover to reject the first version. `attempts ≤ 3` alone is not
preserved (a code screen at 3 goes to 4); the conjunct about the code screen
is what makes it an invariant. That rejection is the method working: the
invariant you believed was not one. It is a theorem, not a test failure,
because the prover's totality checks mean there is no `undefined` to hide
in; the strengthened invariant is the generalization from step 1 applied
to a predicate.

For a relation, prove it over paths, by induction on the event list
(`Bank.safe_path_inv`); the per-step lemma is the same shape as above with
`enabled s e = true` as a hypothesis.

## 3. Name the theorems the code will inherit

Each theorem is a sentence about behaviour, stated so it can be printed:
`resend_keeps_attempts`, `lockout_iff`, `badCode_increments`,
`safe_paths_nonneg`. If the Swift code refines the model on the walks Hegel
ran, it has these properties on those walks; the login screen shows their
names in its trace. Name them for that reader.

A witness is a theorem too. `unsafe_race` proves the unsafe relation
*admits* the race; when Hegel finds it in the Swift code, the code is
refining its model faithfully and the model is what is wrong. Write the
witness so that distinction is available.

## 4. Keep the boundary scalar, and prove the encoders

The C ABI carries tags and fixed-width integers, never prover objects:

```lean
@[export otp_step]
def stepC (screen : UInt8) (attempts : UInt32) (stim : UInt8) : UInt64 := ...
theorem Screen.ofTag_tag (s : Screen) : Screen.ofTag s.tag = some s := by cases s <;> rfl
```

The round-trip theorems are the only place the denotation meets bytes; prove
them on the prover side so the Swift decoders are the only trusted encoding.
Unknown tags return "not enabled" or the input state; they must not crash.
Nullary exports need a `Unit` argument or they become C globals.

## 5. Everything else is Hegel's

The runner, argument generation, α (`consistent:`), shrinking, replay, the
trace display: none of it needs a denotation from you. The Swift side is a
`Command` per stimulus whose `precondition:` and `model:` call the ABI, and
one `run:` adapter to the real code. If you find yourself writing domain
logic in Swift twice, stop; it belongs in the model.

## What "verified" may then mean

Checked by the prover: totality, the invariant, the theorems, the encoder
round-trips. Checked by Hegel: refinement on the walks it ran. Trusted: the
prover's C emission and runtime, the Swift decoders, the adapter, the UI.
The artifacts spec has the full lists; repeat them wherever the word appears.

## References

- Conal Elliott, *Denotational Design with Type Class Morphisms*, 2009.
- Conal Elliott, *Calculating Compilers Categorically*, talk, Haskell Love 2020; *The Simple Essence of Automatic Differentiation*, ICFP 2018.
- Jesper Cockx, *Programming and Proving in Agda*, lecture notes, 2026 (§4, generalizing an induction; §1, totality).
- C. A. R. Hoare, *Proof of correctness of data representations*, 1972.
- `Examples/LeanVerifiedModel/Lean/Otp/Model.lean`, `Lean/Bank/Model.lean`.
