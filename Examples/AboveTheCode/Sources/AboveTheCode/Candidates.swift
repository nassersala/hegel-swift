/// The control: Fung's own method, "make up some wrong sorting algorithms"
/// and test them. A grammar of 24 double-loop swap programs, 1-based as
/// in the paper:
///
///     for i in O:                      O ∈ { 1…n, 1…n−1, 2…n }
///       for j in I(i):                 I ∈ { 1…n, 1…n−1, i+1…n, 1…i−1 }
///         if A[i] ⋈ A[j]: swap(i, j)   ⋈ ∈ { <, > }
///
/// Nothing here is drawn from a behaviour; the grammar is chosen by a
/// person and the intelligence is in the choice. A survivor of drawn
/// inputs is a candidate, and the run says nothing about why it sorts.
public struct Candidate: Hashable, Sendable, CustomStringConvertible {
    public enum Outer: String, CaseIterable, Sendable {
        case oneToN = "1…n", oneToNMinus1 = "1…n−1", twoToN = "2…n"
        func range(_ n: Int) -> Range<Int> {
            switch self {
            case .oneToN: return 0..<n
            case .oneToNMinus1: return 0..<max(0, n - 1)
            case .twoToN: return min(1, n)..<n
            }
        }
    }
    public enum Inner: String, CaseIterable, Sendable {
        case oneToN = "1…n", oneToNMinus1 = "1…n−1", iPlus1ToN = "i+1…n", oneToIMinus1 = "1…i−1"
        func range(_ i: Int, _ n: Int) -> Range<Int> {
            switch self {
            case .oneToN: return 0..<n
            case .oneToNMinus1: return 0..<max(0, n - 1)
            case .iPlus1ToN: return (i + 1)..<max(i + 1, n)
            case .oneToIMinus1: return 0..<i
            }
        }
    }
    public enum Comparison: String, CaseIterable, Sendable {
        case less = "<", greater = ">"
        func holds(_ x: Int, _ y: Int) -> Bool { self == .less ? x < y : x > y }
    }

    public let outer: Outer, inner: Inner, comparison: Comparison

    public init(_ outer: Outer, _ inner: Inner, _ comparison: Comparison) {
        self.outer = outer
        self.inner = inner
        self.comparison = comparison
    }

    /// All 24, comparison outermost so the table reads as two 3×4 grids.
    public static let all: [Candidate] = Comparison.allCases.flatMap { c in
        Outer.allCases.flatMap { o in Inner.allCases.map { Candidate(o, $0, c) } }
    }

    public func run(_ input: [Int]) -> [Int] {
        var a = input
        let n = a.count
        for i in outer.range(n) {
            for j in inner.range(i, n) where comparison.holds(a[i], a[j]) { a.swapAt(i, j) }
        }
        return a
    }

    public var description: String {
        "for i in \(outer.rawValue): for j in \(inner.rawValue): if A[i] \(comparison.rawValue) A[j]: swap"
    }

    public enum Verdict: String, Sendable { case asc, desc, neither }

    /// Fung's Algorithm 1, 2, 3.
    public static let fung = Candidate(.oneToN, .oneToN, .less)
    public static let exchangeSort = Candidate(.oneToNMinus1, .iPlus1ToN, .greater)
    public static let insertionSort = Candidate(.twoToN, .oneToIMinus1, .less)
}
