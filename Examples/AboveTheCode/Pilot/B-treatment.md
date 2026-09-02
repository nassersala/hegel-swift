# Why `for i in 1...n: for j in 1...n: if A[i] < A[j]: swap` sorts

The code is given; the steps below are done in the method's order and no code is written before step 6. Nothing here was run: Hegel is not available in this exercise, so every check is written out as the Swift value and property I would use and marked unchecked. Where a check could be done by hand on the drawn input it was, and that is said.

Indexing: `A[1..n]` in the mathematics as in the problem, `A[0..<n]` in the Swift.

## 1. One behaviour, drawn

Input `A = [2, 0, 3, 1]`, `n = 4`. One arrow per pass of the outer loop. Traced by hand from the code:

```
[2, 0, 3, 1] ─pass 1─▶ [3, 0, 2, 1] ─pass 2─▶ [0, 3, 2, 1] ─pass 3─▶ [0, 2, 3, 1] ─pass 4─▶ [0, 1, 2, 3]
```

Rule 2 fails on this drawing: from the row `[3, 0, 2, 1]` alone one cannot write the next row; one has to remember that the next pass is pass 2. The pass counter is a missing variable. Written in:

```
[A: [2,0,3,1], i: 0] ─pass 1─▶ [A: [3,0,2,1], i: 1] ─pass 2─▶ [A: [0,3,2,1], i: 2] ─pass 3─▶ [A: [0,2,3,1], i: 3] ─pass 4─▶ [A: [0,1,2,3], i: 4]
```

Now each row determines the next. Reading the rows with `i` as a bar in the array:

```
[ | 2,0,3,1]  ─▶  [3 | 0,2,1]  ─▶  [0,3 | 2,1]  ─▶  [0,2,3 | 1]  ─▶  [0,1,2,3 | ]
```

Three things are visible.

- Left of the bar is sorted in every row, and it grows by one element per pass.
- Right of the bar, passes 2, 3, 4 do not touch it: `2,1` then `1` are carried across unchanged. Pass 1 does touch it: `3` came to the front and the `2` it displaced landed where the `3` was. So pass 1 is not "take the next element"; it takes the largest one, and leaves the rest in some order.
- The order right of the bar is the one thing the drawing does not need. What the next pass does is "one element from the right side goes into the sorted left side at its place". Which element it is does not change the shape of the row. So the right side is drawn as a bag, and the choice is a "pick any":

```
[placed: ⟨⟩,        rest: {2,0,3,1}] ─insert 3─▶
[placed: ⟨3⟩,       rest: {0,2,1}]   ─insert 0─▶
[placed: ⟨0,3⟩,     rest: {2,1}]     ─insert 2─▶
[placed: ⟨0,2,3⟩,   rest: {1}]       ─insert 1─▶
[placed: ⟨0,1,2,3⟩, rest: {}]
```

This is the drawing used from here on. Each row plus the word on the arrow gives the next row.

Two finer behaviours, drawn separately because they will be needed in step 7 and are not the granularity used. One arrow per inner-loop iteration `j`; `c` is the element currently at `A[i]`, the carry.

Pass 1 of the run above (`i = 1`, `c` starts as 2):

```
[2,0,3,1] c=2 ─j=1 no─▶ ─j=2 no (2<0 false)─▶ ─j=3 swap (2<3)─▶ [3,0,2,1] c=3 ─j=4 no (3<1 false)─▶ [3,0,2,1]
```

Pass 4 of the run above (`i = 4`, `c` starts as 1):

```
[0,2,3,1] c=1 ─j=1 no─▶ ─j=2 swap (1<2)─▶ [0,1,3,2] c=2 ─j=3 swap (2<3)─▶ [0,1,2,3] c=3 ─j=4 no─▶ [0,1,2,3]
```

In pass 4 the carry walks along the sorted prefix, drops itself at the first larger element, picks that element up, and so on; the prefix shifts right by one from the drop point and the carry ends as the old last element. That is an insertion done by swaps. In pass 1 the carry only grows: it is a running maximum.

