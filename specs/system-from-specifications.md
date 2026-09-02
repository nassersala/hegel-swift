# A system from its specifications: draw, calculate, delegate, check

Status: run 2026-09-02 to 03, result under "Result" at the end; the
code is `Examples/BankSystem` (method) and `Examples/BankControl`
(control), not committed. It is the system-scale test of what `algorithm-search-experiments.md` showed at
component scale, and it is written to be run in a fresh session. Every
claim below is a prediction the run can refute; the ones I would bet
against are marked.

## The claim under test

> One sentence from the person. One agent under the skill draws the
> system's behaviours, reads the variables off them, and writes a relation
> or an equation per component, ending with the product decisions as
> clauses to choose between. The person answers those. Each relation goes
> to an agent under the skill, in parallel; each refinement is checked
> with Hegel, the async ones under schedules, the liveness in TLC; the
> relations are composed and the composed code is checked against the
> composed relation. The result is correct relative to the relations, on
> the checked behaviours, and the person's part is the sentence and the
> answers.

Three of those clauses have evidence at component scale (E1 to E7),
where the agent drew every time. Two do not: that the agent's drawing
scales to a system, and that composition finds what components miss.
Those two are the experiment. The person does not draw. The skill's step
1 is the agent's, and a person drawing for an hour is what would make the
method too slow to use.

## What this does not claim

- Correct by construction. Only the calculated half, with a proof, is that.
  Everything else is correct relative to a relation somebody drew, and the
  relation encodes decisions no equation supplies.
- That the drawing parallelizes. It does not. Phase A is one agent,
  sequential, and the person answers its questions at the end.
- Correctness the person did not ask for. The relations say what the
  drawing forced and what the person decided; a property nobody stated is
  not checked.
- An LLM inside Hegel. Phase D tests a proposer at the seam, recorded for
  CI, and can be killed without touching the rest.

## The system: a bank with two tellers over a real network

Chosen because every piece already has a foothold in the repo, and
because the seams are where distributed systems fail.

| component | shape | foothold | the variable the drawing should force |
|---|---|---|---|
| wire format | calculation: `⟦ r ⟧ b ≡ apply (send r) b` | `Examples/AboveTheCode/Bank.swift`, Pilot C | the constructors; the continuation only under a proof demand |
| ledger service | relation over a trace: messages arrive, possibly duplicated, reordered, or lost | `Examples/LeanVerifiedModel/Lean/Bank` (the race) | the set of message ids already applied; without it a duplicate is applied twice |
| teller session | relation: sends, timeouts, one retry, acknowledgements | `Auth.swift` (retry once, unproven, waiting) | the set of outstanding messages with their ids; without it a late ack is misread |
| two tellers, one account | the drawn race; the ledger refuses an overdraft | `Bank.tla`, `ConcurrencyTests.swift` | nothing new: the point is that the component relations compose |
| integration | every request of every teller is applied exactly once, in that teller's order; the balance is the meaning of the applied sequence; every sent request is eventually acked or refused | `TwoPhaseCommit` (`TPSpec ⇒ TC!TCSpec`) | the linearization: which order the ledger applied, as a variable of the composed relation |

The network is the environment, drawn: any message may be delayed,
duplicated, or dropped, bounded so TLC terminates. It is the same shape
as the arrivals in the search and auth examples, with two more moves.

## The second lane: the data born from an equation

`sketches/Bank.lagda.md` and Pilot C derive `Msg` from one equation,
`⟦ r ⟧ b ≡ apply (send r) b`, with `Msg` empty: each stuck goal is an
equation with the variables in scope, and the constructor that makes it
compute has exactly those variables as fields. The table above uses that
form for the wire format only and draws the other three. The
prediction in Phase A, that drawing 1 forces the ids and the applied set,
is a claim that those two come from a drawing and not from an equation.
This lane tests the opposite claim: state the equation with the network
as a term in it, and the same loop gives birth to them.

```
⟦ r ⟧ b ≡ apply* (net (send r)) b
```

`net` is the drawn environment as a function on message sequences: it
may repeat, reorder within bounds, or drop. `apply*` folds `apply` over
what arrives. With `Msg` as Pilot C left it, the equation fails at the
first repeat: `n` is in scope twice and nothing tells the copies apart.
The constructor that makes the goal compute carries something the ledger
can recognise, and `apply` has to remember what it recognised. If that is
what comes out, the id and the applied set were born, not drawn. The
teller's equation is the same shape with the acks as the message set and
the timeout as a move of `net`.

Predictions:

- The repeat forces an id field and a set at the ledger; the drop forces
  nothing at the ledger and a retry at the teller; the reorder forces
  nothing in this system because `+` and `∸` on one account commute up to
  the refusal, and the refusal is where the reorder shows.
- The equation-born ids and applied set match what drawing 1 forced. If
  they differ, the drawing carried a decision the equation did not, and
  the report names it. (I would bet on one such: whether a retry is the
  same message. The equation cannot say; `net` repeating a message and
  the teller resending one are the same term.)
- The loop takes more rounds than Pilot C's four and at least one round
  produces a constructor with a field that is not a variable in scope.
  That round is the one where the rule needs the drawing.

## Phase A: one agent draws the system

One agent under the skill, no code, given the control's paragraph below
and nothing else. Its job is steps 1 to 4 for every component and the
composition, then the product-decision verdict of step 7 for the whole:

```
/above-the-code Do steps 1 to 4 only, no code. Draw the behaviours of
this system on the smallest inputs that show its seams, one drawing per
interaction, in your reply. Read the variables, say what a step is, and
write Init and Next for each component and for the composed system.
Where the drawing forces a decision, do not make it: state the
alternatives as clauses of Next and stop. Also write, for each
component, the equation with the network as a term, `Msg` empty.
<the control's paragraph, verbatim>
```

