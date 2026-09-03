---
name: above-the-code
description: Lamport's method for arriving at an algorithm ("Thinking Above the Code"). Draw one behaviour by hand, read the variables and the step off it, write Init and Next as a relation, check the relation with Hegel on drawn behaviours, then check that code refines it. Use when asked to come up with an algorithm, to write a non-recursive or iterative or parallel version of one, or to explain why an algorithm works.
---

# Above the code

The order is the method. Do the steps in this order and do not write code
before step 6. The reason: a person who starts from code cannot find the
non-recursive quicksort in ten minutes, and a person who starts from one
drawn behaviour finds `U` in it. The variables are read off the drawing,
not invented.

## 1. Draw one behaviour

Pick a small concrete input: three elements, two jugs, four bits. Write the
behaviour as a row of states, each state a record of named values, one word
on each arrow saying what the step was. Put the drawing in your reply, as a
message, before you write or edit any file; the order is the method, and a
drawing that first appears inside a source file cannot be told from one
made afterwards to match the code:

```
[small: 0, big: 0] ─fill small─▶ [small: 3, big: 0] ─pour─▶ [small: 0, big: 3] ─▶ …
[1, 0, 2] ─pass 0─▶ [2, 0, 1] ─pass 1─▶ [0, 2, 1] ─pass 2─▶ [0, 1, 2]
```

Rules for the drawing:

- A step has no intermediate states. Filling a jug is one arrow. If you
  want to see inside a step, that is a different, finer behaviour; draw it
  separately and say which one you are using.
- Each row must contain enough that the next row follows from the arrow
  alone. If you had to remember something not in the row to write the next
  row, a variable is missing. Write it in. That variable is usually the
  algorithm: `U`, the set of ranges still to partition, is what makes
  quicksort iterative; `rest`, the elements not yet placed, is what is
  above insertion sort.
- Where the drawing did not care which choice was made (which range, which
  pivot, which element), say so. Those become the "pick any"s of Next.

## 2. Read the variables off it

The variables are exactly the fields of the record you drew. Name them.
Say for each what set of values it takes. That is TypeOK.

## 3. Say what one step is

One sentence: "a step is one partition of one range", "a step is one pass
of the outer loop", "a step is one comparator applied to every vector".
The refinement check in step 6 records the code at exactly this
granularity, so decide it here.

## 4. Write Init and Next in mathematics

```
Init:  A = any array of numbers of length N  ∧  U = {⟨0, N−1⟩}
Next:  U ≠ {}  ∧  pick any ⟨b, t⟩ in U:
         if b ≠ t then pick any p in b..t−1:
              A′ ∈ Partitions(A, p, b, t)
            ∧ U′ = U \ {⟨b, t⟩} ∪ {⟨b, p⟩, ⟨p+1, t⟩}
         else A′ = A ∧ U′ = U \ {⟨b, t⟩}
```

Next is a relation between the state and the next state, a disjunction of
step kinds. Every "pick any" is an existential. Every variable's new value
is stated, including the ones that do not change. Nondeterminism is not a
defect; it is what makes the relation more general than any one program.
Define the sets you use (`Partitions`) as sets, not procedures.

Doing nothing is a step. Between any two rows a row can repeat, and the
relation should allow it: an `idle` event, or TLA's `[][Next]_vars`,
which stutters by construction. Say so in Next rather than leaving it to
the reader. The consequence arrives in step 5: once idle is a step, every
"eventually" the drawing promised (the upgrade completes, the queue
drains, the counter reaches three) is no longer a property of any finite
trace, because a behaviour that idles forever is a behaviour. Its bounded
form is: every completed behaviour takes exactly this many non-idle
steps, and that is checkable. The unbounded form is a fairness assumption
on the environment, stated as `WF`, and it belongs to the TLA twin.

## 5. Check the relation with Hegel

Write the relation as a Swift value before any algorithm:

```swift
struct Model {                       // the record from step 1
    func enabled(_ step: Step) -> Bool     // Next(self, step)
    mutating func apply(_ step: Step)      // precondition: enabled
    func draw(_ tc: TestCase) throws -> Step   // the "pick any"s as draws
    static func behaviour(_ input: Input) -> Gen<(steps: [Step], final: Model)>
}
```

Then the relation's own property on drawn inputs and drawn choices, the
thing TLC checks for small N:

