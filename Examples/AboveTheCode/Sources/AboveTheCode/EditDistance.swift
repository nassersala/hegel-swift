import Hegel
import os

/// Edit distance above the code. The behaviour drawn first, for a = "ab"
/// and b = "b", cells (i, j) with i ∈ 0..2 and j ∈ 0..1, in an order that
/// is neither the recursion's nor the table's:
///
///     [D: {}]
///      ─(0,0) ← 0─▶ [D: {(0,0): 0}]
///      ─(1,0) ← D(0,0)+1─▶ [D: {(0,0): 0, (1,0): 1}]
///      ─(0,1) ← D(0,0)+1─▶ [D: {(0,0): 0, (1,0): 1, (0,1): 1}]
///      ─(1,1) ← min(D(0,1)+1, D(1,0)+1, D(0,0)+[a≠b])─▶ [D: {…, (1,1): 1}]
///      ─(2,0) ← D(1,0)+1─▶ [D: {…, (2,0): 2}]
///      ─(2,1) ← min(D(1,1)+1, D(2,0)+1, D(1,0)+[b≠b])─▶ [D: {…, (2,1): 1}]   done
///
/// Each row follows from the arrow and the row before it, so D, the
/// partial function from cells to numbers, is the only variable. After the
/// second arrow both (2,0) and (0,1) had every predecessor known and the
/// drawing picked (0,1); that choice is the "pick any". The recursion, the
/// table and the wavefront are three ways of making it.
///
///     Pred(i, j) = {(i−1, j), (i, j−1), (i−1, j−1)} ∩ Cells
///     Value(D, (0, 0)) = 0
///     Value(D, (i, j)) = min of  {D(i−1, j) + 1 : i > 0}
///                              ∪ {D(i, j−1) + 1 : j > 0}
///                              ∪ {D(i−1, j−1) + [a_i ≠ b_j] : i > 0 ∧ j > 0}
///     Init:  D = {}
///     Next:  pick any c ∉ dom D with Pred(c) ⊆ dom D:  D′ = D ∪ {c ↦ Value(D, c)}
///     Done:  (m, n) ∈ dom D
///
/// A step is one cell computed from its known predecessors. The relation
/// says nothing about which cell; every topological order of the cell
/// graph is a behaviour. It does say, without a clause for it, that every
/// behaviour has exactly (m+1)(n+1) steps: every cell is a transitive
/// predecessor of (m, n), so Done is reached only when all are known.
public struct EditModel: Sendable, Equatable, CustomStringConvertible {
    public struct Cell: Hashable, Sendable, Comparable, CustomStringConvertible {
        public let i: Int, j: Int
        public init(_ i: Int, _ j: Int) { self.i = i; self.j = j }
        public var description: String { "(\(i),\(j))" }
        public static func < (x: Cell, y: Cell) -> Bool { (x.i, x.j) < (y.i, y.j) }
    }

    /// The arrow word: c ← v.
    public struct Step: Hashable, Sendable, CustomStringConvertible {
        public let cell: Cell
        public let value: Int
        public init(_ cell: Cell, _ value: Int) { self.cell = cell; self.value = value }
        public var description: String { "\(cell) ← \(value)" }
    }

    public let a: [Character]
    public let b: [Character]
    public private(set) var d: [Cell: Int]

    public init(_ a: String, _ b: String) {
        self.a = Array(a)
        self.b = Array(b)
        d = [:]
    }

    public var m: Int { a.count }
    public var n: Int { b.count }
    public var cellCount: Int { (m + 1) * (n + 1) }
    public var done: Bool { d[Cell(m, n)] != nil }
    public var answer: Int? { d[Cell(m, n)] }
    public var description: String {
        "a = \(String(a)), b = \(String(b)), D = \(d.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })"
    }

