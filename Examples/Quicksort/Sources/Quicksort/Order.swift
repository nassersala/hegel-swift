/// Sorting as monotone refinement of what is known about the order.
///
/// The lattice: relations "element i ≤ element j" over indices (indices,
/// not values, so duplicates are distinct elements), ordered by inclusion,
/// closed under transitivity. Bottom is nothing known; the top of interest
/// is the true order of the values. Join is union then closure: a bounded
/// join-semilattice, so a state-based CRDT (`Laws.semilattice`).
///
/// A propagator is a comparison that learns pairs. Quicksort and mergesort
/// are two ways of choosing which comparisons to make: quicksort's
/// three-way partition of an index set learns `L×E ∪ L×R ∪ E×R ∪ E×E`;
/// mergesort's node learns the cross pairs of its two halves. Every pair
/// of indices is separated at exactly one node of either tree, so both
/// reach the true order, in any firing order (join is commutative), and
/// firing twice changes nothing (join is idempotent). This is the
/// propagator sorting of Sussman & Radul's model over an LVar-style
/// lattice; the data is never moved, the array is read off the order at
/// the end.
public struct Order: Hashable, Sendable, CustomStringConvertible {
    public struct Pair: Hashable, Sendable { public let i: Int, j: Int
        public init(_ i: Int, _ j: Int) { self.i = i; self.j = j } }
    public let count: Int
    public private(set) var pairs: Set<Pair>

    public init(count: Int, pairs: Set<Pair> = []) {
        self.count = count
        self.pairs = Order.closure(pairs)
    }

    public static func bottom(_ count: Int) -> Order { Order(count: count) }

    /// Union, then transitive closure.
    public func join(_ other: Order) -> Order {
        Order(count: max(count, other.count), pairs: pairs.union(other.pairs))
    }

    public static func <= (a: Order, b: Order) -> Bool { a.pairs.isSubset(of: b.pairs) }

    /// Every pair of distinct indices is ordered.
    public var isTotal: Bool {
        for i in 0..<count { for j in 0..<count where i != j && !pairs.contains(Pair(i, j)) && !pairs.contains(Pair(j, i)) { return false } }
        return true
    }

    /// The true order of `values`: `i ≤ j` iff `values[i] <= values[j]`.
    public static func of(_ values: [Int]) -> Order {
        var pairs = Set<Pair>()
        for i in values.indices { for j in values.indices where i != j && values[i] <= values[j] { pairs.insert(Pair(i, j)) } }
        return Order(count: values.count, pairs: pairs)
    }

    /// Reads the sorted array off a total order.
    public func sorted(_ values: [Int]) -> [Int] {
        precondition(isTotal)
        // i before j if i ≤ j is known and (j ≤ i is not, or i < j breaks the tie).
        return (0..<count).sorted { pairs.contains(Pair($0, $1)) && (!pairs.contains(Pair($1, $0)) || $0 < $1) }.map { values[$0] }
    }

    static func closure(_ pairs: Set<Pair>) -> Set<Pair> {
        var closed = pairs
        var changed = true
        while changed {
            changed = false
            for a in closed { for b in closed where a.j == b.i && a.i != b.j {
                if closed.insert(Pair(a.i, b.j)).inserted { changed = true }
            } }
        }
        return closed
    }

    public var description: String { "Order(\(pairs.count) pairs of \(count))" }
}

/// A propagator: the pairs one comparison step learns about `values`.
public typealias Fact = Set<Order.Pair>

public enum Propagators {
    static func cross(_ l: [Int], _ r: [Int]) -> Fact {
        var f = Fact()
        for i in l { for j in r where i != j { f.insert(Order.Pair(i, j)) } }
        return f
    }

    /// Quicksort's propagators: three-way partition of an index set by
    /// the value at `pivot`, learning all cross pairs, then the same for
    /// the two strict sides. `pivotOf` picks the pivot from an index set.
    public static func quicksort(_ values: [Int], indices: [Int]? = nil, pivotOf: ([Int]) -> Int = { $0[$0.count / 2] }) -> [Fact] {
        let s = indices ?? Array(values.indices)
        guard s.count > 1 else { return [] }
        let v = values[pivotOf(s)]
        let l = s.filter { values[$0] < v }, e = s.filter { values[$0] == v }, r = s.filter { values[$0] > v }
        let here = cross(l, e).union(cross(l, r)).union(cross(e, r)).union(cross(e, e))
        return [here] + quicksort(values, indices: l, pivotOf: pivotOf) + quicksort(values, indices: r, pivotOf: pivotOf)
    }

