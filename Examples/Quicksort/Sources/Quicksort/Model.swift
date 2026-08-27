import Hegel

/// Lamport's quicksort, the two slides of "Thinking Above the Code":
///
///     Init:  A = any array of numbers of length N  ∧  U = {⟨0, N−1⟩}
///     Next:  U ≠ {}  ∧  pick any ⟨b, t⟩ in U:
///              if b ≠ t then pick any p in b..t−1:
///                   A′ ∈ Partitions(A, p, b, t)
///                 ∧ U′ = U with ⟨b, t⟩ removed and ⟨b, p⟩, ⟨p+1, t⟩ added
///              else A′ = A ∧ U′ = U with ⟨b, t⟩ removed
///
/// `Partitions(B, p, lo, hi)` is the set of arrays obtained from `B` by
/// permuting `B[lo...hi]` so that everything in `lo...p` is ≤ everything
/// in `p+1...hi`. Recursion is not part of the algorithm: the recursive
/// quicksort's behaviours are a subset of this relation's.
///
/// The three "pick any"s are the nondeterminism. `Step.draw` makes them
/// draws from the `TestCase`, so an abstract behaviour is generated data:
/// it replays from the blob and shrinks toward the boring choice (the
/// first range, `p = b`, the partition in sorted order).
public struct Lamport: Sendable, Equatable, CustomStringConvertible {
    public struct Range: Hashable, Sendable, Comparable, CustomStringConvertible {
        public var b: Int, t: Int
        public init(_ b: Int, _ t: Int) { self.b = b; self.t = t }
        public static func < (x: Range, y: Range) -> Bool { (x.b, x.t) < (y.b, y.t) }
        public var description: String { "⟨\(b), \(t)⟩" }
    }

    /// One `Next` step: which range, and for a partition, which pivot and
    /// which element of `Partitions`.
    public enum Step: Sendable, Equatable, CustomStringConvertible {
        case partition(Range, p: Int, after: [Int])
        case drop(Range)
        public var description: String {
            switch self {
            case .partition(let r, let p, let after): return "partition \(r) at \(p) → \(after)"
            case .drop(let r): return "drop \(r)"
            }
        }
    }

    public private(set) var a: [Int]
    public private(set) var u: Set<Range>

    public init(_ a: [Int]) {
        self.a = a
        u = a.isEmpty ? [] : [Range(0, a.count - 1)]
    }

    public var done: Bool { u.isEmpty }
    public var description: String { "A = \(a), U = \(u.sorted())" }

    /// `after ∈ Partitions(a, p, r.b, r.t)`.
    public func isPartition(_ after: [Int], p: Int, of r: Range) -> Bool {
        guard after.count == a.count, r.b <= p, p < r.t else { return false }
        for i in a.indices where !(r.b...r.t).contains(i) && a[i] != after[i] { return false }
        guard a[r.b...r.t].sorted() == after[r.b...r.t].sorted() else { return false }
        return after[r.b...p].max()! <= after[(p + 1)...r.t].min()!
    }

    /// Whether `step` is a `Next` step from this state.
    public func enabled(_ step: Step) -> Bool {
        switch step {
        case .partition(let r, let p, let after):
            return u.contains(r) && r.b != r.t && isPartition(after, p: p, of: r)
        case .drop(let r):
            return u.contains(r) && r.b == r.t
        }
    }

    /// Takes the step. Precondition: `enabled(step)`.
    public mutating func apply(_ step: Step) {
        precondition(enabled(step), "not a Next step: \(step) from \(self)")
        switch step {
        case .partition(let r, let p, let after):
            a = after
            u.remove(r)
            u.insert(Range(r.b, p))
            u.insert(Range(p + 1, r.t))
        case .drop(let r):
            u.remove(r)
        }
    }

    /// The three "pick any"s as draws. Precondition: `!done`.
    public func draw(_ tc: TestCase) throws -> Step {
        let ranges = u.sorted()
        let r = ranges[Int(try tc.drawInteger(in: 0...Int64(ranges.count - 1)))]
        if r.b == r.t { return .drop(r) }
        let p = r.b + Int(try tc.drawInteger(in: 0...Int64(r.t - 1 - r.b)))
        // Any element of Partitions: the k = p−b+1 smallest values go left,
        // the rest right, each side in a drawn order.
        let values = a[r.b...r.t].sorted()
        let k = p - r.b + 1
        var after = a
        after.replaceSubrange(r.b...p, with: try shuffled(Array(values[..<k]), tc))
        after.replaceSubrange((p + 1)...r.t, with: try shuffled(Array(values[k...]), tc))
        return .partition(r, p: p, after: after)
    }

    private func shuffled(_ xs: [Int], _ tc: TestCase) throws -> [Int] {
        var xs = xs
        for i in stride(from: xs.count - 1, to: 0, by: -1) {
            xs.swapAt(i, Int(try tc.drawInteger(in: 0...Int64(i))))
        }
        return xs
    }

    /// A complete behaviour from `a`: the steps and the final state.
    public static func behaviour(_ a: [Int]) -> Gen<(steps: [Step], final: Lamport)> {
        Gen { tc in
            var s = Lamport(a)
            var steps: [Step] = []
            while !s.done {
                let step = try s.draw(tc)
                s.apply(step)
                steps.append(step)
            }
            return (steps, s)
        }
    }

    /// Replays a concrete algorithm's steps against the relation: every
    /// step must be enabled, and the run must end with `U = {}`. Returns
    /// the first step that is not a `Next` step, if any.
    public static func refines(_ steps: [Step], from a: [Int]) -> (violation: Step?, final: Lamport) {
        var s = Lamport(a)
        for step in steps {
            guard s.enabled(step) else { return (step, s) }
            s.apply(step)
        }
        return (nil, s)
    }
}