```swift
expectAll(inputs.flatMap { a in Model.behaviour(a).map { (a, $0) } }) { a, run in
    #expect(run.final.done)
    #expect(run.final.answer == expected(a))
}
```

When the goal is a plan or a fixed sequence of steps rather than a loop,
use the Die Hard shape instead: rules for the steps, a false invariant for
the goal, and the shrunk counterexample is the answer.

```swift
try forAll(initial: Gen { _ in Start() },
           rules: [Rule("fill small") { s, _ in s.small = 3 }, …],
           invariants: [Invariant("big is never 4") { if $0.big == 4 { throw Solved() } }])
```

If the state is finite and the goal check is exact, the trace certifies
itself. A sorting network for fixed n is this shape: the state is the set
of all zero-one vectors of length n, a rule is one comparator applied to
every vector, and the trace that reaches "all sorted" is a network by the
zero-one principle. See `Examples/AboveTheCode/Sources/AboveTheCode/Network.swift`.

## 6. Now write the code, and check it refines the relation

Instrument the code to record its states at the granularity of step 3.
Replay the recorded states against the relation: every consecutive pair
must be a Next step and the run must end done. The first pair that is not
a step is the bug, found before the output is wrong.

```swift
let (violation, final) = Model.refines(recordedSteps, from: a)
#expect(violation == nil)
#expect(final.done)
```

Name the code as one refinement and look for a second: the recursive
quicksort and the worklist quicksort refine one relation; Fung's sort and
insertion sort refine one insertion relation, differing by which element
each pass picks. When a code's behaviour is not a behaviour of the relation
you wrote, say which of the two is wrong and why; if the relation is too
strict, weaken one clause and record which.

## 6a. Two claims a relation makes without saying so

- **Steps are whole.** If the code will be async, or called from more than
  one task, that is a claim, not an assumption. Run the refinement under
  the controlled scheduler in `Examples/ScheduleProperties`, and plant the
  classic bug, an `await` between the check and the commit of one step, to
  show the check bites. `Examples/TwoPhaseCommit` is the precedent: the
  same-actor `await` in the decide step was a suspension point.
- **A step that can repeat is bounded, or it is not.** A retry, a refresh,
  a resend: if Next lets it happen again with nothing in between, say
  whether that is a loop the relation permits forever. Write the bound as
  a clause, and its safety form as a temporal formula over the trace,
  checked with `TemporalLogic.swift`: "no two refreshes without a success
  between them". The invariant cannot say it, because an invariant sees
  one state; the formula sees the loop at its second turn and the shrinker
  finds it. Liveness itself is not testable on a finite trace; say so.

## 7. Report, and what the relation does not say

In this order: the drawn behaviour; the variables; what a step is; Init
and Next; the checks and their numbers; the code and the refinement result;
what the relation does not say. The last item matters: refinement shows
the code is a behaviour of the relation, it does not say why the code is
one. Silence from the checker is not a proof.

The list of what the relation does not say is not the end of the run.
Every item on it gets one of three verdicts, and the run ends when each
has been handled:

- **Checkable now.** Write the check and run it in this session. A bound,
  a liveness formula, a second refinement, the async version under
  schedules.
- **A product decision.** Stop and ask, with the alternatives stated as
  clauses of Next, not as prose. "A refresh that fails from the network
  signs out" versus "is retried once with the same token" is a decision
  the person makes, and it goes into the relation once made.
- **Out of scope.** One line saying why, and what would change if it came
  in. Another process sharing the same state (an app extension reading the
  same Keychain item) is the usual one: it breaks a one-session relation
  and no check of the session finds it.

## What the method does not do

The drawing and the reading of variables are the person's move. Hegel
starts at step 5. A grammar search over programs, "make up some wrong
algorithms and test them", finds programs and says nothing about why they
work; it is the control, not the method.

## Worked examples in this repository

- `Tests/HegelTests/DieHardTests.swift`: the plan as the shrunk trace.
- `Examples/Quicksort`: `(A, U)`, three refinements, TLC on the same relation.
- `Examples/AboveTheCode`: the sorting network as a trace; the insertion
  relation above Fung's algorithm, two wrong relations refuted with
  minimal traces; the 24-program grammar as the control.
- `Examples/TwoPhaseCommit`: transaction commit as the relation, two-phase
  commit as the refinement, `TPSpec ⇒ TC!TCSpec` checked of the code.
