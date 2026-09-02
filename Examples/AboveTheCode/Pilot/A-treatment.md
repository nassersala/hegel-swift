# Non-recursive mergesort, above the code

Nothing here was run. Hegel is not available in this exercise; every check below is written as I would write it and marked unchecked. The `Gen`, `TestCase` and `expectAll` spellings follow the shape given in the method and may need adjusting to Hegel's actual signatures. The hand traces are hand traces.

## 1. One behaviour, drawn

Input: four integers, `⟨3, 1, 2, 0⟩`.

First attempt, array only:

```
⟨3, 1, 2, 0⟩ ─merge 0..0 with 1..1─▶ ⟨1, 3, 2, 0⟩ ─merge 2..2 with 3..3─▶ ⟨1, 3, 0, 2⟩ ─merge 0..1 with 2..3─▶ ⟨0, 1, 2, 3⟩
```

To write the third arrow I had to remember that `0..1` and `2..3` were the sorted pieces; nothing in the row `⟨1, 3, 0, 2⟩` says so. `⟨1, 3, 0, 2⟩` looks like any other unsorted array. A variable is missing: the set of ranges that are already sorted runs. Written in:

```
[A: ⟨3, 1, 2, 0⟩, R: {0..0, 1..1, 2..2, 3..3}]
   ─merge 0..0 with 1..1─▶ [A: ⟨1, 3, 2, 0⟩, R: {0..1, 2..2, 3..3}]
   ─merge 2..2 with 3..3─▶ [A: ⟨1, 3, 0, 2⟩, R: {0..1, 2..3}]
   ─merge 0..1 with 2..3─▶ [A: ⟨0, 1, 2, 3⟩, R: {0..3}]
```

Now each row follows from the previous row and the arrow alone: the arrow names two adjacent members of `R`, the next `A` is the previous `A` with that stretch sorted, the next `R` has the two members replaced by their union.

A step has no inside. What a merge does element by element is a finer behaviour; I am not drawing it and am not using it.

Where the drawing did not care: after the first row, the arrow could have been `merge 2..2 with 3..3` or `merge 0..0 with 1..1`, and after the second row it could have been `merge 0..1 with 2..2` instead of `2..2 with 3..3`. I picked left to right and pairs of equal width because that is the drawing I had in my head, but nothing in the rows required it. Any two adjacent runs will do. That is the "pick any" of Next, and it is what will make the recursive and the non-recursive code two refinements of the same relation.

## 2. The variables

Read off the record:

- `A`, the array: a function `0..N−1 → Int`.
- `R`, the runs: a set of pairs `⟨b, t⟩` with `0 ≤ b ≤ t ≤ N−1`.

```
TypeOK:  A ∈ [0..N−1 → Int]  ∧  R ⊆ { ⟨b, t⟩ ∈ (0..N−1) × (0..N−1) : b ≤ t }
```

`R` is the variable that was above the drawing. It plays the part `U` plays in quicksort, with the direction reversed: `U` is the set of ranges still to be split and shrinks toward empty; `R` is the set of ranges already sorted and shrinks toward one.

There is no `width` and no loop index. Those will belong to one particular program, not to the relation.

## 3. What one step is

A step is one merge of two adjacent runs. The code in step 6 is recorded once per merge, after the merge has finished; the split in a recursive mergesort leaves no row, because it changes neither `A` nor `R`.

## 4. Init and Next

```
Init:  A = any array of integers of length N
     ∧ R = { ⟨i, i⟩ : i ∈ 0..N−1 }

Next:  pick any ⟨b, m⟩ ∈ R and ⟨m+1, t⟩ ∈ R:
           A′ ∈ Merged(A, b, t)
         ∧ R′ = (R \ {⟨b, m⟩, ⟨m+1, t⟩}) ∪ {⟨b, t⟩}

Merged(A, b, t) = { B ∈ [0..N−1 → Int] :
                      ∀ i ∉ b..t : B[i] = A[i]
                    ∧ B restricted to b..t is a permutation of A restricted to b..t
                    ∧ ∀ i ∈ b..t−1 : B[i] ≤ B[i+1] }

Done:  |R| ≤ 1
```

