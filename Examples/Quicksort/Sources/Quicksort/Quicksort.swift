/// A concrete quicksort: Hoare partition, recursive. Each partition and
/// each one-element range is recorded as a `Lamport.Step`, so the run
/// can be checked as a behaviour of the relation.
///
/// Hoare's partition returns `p` in `b...t−1` with `a[b...p] ≤ a[p+1...t]`,
/// the pivot not in its final place; the subranges are `⟨b, p⟩` and
/// `⟨p+1, t⟩`, exactly the relation's. `Bug.excludePivot` recurses on
/// `⟨b, p−1⟩` and `⟨p+1, t⟩` instead — Lomuto's split applied to Hoare's
/// partition, a classic mix-up. It sorts wrongly, and before that it is
/// not a `Next` step.
public enum Bug: Sendable { case none, excludePivot }

public func quicksort(_ input: [Int], bug: Bug = .none) -> (sorted: [Int], steps: [Lamport.Step]) {
    var a = input
    var steps: [Lamport.Step] = []

    func partition(_ b: Int, _ t: Int) -> Int {
        let pivot = a[(b + t) / 2]
        var i = b - 1, j = t + 1
        while true {
            repeat { i += 1 } while a[i] < pivot
            repeat { j -= 1 } while a[j] > pivot
            if i >= j { return j }
            a.swapAt(i, j)
        }
    }

    func sort(_ b: Int, _ t: Int) {
        if b < t {
            let p = partition(b, t)
            steps.append(.partition(Lamport.Range(b, t), p: p, after: a))
            switch bug {
            case .none: sort(b, p)
            case .excludePivot: sort(b, p - 1)
            }
            sort(p + 1, t)
        } else {
            steps.append(.drop(Lamport.Range(b, t)))
        }
    }

    if !a.isEmpty { sort(0, a.count - 1) }
    return (a, steps)
}