## 2. The variables

The record has two fields.

- `placed`: a finite sequence of integers. `placed ∈ Seq(ℤ)`.
- `rest`: a finite bag (multiset) of integers. `rest ∈ Bag(ℤ)`, i.e. a function `ℤ → ℕ` with finite support.

That is TypeOK. `i`, the pass counter of the first drawing, is `Len(placed)` and is not a separate variable. `n = Len(placed) + |rest|` is constant.

What the drawing also shows, and what will be the invariant rather than a variable: `placed` is sorted in every row, and `bag(placed) ⊎ rest` is the bag of the input in every row.

## 3. What one step is

A step is one pass of the outer loop: one value of `i`, the whole inner `j` loop run to the end. Step 6 records the code once per outer pass and nowhere else. The inner-loop drawings above are a finer behaviour and are not what is checked.

## 4. Init and Next

Definitions, as sets:

```
Sorted(t)        ≜  ∀ k, l ∈ 1..Len(t): k < l ⇒ t[k] ≤ t[l]
Perm(s)          ≜  { t ∈ Seq(ℤ) : bag(t) = bag(s) }
Inserts(x, s)    ≜  { t ∈ Perm(s ⌢ ⟨x⟩) : Sorted(t) }
```

`Inserts(x, s)` has exactly one element as a sequence of values, for every `s`: the sorted arrangement of `s` with `x` added. It is written as a set so that Next says what the new `placed` must satisfy, not how to build it.

```
Init:  placed = ⟨⟩  ∧  rest = bag(A₀)            for A₀ any finite sequence of integers

Next:  rest ≠ ∅  ∧  pick any x with rest(x) > 0:
           placed′ ∈ Inserts(x, placed)
         ∧ rest′   = rest ⊖ {x}                    (multiplicity of x down by one)
```

One step kind, one existential. Both variables' new values are stated.

Invariant, from the drawing:

```
Inv:  Sorted(placed)  ∧  bag(placed) ⊎ rest = bag(A₀)
```

`Init ⇒ Inv` (empty sequence is sorted; `∅ ⊎ bag(A₀) = bag(A₀)`). `Inv ∧ Next ⇒ Inv′`: `placed′ ∈ Inserts(x, placed)` is sorted by definition, and `bag(placed′) = bag(placed) ⊎ {x}` while `rest′ = rest ⊖ {x}`, so the union is unchanged. Every step lowers `|rest|` by one, so after exactly `n` steps `rest = ∅` and Inv gives `placed` sorted with `bag(placed) = bag(A₀)`: a sorted permutation of the input. This holds for every sequence of picks; the pick is free.

What was revised in getting here. The first Next I wrote had `rest` as a sequence and `x = Head(rest)`, `rest′ = Tail(rest)`, because passes 2–4 of the drawing do exactly that. Pass 1 of the drawing, `[2,0,3,1] → [3,0,2,1]`, is not a step of that relation: `Head(rest) = 2` and it would have given `placed′ = ⟨2⟩`, `rest′ = ⟨0,3,1⟩`. The clause weakened is the choice of `x`, from "the head" to "any element", which also turns `rest` from a sequence into a bag. That is recorded here; it was done from the drawing, before any code.

## 5. The relation as a Swift value, and its check

Unchecked: written against the shapes in the method (`Gen`, `TestCase`, `expectAll`), not run.

