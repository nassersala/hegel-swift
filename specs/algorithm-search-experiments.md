# Above the code: Lamport's method as a skill, and whether an agent finds the variables

Status: 2026-09-02. Fixtures built, run, and checked in (`Examples/AboveTheCode`,
15 tests, all green; numbers below are from the first run). The skill is
written (`.claude/skills/above-the-code/SKILL.md`). The evaluation is designed
and piloted at one run per cell; the full run is not done.

This file replaces a draft of the same name that began at the fixtures. The
draft's mistake, found by reading it against Lamport's own Die Hard and
quicksort lectures, is recorded in "What the draft got wrong" so the report
can say what changed and why.

## Question

Lamport's method for arriving at an algorithm has a first step before any
formula: write one behaviour by hand. From the jugs behaviour he reads off
the variables `small` and `big` and the fact that filling a jug is one step;
from the quicksort behaviour he reads off `A` and `U`, the set of ranges
still to partition, and `U` is what almost nobody who starts from the
recursive code can find in ten minutes. Then Init and Next as a relation, then
TLC, then code as one refinement among several.

The relation is the algorithm. So "can the tool come up with the algorithm"
is the wrong question; the tool starts after the drawing. The question is:

> Does an agent made to draw one behaviour and read the variables off it,
> before writing code, arrive at the relation (the variable not in the code,
> Next as a relation, code as a refinement) where an agent asked for the
> algorithm directly writes code and stops?

Lamport's evidence for the method is a human experiment, the ten-minute test
on his friends. The output here is the method as a skill an agent can follow,
and the experiment is his test made repeatable, with Hegel as the judge at
the end of each run.

## What the draft got wrong

- It opened every experiment at the fixture: a `State` type, rules, an
  invariant. The drawing, which is where the variables come from, was
  skipped. Doing the drawing for the network fixture found that the set of
  vectors shrinks (see E1), which made the draft's targeting score constant.
- It called grammar search over loop programs an experiment in the same
  method. It is Fung's method, "make up some wrong sorting algorithms and
  test them", minds in the code. It is kept, as the control.
- It stated the explanation of Fung as three relations without deciding what
  one step is; relation 1 was per swap and relations 2 and 3 per pass.
  Lamport's second lesson from the drawing is that decision.
- It justified the network search's hit rate with "any superset of bubble's
  comparators in any order is a network", which is false. The right reason
  is monotonicity: a comparator with `i < j` never unsorts a zero-one vector
  and never raises its inversion count, and while any vector is unsorted
  some comparator lowers it.

## The method, as the skill states it

1. Draw one behaviour by hand on a small concrete input: states as records,
   one word per arrow. A step has no intermediate states. Each row must
   determine the next from the arrow alone; if not, a variable is missing.
2. Read the variables off it. They are the fields of the record. TypeOK.
3. Say what one step is, in one sentence. The refinement check records the
   code at this granularity.
4. Init and Next in mathematics. Every "pick any" an existential; every
   variable's new value stated.
5. Check the relation with Hegel on drawn behaviours (the thing TLC does for
   small N); or, when the goal is a plan or a fixed step sequence, the Die
   Hard shape, rules and a false invariant.
6. Only now the code, instrumented at the step granularity, and `refines`:
   every consecutive pair a Next step, the run ends done. Name a second
   refinement if there is one.
7. Report, ending with what the relation does not say.

Steps 1 and 2 are the person's move. Hegel starts at 5. The skill says so.

## Hypotheses

**H1 (the trace is the algorithm, finite case).** With the state being every
zero-one vector of length `n` at once and a rule one comparator applied to
all of them, the shrunk counterexample to "not all sorted" is a sorting
network, and it certifies itself. Confirmed, E1.

**H2 (a relation above Fung).** Drawing Fung's algorithm one state per pass
yields the variables prefix and rest; the insertion relation with the rest
free to permute is refined by Fung and by insertion sort, and two stricter
relations are refuted with minimal traces. Confirmed, E3.

**H3 (the control).** The 24-program grammar classifies as the hand table
says, every wrong program refuted by two or three elements, and the run
says nothing about why the survivors sort. Confirmed, E2.

**H4 (the skill).** An agent following the skill produces, on a held-out
problem, a drawn behaviour before any code, a state variable that is not a
variable of the code, Next as a relation, and code presented as one
refinement, at a higher rate than the same agent asked directly. This is
the open one. Design and pilot below.

## E1: the trace is the algorithm

Drawn by hand first, `n = 2`:

```
{00, 01, 10, 11}  ─cmp 0 1─▶  {00, 01, 11}
```

