/// Fung 2021, "Is this the simplest (and most surprising) sorting
/// algorithm ever?" (arXiv 2110.01111). Three algorithms from the paper,
/// 1-based there, 0-based here, each instrumented so that its run is a
/// behaviour: a sequence of states the relations in `Relations.swift`
/// can be checked against.

/// Algorithm 1: two full loops, swap when `A[i] < A[j]`. Looks wrong,
/// sorts ascending.
public func fung(_ a: [Int]) -> [Int] { fungPasses(a).last ?? a }

/// Algorithm 1 as a behaviour with one state per outer pass: the array
/// after pass `i`, for `i` in `0..<n`. Drawn by hand first, on `[1, 0, 2]`:
///
///     [1, 0, 2] ─pass 0─▶ [2, 0, 1] ─pass 1─▶ [0, 2, 1] ─pass 2─▶ [0, 1, 2]
///
/// The variables the drawing shows: a sorted prefix of length `i + 1`,
/// and the rest. The step: one element joins the prefix at its place.
/// And what pass 0 does to the rest, `[0, 2]` became `[0, 1]`: it is
/// permuted. That is the clause the relation has to allow.
public func fungPasses(_ a: [Int]) -> [[Int]] {
    var a = a
    var states: [[Int]] = []
    for i in a.indices {
        for j in a.indices where a[i] < a[j] { a.swapAt(i, j) }
        states.append(a)
    }
    return states
}

/// Algorithm 1 with one state per swap.
public func fungSwaps(_ a: [Int]) -> [[Int]] {
    var a = a
    var states: [[Int]] = []
    for i in a.indices {
        for j in a.indices where a[i] < a[j] {
            a.swapAt(i, j)
            states.append(a)
        }
    }
    return states
}

/// Algorithm 3, Fung's stripped insertion sort: `i` from the second
/// element, `j` over the prefix only. Recorded with the same one state
/// per pass as `fungPasses`, pass 0 a no-op, so the two behaviours line
/// up pass for pass.
public func insertionSortPasses(_ a: [Int]) -> [[Int]] {
    var a = a
    var states: [[Int]] = []
    for i in a.indices {
        for j in 0..<i where a[i] < a[j] { a.swapAt(i, j) }
        states.append(a)
    }
    return states
}

/// Algorithm 2, textbook exchange sort: `j` over the suffix, swap when
/// `A[i] > A[j]`. One state per swap.
public func exchangeSortSwaps(_ a: [Int]) -> [[Int]] {
    var a = a
    var states: [[Int]] = []
    for i in a.indices {
        for j in (i + 1)..<max(i + 1, a.count) where a[i] > a[j] {
            a.swapAt(i, j)
            states.append(a)
        }
    }
    return states
}

/// Fung's Algorithm 1 with pass 0 skipped, `i` from the second element,
/// `j` still over everything. It sorts (E2's `2…n, 1…n, <` cell). Recorded
/// like `fungPasses`, with the skipped pass 0 as a no-op row so the
/// behaviours line up.
public func fungWithoutPassZeroPasses(_ a: [Int]) -> [[Int]] {
    var a = a
    var states: [[Int]] = []
    for i in a.indices {
        if i > 0 { for j in a.indices where a[i] < a[j] { a.swapAt(i, j) } }
        states.append(a)
    }
    return states
}