Notes on the relation.

- There is one step kind. The "pick any" over the pair of runs is the only existential with more than one witness: for integers, `Merged(A, b, t)` has exactly one element, the sorted rearrangement of the stretch. It is still written as a set, because that is what a merge is required to produce, not how.
- `Merged` does not ask that the two halves be sorted beforehand. It asks that the result be sorted. That the halves are sorted is an invariant, below, not a precondition of the relation.
- `Next` is enabled exactly when `|R| ≥ 2`: `R` partitions `0..N−1` into intervals, so if it has two members it has two adjacent members. Every step removes one member. Every behaviour therefore has exactly `max(N−1, 0)` steps and ends `Done`. That is the termination argument; it is about `R`, not about any loop.
- The invariant I expect TLC to confirm for small `N`:

```
Inv:  R partitions 0..N−1 into intervals
    ∧ ∀ ⟨b, t⟩ ∈ R : ∀ i ∈ b..t−1 : A[i] ≤ A[i+1]
    ∧ A is a permutation of the initial A
```

`Init ⇒ Inv` because singletons are sorted. `Inv ∧ Next ⇒ Inv′` because a merge replaces two adjacent intervals with their union, the union is sorted by the third clause of `Merged`, and the multiset is kept by the second. `Inv ∧ Done ⇒ A sorted`, since then `R = {⟨0, N−1⟩}` (or `N = 0`).

- How many behaviours the relation has per input: with `k` runs there are `k−1` adjacent pairs, so the number of distinct step sequences is `(N−1) · (N−2) · … · 1 = (N−1)!`. The drawing is one of the 6 for `N = 4`. Each program in step 6 is one of them.

## 5. The relation as a Swift value, and its own check

The record, `enabled`, `apply`, the draw, and the behaviour generator. No algorithm yet: `apply` takes the one element of `Merged` by sorting the stretch, which is the set's definition, not a merge.

```swift
struct Run: Hashable {
    let b: Int
    let t: Int
}

/// The arrow word: merge ⟨b, m⟩ with ⟨m+1, t⟩.
struct MergeStep: Equatable {
    let b: Int
    let m: Int
    let t: Int
}

struct MergeModel {
    var a: [Int]          // A
    var runs: Set<Run>    // R

    /// Init.
    init(_ input: [Int]) {
        a = input
        runs = Set(input.indices.map { Run(b: $0, t: $0) })
    }

    var done: Bool { runs.count <= 1 }

    /// Next(self, step): both named runs are in R. Adjacency is in the step's shape.
    func enabled(_ s: MergeStep) -> Bool {
        runs.contains(Run(b: s.b, t: s.m)) && runs.contains(Run(b: s.m + 1, t: s.t))
    }

    /// Membership in Merged(A, b, t), the set from step 4, as a predicate on (A, A′).
    static func inMerged(_ before: [Int], _ after: [Int], b: Int, t: Int) -> Bool {
        before.count == after.count
            && before.indices.allSatisfy { i in (b...t).contains(i) || before[i] == after[i] }
            && after[b...t].sorted() == before[b...t].sorted()
            && zip(after[b...t], after[b...t].dropFirst()).allSatisfy { $0 <= $1 }
    }

    /// Precondition: enabled. A′ is the one element of Merged(A, b, t); R′ as in Next.
    mutating func apply(_ s: MergeStep) {
        precondition(enabled(s))
        a.replaceSubrange(s.b...s.t, with: a[s.b...s.t].sorted())
        runs.remove(Run(b: s.b, t: s.m))
        runs.remove(Run(b: s.m + 1, t: s.t))
        runs.insert(Run(b: s.b, t: s.t))
    }

    /// The witnesses of the "pick any": every adjacent pair in R.
    var candidates: [MergeStep] {
        let ordered = runs.sorted { $0.b < $1.b }
        return zip(ordered, ordered.dropFirst()).map { MergeStep(b: $0.b, m: $0.t, t: $1.t) }
    }

    func draw(_ tc: TestCase) throws -> MergeStep {
        try tc.draw(Gen.element(of: candidates))
    }

    /// Inv from step 4, minus the permutation clause, which the property checks against the input.
    var invariant: Bool {
        let ordered = runs.sorted { $0.b < $1.b }
        let partition = (ordered.first?.b ?? 0) == 0
            && (ordered.last?.t ?? -1) == a.count - 1
            && zip(ordered, ordered.dropFirst()).allSatisfy { $0.t + 1 == $1.b }
        let runsSorted = ordered.allSatisfy { r in
            zip(a[r.b...r.t], a[r.b...r.t].dropFirst()).allSatisfy { $0 <= $1 }
        }
        return partition && runsSorted
    }

    static func behaviour(_ input: [Int]) -> Gen<(steps: [MergeStep], final: MergeModel)> {
        Gen { tc in
            var m = MergeModel(input)
            var steps: [MergeStep] = []
            while !m.done {
                let s = try m.draw(tc)
                m.apply(s)
                steps.append(s)
            }
            return (steps, m)
        }
    }
}
```