Output: the drawings; one relation per component; the composed relation;
TypeOK for each; one equation per component with `net` as a term; and the
list of product decisions as clauses to choose between. The person reads
the drawings and answers the decisions. Nothing else from the person.

The three drawings the seams should make it draw, written down here so
the run can say which it found unprompted:

1. One teller, one deposit, the ack lost, the retry, the duplicate at the
   ledger. The row at the duplicate cannot say whether to apply it.
2. Two tellers, two withdrawals of the whole balance, messages reordered.
3. One teller, a withdrawal refused, the refusal delayed past the retry.

Predictions:

- The agent draws 1 and 2 unprompted and misses 3. If it misses 1 the
  drawing does not scale and the report says so first.
- Drawing 1 forces the ids on messages and the applied set at the ledger.
- Drawing 3, if drawn, forces a decision: is a retry the same message
  (same id, the ledger deduplicates) or a new one (the teller must not
  resend a refused request)? Prediction: the agent stops and asks, as the
  prompt tells it to, and does not make the choice itself. The person
  answers same id. If the agent decides it alone, that is a finding
  against the skill's product-decision verdict.
- The composed relation needs a variable none of the components has: the
  order the ledger applied messages in. If it can be written without one,
  that is a finding against the integration claim.
- The person's part is under ten minutes: reading three drawings and
  answering two or three questions.

Kill criterion: if the person's minutes in Phase A exceed the person's
minutes for the control, which are the minutes to write the paragraph,
by more than the time it takes to read the drawings, the method costs
the person something the control does not; record it and continue.

## Phase B: one agent per relation, in parallel

Four agents, one prompt each, no shared state, each in its own worktree,
each with the skill and the relation from Phase A as given. Each is told
the relation is fixed; its job is steps 5 to 7: the relation as a Swift
value, the checks, the code, refinement, schedules where async, the
verdict list with verdicts.

```
/above-the-code The relation below is fixed; do not redraw it. Implement
it in Examples/BankSystem/<Component>, check it with Hegel, and check
the code refines it, under drawn schedules if anything in it is async.
End with the verdict list. Do not edit README or the memory files.
<the relation from Phase A, verbatim>
```

The wire-format agent gets the calculation form: the equation, `send`
partial, and the rule; its stuck goals come from `Calculation.stuckGoal`.

Two more agents, the ledger and the teller again, get the equation form
instead of the relation: the equation with `net`, `Msg` as Pilot C left
it, `apply` partial, and the rule. They run the stuck-goal loop until the
equation holds under drawn network moves, and end with the data they
were given birth to and the round at which each field appeared. Same
component, two derivations; the comparison is the second lane's data.

Measures per agent: minutes; whether the drawing in its reply matches
Phase A's or diverges (divergence is a finding about the relation's
clarity, not about the agent); refinement green; the verdict list turned
into checks; the "does not say" items that name another component. That
last one is the seam list and it is the input to Phase C.

Predictions:

- Every agent finishes under twenty minutes and green. (Component-scale
  evidence: seven of seven.)
- Every ledger agent's "does not say" mentions what the teller does on
  timeout, and every teller agent's mentions what the ledger does with a
  duplicate. If neither does, the verdict step is not surfacing seams
  and needs a rule for it.