    public static func predecessors(of c: Cell) -> [Cell] {
        var p: [Cell] = []
        if c.i > 0 { p.append(Cell(c.i - 1, c.j)) }
        if c.j > 0 { p.append(Cell(c.i, c.j - 1)) }
        if c.i > 0 && c.j > 0 { p.append(Cell(c.i - 1, c.j - 1)) }
        return p
    }

    /// `Value` over whatever `known` answers for. With every predecessor
    /// known this is the relation's `Value(D, c)`; with fewer it is the min
    /// over the ones found, and 0 over none, which is what a program that
    /// reads a cell before it exists computes. The one recurrence, shared
    /// by the relation and every refinement.
    public static func value(of c: Cell, a: [Character], b: [Character], known: (Cell) -> Int?) -> Int {
        var options: [Int] = []
        if c.i > 0, let up = known(Cell(c.i - 1, c.j)) { options.append(up + 1) }
        if c.j > 0, let left = known(Cell(c.i, c.j - 1)) { options.append(left + 1) }
        if c.i > 0, c.j > 0, let diag = known(Cell(c.i - 1, c.j - 1)) {
            options.append(diag + (a[c.i - 1] == b[c.j - 1] ? 0 : 1))
        }
        return options.min() ?? 0
    }

    /// Precondition: `Pred(c) ⊆ dom D`.
    public func value(of c: Cell) -> Int {
        precondition(Self.predecessors(of: c).allSatisfy { d[$0] != nil }, "a predecessor of \(c) is not known")
        return Self.value(of: c, a: a, b: b) { d[$0] }
    }

    /// Next(self, step): the cell is new, its predecessors are known, and
    /// the value is the relation's.
    public func enabled(_ s: Step) -> Bool {
        d[s.cell] == nil && Self.predecessors(of: s.cell).allSatisfy { d[$0] != nil } && s.value == value(of: s.cell)
    }

    public mutating func apply(_ s: Step) {
        precondition(enabled(s), "not a Next step: \(s) from \(self)")
        d[s.cell] = s.value
    }

    /// The witnesses of the "pick any": every unknown cell whose
    /// predecessors are all known.
    public var frontier: [Cell] {
        var cells: [Cell] = []
        for i in 0...m {
            for j in 0...n {
                let c = Cell(i, j)
                if d[c] == nil && Self.predecessors(of: c).allSatisfy({ d[$0] != nil }) { cells.append(c) }
            }
        }
        return cells
    }

    public func draw(_ tc: TestCase) throws -> Step {
        let c = try tc.draw(.element(of: frontier))
        return Step(c, value(of: c))
    }

    /// Inv: dom D is closed under predecessors and every known cell carries
    /// `Value` of its predecessors.
    public var invariant: Bool {
        d.allSatisfy { c, v in
            Self.predecessors(of: c).allSatisfy { d[$0] != nil } && v == value(of: c)
        }
    }

    public static func behaviour(_ a: String, _ b: String) -> Gen<(steps: [Step], final: EditModel)> {
        Gen { tc in
            var s = EditModel(a, b)
            var steps: [Step] = []
            while !s.done {
                let step = try s.draw(tc)
                s.apply(step)
                steps.append(step)
            }
            return (steps, s)
        }
    }

    public struct Violation: Equatable, CustomStringConvertible {
        public let index: Int
        public let step: Step
        public let reason: String
        public var description: String { "step \(index) (\(step)): \(reason)" }
    }

    /// Replays recorded steps: each cell new, each predecessor known where
    /// the step fires, each value the relation's. The first pair that is
    /// not a step is the bug.
    public static func refines(_ recorded: [Step], from a: String, _ b: String) -> (violation: Violation?, final: EditModel) {
        var s = EditModel(a, b)
        for (i, step) in recorded.enumerated() {
            guard s.d[step.cell] == nil else {
                return (Violation(index: i, step: step, reason: "cell already known"), s)
            }
            if let missing = predecessors(of: step.cell).first(where: { s.d[$0] == nil }) {
                return (Violation(index: i, step: step, reason: "predecessor \(missing) not known"), s)
            }
            let expected = s.value(of: step.cell)
            guard step.value == expected else {
                return (Violation(index: i, step: step, reason: "value ≠ Value(D, c) = \(expected)"), s)
            }
            s.apply(step)
        }
        return (nil, s)
    }
}