    /// Mergesort's propagators: split an index set in half; the node
    /// learns the cross pairs of the halves by comparing values.
    public static func mergesort(_ values: [Int], indices: [Int]? = nil) -> [Fact] {
        let s = indices ?? Array(values.indices)
        guard s.count > 1 else { return [] }
        let l = Array(s[..<(s.count / 2)]), r = Array(s[(s.count / 2)...])
        var here = Fact()
        for i in l { for j in r {
            if values[i] <= values[j] { here.insert(Order.Pair(i, j)) }
            if values[j] <= values[i] { here.insert(Order.Pair(j, i)) }
        } }
        return [here] + mergesort(values, indices: l) + mergesort(values, indices: r)
    }
}

// MARK: - The moving-data algorithm, projected onto the lattice

extension Propagators {
    /// Tags each value with its index so the moving-data algorithm keeps
    /// element identity: `value * n + index`. Preserves `<` between
    /// unequal values and orders ties by index, so every fact read off a
    /// tagged partition is sound for the original values.
    public static func tagged(_ values: [Int]) -> [Int] {
        values.enumerated().map { $0.element * values.count + $0.offset }
    }

    /// A `Lamport` partition step on tagged values, read as a fact: the
    /// elements that landed left are ≤ the elements that landed right.
    /// `drop` steps learn nothing. This is the projection from the
    /// relation that moves data to the lattice that accumulates knowledge.
    public static func facts(of steps: [Lamport.Step], count n: Int) -> [Fact] {
        steps.compactMap { step in
            guard case .partition(let r, let p, let after) = step else { return nil }
            let ids = after.map { $0 % n }
            let k = p - r.b + 1
            return cross(Array(ids[..<k]), Array(ids[k...]))
        }
    }
}

// MARK: - Threshold reads

/// Mergesort as propagators with threshold reads (LVars): a node waits
/// until the cell is total on each half, then merges with at most
/// `|l| + |r| − 1` comparisons, learning only the pairs it compared; the
/// cell's closure supplies the rest. The cost drops from O(n²) pairs to
/// n log n comparisons, and blocking makes deadlock possible: a node whose
/// threshold is never reached waits forever.
public struct MergeNode: Sendable {
    public let l: [Int], r: [Int]
    public var indices: [Int] { l + r }

    /// The nodes of the split tree of `n` indices, leaves excluded.
    public static func tree(_ n: Int) -> [MergeNode] {
        func nodes(_ s: [Int]) -> [MergeNode] {
            guard s.count > 1 else { return [] }
            let l = Array(s[..<(s.count / 2)]), r = Array(s[(s.count / 2)...])
            return [MergeNode(l: l, r: r)] + nodes(l) + nodes(r)
        }
        return nodes(Array(0..<n))
    }

    /// Precondition: `order` is total on `l` and on `r`. Returns the pairs
    /// compared and how many comparisons it took.
    public func merge(_ values: [Int], given order: Order) -> (fact: Fact, comparisons: Int) {
        func sorted(_ s: [Int]) -> [Int] { s.sorted { order.pairs.contains(Order.Pair($0, $1)) && (!order.pairs.contains(Order.Pair($1, $0)) || $0 < $1) } }
        let ls = sorted(l), rs = sorted(r)
        var i = 0, j = 0, comparisons = 0
        var fact = Fact()
        while i < ls.count && j < rs.count {
            comparisons += 1
            if values[ls[i]] <= values[rs[j]] { fact.insert(Order.Pair(ls[i], rs[j])); i += 1 }
            else { fact.insert(Order.Pair(rs[j], ls[i])); j += 1 }
        }
        return (fact, comparisons)
    }
}

extension Order {
    /// Total on a subset of the indices.
    public func isTotal(on s: [Int]) -> Bool {
        for i in s { for j in s where i != j && !pairs.contains(Pair(i, j)) && !pairs.contains(Pair(j, i)) { return false } }
        return true
    }
}
