# Pilot C: the calculation as propose and refute

Bank, after `sketches/Bank.lagda.md` in the denotational-design book. Hegel is the
refute half (`Bank.swift`, `stuckGoal`): with `send` partial, the equation as a
property fails and the shrunk counterexample is the stuck goal with the values in
scope. A fresh agent with no files and no tools is the propose half, one goal per
round, under the rule "one constructor whose fields are the variables in scope at
the goal; `apply` on it so the goal computes; `send` read off". Run 2026-09-02.

## Round 1, tester: `stuck at ⟦ deposit 0 ⟧ 0 = 0`, in scope n = 0, b = 0

```
Deposit : Nat → Msg                (field: n; b is the ledger's argument, not a field)
apply (Deposit n) b = b + n
send (deposit n) = Deposit n
```

## Round 2, tester: `stuck at ⟦ withdraw 0 ⟧ 0 = 0`

```
Withdraw : Nat → Msg               (field: n; b again the ledger's argument)
apply (Withdraw n) b = b ∸ n
send (withdraw n) = Withdraw n
```

## Round 3, tester: `stuck at ⟦ (deposit 0 then deposit 0) ⟧ 0 = 0`, with both hypotheses

```
Then : Msg → Msg → Msg             (fields m₁ = send r₁, m₂ = send r₂; b again the ledger's argument)
apply (Then m₁ m₂) b = apply m₂ (apply m₁ b)
send (r₁ then r₂) = Then (send r₁) (send r₂)
```
Alternative named: fields `r₁ r₂ : Req` with `apply (Then r₁ r₂) b = ⟦ r₁ then r₂ ⟧ b`, which also
holds by computation; not taken because it puts `Req` and `⟦_⟧` inside the ledger, ignoring both
hypotheses, and the goal after the hypotheses mentions only `send r₁`, `send r₂`, `b`.

Fork A, unprompted. The stream was not among the alternatives it saw.

## Round 4, constraint: Msg is a flat sequence, no message contains another; Then refused

```
send : Req → List Msg
send (deposit n)  = [Deposit n]
send (withdraw n) = [Withdraw n]
send (r₁ then r₂) = send r₁ ++ send r₂
applyAll []       b = b
applyAll (m ∷ ms) b = applyAll ms (apply m b)
```
"The then case no longer holds by computation: it needs the lemma
`applyAll (ms ++ ns) b ≡ applyAll ns (applyAll ms b)`, proved by induction on ms."

Append, as predicted. The tester accepts it; only the prover sees the lemma.

## Round 5, the prover's demand: every case by computation, no lemma, the equation may change

```
Equation:  applyAll (send r ms) b ≡ applyAll ms (⟦ r ⟧ b)      for all r, ms, b
send : Req → List Msg → List Msg
send (deposit n)  ms = Deposit n ∷ ms
send (withdraw n) ms = Withdraw n ∷ ms
send (r₁ then r₂) ms = send r₁ (send r₂ ms)
```
"No constructor is born. … The top level is the instance `ms = []`."

Fork B, the continuation, with the proof sketch and DONE as the empty stream.

## Reading

Three moves in the sketch, three rounds here, in the same order: the tree unprompted, append
under the wire constraint, the continuation only when a proof by computation was demanded.
The tester forced the first two births and never the third. What refusing `SEQ` costs is
visible to the prover and not to the tester; the agent found it when asked for the proof,
not when asked for the wire.