Variables: one set of vectors. Step: one comparator on all of them. The
drawing also shows `10` and `01` merging: the set shrinks, "all sorted" is
reached when the unsorted vectors have merged away, and the sorted vectors
`0…01…1` are all present from the start. So the draft's targeting score,
"number of sorted vectors", is constant from step zero; the score is the
unsorted count. TypeOK: every vector length `n` over `{0, 1}`, set nonempty.

Fixture: `ZeroOne`, `searchNetwork(n:seed:testCases:steps:targeted:)`,
`network(fromTrace:)`, the two checks outside the runner.

Results, first run:

| | |
|---|---|
| `n = 4`, seed 1 | `cmp 0 2; cmp 1 3; cmp 0 1; cmp 2 3; cmp 1 2`, 5 comparators, the optimum |
| `n = 4`, seeds 1–20 | 18 shrink to 5, 2 to 6 (seeds 6 and 20); all pass both checks |
| `n = 4`, unseeded | 20 of 20 hit at the default 50 steps |

`n = 5` (32 vectors, 10 comparators, optimum 9), 20 seeds, 200 cases, by
step budget, random versus targeted:

| steps | random | targeted | sizes found |
|---|---|---|---|
| 9 | 0 | 1 | |
| 10 | 1 | 3 | 10 |
| 12 | 6 | 11 | all 9 |
| 16 | 20 | 17 | all 9 |
| 50 | 20 | 20 | 16 × 9, 4 × 10 |

Predictions against the run: "5 or 6" held, and the optimum came out of a
deletion-minimal shrink in 18 of 20 seeds, which the draft did not predict.
"Near 100 percent at 50 steps" held. Targeting helped at budgets near the
optimum and cost three hits at 16 steps in that run. The checked-in test
keeps 10 seeds and 100 cases for CI time, and its run was: 10 steps 0 versus
1, 12 steps 3 versus 5, 16 steps 8 versus 8, 50 steps 10 versus 10. The
help near the optimum reproduced; the cost with slack did not, so it is
recorded as one run's observation, not a finding. Fewer cases per search
lowered every hit rate, which says the budget that matters is cases times
steps, not steps alone.

## E2: the control