```swift
/// The record of step 1.
struct Model: Equatable {
    var placed: [Int]          // Seq(Int)
    var rest: [Int: Int]       // Bag(Int): value -> multiplicity, no zero entries

    enum Step: Equatable { case insert(Int) }        // the "pick any x in rest"

    var done: Bool { rest.isEmpty }
    var answer: [Int] { placed }

    // Next(self, step): the guard.
    func enabled(_ step: Step) -> Bool {
        switch step { case .insert(let x): return (rest[x] ?? 0) > 0 }
    }

    // Next(self, step): the new state. Precondition: enabled(step).
    mutating func apply(_ step: Step) {
        precondition(enabled(step))
        switch step {
        case .insert(let x):
            // placed' ∈ Inserts(x, placed): the sorted arrangement of placed ++ [x].
            placed.insert(x, at: placed.firstIndex { $0 > x } ?? placed.count)
            rest[x]! -= 1
            if rest[x] == 0 { rest[x] = nil }
        }
    }

    // Inv of step 4, checked at every state.
    var invariant: Bool { zip(placed, placed.dropFirst()).allSatisfy { $0 <= $1 } }

    // The existential as a draw: any element of rest.
    func draw(_ tc: TestCase) throws -> Step {
        .insert(try tc.draw(Gen.element(of: Array(rest.keys))))
    }

    static func initial(_ input: [Int]) -> Model {
        Model(placed: [], rest: Dictionary(input.map { ($0, 1) }, uniquingKeysWith: +))
    }

    static func behaviour(_ input: [Int]) -> Gen<(steps: [Step], final: Model)> {
        Gen { tc in
            var m = initial(input)
            var steps: [Step] = []
            precondition(m.invariant)
            while !m.done {
                let s = try m.draw(tc)
                precondition(m.enabled(s))
                m.apply(s)
                precondition(m.invariant)            // Inv ∧ Next ⇒ Inv′, on this path
                steps.append(s)
            }
            return (steps, m)
        }
    }
}
```

The property, on drawn inputs and drawn picks:

```swift
let inputs = Gen.array(of: Gen.int(in: 0...4), count: 0...6)   // duplicates included on purpose

expectAll(inputs.flatMap { a in Model.behaviour(a).map { (a, $0) } }) { a, run in
    #expect(run.final.done)
    #expect(run.final.answer == a.sorted())      // Sorted ∧ permutation of the input
    #expect(run.steps.count == a.count)          // one step per element, no more
}
```

`a.sorted()` is the expected value, not part of the relation; the relation never calls a sort. Numbers I can give without running anything: for the drawn input, the four values are distinct, so a state is fixed by the set of placed values: 16 reachable states, 24 behaviours (one per order of picks), every one ending at `⟨0,1,2,3⟩` by Inv. For an input with duplicates, e.g. `[1,1,0]`, there are 6 states and 3 distinct behaviours as value-sequences. What the exhaustive run over `inputs` would report is unchecked.

## 6. The code, instrumented, and the refinement

The given code, recorded once per outer pass, which is the granularity of step 3:

```swift
func fungSort(_ input: [Int], record: ([Int]) -> Void) -> [Int] {
    var A = input
    let n = A.count
    record(A)                                          // state before pass 1
    for i in 0..<n {
        for j in 0..<n where A[i] < A[j] { A.swapAt(i, j) }
        record(A)                                      // one state per pass
    }
    return A
}
```

The code's state after pass `i` is `(A, i)`. The refinement mapping to the relation's record is the bar of step 1:

```swift
func project(_ A: [Int], passes i: Int) -> Model {
    Model(placed: Array(A[..<i]),
          rest: Dictionary(A[i...].map { ($0, 1) }, uniquingKeysWith: +))
}
```

Replay: the step between two consecutive projected states is the element that entered `placed`; there must be exactly one, it must be enabled, and applying it must give exactly the next recorded state.

