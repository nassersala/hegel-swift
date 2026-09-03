# A poor man's proof assistant: calculation by refutation

Status: method, evaluated 2026-09-02 and 03; the library half is
`Sources/Hegel/Stuck.swift`, prototyped 2026-09-03 and not yet merged into
the README. Reading order: after `denotational-design.md` and
`algorithm-search-experiments.md` (E7); `system-from-specifications.md` is
the system-scale evaluation.

## The claim

Bahr and Hutton calculate a compiler from its correctness equation. The
source language and its meaning are known; the machine, its instructions,
and the compiler are not. They prove the equation by induction, and at
every goal the proof cannot take, they define the instruction that makes
the goal compute. The data type is not designed. It is what the stuck
goals give birth to, one constructor per goal, its fields the variables in
scope at that goal. That needs a proof assistant to show the goal.

Hegel cannot close a goal. It can find one. Leave the unknowns partial,
state the equation as a property, and the shrunk counterexample is the
smallest input the definitions do not cover, with the values in scope.
That is the stuck goal as a concrete term. Someone, a person or an agent
under the rule "one constructor whose fields are the variables in scope",
defines the case; the property runs again; the next counterexample is the
next goal. The calculation proceeds by refutation instead of proof.

The claim is that this loop derives a data type from an equation the way
the proof does, on the systems people write in Swift, with the proof
assistant replaced by a property tester and a shrinker.

## What it is not

- **A proof.** When the tester stops finding goals, the equation holds on
  drawn inputs. It does not hold. Pilot C established the limit
  concretely: the append form and the continuation form of the bank's
  `send` both pass, and only the prover sees the lemma that separates
  them. The fork is visible to the prover and not to the tester.
- **A design.** The equation is stated by a person and does not move
  during the loop. Where a goal cannot be made to compute from what is in
  scope, the loop stops and the person decides. The list of those stops is
  short and it is the product; see "Where the rule runs out".
- **Synthesis.** Counterexample-guided inductive synthesis proposes a
  program and refines it against counterexamples. Here the counterexample
  is "undefined here", not "wrong answer"; what is born is a data type's
  constructors and fields, not a program over a fixed type; and the
  proposer is bound by a rule about scope, not a search.

## The loop

1. State the equation with the meaning on one side and the unknowns on
   the other: `apply (send r) b ≡ ⟦ r ⟧ b`. The term `r` appears once as
   data handed to the unknown and once interpreted. That is the
   homomorphism square, and it is the same in every source: Hutton's
   `eval' e c = c (eval e)`, Bahr and Hutton's
   `exec (comp' x c) s = exec c (eval x : s)`.
2. Make every unknown partial: `Msg` with no constructors, `send`
   returning nil.
3. Run the equation as a property. It stops in one of three ways, and
   they are different findings. **Stuck**: an unknown is undefined at the
   shrunk input, the next goal. **Refuted**: a defined case is wrong at
   the shrunk input, a bug to fix before going on. **Holds**: no drawn
   input reaches a hole or a wrong case.
4. At a stuck goal, propose one constructor or one field whose value is
   exactly a variable in scope, define the function on it so the goal
   computes, and record the round: the goal as printed, the constructor,
   and where each field came from.
5. Repeat until holds. The rounds are the derivation, and they are what
   a reader compares against the proof.

## The library half

```swift
public struct Stuck: Error          // a hole: the goal, and optionally the values in scope by name
public func defined<T>(_ value: T?, _ goal: @autoclosure () -> String) throws -> T
public enum Verdict<Input> { case stuck(Input, Stuck), refuted(Input, String) }
public func stuckGoal<A>(_ inputs: Gen<A>, …, _ equation: (A) throws -> Void) throws -> Verdict<A>?
```

`defined` turns an Optional unknown into a throw naming the hole; the word
is the calculation's own, the proof is stuck where a function is not yet
defined. `stuckGoal` is one `forAll` run: nil when the equation holds on
every drawn input; otherwise the minimal input recovered as a value by
replaying the failure's blob, and the equation run once more at that input
to classify what it throws. It is a new function rather than a mode of
`forAll` because the contract differs: `forAll` throws and its
counterexample is a string for a report; a calculation has three outcomes
and needs the stopping input as a value to continue from. Inside a plain
`forAll` or `expectAll` a thrown `Stuck` is a distinct bug from any
refutation and the report reads `stuck: <goal>` under the counterexample.

The bank, `send` defined as far as `born`:

```swift
try stuckGoal(zip(Req.gen(), .int(in: 0...9))) { r, b in
    let m = try defined(Msg.send(r, born: born), "send (\(r))")
    let got = Msg.apply(m, b)
    if got != r.meaning(b) { throw LawViolated("apply (send r) b", got, "meaning r b", r.meaning(b)) }
}
```

One `stuckGoal` per birth, the same three goals `Calculation.stuckGoal` in
`Examples/AboveTheCode/Bank.swift` hand-rolls, in the same order, and nil
once `SEQ` is born:

```
stuck: send (deposit 0)
  at (deposit 0, 0)
stuck: send (withdraw 0)
  at (withdraw 0, 0)
stuck: send ((deposit 0 then deposit 0))
  at ((deposit 0 then deposit 0), 0)
holds
```

With debit not monus, a refutation, not a hole:

```
refuted at (withdraw 1, 0): apply (send r) b = -1, meaning r b = 0
```

Undo, the equation `⟦ undo (record e d h) ⟧ (⟦ e ⟧ d) ≡ d`, with the first
draft of the entry holding the edit alone (`Tests/HegelTests/UndoSubject.swift`):