The relation's own property on drawn inputs and drawn choices, what TLC would check for small `N`:

```swift
let inputs = Gen.array(of: Gen.int(in: -5...5), count: 0...8)

expectAll(inputs.flatMap { a in MergeModel.behaviour(a).map { (a, $0) } }) { a, run in
    var m = MergeModel(a)
    #expect(m.invariant)
    for s in run.steps {
        #expect(m.enabled(s))
        m.apply(s)
        #expect(m.invariant)
    }
    #expect(run.final.done)
    #expect(run.final.a == a.sorted())
    #expect(run.steps.count == max(a.count - 1, 0))
}
```

Unchecked. What I expect it to say, and why: the `a == a.sorted()` line is weak for integers, because `apply` sorts the stretch itself; the content of the check is in the other lines, that every drawn adjacent pair is enabled, that `R` stays a partition of sorted intervals through every choice of pair, that every behaviour ends with one run, and that every behaviour has exactly `N−1` steps. The draw over `candidates` covers all `(N−1)!` orders at each length as the number of test cases grows; at `N = 8` that is 5040 orders per input, so a run of a few hundred cases samples them rather than exhausts them.

## 6. The code, and whether it refines the relation

Now the non-recursive mergesort. Its own variables are `width` and `b`; they choose which pair of runs to merge next, and nothing else. It is instrumented to record `(step, A′)` once per merge, the granularity of step 3.

```swift
/// Bottom-up mergesort. Non-recursive: runs of width 1, 2, 4, … are merged left to right.
func mergeSort(_ a: inout [Int], record: (MergeStep, [Int]) -> Void = { _, _ in }) {
    let n = a.count
    var buffer = a
    var width = 1
    while width < n {
        var b = 0
        while b + width < n {                          // a right run exists
            let m = b + width - 1
            let t = min(b + 2 * width - 1, n - 1)
            merge(&a, into: &buffer, b, m, t)
            record(MergeStep(b: b, m: m, t: t), a)
            b += 2 * width
        }
        width *= 2
    }
}

/// Linear merge of a[b...m] and a[m+1...t], both sorted, back into a[b...t].
private func merge(_ a: inout [Int], into buf: inout [Int], _ b: Int, _ m: Int, _ t: Int) {
    var i = b, j = m + 1, k = b
    while i <= m && j <= t {
        if a[i] <= a[j] { buf[k] = a[i]; i += 1 } else { buf[k] = a[j]; j += 1 }
        k += 1
    }
    while i <= m { buf[k] = a[i]; i += 1; k += 1 }
    while j <= t { buf[k] = a[j]; j += 1; k += 1 }
    for x in b...t { a[x] = buf[x] }
}
```

The refinement check. Replay the recorded pairs against the relation from `Init`: each recorded step must be enabled in the model's `R`, and each recorded `A′` must be in `Merged(A, b, t)` for the model's `A`. The first pair that fails is the bug.

