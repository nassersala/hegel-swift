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
            steps.append(.partition(Lamport.Range(b, t), p: p, after: Array(a[b...t])))
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

/// The non-recursive quicksort Lamport says almost no one can write in ten
/// minutes: `U` as a worklist. `pick` decides which range to take; the
/// default takes the last (depth-first, the recursive order), and a
/// drawn `pick` takes any, so the worklist reaches behaviours the
/// recursion never does. Same relation either way.
public func worklistQuicksort(
    _ input: [Int],
    pick: (_ ranges: [Lamport.Range]) throws -> Int = { $0.count - 1 }
) rethrows -> (sorted: [Int], steps: [Lamport.Step]) {
    var a = input
    var steps: [Lamport.Step] = []
    var u: [Lamport.Range] = a.isEmpty ? [] : [Lamport.Range(0, a.count - 1)]

    while !u.isEmpty {
        let r = u.remove(at: try pick(u))
        if r.b == r.t {
            steps.append(.drop(r))
            continue
        }
        let pivot = a[(r.b + r.t) / 2]
        var i = r.b - 1, j = r.t + 1
        let p: Int
        while true {
            repeat { i += 1 } while a[i] < pivot
            repeat { j -= 1 } while a[j] > pivot
            if i >= j { p = j; break }
            a.swapAt(i, j)
        }
        steps.append(.partition(r, p: p, after: Array(a[r.b...r.t])))
        u.append(Lamport.Range(p + 1, r.t))
        u.append(Lamport.Range(r.b, p))  // last, so the depth-first pick takes the left child first, as the recursion does
    }
    return (a, steps)
}
