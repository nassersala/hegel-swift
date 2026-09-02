# Non-recursive mergesort in Swift

## The code

```swift
/// Stable bottom-up mergesort. O(n log n) time, O(n) extra space.
func mergeSort(_ input: [Int]) -> [Int] {
    let n = input.count
    if n < 2 { return input }

    var src = input   // runs of length `width` are sorted here
    var dst = input   // merged runs of length `2 * width` are written here
    var width = 1

    while width < n {
        var lo = 0
        while lo < n {
            let mid = min(lo + width, n)       // end of left run
            let hi  = min(lo + 2 * width, n)   // end of right run
            var i = lo, j = mid, k = lo
            while i < mid && j < hi {
                if src[j] < src[i] {           // strict: left wins ties, so the sort is stable
                    dst[k] = src[j]; j += 1
                } else {
                    dst[k] = src[i]; i += 1
                }
                k += 1
            }
            while i < mid { dst[k] = src[i]; i += 1; k += 1 }
            while j < hi  { dst[k] = src[j]; j += 1; k += 1 }
            lo = hi
        }
        swap(&src, &dst)   // O(1): exchanges the two buffers, no element is copied
        width *= 2
    }
    return src
}
```

A quick check:

```swift
let xs = [5, 3, 9, 1, 1, 8, 2, 7, 0, 6, 4]
print(mergeSort(xs))                       // [0, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9]
print(mergeSort([]), mergeSort([42]))      // [] [42]
print(mergeSort([3, 2, 1]) == [1, 2, 3])   // true
```

## How I arrived at it

The usual mergesort is recursive:

```swift
func mergeSortRecursive(_ a: [Int]) -> [Int] {
    if a.count < 2 { return a }
    let mid = a.count / 2
    return merge(mergeSortRecursive(Array(a[..<mid])),
                 mergeSortRecursive(Array(a[mid...])))
}
```

Two ways exist to remove the recursion. The first is mechanical: replace the call stack with an explicit stack of `(lo, hi)` ranges and simulate the post-order traversal. That works but keeps all the bookkeeping of the recursive version and adds a stack structure on top.

The second way comes from asking what the recursion actually contributes. Look at the recursion tree: the leaves are single elements, which are trivially sorted; level 1 merges pairs of elements into runs of 2; level 2 merges pairs of those into runs of 4; and so on. The recursion only serves to reach the leaves and then merge upward level by level. But the merges at one level do not depend on the order in which the merges at the level below happened, only on all of them being done. So the levels can be processed directly as passes over the array, with no recursion and no stack.

That gives the loop structure:

- Outer loop: `width = 1, 2, 4, ...` while `width < n`. This is the level of the tree.
- Inner loop: walk the array in blocks of `2 * width`; each block is a left run `[lo, mid)` and a right run `[mid, hi)`, both already sorted, and gets merged.

The invariant that makes it correct: after the pass for a given `width`, every block `[k * 2 * width, min((k + 1) * 2 * width, n))` is sorted. It holds before the first pass with `width = 1` because every one-element block is sorted; each pass preserves it by merging two adjacent sorted blocks into one; and the loop stops once a single block covers the whole array.

Three details had to be decided:

1. **Ragged ends.** `n` is not a power of two, so the last block may be short, or may have a left run and no right run at all. Clamping `mid` and `hi` with `min(_, n)` handles both: if `mid == hi` the right run is empty, the merge loop does nothing, and the copy loop moves the left run across unchanged. No special case is needed.

2. **Where the merged output goes.** Merging in place is awkward; the standard answer is a second buffer. Rather than copy the result back after each pass, the two buffers swap roles. `swap` on two Swift arrays exchanges their storage references, so it is constant time. Because the number of passes is `ceil(log2 n)`, the final result may be in either buffer, which is why the function returns `src` (the swap leaves the freshly written buffer in `src`) rather than the original variable.

3. **Stability.** Taking from the right run only when its element is strictly smaller means equal elements keep their left-to-right order. This matters little for `[Int]` but it is the property that makes mergesort worth choosing over quicksort, so the comparison is written that way on purpose.

Cost: each pass touches every element once, and there are `ceil(log2 n)` passes, so O(n log n) time, with O(n) extra space for the second buffer. The same code generalizes to `[T] where T: Comparable` by changing the signature; nothing in the body depends on `Int`.