```swift
extension MergeModel {
    struct Violation: Equatable {
        let index: Int
        let step: MergeStep
        let reason: String
    }

    static func refines(_ recorded: [(step: MergeStep, state: [Int])], from input: [Int])
        -> (violation: Violation?, final: MergeModel)
    {
        var m = MergeModel(input)
        for (i, r) in recorded.enumerated() {
            guard m.enabled(r.step) else {
                return (Violation(index: i, step: r.step, reason: "a named run is not in R"), m)
            }
            guard inMerged(m.a, r.state, b: r.step.b, t: r.step.t) else {
                return (Violation(index: i, step: r.step, reason: "A′ ∉ Merged(A, b, t)"), m)
            }
            m.apply(r.step)      // Merged is a singleton for Int, so m.a == r.state here
        }
        return (nil, m)
    }
}

expectAll(inputs) { a in
    var sorted = a
    var recorded: [(step: MergeStep, state: [Int])] = []
    mergeSort(&sorted) { step, state in recorded.append((step, state)) }
    let (violation, final) = MergeModel.refines(recorded, from: a)
    #expect(violation == nil)
    #expect(final.done)
    #expect(final.a == sorted)
}
```

Unchecked. By hand, on the drawn input `⟨3, 1, 2, 0⟩`, the code records `(0,0,1)`, `(2,2,3)`, `(0,1,3)`, which is the drawing. On `N = 5`, where the widths do not divide evenly, it records `(0,0,1)`, `(2,2,3)`, `(0,1,3)`, `(0,3,4)`; the run `⟨4,4⟩` is never merged at widths 1 and 2 and so is still in `R` when width 4 reaches it, which is why `b + width < n` and not `≤` is the loop test: a left run with no right run is not a step and must leave no row. `N = 6` gives `(0,0,1)`, `(2,2,3)`, `(4,4,5)`, `(0,1,3)`, `(0,3,5)`; `N = 7` gives `(0,0,1)`, `(2,2,3)`, `(4,4,5)`, `(0,1,3)`, `(4,5,6)`, `(0,3,6)`. Each is a sequence of enabled steps of the relation ending in one run.

What the check finds that the output does not. Take the off-by-one `let t = min(b + 2 * width, n - 1)`. On `⟨3, 1, 2, 0⟩` it records `(0,0,2)` first: the merge of `⟨3⟩` with `⟨1, 2⟩` gives `⟨1, 2, 3, 0⟩`, then `(2,2,3)` gives `⟨1, 2, 0, 3⟩`, then `(0,1,3)` gives `⟨0, 1, 2, 3⟩`. The output is correct. The refinement fails at index 0 with "a named run is not in R", because `⟨1, 2⟩ ∉ R` in `{⟨0,0⟩, ⟨1,1⟩, ⟨2,2⟩, ⟨3,3⟩}`. The same bug on `⟨3, 2, 1, 0⟩` merges `⟨3⟩` with the unsorted `⟨2, 1⟩` and ends at `⟨0, 2, 1, 3⟩`; the output check would find it on that input, the refinement check finds it on the first input, at the first step, with the reason.

One refinement named; a second. The recursive mergesort, recorded at the same granularity:

```swift
func mergeSortRecursive(_ a: inout [Int], record: (MergeStep, [Int]) -> Void = { _, _ in }) {
    var buffer = a
    func sort(_ b: Int, _ t: Int) {
        guard b < t else { return }
        let m = (b + t) / 2
        sort(b, m)
        sort(m + 1, t)
        merge(&a, into: &buffer, b, m, t)
        record(MergeStep(b: b, m: m, t: t), a)
    }
    if !a.isEmpty { sort(0, a.count - 1) }
}
```