```swift
extension Model {
    /// The one element in `to` and not in `from`, as bags; nil if not exactly one entered
    /// and nothing left.
    static func entered(_ from: [Int], _ to: [Int]) -> Int? {
        var diff = Dictionary(to.map { ($0, 1) }, uniquingKeysWith: +)
        for v in from { diff[v, default: 0] -= 1 }
        let nonzero = diff.filter { $0.value != 0 }
        guard nonzero.count == 1, let (x, k) = nonzero.first, k == 1 else { return nil }
        return x
    }

    /// (index of the first pair that is not a Next step, or nil; the state reached).
    static func refines(_ states: [Model], from input: [Int]) -> (violation: Int?, final: Model) {
        var m = initial(input)
        guard states.first == m else { return (0, m) }
        for (k, next) in states.dropFirst().enumerated() {
            guard let x = entered(m.placed, next.placed), m.enabled(.insert(x)) else { return (k, m) }
            m.apply(.insert(x))
            guard m == next else { return (k, m) }
        }
        return (nil, m)
    }
}

expectAll(inputs) { a in
    var recorded: [[Int]] = []
    _ = fungSort(a) { recorded.append($0) }
    let states = recorded.enumerated().map { project($0.element, passes: $0.offset) }
    let (violation, final) = Model.refines(states, from: a)
    #expect(violation == nil)
    #expect(final.done)
}
```

Unchecked by machine. Replayed by hand on three inputs:

`[2, 0, 3, 1]` (the drawn run). Pairs: `(⟨⟩,{2,0,3,1}) → (⟨3⟩,{0,2,1})` is `insert 3`, 3 is in rest, `Inserts(3, ⟨⟩) = {⟨3⟩}`. `→ (⟨0,3⟩,{2,1})` is `insert 0`. `→ (⟨0,2,3⟩,{1})` is `insert 2`. `→ (⟨0,1,2,3⟩,{})` is `insert 1`. Four steps, final done. No violation.

`[1, 1, 0]` (duplicates, the maximum already in front). Code: pass 1 `[1,1,0]` (no swap: `1<1` and `1<0` false), pass 2 `[1,1,0]`, pass 3 `[0,1,1]`. Projected: `(⟨⟩,{1,1,0}) → (⟨1⟩,{1,0}) → (⟨1,1⟩,{0}) → (⟨0,1,1⟩,{})`: `insert 1`, `insert 1`, `insert 0`. No violation.

`[3, 1, 3, 2]` (duplicate maximum). Code: pass 1 `[3,1,3,2]`, pass 2 `[1,3,3,2]`, pass 3 `[1,3,3,2]`, pass 4 `[1,2,3,3]`. Projected steps `insert 3`, `insert 1`, `insert 3`, `insert 2`; each `placed′` is the sorted arrangement of the previous `placed` with the element added, and `rest` loses exactly that element. No violation.

Result on these: the given code is a refinement of the relation, with the pick fixed as: the maximum in pass 1, then `A[i+1]` in every later pass. The relation did not have to be revised at this step; the one revision is the one recorded in step 4.

A second and a third refinement of the same relation:

- Insertion sort, `for i in 1...n: for j in 1...i: if A[i] < A[j]: swap`. Pass `i` is the pass-4 drawing of step 1 cut at `j = i`: the carry inserts `A[i]` into `A[1..i−1]`. Pick = `A[i]` in every pass, pass 1 included (`Inserts(A[1], ⟨⟩) = {⟨A[1]⟩}`).
- Selection sort. Pick = the minimum of `rest`; since every element of `placed` is then at most that minimum, `Inserts(min, placed) = {placed ⌢ ⟨min⟩}`, an append.

The three differ only in which `x` the existential is resolved to. The given code differs from insertion sort in one pick, the first.

## 7. Report

**The drawn behaviour.** `[2,0,3,1] → [3,0,2,1] → [0,3,2,1] → [0,2,3,1] → [0,1,2,3]`, one arrow per outer pass; the pass counter had to be written in; read as a sorted part and a bag of the rest: `(⟨⟩,{2,0,3,1}) → (⟨3⟩,{0,2,1}) → (⟨0,3⟩,{2,1}) → (⟨0,2,3⟩,{1}) → (⟨0,1,2,3⟩,{})`.

**The variables.** `placed ∈ Seq(ℤ)`, `rest ∈ Bag(ℤ)`.

**A step.** One pass of the outer loop.