// MARK: - The reference

/// Edit distance by its meaning, not by the recurrence: the length of the
/// shortest sequence of single-character insertions, deletions and
/// substitutions that turns `a` into `b`, found by breadth-first search
/// over strings. An optimal script inserts or substitutes only characters
/// of `b`, so that is the alphabet. Fine for the lengths the tests draw.
public func editDistanceBySearch(_ a: String, _ b: String) -> Int {
    let target = Array(b)
    let alphabet = Array(Set(target))
    var frontier: Set<[Character]> = [Array(a)]
    var seen = frontier
    var depth = 0
    while !frontier.contains(target) {
        var next = Set<[Character]>()
        for s in frontier {
            for t in edits(of: s, alphabet: alphabet) where !seen.contains(t) {
                seen.insert(t)
                next.insert(t)
            }
        }
        frontier = next
        depth += 1
    }
    return depth
}

private func edits(of s: [Character], alphabet: [Character]) -> [[Character]] {
    var out: [[Character]] = []
    for i in s.indices {
        var t = s
        t.remove(at: i)
        out.append(t)
        for x in alphabet where x != s[i] {
            var u = s
            u[i] = x
            out.append(u)
        }
    }
    for i in 0...s.count {
        for x in alphabet {
            var t = s
            t.insert(x, at: i)
            out.append(t)
        }
    }
    return out
}

// MARK: - Refinement 1: the memoized recursion

/// The memo is D. A cell is recorded when it is stored, after its three
/// predecessors, so the recorded order is the recursion's post-order. In
/// the written call order, up then left then diagonal, that post-order is
/// row-major, the table's trace exactly. Calling the diagonal first, then
/// up, then left, records the drawn behaviour's order on the drawn input:
/// (0,0), (1,0), (0,1), (1,1), (2,0), (2,1).
public func editDistanceMemoized(_ a: String, _ b: String, record: (EditModel.Step) -> Void = { _ in }) -> Int {
    let a = Array(a), b = Array(b)
    var memo: [EditModel.Cell: Int] = [:]
    func d(_ i: Int, _ j: Int) -> Int {
        let c = EditModel.Cell(i, j)
        if let v = memo[c] { return v }
        if i > 0 { _ = d(i - 1, j) }
        if j > 0 { _ = d(i, j - 1) }
        if i > 0 && j > 0 { _ = d(i - 1, j - 1) }
        let v = EditModel.value(of: c, a: a, b: b) { memo[$0] }
        memo[c] = v
        record(EditModel.Step(c, v))
        return v
    }
    return d(a.count, b.count)
}

// MARK: - Refinement 2: the bottom-up table