Fung's grammar, 24 programs, on `array(of: .int(in: 0...9), count: 0...8)`,
1000 cases per direction, seed 1. The hand table (in `CandidateTests`) was
confirmed cell for cell: 8 ascending, 8 descending, 8 neither; every
`neither` refuted by an array of length two or three; the two hand-checked
instances reproduced (`[1, 0]` and `[0, 1, 2]` for `<, 1…n−1, 1…n` came
out as `[0, 1]` and `[0, 0, 1]`, the shrinker's smaller pair). The table is
a theorem by the argument in the test's comment, so the run confirmed a
proof; what the control shows is the shape of the evidence, an input per
refuted program and silence on the rest.

A use it was not built for: the control B answer in the pilot (below)
asserts that the `>` variant of Fung "does not sort"; the table says it
sorts descending. The grammar refuted a claim made by the agent that had
the invariant proof right.

## E3: the relation above Fung

Drawn by hand first, one state per pass, on `[1, 0, 2]`:

```
[1, 0, 2] ─pass 0─▶ [2, 0, 1] ─pass 1─▶ [0, 2, 1] ─pass 2─▶ [0, 1, 2]
```

Variables: a sorted prefix and the rest. Step: one pass, one element joins
the prefix at its place. Pass 0 turned the rest `[0, 2]` into `[0, 1]`: the
rest is permuted, and the relation has to allow that.

Three relations, each a `Next(s, s′)`, each checked as `Lamport.refines` is:

| relation | step granularity | Fung | insertion sort | exchange sort |
|---|---|---|---|---|
| 1. a step swaps an inversion | swap | refuted on `[0, 1]`: `[0, 1] → [1, 0]` | | refines |
| 2. insertion, rest fixed | pass | refuted on `[1, 0, 2]`: `prefix [], rest [1, 0, 2] → prefix [2], rest [0, 1]` | refines | |
| 3. insertion, rest permuted | pass | refines | refines | |

Both refutations shrank to exactly the hand-predicted inputs. Every drawn
behaviour of relations 2 and 3 ends sorted. Relation 3 does not say why
Fung's later passes leave the rest alone; that is his invariant "the prefix
ends with the maximum", which the check does not need and does not find.
Two pieces of code, one relation, differing by which element a pass picks.

## E4: the skill, evaluated

### Conditions

- **Control.** The bare task.
- **Treatment.** The task with the skill text inline, the instruction to
  follow it in order, and no algorithm code before step 6.

Same model, fresh context, no repository access, no web. Runs write a
markdown answer; the transcript is the data.

### Problems

Die Hard and `(A, U)` are in every Lamport lecture and will be recited.
The problems must have famous code and no written relation.

- **A, derive:** a non-recursive mergesort. The discovery is that the state
  is a sequence of sorted runs and a step merges two of them; bottom-up
  mergesort and the recursive one are two refinements.
- **B, explain:** Fung's algorithm, why it sorts. The discovery is prefix
  and rest, and that the relation is insertion with the rest free. The
  invariant proof from the paper is the control's expected answer.
- Candidates for a third: heapsort as a relation over a heap-ordered set
  and the sorted suffix; the alarm example from `usage-models.md`.

### Measures, per run, yes or no

1. A behaviour, states as records, appears before any code.
2. A state variable that is not a variable of the code is named (`U`,
   the runs, `rest`).
3. Next is written as a relation with at least one "pick any", not as a
   loop.
4. The code is presented as a refinement of the relation, and a second
   refinement is named.
5. Hegel, when run on the produced relation and code, confirms: every
   drawn behaviour is correct and the code refines. Not measurable in a
   no-repository run; measured by porting the answer into
   `Examples/AboveTheCode` afterwards.

### Kill criteria

- If the control also draws first and names the missing variable, the skill
  adds nothing and the finding is that the model already has the method.
- If the treatment draws and still names only the code's variables, the
  drawing does not deliver the variables to an agent, and the honest
  sentence is Lamport's: the reading is the person's move.
- If the treatment produces relations that fail measure 5, the skill makes
  agents write mathematics that is wrong, which is worse than code.

### Pilot, one run per cell

Run 2026-09-02, same model in all four cells, fresh context, no
repository or web access, answers in `Examples/AboveTheCode/Pilot/`. The
first treatment attempts died on a rate limit and were rerun with identical
prompts. Judged by the author of the skill, which is a weakness recorded here.

| measure | A control | A treatment | B control | B treatment |
|---|---|---|---|---|
| 1. behaviour before code | no: code first, merges described in prose | yes: drawn, then redrawn when a row could not determine the next | no: a printed trace after the proof | yes: drawn per pass, then redrawn as prefix and a bag |
| 2. variable not in the code | no: `width` and blocks, the code's own | yes: `R`, the set of runs already sorted | no: the invariant over `A[0..i]` and the maximum | yes: `placed` and `rest` as a bag |
| 3. Next as a relation, a "pick any" | no: a loop invariant | yes: any two adjacent runs; `Merged` as a set | no | yes: any `x` in `rest`; `Inserts` as a set |
| 4. code as one refinement, a second named | no | yes: bottom-up and recursive; natural mergesort under a weakened Init | no | yes: insertion sort and selection sort as other picks |
| 5. Hegel confirms | not applicable | yes, `Mergesort.swift`: every behaviour keeps Inv and ends in `N−1` steps, both codes refine, the predicted off-by-one rejected at step 0 and shrunk to `[0, 0, 0]` | one claim refuted: "the `>` variant does not sort"; E2's table has it sorting descending | yes: its relation is E3's relation 3; its new claim, that skipping pass 0 sorts but does not refine the relation, confirmed and shrunk to `[1, 0, 2]` |

Two things beyond the table.

- Treatment B wrote a first Next with `x = Head(rest)`, saw that pass 1 of
  its own drawing was not a step of it, and weakened the pick to "any
  element" before writing code. That is E3's relation 2 refuted by hand,
  from the drawing, which is what the method says should happen.
- Both treatments ended with what the relation does not say and put the
  maximum argument there, outside the relation, in the refinement proof.
  Both controls were correct, and control B's proof is the paper's; its one
  false sentence is the kind the grammar table exists to catch.

Against the kill criteria: the controls did not draw first, so the skill is
not redundant with the model; both treatments read the variables from the
drawing rather than from the code, so on these two problems the reading
was not lost on an agent; no treatment relation failed measure 5. One run
per cell is a pilot. The full run needs more seeds, a third problem, and a
judge who did not write the skill.

## Not claimed

- Hegel does not find the variables. The drawing and the reading are done by
  whoever draws; the skill makes an agent draw, and E4 measures whether it
  then reads.
- E1's networks are algorithms for one `n`. Nothing here produces a loop
  from a trace.
- E3's relations are written by a person. Two are refuted; silence on the
  third is not a proof, and the relation's own correctness is checked on
  drawn behaviours only.
- E2's grammar is chosen by a person and the intelligence is in the choice.

## Where this goes

- README: section "Example: above the code, and the trace as the algorithm"
  and a roadmap line, done.
- The book afterword on property-based testing: Bahr and Hutton calculate
  the program from the meaning and get the reason with it; TLC and Hegel
  search against the meaning and get a witness with no reason; Lamport's
  drawing is a third thing, a method for finding the variables that neither
  calculation nor search supplies, and E4 is whether a method is enough.
