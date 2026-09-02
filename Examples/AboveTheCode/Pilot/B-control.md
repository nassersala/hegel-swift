# Why `if A[i] < A[j] { swap }` over all pairs sorts ascending

```swift
func sort(_ a: inout [Int]) {
    let n = a.count
    for i in 0..<n {
        for j in 0..<n {
            if a[i] < a[j] { a.swapAt(i, j) }
        }
    }
}
```

(0-based below; the argument is the same with 1-based indices.)

The comparison looks backwards. `a[i] < a[j]` with `j` running over the whole array, including `j < i`, reads like it should push large elements to the left. It does push a large element to the left, on the very first pass, and the rest of the algorithm is that element being carried one slot to the right per pass while the prefix behind it is kept sorted.

## The invariant

After outer iteration `i` (that is, after the inner loop has run for that `i`):

1. `a[0...i]` is sorted ascending, and
2. `a[i]` is the maximum of the whole array `a[0..<n]`.

When `i = n-1` the first clause says the whole array is sorted, which is the claim.

## Pass `i = 0`

`j` runs over every index. Whenever `a[0] < a[j]`, the two are swapped, so `a[0]` only ever grows and every element larger than it gets pulled into position 0. After the pass `a[0]` is the maximum of the array. A one-element prefix is sorted. The invariant holds.

## Pass `i ≥ 1`

Assume the invariant for `i-1`: `a[0..<i]` is sorted and `a[i-1]` is the global maximum. Write `x` for the value in `a[i]` at the start of the pass, and `p₀ ≤ p₁ ≤ … ≤ pᵢ₋₁` for the sorted prefix. Since `pᵢ₋₁` is the maximum, `x ≤ pᵢ₋₁`.

The inner loop splits into three parts.

**`j < i` — insert `x` into the sorted prefix and push the maximum out.**
Let `k` be the first index in `0..<i` with `pₖ > x`. (If there is none, `x = pᵢ₋₁` is itself a maximum; no swap fires for `j < i`, and `a[0...i]` is already sorted with `a[i]` maximal.)

- For `j < k`: `a[j] ≤ x`, so `a[i] < a[j]` is false. Nothing happens.
- At `j = k`: `x < pₖ`, swap. Now `a[k] = x` and `a[i] = pₖ`. The prefix `a[0...k]` is `p₀ … pₖ₋₁ x`, sorted because `pₖ₋₁ ≤ x`.
- At `j = k+1`: `a[i] = pₖ ≤ pₖ₊₁`. If strictly less, swap: `a[k+1] = pₖ`, `a[i] = pₖ₊₁`. If equal, no swap, but the array holds the same values either way. So after this step `a[0...k+1] = p₀ … pₖ₋₁ x pₖ` and `a[i] = pₖ₊₁`.
- The same happens at each subsequent `j`: the value in `a[i]` is always the `p` that was just displaced, it is at most `a[j]`, and it trades places with `a[j]`.

After `j = i-1` the prefix is `p₀ … pₖ₋₁ x pₖ … pᵢ₋₂`, which is sorted (`pₖ₋₁ ≤ x < pₖ`), and `a[i] = pᵢ₋₁`, the global maximum. This is exactly one step of insertion sort, with the maximum leaking one slot to the right instead of staying in the prefix.

**`j = i`.** `a[i] < a[i]` is false.

**`j > i` — nothing.** `a[i]` is the global maximum, so `a[i] < a[j]` is false for every `j`. These iterations are dead work; they matter only in pass 0, where they are what fetched the maximum into `a[0]`.

Both clauses of the invariant hold for `i`. By induction they hold for `i = n-1`, so the array is sorted.

## Watching it happen

```swift
var a = [3, 1, 4, 1, 5, 9, 2, 6]
let n = a.count
for i in 0..<n {
    for j in 0..<n where a[i] < a[j] { a.swapAt(i, j) }
    print(i, a)
}
```

```
0 [9, 1, 3, 1, 4, 5, 2, 6]
1 [1, 9, 3, 1, 4, 5, 2, 6]
2 [1, 3, 9, 1, 4, 5, 2, 6]
3 [1, 1, 3, 9, 4, 5, 2, 6]
4 [1, 1, 3, 4, 9, 5, 2, 6]
5 [1, 1, 3, 4, 5, 9, 2, 6]
6 [1, 1, 2, 3, 4, 5, 9, 6]
7 [1, 1, 2, 3, 4, 5, 6, 9]
```

Pass 0 fetches 9 to the front. Every later pass shows a sorted prefix ending in 9, one longer than before: the new element has been inserted and 9 has moved right by one.

## Checking the invariant mechanically

```swift
func sortChecked(_ a: inout [Int]) {
    let n = a.count
    let maxValue = a.max()
    for i in 0..<n {
        for j in 0..<n where a[i] < a[j] { a.swapAt(i, j) }
        precondition(zip(a[0...i], a[0...i].dropFirst()).allSatisfy { $0 <= $1 })
        precondition(a[i] == maxValue)
    }
}

for _ in 0..<10_000 {
    var a = (0..<Int.random(in: 0...12)).map { _ in Int.random(in: -5...5) }
    let expected = a.sorted()
    sortChecked(&a)
    precondition(a == expected)
}
```

Small value ranges force duplicates, which is where the `≤` versus `<` details in the argument are exercised.

## Notes

- The direction of the comparison is the whole story. `a[i] > a[j]` over the same index ranges does not sort; it is the `<` that makes pass 0 park the maximum at the left end, and the same `<` that then makes the maximum the element that steps right while everything else is inserted behind it.
- The outer loop must start at the first index. Starting at `i = 1` skips the pass that establishes the invariant.
- Every pass compares `n` pairs, so the running time is `n²` comparisons and at most `n²` swaps regardless of input, which is worse than insertion sort's `n²/2` comparisons and its linear best case. The algorithm is of interest for its shape, not its speed.