```swift
let verdict = try stuckGoal(inputs) { e, d, h in
    let history = Draft.record(e, d, h)
    let past = try defined(Draft.undo(history), "undo \(history)")
    let got = meaning(past)(meaning(e)(d))
    if got != d { throw LawViolated("undo(e)(e(d)) = \(got.debugDescription), d = \(d.debugDescription)") }
}
```

```
stuck: undo [Entry(delete(at: 0, count: 0))]
  at (delete(at: 0, count: 0), "", [])
```

The shrinker went to `delete(at: 0, count: 0)` on the empty document, the
smallest input that reaches the hole, which is smaller than the smallest
input that refutes the total version (`delete(at: 0, count: 1)` on `"a"`).
That is the right shape for a goal: it is unprovable regardless of
content. The deleted text is nowhere on the unknown's side; it was in `d`.
So `record` takes `d` and the entry grows a field holding the substring,
and the verdict is nil. That field is the design of undo, born at one goal.

In a plain `forAll` the same draft reports:

```
property failed with 1 distinct bug(s)
  counterexample: (delete(at: 0, count: 0), "", [])
  stuck: undo [Entry(delete(at: 0, count: 0))]
  reproduce blob: AXicY2UAAi5GIMEIoaA8BhYGsBgAA4UALQ==
```

`Failure.error` in `Runner.swift` carries what the property threw at the
minimal counterexample, and the report prints it on the line after. The
line comes from the last error the run saw under the bug's origin, correct
on the single-bug default; under `reportMultipleFailures` a cross-origin
hit can name a larger case's error. The deterministic version re-runs the
property at the replayed value, as `expectAll` and `stuckGoal` do, and
needs the async loop to replay too. Described, not made.

## Evidence

- **Pilot C** (`Examples/AboveTheCode/Pilot/C-calculation.md`,
  `algorithm-search-experiments.md` E7). A fresh agent with no files as the
  propose half, Hegel as the refute half, one goal per round. `CREDIT`,
  `DEBIT`, `Then` unprompted; the stream once a flat wire was demanded.
  Four rounds, zero retries. The fork between append and continuation was
  invisible to the tester.
- **The bank, system scale** (`system-from-specifications.md`, the second
  lane). The ledger from its equation with the network as a term,
  `∀ net: apply* (net (send r)) b ≡ ⟦ r ⟧ b`, in eight rounds: `CREDIT n`,
  `DEBIT n` from scope; the first repeat refuted; a ledger remembering one
  message, from scope; the balance-now reply refuted by a single request;
  the stored reply, from scope; two equal requests refuted and an identity
  invented; a delayed copy refuted and the set of seen messages from
  scope. The teller in nine, inventing the retry bound, since no safety
  equation forces a resend. The equation-born ledger and teller matched
  the hand-drawn ones on every field except the three below, and showed
  which network kills each cheaper design, which the drawings never did.
- **Undo** (`Tests/HegelTests/StuckTests.swift`), above.

## Where the rule runs out

The rule is "a field is a variable in scope at the goal". Three times in
the bank it could not be followed, and each time the loop said so at its
round. These are the decisions the equation cannot make, and they are the
person's part.

- **Identity.** Two equal requests, `deposit 1` twice, refute the
  equation with nothing in scope to tell them apart. An id is invented.
- **A bound.** No safety equation forces a resend; a single copy satisfies
  them, and the network's fairness collapses. The retry and its bound come
  from outside the equation, and the teller's `tries` is invented.
- **Structure the equation cannot see.** With one teller the equation
  accepts an id that is a bare sequence number; with two, the drawing
  refutes it. The teller in the id comes from the composed system, not
  the component's equation.

The stops are the product as much as the fields are: a list of what a
person has to decide, each at the concrete input that forced it.

## Relation to other work

- Bahr and Hutton, calculating correct compilers (2015) and the series
  after it: the method, with a proof assistant showing the goal.
- Elliott, denotational design and homomorphic specification: the
  equation as the design, the square as the invariant. The wiki's pages on
  the homomorphism square and on stuck calculations record the lineage.
- Danielsson, Hughes, Jansson and Gibbons, "Fast and Loose Reasoning is
  Morally Correct": reasoning as if the language were total. This method
  calculates as if it had a prover and checks by refutation; the same
  spirit, and the same caveat about what carries over.
- Claessen, "A Poor Man's Concurrency Monad": the phrase, and its meaning,
  the cheap version that does the one job.
- Counterexample-guided inductive synthesis: the nearest loop; see "What
  it is not".
- Type-targeted testing (Seidel, Vazou, Jhala 2015), QuickChick's derived
  generators (Lampropoulos, Paraskevopoulou, Pierce 2018), Feat (Duregård,
  Jansson, Wang 2012): generators from types. Relevant to the open
  question below on making "holds" mean something.

## Open questions

- **Holds is the weak verdict.** It means the drawn inputs reached no
  hole. Bounded exhaustive enumeration of the input type would make it
  "no hole reachable up to size n", a bounded proof in the SmallCheck
  sense; a solver over the type would make it exact. Hegel's enumeration
  today is over state machines, not types; this would be a new piece, and
  the bridge to closing the loop in a prover.
- **The proposer.** `system-from-specifications.md` Phase D asked whether
  a proposer at the seam is worth automating and closed it by its kill
  criterion: in every lane the fields were read off the goal mechanically
  except at the invented ones, and there the proposer's contribution was
  the decision, not the name. The rule does the naming; the person does
  the deciding.
- **Export.** The equation Hegel checks and the theorem Agda would close
  have the same left side. A deep embedding of the equation, one value
  interpreted by the tester and printed for the prover, would let the
  constructors born under Hegel be the ones the proof needs, without
  retyping. Not built.
- **The report line under multiple failures.** Above.
