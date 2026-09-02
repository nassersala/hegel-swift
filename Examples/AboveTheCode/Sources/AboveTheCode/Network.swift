import Hegel

/// The state of a sorting-network search is not one array but every
/// zero-one input at once. By the zero-one principle a fixed comparator
/// sequence sorts every input of length `n` iff it sorts every vector over
/// {0, 1} of length `n`; so with the set of all `2ⁿ` such vectors as the
/// state, a rule that applies one comparator to every vector is one
/// algorithm step for every input, and a rule sequence that leaves the
/// whole set sorted is a sorting network.
///
/// Drawn by hand first, `n = 2`:
///
///     {00, 01, 10, 11}  ─cmp 0 1─▶  {00, 01, 11}
///
/// The variables: one set of vectors. The step: one comparator on all of
/// them. And a fact the drawing shows that the prose does not: `10` and
/// `01` merged, the set shrank. "All sorted" is reached when the unsorted
/// vectors have merged away, not when vectors sort in place; the sorted
/// vectors `0…01…1` are all present from the start, so "count the sorted
/// ones" is constant and `unsorted` is the score that moves.
public struct ZeroOne: Hashable, Sendable, CustomStringConvertible {
    public let n: Int
    public private(set) var vectors: Set<[UInt8]>

    /// `{0, 1}ⁿ`.
    public static func all(_ n: Int) -> ZeroOne {
        precondition(n >= 0)
        var vectors: Set<[UInt8]> = []
        for bits in 0..<(1 << n) {
            vectors.insert((0..<n).map { UInt8((bits >> ($0)) & 1) })
        }
        return ZeroOne(n: n, vectors: vectors)
    }

    private init(n: Int, vectors: Set<[UInt8]>) {
        self.n = n
        self.vectors = vectors
    }

    /// The comparator `(i, j)`, `i < j`, on every vector: the smaller
    /// value goes to `i`.
    public mutating func apply(_ c: Comparator) {
        precondition(c.i < c.j && c.j < n, "comparator \(c) out of range for n = \(n)")
        vectors = Set(vectors.map { v in
            var v = v
            if v[c.i] > v[c.j] { v.swapAt(c.i, c.j) }
            return v
        })
    }

    public var unsorted: Int { vectors.filter { !isSorted($0) }.count }
    public var allSorted: Bool { unsorted == 0 }

    /// Type correctness, Lamport's `TypeOK`: every vector has length `n`
    /// over {0, 1}, and the set is never empty.
    public var typeOK: Bool {
        !vectors.isEmpty && vectors.allSatisfy { $0.count == n && $0.allSatisfy { $0 <= 1 } }
    }

    public var description: String {
        let shown = vectors.sorted { $0.lexicographicallyPrecedes($1) }
            .map { $0.map(String.init).joined() }
        return "{\(shown.joined(separator: ", "))}"
    }
}

public struct Comparator: Hashable, Sendable, CustomStringConvertible {
    public let i: Int, j: Int
    public init(_ i: Int, _ j: Int) {
        precondition(i < j)
        self.i = i
        self.j = j
    }
    public var description: String { "cmp \(i) \(j)" }

    /// Parses a rule line of the stateful trace, the name given in
    /// `comparators(_:)`.
    public init?(line: String) {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "cmp", let i = Int(parts[1]), let j = Int(parts[2]), i < j else {
            return nil
        }
        self.init(i, j)
    }
}

/// All `n(n−1)/2` comparators, the rule set.
public func comparators(_ n: Int) -> [Comparator] {
    (0..<n).flatMap { i in ((i + 1)..<n).map { Comparator(i, $0) } }
}

/// The network as an algorithm on one array.
public func apply<T: Comparable>(_ network: [Comparator], to input: [T]) -> [T] {
    var v = input
    for c in network where v[c.i] > v[c.j] { v.swapAt(c.i, c.j) }
    return v
}

public func isSorted<T: Comparable>(_ v: [T]) -> Bool {
    zip(v, v.dropFirst()).allSatisfy { $0 <= $1 }
}

/// Check 1: the goal, outside the runner.
public func sortsAllZeroOne(_ network: [Comparator], n: Int) -> Bool {
    ZeroOne.all(n).vectors.allSatisfy { isSorted(apply(network, to: $0)) }
}

/// Check 2: all `n!` permutations, the zero-one principle confirmed on the
/// instance rather than assumed.
public func sortsAllPermutations(_ network: [Comparator], n: Int) -> Bool {
    permutations(Array(0..<n)).allSatisfy { isSorted(apply(network, to: $0)) }
}

public func permutations<T>(_ xs: [T]) -> [[T]] {
    guard !xs.isEmpty else { return [[]] }
    return xs.indices.flatMap { i -> [[T]] in
        var rest = xs
        let x = rest.remove(at: i)
        return permutations(rest).map { [x] + $0 }
    }
}

/// The search, Die Hard's shape: the false invariant is "not all sorted",
/// and the shrunk counterexample is the network. Returns `nil` when the
/// walks never reached the goal.
public struct NetworkFound: Error {}
public struct NotTypeOK: Error {}

public func searchNetwork(
    n: Int,
    seed: UInt64? = nil,
    testCases: UInt64 = 200,
    steps: Int64? = nil,
    targeted: Bool = false
) throws -> [Comparator]? {
    let rules: [Rule<ZeroOne>] = comparators(n).map { c in
        Rule(c.description) { (s: inout ZeroOne, _: TestCase) throws in s.apply(c) }
    }
    let invariants: [Invariant<ZeroOne>] = [
        Invariant("type ok") { (s: ZeroOne) throws in if !s.typeOK { throw NotTypeOK() } },
        Invariant("not all sorted") { (s: ZeroOne) throws in if s.allSorted { throw NetworkFound() } },
    ]
    var score: (@Sendable (ZeroOne) -> Double)? = nil
    if targeted { score = { (s: ZeroOne) -> Double in -Double(s.unsorted) } }
    do {
        try forAll(
            initial: Gen<ZeroOne> { _ in ZeroOne.all(n) },
            rules: rules,
            invariants: invariants,
            maximize: score,
            testCases: testCases,
            seed: seed,
            database: "",
            settings: Settings(statefulStepCount: steps))
        return nil
    } catch let failure as PropertyFailure {
        guard let trace = failure.failures.first?.counterexample else { throw failure }
        return network(fromTrace: trace)
    }
}

/// Rule lines sit between `initial:` and the invariant/violation tail.
public func network(fromTrace trace: String) -> [Comparator] {
    trace.split(separator: "\n")
        .map { String($0.drop(while: { $0 == " " })) }
        .compactMap { Comparator(line: $0) }
}
