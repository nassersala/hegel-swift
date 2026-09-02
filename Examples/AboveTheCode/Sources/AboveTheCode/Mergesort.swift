import Hegel

/// The pilot's treatment answer for problem A (see
/// `specs/algorithm-search-experiments.md`, E4), ported with the names
/// kept so the port can be read against the answer. The agent, made to
/// draw first, redrew its behaviour once it could not write the third
/// arrow from the row alone, and read off `R`, the set of runs already
/// sorted:
///
///     [A: ⟨3, 1, 2, 0⟩, R: {0..0, 1..1, 2..2, 3..3}]
///        ─merge 0..0 with 1..1─▶ [A: ⟨1, 3, 2, 0⟩, R: {0..1, 2..2, 3..3}]
///        ─merge 2..2 with 3..3─▶ [A: ⟨1, 3, 0, 2⟩, R: {0..1, 2..3}]
///        ─merge 0..1 with 2..3─▶ [A: ⟨0, 1, 2, 3⟩, R: {0..3}]
///
///     Init:  A = any array of integers of length N ∧ R = {⟨i, i⟩ : i ∈ 0..N−1}
///     Next:  pick any ⟨b, m⟩ ∈ R and ⟨m+1, t⟩ ∈ R:
///                A′ ∈ Merged(A, b, t)
///              ∧ R′ = (R \ {⟨b, m⟩, ⟨m+1, t⟩}) ∪ {⟨b, t⟩}
///     Done:  |R| ≤ 1
///
/// `U` shrinks toward empty; `R` shrinks toward one. No `width`, no index:
/// those belong to one program, not to the relation.
public struct MergeModel: Sendable, Equatable, CustomStringConvertible {
    public struct Run: Hashable, Sendable {
        public let b: Int, t: Int
        public init(b: Int, t: Int) { self.b = b; self.t = t }
    }

    /// The arrow word: merge ⟨b, m⟩ with ⟨m+1, t⟩.
    public struct MergeStep: Hashable, Sendable, CustomStringConvertible {
        public let b: Int, m: Int, t: Int
        public init(b: Int, m: Int, t: Int) { self.b = b; self.m = m; self.t = t }
        public var description: String { "merge \(b)..\(m) with \(m + 1)..\(t)" }
    }

    public private(set) var a: [Int]
    public private(set) var runs: Set<Run>

    public init(_ input: [Int]) {
        a = input
        runs = Set(input.indices.map { Run(b: $0, t: $0) })
    }

    public var done: Bool { runs.count <= 1 }
    public var description: String {
        "A = \(a), R = \(runs.sorted { $0.b < $1.b }.map { "\($0.b)..\($0.t)" })"
    }

    /// Next(self, step): both named runs are in R.
    public func enabled(_ s: MergeStep) -> Bool {
        runs.contains(Run(b: s.b, t: s.m)) && runs.contains(Run(b: s.m + 1, t: s.t))
    }

    /// Membership in `Merged(A, b, t)`, as a predicate on (A, A′).
    public static func inMerged(_ before: [Int], _ after: [Int], b: Int, t: Int) -> Bool {
        before.count == after.count
            && before.indices.allSatisfy { i in (b...t).contains(i) || before[i] == after[i] }
            && after[b...t].sorted() == before[b...t].sorted()
            && zip(after[b...t], after[b...t].dropFirst()).allSatisfy { $0 <= $1 }
    }

    /// Precondition: enabled. A′ is the one element of `Merged(A, b, t)`.
    public mutating func apply(_ s: MergeStep) {
        precondition(enabled(s), "not a Next step: \(s) from \(self)")
        a.replaceSubrange(s.b...s.t, with: a[s.b...s.t].sorted())
        runs.remove(Run(b: s.b, t: s.m))
        runs.remove(Run(b: s.m + 1, t: s.t))
        runs.insert(Run(b: s.b, t: s.t))
    }

    /// The witnesses of the "pick any": every adjacent pair in R.
    public var candidates: [MergeStep] {
        let ordered = runs.sorted { $0.b < $1.b }
        return zip(ordered, ordered.dropFirst()).map { MergeStep(b: $0.b, m: $0.t, t: $1.t) }
    }

    public func draw(_ tc: TestCase) throws -> MergeStep {
        try tc.draw(.element(of: candidates))
    }

    /// Inv: R partitions the indices into intervals, every run is sorted.
    public var invariant: Bool {
        let ordered = runs.sorted { $0.b < $1.b }
        let partition = (ordered.first?.b ?? 0) == 0
            && (ordered.last?.t ?? -1) == a.count - 1
            && zip(ordered, ordered.dropFirst()).allSatisfy { $0.t + 1 == $1.b }
        let runsSorted = ordered.allSatisfy { r in
            zip(a[r.b...r.t], a[r.b...r.t].dropFirst()).allSatisfy { $0 <= $1 }
        }
        return partition && runsSorted
    }

    public static func behaviour(_ input: [Int]) -> Gen<(steps: [MergeStep], final: MergeModel)> {
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

    public struct Violation: Equatable, CustomStringConvertible {
        public let index: Int
        public let step: MergeStep
        public let reason: String
        public var description: String { "step \(index) (\(step)): \(reason)" }
    }

    /// Replays the recorded merges: each step enabled in the model's R,
    /// each recorded A′ in `Merged(A, b, t)`.
    public static func refines(_ recorded: [(step: MergeStep, state: [Int])], from input: [Int])
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
            m.apply(r.step)
        }
        return (nil, m)
    }
}

public enum MergesortBug: Sendable { case none, rightEndOffByOne }

/// Bottom-up mergesort, the agent's step 6: runs of width 1, 2, 4, …
/// merged left to right, recorded once per merge. `b + width < n` and not
/// `<=`: a left run with no right run is not a step and leaves no row.
public func mergeSort(_ a: inout [Int], bug: MergesortBug = .none, record: (MergeModel.MergeStep, [Int]) -> Void = { _, _ in }) {
    let n = a.count
    var buffer = a
    var width = 1
    while width < n {
        var b = 0
        while b + width < n {
            let m = b + width - 1
            let t = bug == .rightEndOffByOne ? min(b + 2 * width, n - 1) : min(b + 2 * width - 1, n - 1)
            merge(&a, into: &buffer, b, m, t)
            record(MergeModel.MergeStep(b: b, m: m, t: t), a)
            b += 2 * width
        }
        width *= 2
    }
}

/// The agent's second refinement: the recursion, recorded at the same
/// granularity. Splits change neither A nor R and leave no row.
public func mergeSortRecursive(_ a: inout [Int], record: (MergeModel.MergeStep, [Int]) -> Void = { _, _ in }) {
    var buffer = a
    func sort(_ b: Int, _ t: Int) {
        guard b < t else { return }
        let m = (b + t) / 2
        sort(b, m)
        sort(m + 1, t)
        merge(&a, into: &buffer, b, m, t)
        record(MergeModel.MergeStep(b: b, m: m, t: t), a)
    }
    if !a.isEmpty { sort(0, a.count - 1) }
}

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