- At least one agent proposes a stricter relation than Phase A's and has
  to be told the relation is fixed. (I would bet on the teller's retry.)
- The equation-form ledger agent reaches the id and the set in two
  rounds; the equation-form teller agent gets stuck at the retry decision
  and asks, or invents a clause the equation does not contain. Either is
  the finding: the seam the equation cannot decide.

## Phase C: integration

One agent, sequential, given the four components and the composed
relation. Its job: the composed code, the network as a drawn environment,
the composed refinement under drawn schedules and drawn network moves,
and the TLA twin of the composed relation for liveness.

Predictions, and these are the experiment:

- The composed check finds at least one bug that no component check
  found. Candidates: a retry applied twice because the ledger's applied
  set and the teller's ids disagree on what "same message" is; a refusal
  and a late ack for the same id; the race applied in an order the
  teller's view contradicts. If it finds none, either the seams were
  fully in the component relations, which is a finding for Phase A, or
  the composed check is too weak, which the planted bug below decides.
- Plant one seam bug on purpose, an id scheme that differs between teller
  and ledger, and confirm the composed check finds it and shrinks it to
  one duplicate. If the plant is not found, the composed check is wrong
  and nothing else in Phase C counts.
- TLC on the composed relation finds a liveness violation the finite
  checks could not: a request whose every copy is dropped is never acked.
  The fix is a fairness assumption on the network, stated as such.

## The control

One agent, the same session budget as Phases A to C combined, given the
system as a paragraph and no skill:

```
Build a small bank: a ledger service and a teller app that talk over a
network that can delay, duplicate, or drop messages; two tellers may
share an account; withdrawals that would overdraw are refused. Swift,
with tests. Put it in Examples/BankControl.
```

Measures: minutes; does it handle duplicates; does it handle a refusal
arriving after a retry; does it state any property over interleavings;
does it name what it does not handle. Prediction: it is faster, it
handles duplicates with an id scheme it invents, it has no statement
about interleavings, and the seam bug from Phase C is present and not
tested for. If the control is correct on the planted bug's scenario, the
method has not earned its cost here and the report says so first.

## Phase D: the proposer at the seam, not committed

Only if Phases A to C run. This is the second lane automated: the
propose half of the stuck-goal loop as a harness component rather than
an agent in a terminal. A `Proposer` next to `Calculation.stuckGoal`:
the stuck goal as a typed value with the in-scope variables computed by
the harness; a recorded proposer replaying Pilot C in CI; a live one
behind a flag, as `Examples/AgentProperties` does it; proposals as Swift
compiled in a scratch package.

Prediction: one round per goal, zero retries, and the fork never taken
without a demand from outside the tester. Kill criterion: if the harness
can extract fields and `apply` mechanically for every goal in the bank,
which Pilot C suggests, the proposer's only contribution is the name, and
the experiment is closed with that sentence.

## Measures, whole run

| | method | control |
|---|---|---|
| person's minutes: sentence, reading drawings, answering decisions | | |
| wall clock, all phases | | |
| drawings 1 to 3 found unprompted by the Phase A agent | | |
| bugs found before integration, by component checks | | |
| bugs found at integration, by the composed check | | |
| planted seam bug found | | |
| liveness violation found, by TLC | | |
| product decisions made explicit, count | | |
| "does not say" items that named another component | | |
| fields born from the equation that the drawing also forced | | |
| fields the drawing forced that no equation produced | | |
| rounds of the stuck-goal loop, ledger and teller | | |

Predictions failing are listed first in the report, as in the earlier
spec. The claim survives if the composed check finds the plant and at
least one unplanted seam bug, and the control has the plant's scenario
wrong. It fails if the control is right on it, or if the Phase A agent
cannot draw the lost ack and the duplicate, since then the person would
have to, and the method's cost returns.

## How to run it next session

1. Phase A: one agent in a fresh terminal with the prompt above. Read its
   drawings, answer its decisions, note the minutes. Commit the spec with
   the drawings, relations, equations, and answers appended before
   Phase B.
2. Phase B: six terminals or the `Workflow` tool, one prompt each, from
   the block above with the relation pasted in, or the equation for the
   two equation-form agents. Do not start Phase C until all six are
   green.
3. The control in a seventh terminal, started at the same time as Phase
   A, so its budget is honest.
4. Phase C in this terminal.
5. Score the table; write the report into this file under "Result".

What to bring back from each agent: what it drew before writing any
file, and its verdict list. Those two are the data; the code is the
artifact.

## Run 2026-09-02

Start 19:58:48 AEST. Control started 19:59:13, green 20:02:38 (3.5 min wall clock, 20 tests, no Hegel). Phase A agent started 19:58:48, returned 20:05:13 (6.4 min wall clock; it reported 22 minutes of its own work). Its output follows verbatim, headings demoted one level.

### Phase A: bank over a lossy network, steps 1 to 4 of above-the-code

Balance 10 throughout. `wd 4` where a duplicate must show as a double debit, `wd 7` where an overdraft must show as a refusal. A teller's record is `⟨pend, seq, tries, out⟩`. `⦃ ⦄` is a bag. `q(i, r)` is the request message with identity `i`, `r(i, rep)` the reply. The drawings were made before any repository file was read.

#### 1. Drawings

**A. Wire format, honest network, one account.** A state is a balance and the reply the last request produced.

```
[bal: 10] ─wd 7─▶ [bal: 3, rep: ok 3] ─wd 7─▶ [bal: 3, rep: refused 3] ─dep 5─▶ [bal: 8, rep: ok 8]
```

**B. Ledger, one message arriving twice.** First without an identity; the row cannot say whether the second arrow is a second withdrawal or the network's copy of the first, so a variable is missing.

```
[bal: 10] ─arrive wd 4─▶ [bal: 6] ─arrive wd 4─▶ [bal: 2]        copy or repeat? the row cannot say: id is missing
```

With an identity `t·n` (teller, sequence number) and the set of what was applied:

```
[bal: 10, seen: {}]
  ─arrive ⟨t·1, wd 4⟩─▶ [bal: 6, seen: {t·1 ↦ ok 6}, out: ok 6]
  ─arrive ⟨t·2, wd 4⟩─▶ [bal: 2, seen: {t·1 ↦ ok 6, t·2 ↦ ok 2}, out: ok 2]
  ─arrive ⟨t·1, wd 4⟩─▶ [bal: 2, seen: same, out: ok 6 ? ok 2 ? nothing ?]      the drawing cannot decide (P2)
```

**C. Teller session.** Submit puts `⟨t·seq, pend⟩` on the wire, timeout puts it again; a reply is taken only if its identity is the pending one.

```
[pend: –, seq: 0, tries: 0, out: –]
  ─submit wd 4─▶ [pend: wd 4, seq: 1, tries: 1, out: –]
  ─timeout─▶     [pend: wd 4, seq: 1, tries: 2, out: –]
  ─reply ⟨t·1, ok 6⟩─▶ [pend: –, seq: 1, tries: 0, out: ok 6]
  ─reply ⟨t·1, ok 6⟩─▶ [pend: –, seq: 1, tries: 0, out: ok 6]          late copy, ignored
  ─submit wd 7─▶ [pend: wd 7, seq: 2, tries: 1, out: –]
  ─reply ⟨t·2, refused 6⟩─▶ [pend: –, seq: 2, tries: 0, out: refused 6]
```

The `timeout` arrow can be drawn again at any state with `pend ≠ –`, with nothing between two of them; whether the row may go on that way forever is not in the drawing (P4).

**D. Two tellers, one account.** Both submitted; the drawing did not care which request the ledger sees first, so the first arrow is a pick-any. The teller who submitted first can be the one refused.

```
[bal: 10, seen: {}, net: ⦃q(t1·1, wd 7), q(t2·1, wd 7)⦄, t1: ⟨wd 7, 1, 1, –⟩, t2: ⟨wd 7, 1, 1, –⟩]
  ─deliver q(t2·1)─▶ [bal: 3, seen: {t2·1 ↦ ok 3}, net: ⦃q(t1·1, wd 7), r(t2·1, ok 3)⦄, t1, t2 same]
  ─deliver q(t1·1)─▶ [bal: 3, seen: {t2·1 ↦ ok 3, t1·1 ↦ refused 3}, net: ⦃r(t2·1, ok 3), r(t1·1, refused 3)⦄]
  ─deliver r(t1·1)─▶ [… net: ⦃r(t2·1, ok 3)⦄, t1: ⟨–, 1, 0, refused 3⟩]
  ─deliver r(t2·1)─▶ [… net: ⦃⦄, t2: ⟨–, 1, 0, ok 3⟩]
```

The same drawing with the identity being the sequence number alone:

```
[bal: 10, seen: {}, net: ⦃q(1, wd 7) from t2, q(1, wd 7) from t1⦄]
  ─deliver t2's─▶ [bal: 3, seen: {1 ↦ ok 3}]
  ─deliver t1's─▶ [bal: 3, seen: {1 ↦ ok 3}, out: ok 3 to t1]        t1 is told ok for money it did not get: refuted
```

So the identity carries the teller (or is otherwise unique across tellers, P1).

**E. Composed, request dropped, resend, reply duplicated.**

```
[bal: 10, seen: {}, net: ⦃⦄, t: ⟨–, 0, 0, –⟩]
  ─submit wd 4─▶ [bal: 10, seen: {}, net: ⦃q(t·1, wd 4)⦄, t: ⟨wd 4, 1, 1, –⟩]
  ─drop q─▶      [bal: 10, seen: {}, net: ⦃⦄, t: ⟨wd 4, 1, 1, –⟩]
  ─timeout─▶     [bal: 10, seen: {}, net: ⦃q(t·1, wd 4)⦄, t: ⟨wd 4, 1, 2, –⟩]
  ─deliver q─▶   [bal: 6, seen: {t·1 ↦ ok 6}, net: ⦃r(t·1, ok 6)⦄, t: ⟨wd 4, 1, 2, –⟩]
  ─dup r─▶       [bal: 6, seen: {t·1 ↦ ok 6}, net: ⦃r(t·1, ok 6), r(t·1, ok 6)⦄, t same]
  ─deliver r─▶   [bal: 6, seen: {t·1 ↦ ok 6}, net: ⦃r(t·1, ok 6)⦄, t: ⟨–, 1, 0, ok 6⟩]
  ─deliver r─▶   [bal: 6, seen: {t·1 ↦ ok 6}, net: ⦃⦄, t: ⟨–, 1, 0, ok 6⟩]
```

**F. Composed, delay: the resend and the original both arrive.** This is the drawing that forces `seen`.

```
[bal: 10, seen: {}, net: ⦃q(t·1, wd 4)⦄, t: ⟨wd 4, 1, 1, –⟩]
  ─timeout─▶   [bal: 10, seen: {}, net: ⦃q(t·1, wd 4), q(t·1, wd 4)⦄, t: ⟨wd 4, 1, 2, –⟩]
  ─deliver q─▶ [bal: 6, seen: {t·1 ↦ ok 6}, net: ⦃q(t·1, wd 4), r(t·1, ok 6)⦄]
  ─deliver q─▶ [bal: 6, seen: {t·1 ↦ ok 6}, net: ⦃r(t·1, ok 6), r(t·1, ok 6)⦄]       second copy not applied
  ─deliver r─▶ [… t: ⟨–, 1, 0, ok 6⟩] ─deliver r─▶ [same]
```

Without `seen` the third row is `bal: 2` with `r(t·1, ok 2)` beside `r(t·1, ok 6)`, and the teller shows `ok 6` or `ok 2` by arrival order, for one withdrawal debited twice: refuted. With `wd 7` in place of `wd 4` the same drawing gives one request the two replies `ok 3` and `refused 3`.

**G. Acknowledgement and forgetting, a delayed copy still in flight.** If the ledger forgets an identity when the teller acknowledges the reply:

```
[bal: 6, seen: {t·1 ↦ ok 6}, net: ⦃q(t·1, wd 4)⦄, t: ⟨–, 1, 0, ok 6⟩]
  ─ack t·1─▶   [bal: 6, seen: {}, net: ⦃q(t·1, wd 4)⦄]
  ─deliver q─▶ [bal: 2, seen: {t·1 ↦ ok 2}]                                       applied twice: refuted
```

Forgetting on acknowledgement alone is refuted by this row; the alternatives that survive are in P3.

#### 2. Variables and TypeOK

Sets used by every component:

```
Acct      = a finite set of account names (one, `a`, in every drawing)
Teller    = a finite set of teller names, {t1, t2}
Bal       = ℕ
Req       = { dep n : n ∈ ℕ⁺ } ∪ { wd n : n ∈ ℕ⁺ }
Rep       = { ok b : b ∈ Bal } ∪ { refused b : b ∈ Bal }
Id        = Teller × ℕ⁺            (written t·n; the alternative shapes are P1)
Msg       = (no constructors)      what the drawings ask of it is in section 5
```

**Wire format.** Variables `bal`, `rep`.

```
TypeOK_W:  bal ∈ Bal  ∧  rep ∈ Rep ∪ {–}
```

**Ledger.** Variables `bal`, `seen`, `out`.

```
TypeOK_L:  bal ∈ [Acct → Bal]  ∧  seen ∈ (Id ⇸ Rep)  ∧  out ∈ Rep ∪ {–}
```

`seen` is a partial function because drawing B needs the reply stored, not only the identity; if P2 chooses "current balance" or "nothing", `seen` shrinks to a subset of `Id`.

**Teller session** (one teller `t`). Variables `pend`, `seq`, `tries`, `out`.

```
TypeOK_T:  pend ∈ Req ∪ {–}  ∧  seq ∈ ℕ  ∧  tries ∈ ℕ  ∧  out ∈ Rep ∪ {–}
```

`out` gains the value `unknown` under P4b.

**Two tellers on one account.** Variables `bal`, `seen`, `tl`, `net`.

```
TypeOK_2:  TypeOK_L  ∧  tl ∈ [Teller → TellerState]  ∧  net ∈ Bag(Msg)
TellerState = { ⟨pend, seq, tries, out⟩ : TypeOK_T }
```

**Composed system.** Same variables as two tellers; the network gains two step kinds, not a variable.

```
TypeOK_S:  TypeOK_2
```

#### 3. What a step is

- **Wire format:** a step is one request applied to one balance.
- **Ledger:** a step is the arrival of one message.
- **Teller session:** a step is one submit, one timeout, or the arrival of one reply (taken or ignored).
- **Two tellers on one account:** a step is one teller step or one ledger arrival; a delivery from `net` is the arrival.
- **Composed system:** a step is a two-teller step, or one network action on one message (duplicate, drop). Delay is not a step: arrival picks any message in the bag.

#### 4. Init and Next

**Meaning of a request on a balance** (defined once, used by every component):

```
⟦ dep n ⟧ b  =  ⟨b + n, ok (b + n)⟩
⟦ wd n ⟧ b   =  if n ≤ b then ⟨b − n, ok (b − n)⟩ else ⟨b, refused b⟩
bal⟦ r ⟧ b  =  fst (⟦ r ⟧ b)        rep⟦ r ⟧ b  =  snd (⟦ r ⟧ b)
```

**Wire format**

```
Init_W:  bal = b₀ ∈ Bal  ∧  rep = –
Next_W:  pick any r ∈ Req:  bal′ = bal⟦ r ⟧ bal  ∧  rep′ = rep⟦ r ⟧ bal
```

**Ledger**, over a trace of arriving messages. `id(m) ∈ Id`, `req(m) ∈ Req`, `acct(m) ∈ Acct` are what the arrival of a request message determines (constructors of `Msg` left open).

```
Init_L:  bal = [a ∈ Acct ↦ b₀]  ∧  seen = {}  ∧  out = –

Next_L:  pick any arriving m with i = id(m), r = req(m), a = acct(m):
   Apply:   i ∉ dom seen
          ∧ bal′  = [bal EXCEPT ![a] = bal⟦ r ⟧ bal[a]]
          ∧ seen′ = seen ∪ { i ↦ rep⟦ r ⟧ bal[a] }
          ∧ out′  = rep⟦ r ⟧ bal[a]
 ∨ Again:   i ∈ dom seen
          ∧ bal′ = bal  ∧  seen′ = seen
          ∧ out′ = (P2: seen[i]  |  ok bal[a]  |  –)
```

**Teller session** (teller `t`). `emit(m)` records what the step puts on the wire; in the standalone session it is a label on the arrow, in the composed system it is `net′ = net ⊎ ⦃m⦄`.

```
Init_T:  pend = –  ∧  seq = 0  ∧  tries = 0  ∧  out = –

Next_T:
   Submit:   pend = –  ∧  pick any r ∈ Req:
             pend′ = r  ∧  seq′ = seq + 1  ∧  tries′ = 1  ∧  out′ = –
             ∧ emit q(t·seq′, r)
 ∨ Timeout:  pend ≠ –
             ∧ tries′ = tries + 1  ∧  pend′ = pend  ∧  seq′ = seq  ∧  out′ = out
             ∧ emit q(t·seq, pend)                         (bound: P4)
 ∨ Take:     pick any arriving reply ⟨i, rep⟩:
             pend ≠ –  ∧  i = t·seq
             ∧ pend′ = –  ∧  tries′ = 0  ∧  out′ = rep  ∧  seq′ = seq
 ∨ Ignore:   pick any arriving reply ⟨i, rep⟩:
             (pend = –  ∨  i ≠ t·seq)
             ∧ pend′ = pend  ∧  seq′ = seq  ∧  tries′ = tries  ∧  out′ = out
```

`Submit` requires `pend = –`: one outstanding request per teller. That is what the drawings used; the alternative is P5.

**Two tellers on one account.** `net` delivers in any order and loses nothing. `to(m)` is the teller a reply is addressed to.

```
Init_2:  Init_L  ∧  net = ⦃⦄  ∧  ∀ k ∈ Teller: tl[k] satisfies Init_T

Next_2:
   Submit_k / Timeout_k:   Next_T on tl[k] with emit m ≡ net′ = net ⊎ ⦃m⦄;
                           bal, seen, tl[j ≠ k] unchanged
 ∨ Arrive(m):   m ∈ net  ∧  m is a request
                ∧ Next_L on m
                ∧ net′ = (net ∖ ⦃m⦄) ⊎ (if out′ = – then ⦃⦄ else ⦃r(id(m), out′)⦄)
                ∧ tl unchanged
 ∨ Deliver_k(m): m ∈ net  ∧  m is a reply  ∧  to(m) = k
                ∧ (Take ∨ Ignore) on tl[k] with ⟨id(m), rep(m)⟩
                ∧ net′ = net ∖ ⦃m⦄  ∧  bal, seen, tl[j ≠ k] unchanged
```

Reordering is the pick-any in `Arrive` and `Deliver`; drawing D's first arrow is that choice.

**Composed system.** Two tellers plus the faulty network.

```
Init_S:  Init_2

Next_S:  Next_2
 ∨ Dup(m):   m ∈ net  ∧  net′ = net ⊎ ⦃m⦄   ∧  bal, seen, tl unchanged
 ∨ Drop(m):  m ∈ net  ∧  net′ = net ∖ ⦃m⦄   ∧  bal, seen, tl unchanged
```

Delay needs no clause: `Arrive` and `Deliver` pick any message, so a message may sit in `net` through any number of other steps.

What every drawing kept true, stated as invariants of `Next_S` (to be checked at step 5, not claimed here):

```
NonNegative:  ∀ a: bal[a] ≥ 0
Once:         ∀ i ∈ dom seen: the request with identity i has been applied to bal exactly once
Serial:       bal = the fold of ⟦ ⟧ over dom seen in the order the Apply steps occurred
Agree:        ∀ k: tl[k].out ≠ – ⇒ tl[k].out = seen[k·tl[k].seq]
```

#### 5. Equations with `net`

`Msg` has no constructors. The terms below are typed against it as an unknown:

```
send   : Req → [Msg]                one request as messages
retry  : Req → [Msg]                send r repeated, one copy per Submit or Timeout (an infinite sequence under P4a)
apply* : [Msg] → Bal → Bal          the ledger's fold over arrivals; apply* [] b = b
net    : [Msg] → [Msg]              the environment: net s is a sequence each of whose elements is an element of s,
                                    in any order, with any multiplicity (0 = dropped, ≥ 2 = duplicated)
Net    = all such net;  Net₁ = those giving every element multiplicity ≥ 1;  id ∈ Net₁
Net_fin = those giving at least one element of every infinite suffix of s multiplicity ≥ 1
r₁ ∥ r₂ = the set of interleavings of two sequences
```

What the drawings require of the missing constructors, without naming them: a request message determines `id`, `acct`, `req` (drawings B, D); a reply message determines `id`, `to`, `rep` with the balance inside `rep` (drawings A, C, D: the refused teller learns 3, not 10). Nothing more.

**Wire format**, the network honest:

```
⟦ r ⟧ b  ≡  apply* (send r) b                                          (net = id)
```

**Ledger**, the network delivering at least once, or not at all:

```
∀ net ∈ Net₁:  apply* (net (send r)) b  ≡  ⟦ r ⟧ b                     copies do not count twice
∀ net ∈ Net:   apply* (net (send r)) b  ∈  { b, ⟦ r ⟧ b }               a dropped request is a no-op, never a partial one
```

Here and below `⟦ r ⟧ b` stands for `bal⟦ r ⟧ b`; the reply component is the teller's equation.

**Teller session**, retry making at-least-once out of a lossy network, `seen` making exactly-once out of at-least-once:

```
∀ net ∈ Net_fin:  apply* (net (retry r)) b  ≡  ⟦ r ⟧ b
∀ net ∈ Net_fin:  out                        ≡  rep⟦ r ⟧ b       once a reply has been taken
∀ net ∈ Net:      apply* (net (retry r)) b  ∈  { b, ⟦ r ⟧ b }   and if the reply never comes, out ∈ {–} (P4a) or {unknown} (P4b), with bal on either side
```

**Two tellers on one account**, serialisable in some order:

```
∀ net ∈ Net_fin, ∀ s ∈ retry r₁ ∥ retry r₂:
   apply* (net s) b  ∈  { ⟦ r₂ ⟧ (⟦ r₁ ⟧ b),  ⟦ r₁ ⟧ (⟦ r₂ ⟧ b) }
   and for the order π the ledger took, out_k ≡ rep⟦ r_k ⟧ (balance before r_k in π)
```

**Composed system**, the same with `n` tellers each submitting a sequence of requests, `R_k = r_{k,1}, r_{k,2}, …`:

```
∀ net ∈ Net_fin, ∀ s ∈ ∥_k (retry* R_k):
   ∃ π a linear order on ⋃_k R_k extending each teller's own order:
        apply* (net s) b  ≡  fold ⟦ ⟧ over π from b
      ∧ ∀ k, j:  out_{k,j} ≡ rep⟦ r_{k,j} ⟧ (balance before r_{k,j} in π)
```

`retry* R_k` is the sequence of copies teller `k` puts on the wire across all its submits and timeouts; because `Submit` needs `pend = –`, each teller's requests are ordered in `s` and π must respect that.

#### 6. Product decisions

Each is a place a drawing could not choose. Alternatives are clauses of `Next`; nothing is recommended.

**P1. What the identity of a request is.**
- (a) `Id = Teller × ℕ⁺`, `Submit` sets `seq′ = seq + 1` and emits `q(t·seq′, r)`; the ledger can read the teller and the order from the identity.
- (b) `Id` = a fresh value, `Submit` picks any `i ∉ used`, emits `q(i, r)`, `used′ = used ∪ {i}`; the ledger can read nothing from it, and P3b is unavailable.
- Refuted by drawing D: `Id = ℕ⁺` alone.

**P2. What the ledger says to a copy of a request already applied** (`Again` in `Next_L`).
- (a) `out′ = seen[i]`: the stored reply; `seen` is `Id ⇸ Rep`.
- (b) `out′ = ok bal[a]`: the balance now; `seen ⊆ Id` suffices; drawing B's last row shows this differs from (a) (`ok 2` against `ok 6`) once another request has applied in between, and a teller taking it reads a balance its request did not produce.
- (c) `out′ = –`: no reply to a copy; then a teller whose only reply was dropped resends forever under P4a, and reaches `unknown` under P4b, for a request the ledger applied.

**P3. What the ledger remembers, and for how long.**
- (a) `seen` grows without bound: `Again` requires `i ∈ dom seen`, nothing ever removes from `seen`.
- (b) Per teller, only the last: `seen ∈ [Teller → (ℕ × Rep)]`; `Apply` requires `n = fst seen[t] + 1`, `Again` requires `n = fst seen[t]`, and a third clause `Stale: n < fst seen[t] ∧ unchanged ∧ out′ = –` takes an older copy. Requires P1a and P5a.
- (c) Forget on acknowledgement: a teller step `Ack` emits `ack(i)`; a ledger step `Forget(i)` on its arrival sets `seen′ = seen ∖ {i}`. Refuted by drawing G as stated; survives only combined with (b), where the high-water mark makes the delayed copy `Stale`.

**P4. Whether `Timeout` is bounded.**
- (a) Unbounded: `Timeout` as written, `tries` any natural. The relation permits the row of drawing C to be `timeout, timeout, …` forever.
- (b) Bounded: `Timeout` requires `tries < K`, and a new clause `GiveUp: pend ≠ – ∧ tries = K ∧ pend′ = – ∧ tries′ = 0 ∧ out′ = unknown`. `out = failed` in place of `unknown` is refuted by drawing E's fourth row: the ledger may have applied the request the teller gave up on.
- Under (b) a further choice: whether a copy of the given-up request may still apply at the ledger. With P3a it may (`i ∉ dom seen` remains true); with P3b the next `Submit` makes it `Stale`.

**P5. Outstanding requests per teller.**
- (a) One at a time: `Submit` requires `pend = –`, as written.
- (b) Pipelined: `pend ∈ (ℕ ⇸ Req)`, `Submit` adds `seq′ ↦ r`, `Take` removes the matching entry, `Timeout` picks any pending entry to resend. Then a teller's two requests can reach the ledger in either order, the composed equation's "extending each teller's own order" is dropped, and P3b is unavailable.

**P6. What a refusal reply carries.**
- (a) `refused b` with the balance, as drawn: the refused teller in drawing D learns 3.
- (b) `refused` without a balance, and a request `bal` in `Req` with `⟦ bal ⟧ b = ⟨b, ok b⟩` for a teller that wants the number; `Rep` and the teller's `out` change accordingly.

#### 7. Minutes

22

### Decisions, answered by the person

About four minutes to read the drawings and answer. Every answer was the
one the spec predicted: P1 teller × sequence; P2 the stored reply; P3
remember everything; P4 bounded, then `unknown`; P5 one outstanding
request per teller; P6 the refusal carries the balance. Phase B started
20:10 with these substituted into Next.

### Phase B, six agents in parallel, 20:09 to 20:21

| agent | wall clock | tests | planted bug found | unplanted finding | "does not say" naming another component |
|---|---|---|---|---|---|
| Wire, calculation | 3.6 min | 5 | n/a | monus vs refusal visible only in the reply | ledger, teller, network |
| Ledger, relation | 6.2 min | 12 | one deviation | `Again` path recorded without setting `out`, refuted at zero deviations | teller (timeout), network, wire |
| Teller, relation | 10 min | 8 | two plants, one deviation each | `Task {}` inside the actor escaped the scheduler; `restartsOnStray` keeps the invariant and fails the formula | ledger (duplicate), network, wire |
| Race, relation | 6.9 min | 8 | one deviation, caught by the recorded reply not the balance | leaked sleep continuations; `Agree` unstated for `unknown` | ledger, composed system, lossy network |
| LedgerEq, equation | 7.3 min | 2 (15 pinned goals) | n/a | the `last : Msg?` ledger passes one request and is refuted only by two equal requests and by a delayed copy | teller, network |
| TellerEq, equation | 9.3 min | 14 | n/a | `tries` and the resend are not forced by any safety equation | ledger, composed system |

Whole package after Phase B: 49 tests in 8 suites green. No agent
proposed a stricter relation or had to be told the relation was fixed;
every disagreement went into the verdict list. Every ledger list named
what the teller does on timeout and every teller list named what the
ledger does with a duplicate.

Rounds in the equation lane: ledger 8, teller 9. Ledger: `CREDIT n`,
`DEBIT n` from scope; the first repeat refuted; `last : Msg?` from scope;
the balance-now reply (P2b) refuted by one request, `wd 1` at 1 twice;
`lastRep` from scope; `then` as append, nothing born; whole-stream
reorder refuted and not fixable from scope, taken as the clause P5a on
`net`; two equal requests refuted; `id` invented; a delayed copy refuted;
`seen : Msg ⇸ Rep` from scope. Teller: `CREDIT n`, `DEBIT n`; `pend`
carried from the submit; `tries` invented at the fourth timeout, since
no safety equation forces a resend; `REPLY rep` from the ledger's scope;
`out`; `unknown` from the equation; a copy the ledger cannot tell from a
new request, not decidable with one request per session, both content
dedup and `id = seq` pass, P1a taken; `Take` must clear `pend` and
`tries`.

### Phase C, one agent

Composed relation over `LedgerModel` and `Session` reused as the
component clauses, `net` a bag, history `applied` as π. 500 drawn
behaviours with every network move a draw; 400 runs of the real
`LedgerService` and two real `TellerSession`s through a network that
delays, duplicates and drops by drawn fault list under drawn schedules;
drawings E and F on the code under 100 schedules each. Full package 57
tests in 9 suites green. The composed target had to be named `Composed`:
a Swift module called `System` shadows Darwin's.

One bug no component check found: the composed equation's order clause
is false of the fixed relation. Shrunk to one teller at balance 0, `wd 1`
twice, the first copy delayed past both resends, both resends dropped:
give up, `unknown`; submit `wd 1` again, applied and refused; the late
copy of the first arrives and is applied after it. Every step is a
`Next_S` step and all four invariants hold, so the relation and the code
are right and Phase A's equation, "π extending each teller's own order",
is wrong under P4b with P3a. It is a product decision: order only among
requests not given up, or P3b so a given-up request's late copy is stale.

The planted seam bug, the bridge numbering every forwarded copy with a
fresh sequence, found and shrunk to one duplicate: `wd 1` at 0, message
0 duplicated, first non-step at the second arrival where the relation
says `Again` and the code applied twice. A second plant, the teller
dropped from the id, refuted at the first arrival and, forced with both
tellers, reproduces drawing D's refutation.

TLC, two tellers, balance 2, amounts {1, 2}, K = 2, one dup and one
drop, one request per teller: 44,321 distinct states. Under weak
fairness of the tellers' timers and of the network, every invariant and
both liveness properties hold. Under fairness of the timers alone, no
fairness on the network, both liveness properties still hold: P4b makes
liveness the teller's own. The stronger reading, an applied request's
teller eventually shows the reply itself, is violated in twelve states:
the request dropped, resent, applied, the teller gives up while the
reply sits in `net`, the reply delivered and ignored. Fairness cannot fix
it because the reply was delivered; it is the Late clause, the item the
teller's relation ignores and the teller's equation takes. Two requests
per teller passed eleven million states without finishing; symmetry on
the tellers would be the fix.

### The control on the seven seam scenarios

A probe test file added to the control, 2.6 minutes: resend and original
both arriving, refusal delayed past the retry, two tellers for the whole
balance with arrival reversed, the same sequence number at two tellers,
a late reply after give-up, a stale duplicate reply before the next
same-shaped one: all six correct. A single teller's own order: wrong,
seed 7 under delay 1 to 3, the withdraw applied before the teller's
earlier deposit, final 15 where the specification says 3. The control's
own report had named that as deliberate.

## Result

Predictions that failed, first:

1. **The control is right on the planted bug's scenario.** Its
   per-teller sequence ids and stored-reply table are P1a, P2a and P3a,
   chosen without being stated. By the spec's own criterion the claim
   has not earned its cost on correctness here. What the control gets
   wrong is P5, the one decision it made the other way, and its tests
   do not check it because nothing in its design names the property.
2. **No agent proposed a stricter relation.** Six of six implemented what
   was given and put their disagreement in the verdict list. The clause
   "and has to be told the relation is fixed" never fired.
3. **The ledger's equation took eight rounds, not two, to reach the id
   and the set,** and the id was born at two equal requests, not at the
   first repeat. The first repeat was satisfied by remembering one
   message.
4. **TLC found no liveness violation from a dropped request.** Under P4b
   the teller's own bounded timer gives liveness with no fairness on
   the network. The violation it found is the Late clause, a stronger
   property than the one the spec named.
5. **The Phase A agent drew all three reference seams, not two,** plus
   two the spec did not list, one of which it refuted itself. And it did
   not pose the retry-is-the-same-message question: its drawing
   settled it, the timeout arrow re-emits the same id, and the decision
   it posed instead was what the ledger says to the copy.

Predictions that held: every Phase B agent under twenty minutes and
green; every ledger list names the teller on timeout and every teller
list names the ledger on the duplicate; the composed relation needed the
applied order as a history variable; the composed check found one bug no
component check found, and found the plant at one duplicate; the
person's part was about four minutes; the equation lane invented at
least one field not in scope (`id`, `tries`); the retry decision was not
decidable from the teller's equation with one request per session; the
balance-now reply was decidable from the ledger's equation.

| | method | control |
|---|---|---|
| person's minutes | about 4, answering six decisions | about 1, the paragraph |
| wall clock, agents | A 6.4, B 11 in parallel, C 48 self-reported (C was interrupted by a session limit and resumed) | 3.5 |
| reference drawings found unprompted | 3 of 3, plus 2 | n/a |
| bugs before integration, component checks | 3 unplanted, 4 plants found | 0 (its own mutation check only) |
| bugs at integration, composed check | 1 unplanted, in the composed equation; plant found | n/a |
| planted seam bug | found, one duplicate | scenario correct |
| liveness violation by TLC | yes, the Late clause; no network fairness needed | n/a |
| product decisions made explicit | 6 in A, 3 more surfaced in B and C | 0 as decisions, 7 named gaps |
| "does not say" items naming another component | every agent, 2 to 4 each | n/a |
| fields born from the equation that the drawing also forced | ledger: `bal`, `seen : Id ⇸ Rep`, P2a, P3a; teller: `pend`, `seq`, `tries`, `out`, `unknown`, GiveUp, same-id resend | n/a |
| fields the drawing forced that no equation produced | `acct`; `out` as state; the teller in `Id`; the reply's id with the `Take` guard and `Ignore` | n/a |
| rounds of the stuck-goal loop | ledger 8, teller 9 | n/a |
| tests at the end | 57, plus 27 in the control with the probe | 20 |

What the run says. The two open clauses of the claim both held: one
agent's drawing scaled to the system, and composition found what the
components missed. But what composition found was a flaw in the drawn
specification, not in the code, and the control, with no specification,
arrived at the same design on every decision but one. On this system the
method's product is the list of nine decisions and the proof that one
stated equation was false under them; its cost is roughly twenty times
the control's wall clock. The method earns that where the one decision
the control made silently is the one that matters. Here it was P5, and
the control's tests could not see it because nothing in the control
names it.

The second lane: the equation births the ledger and the teller almost
whole, and shows exactly which network kills each cheaper design, which
the drawings never did. What it cannot supply is what the drawings had
to invent: an identity when two requests are equal, a bound when no
safety equation forces a resend, and the teller in the id when there
are two tellers. Those three are where the rule "fields are variables in
scope" runs out, and each was named at its round.

Phase D is closed by the kill criterion: in both equation lanes the
fields were read off the goal mechanically except at the invented ones,
and at those the proposer's contribution was the decision, not the name.
