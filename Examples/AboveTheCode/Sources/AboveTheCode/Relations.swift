import Hegel

/// Relations written above the code, each a `Next(s, s′)` over states a
/// concrete algorithm's behaviour can be projected onto. The code refines
/// a relation when every consecutive pair of its recorded states is a
/// `Next` step and the run ends done.

/// Relation 1, what an exchange sort refines: a step swaps one inversion.
///
///     Next(s, s′) ⇔ ∃ i < j: s[i] > s[j] ∧ s′ = s with i, j swapped
public enum Exchange {
    public static func next(_ s: [Int], _ t: [Int]) -> Bool {
        guard s.count == t.count else { return false }
        let changed = s.indices.filter { s[$0] != t[$0] }
        guard changed.count == 2 else { return false }
        let (i, j) = (changed[0], changed[1])
        return s[i] > s[j] && t[i] == s[j] && t[j] == s[i]
    }

    /// The first pair that is not a step, if any.
    public static func refines(_ states: [[Int]], from a: [Int]) -> (violation: (from: [Int], to: [Int])?, final: [Int]) {
        var s = a
        for t in states {
            guard next(s, t) else { return ((s, t), s) }
            s = t
        }
        return (nil, s)
    }
}

/// Relations 2 and 3, insertion: the state is a sorted prefix and the
/// unplaced rest.
///
///     Init:  prefix = [] ∧ rest = A
///     Next:  rest ≠ [] ∧ pick any x in rest:
///              prefix′ = prefix with x inserted at its place
///            ∧ rest′ = rest with one x removed          (remainder fixed)
///            ∧ rest′ is a permutation of rest with one x removed   (free)
///
/// The two relations differ by that one clause. Insertion sort refines
/// the first; Fung refines only the second, because its pass 0 shuffles
/// the rest. Neither says why Fung's later passes leave the rest alone;
/// that is his invariant "the prefix ends with the maximum", which the
/// refinement check does not need and does not find.
public struct Insertion: Hashable, Sendable, CustomStringConvertible {
    public enum Remainder: Sendable { case fixed, free }

    public var prefix: [Int]
    public var rest: [Int]

    public init(_ a: [Int]) {
        prefix = []
        rest = a
    }
    public init(prefix: [Int], rest: [Int]) {
        self.prefix = prefix
        self.rest = rest
    }

    public var done: Bool { rest.isEmpty }
    public var description: String { "prefix = \(prefix), rest = \(rest)" }

    /// `Next(self, t)` under the remainder clause.
    public func next(_ t: Insertion, remainder: Remainder) -> Bool {
        guard !rest.isEmpty, t.prefix.count == prefix.count + 1, isSorted(t.prefix) else { return false }
        // x is the one element of t.prefix not accounted for by prefix.
        var extra = t.prefix
        for p in prefix {
            guard let k = extra.firstIndex(of: p) else { return false }
            extra.remove(at: k)
        }
        guard extra.count == 1, let k = rest.firstIndex(of: extra[0]) else { return false }
        var removed = rest
        removed.remove(at: k)
        switch remainder {
        case .fixed: return t.rest == removed
        case .free: return t.rest.sorted() == removed.sorted()
        }
    }

    /// The "pick any"s as draws: which element, and for the free
    /// relation, which order the rest ends in. Precondition: `!done`.
    public func draw(_ tc: TestCase, remainder: Remainder) throws -> Insertion {
        let k = Int(try tc.drawInteger(in: 0...Int64(rest.count - 1)))
        var rest = rest
        let x = rest.remove(at: k)
        var prefix = prefix
        prefix.insert(x, at: prefix.firstIndex { $0 > x } ?? prefix.count)
        if remainder == .free {
            for i in stride(from: rest.count - 1, to: 0, by: -1) {
                rest.swapAt(i, Int(try tc.drawInteger(in: 0...Int64(i))))
            }
        }
        return Insertion(prefix: prefix, rest: rest)
    }

    /// A complete behaviour from `a`.
    public static func behaviour(_ a: [Int], remainder: Remainder) -> Gen<(states: [Insertion], final: Insertion)> {
        Gen { tc in
            var s = Insertion(a)
            var states: [Insertion] = []
            while !s.done {
                s = try s.draw(tc, remainder: remainder)
                states.append(s)
            }
            return (states, s)
        }
    }

    /// The refinement mapping from a pass-instrumented run: after pass
    /// `k` the prefix is the first `k + 1` elements and the rest is what
    /// follows.
    public static func project(passes: [[Int]]) -> [Insertion] {
        passes.enumerated().map { k, a in Insertion(prefix: Array(a[...k]), rest: Array(a[(k + 1)...])) }
    }

    /// Replays a pass-instrumented run against the relation. Returns the
    /// first pair that is not a `Next` step, if any.
    public static func refines(
        passes: [[Int]], from a: [Int], remainder: Remainder
    ) -> (violation: (from: Insertion, to: Insertion)?, final: Insertion) {
        var s = Insertion(a)
        for t in project(passes: passes) {
            guard s.next(t, remainder: remainder) else { return ((s, t), s) }
            s = t
        }
        return (nil, s)
    }
}