**Init and Next.** `placed = ⟨⟩ ∧ rest = bag(A₀)`; `rest ≠ ∅ ∧ pick any x ∈ rest: placed′ ∈ Inserts(x, placed) ∧ rest′ = rest ⊖ {x}`. Invariant `Sorted(placed) ∧ bag(placed) ⊎ rest = bag(A₀)`, preserved by every step whatever `x` is; `n` steps to `rest = ∅`, where the invariant says `placed` is a sorted permutation of the input. That is the reason the code sorts: it is a behaviour of this relation.

**The checks and their numbers.** Step 5 property: unchecked; by hand for the drawn input, 16 states, 24 behaviours, all ending sorted, which is what Inv says. Step 6 refinement: unchecked by machine; by hand on `[2,0,3,1]`, `[1,1,0]`, `[3,1,3,2]`, 11 consecutive pairs, all Next steps, all three runs ending done. One revision, before code, recorded in step 4: the pick weakened from "head of rest" to "any element of rest".

**The code and the refinement result.** The code refines the relation with the pick resolved as: the maximum first, then the elements in their array order. Insertion sort and selection sort refine the same relation with other picks.

**What the relation does not say.** The relation never mentions the maximum, and the checker's silence would not tell anyone why a pass of this inner loop is an insertion. That argument is the finer behaviour of step 1, and it is where the algorithm actually lives:

1. In pass `i+1` with `placed = A[1..i]` sorted and carry `c = A[i+1]`, the iterations `j = 1..i` keep `A[1..i]` sorted, keep `bag(A[1..i]) ⊎ {c} = bag(placed) ⊎ {x}`, and keep `c ≥ A[1..j]`: a swap at `j` puts `c` where `A[j−1] ≤ c < A[j] ≤ A[j+1]` and picks up the larger `A[j]`. After `j = i`, `A[1..i+1]` is the sorted arrangement of `placed ⌢ ⟨x⟩`, so `A[1..i+1] ∈ Inserts(x, placed)`.
2. `j = i+1` does nothing (`A[i+1] < A[i+1]` is false).
3. `j = i+2..n` does nothing only because `c` is now the maximum of the whole array, and it is that only because pass 1 put the maximum into `placed` and an insertion never removes anything from `placed`. Without that, the second half of the inner loop would drag larger elements in from the right and evict one from the prefix, and the pass would not be an `Inserts` step.
4. Pass 1 itself: the carry only grows and takes every larger value it meets, so it ends as the maximum; the elements it displaced land in the suffix, in an order the relation does not fix and the drawing did not need.

So the relation says "each pass inserts some remaining element into the sorted prefix". Points 3 and 4 are the reason the given code's passes are such insertions, and they are not in the relation; they are in the refinement proof, which refinement checking on drawn inputs samples and does not prove.

Two more things the relation does not cover. The relation fixes nothing about the suffix's order, so it says nothing about the code's `A[i+2..n]` being untouched; that is a fact about this refinement, visible in the drawing and not needed for the result. And the relation is a sufficient account of this code, not the only one. The variant that skips pass 1 (`for i in 2...n`, same inner loop) also sorts: on `[2,0,3,1]` it goes `[2,0,3,1] → [0,3,2,1] → [0,2,3,1] → [0,1,2,3]`, and its first pair, `placed ⟨2⟩ → ⟨0,3⟩`, evicts an element and is not a Next step of this relation, so `refines` reports a violation at pair 0 on a run whose output is correct. That variant is a behaviour of a weaker relation, `placed′ ∈ Perm(placed ⌢ rest) restricted so that Sorted(placed′) ∧ last(placed′) = max(A₀)`, which is also the invariant one would write directly for the given code (`A[1..i]` sorted and `A[i]` the maximum). I kept the insertion relation because it is what the drawing showed, its correctness argument does not depend on the maximum at all, and it names the given code as one pick among the picks of a family that includes insertion sort; the price is that it explains this code and not every code that sorts by the same inner loop.