Same `refines` call, unchecked. On `N = 4` it records the same three steps as the bottom-up code. On `N = 5` it records `(0,0,1)`, `(0,1,2)`, `(3,3,4)`, `(0,2,4)`, a different one of the 24 step sequences the relation allows; the bottom-up code's is `(0,0,1)`, `(2,2,3)`, `(0,1,3)`, `(0,3,4)`. Both are behaviours of the relation. The two programs differ only in which adjacent pair they pick, which is exactly the clause the drawing did not care about. The recursion was never the algorithm; it was one way to choose pairs, and the `width` loop is another.

A natural mergesort, which starts from the sorted runs already present in the input, is not a behaviour of this relation: `Init` fixes `R` to singletons. To admit it, `Init` would be weakened to "`R` is any partition of `0..N−1` into intervals each sorted in `A`". `Inv` already holds of that `Init`, so nothing else changes. I have not made that change, since no code here needs it; I record where it would go.

## 7. Report

**The drawn behaviour.** `⟨3, 1, 2, 0⟩` through three merges to `⟨0, 1, 2, 3⟩`, redrawn once the missing variable was found: each row is `[A, R]`, each arrow "merge one run with the adjacent one".

**The variables.** `A : 0..N−1 → Int`, the array; `R`, a set of index intervals, the runs already sorted. `R` is the variable above the drawing. No `width`, no index.

**A step.** One merge of two adjacent runs. Splits are not steps.

**Init and Next.** `Init`: `R` is the singletons. `Next`: pick any two adjacent members of `R`, replace the stretch by a sorted permutation of itself, replace the two members by their union. `Done`: `|R| ≤ 1`. `Merged` defined as a set. `Inv`: `R` partitions the indices into intervals, every run is sorted, `A` is a permutation of the input.

**The checks and their numbers.** All unchecked, Hegel not being available here. Derived by hand: every behaviour has exactly `max(N−1, 0)` steps; the relation has `(N−1)!` step sequences per input, 6 at `N = 4`, 5040 at `N = 8`; the property in step 5 draws over them. Hand-traced: the bottom-up code's recorded steps for `N = 4, 5, 6, 7` are enabled step sequences ending in one run; the off-by-one in `t` is rejected at index 0 on the drawn input while producing the correct output on it.

**The code and the refinement result.** `mergeSort`, bottom-up with `width` doubling, recorded once per merge; `MergeModel.refines` replays the records against `enabled` and `Merged`. Expected result on the property: no violation, `final.done`. Second refinement: `mergeSortRecursive`, the same steps in a different order. Unchecked.

**What the relation does not say.**

- It does not say the merge is linear. `Merged(A, b, t)` is satisfied by any procedure that sorts the stretch; a "merge" that called `sorted()` on `a[b...t]` would refine the relation and be O(N² log N). The refinement check on `A′` is by membership in a set defined with `sorted()`, so it is a specification, not a second implementation, but it says nothing about cost.
- It does not say the halves were sorted when the merge began. That is `Inv`, which the relation preserves and the code inherits by refining it; the checker inspects only consecutive pairs and would accept a code that produced the right `A′` from unsorted halves by luck.
- It does not say stability. For integers `Merged` is a singleton and stability cannot be stated. For records with keys, `Merged` would have several members and the relation as written would admit unstable merges; a stability clause would have to be added, and the two codes would then need re-checking against it.
- It does not say the code terminates on inputs the property did not draw. The relation terminates because `|R|` decreases; the code terminates because `width` doubles and `b` grows, and refinement on drawn runs shows only that on those runs the two agree. `N ≤ 8` in the generator; nothing here is said about `N = 9`.
- It does not say why `b + width < n` is the right loop test, or why `min(b + 2*width − 1, n − 1)` is the right `t`. Those were found by asking, at each recorded step, whether both named runs are in `R`; the relation reports which step is not a step, and I supplied the reason.
- The extra buffer, the in-place copy back, the choice of `(b + t) / 2` as the split: all the code's own, invisible to the relation.

Silence from the checker, had it run, would be silence on `N ≤ 8` with a few hundred draws over `(N−1)!` orders. It would not be a proof that the code is a behaviour of the relation, and it would say nothing at all about why it is one; that is the argument under `Inv` in step 4, which is a person's move.