/// Row-major. The border is written in closed form, `i` and `j`, which is
/// what `Value` gives from the cell before it; the refinement check
/// compares the value, not the expression.
public func editDistanceTable(_ a: String, _ b: String, record: (EditModel.Step) -> Void = { _ in }) -> Int {
    let a = Array(a), b = Array(b)
    let m = a.count, n = b.count
    var t = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
    for i in 0...m {
        for j in 0...n {
            let v: Int
            if i == 0 {
                v = j
            } else if j == 0 {
                v = i
            } else {
                v = min(t[i - 1][j] + 1, t[i][j - 1] + 1, t[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            t[i][j] = v
            record(EditModel.Step(EditModel.Cell(i, j), v))
        }
    }
    return t[m][n]
}

// MARK: - Refinement 3: a task per cell

/// Which predecessors a cell's task waits for before it reads. The
/// relation's guard is `Pred(c) ⊆ dom D`; a task that waits for fewer
/// cells assumes the rest from the schedule it has seen.
///
/// - `all`: wait for all three. The guard, checked.
/// - `orthogonal`: wait for the cell above and the cell to the left, read
///   the diagonal. The relation says this is enough: the diagonal is a
///   predecessor of both, so it is known once they are.
/// - `upOnly`: wait for the cell above, read the other two. The belief
///   that the cell to the left "is on my row, so it is done" is true of
///   the row-major order and of no other; a task per cell has no row.
public enum CellWaits: Sendable {
    case all, orthogonal, upOnly

    func waited(of c: EditModel.Cell) -> [EditModel.Cell] {
        switch self {
        case .all: return EditModel.predecessors(of: c)
        case .orthogonal: return EditModel.predecessors(of: c).filter { $0.i == c.i || $0.j == c.j }
        case .upOnly: return c.i > 0 ? [EditModel.Cell(c.i - 1, c.j)] : []
        }
    }
}

/// D as shared state: write-once cells, a step recorded per write in
/// write order, and waiters resumed by the write they wait for. The check
/// and the registration happen under one lock, so a cell written between
/// them is seen; the two-phase commit and token refresh examples found
/// the lost wakeup when they were not.
public final class CellStore: @unchecked Sendable {
    private struct State {
        var cells: [EditModel.Cell: Int] = [:]
        var steps: [EditModel.Step] = []
        var waiters: [EditModel.Cell: [CheckedContinuation<Int, Never>]] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func value(of c: EditModel.Cell) -> Int? { state.withLock { $0.cells[c] } }
    public var steps: [EditModel.Step] { state.withLock { $0.steps } }

    public func wait(for c: EditModel.Cell) async -> Int {
        if let v = value(of: c) { return v }
        return await withCheckedContinuation { k in
            let known: Int? = state.withLock { s in
                if let v = s.cells[c] { return v }
                s.waiters[c, default: []].append(k)
                return nil
            }
            if let known { k.resume(returning: known) }
        }
    }

    public func set(_ c: EditModel.Cell, _ v: Int) {
        let waiters: [CheckedContinuation<Int, Never>] = state.withLock { s in
            precondition(s.cells[c] == nil, "cell \(c) written twice")
            s.cells[c] = v
            s.steps.append(EditModel.Step(c, v))
            return s.waiters.removeValue(forKey: c) ?? []
        }
        for w in waiters { w.resume(returning: v) }
    }
}

/// One child task per cell in a task group. Each waits for the
/// predecessors its `waits` names, reads the rest from the store, computes
/// `Value` over what it found, and writes. `hop` is an optional suspension
/// between the read and the write, the classic split of one step; the
/// tests show it is harmless here, because D only grows. Cells are added
/// last first so that the controlled scheduler's depth-first default,
/// which runs the newest job, visits them in row-major order; the test
/// that draws schedules is what leaves that order.
public func parallelEditDistance(
    _ a: String, _ b: String, waits: CellWaits = .all, hop: (@Sendable () async -> Void)? = nil
) async -> (distance: Int, steps: [EditModel.Step]) {
    let chars = (Array(a), Array(b))
    let m = chars.0.count, n = chars.1.count
    let store = CellStore()
    await withTaskGroup(of: Void.self) { group in
        for i in (0...m).reversed() {
            for j in (0...n).reversed() {
                let c = EditModel.Cell(i, j)
                group.addTask {
                    var known: [EditModel.Cell: Int] = [:]
                    for p in waits.waited(of: c) { known[p] = await store.wait(for: p) }
                    for p in EditModel.predecessors(of: c) where known[p] == nil { known[p] = store.value(of: p) }
                    let v = EditModel.value(of: c, a: chars.0, b: chars.1) { known[$0] }
                    if let hop { await hop() }
                    store.set(c, v)
                }
            }
        }
    }
    return (store.value(of: EditModel.Cell(m, n))!, store.steps)
}
