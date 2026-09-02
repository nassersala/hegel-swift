import Testing
import HegelTesting
import AboveTheCode

/// The control: Fung's method. Every program in the grammar is run on
/// drawn arrays against `sorted()`, both directions, and classified. The
/// table was worked by hand first (see `Candidate`'s spec); the run
/// confirms it or corrects it, and a corrected cell is a finding about
/// the hand argument.
@Suite struct TheControl {
    static let arrays = array(of: Gen<Int>.int(in: 0...9), count: 0...8)

    typealias V = Candidate.Verdict
    /// Rows `Outer.allCases`, columns `Inner.allCases`, for `<`. With `<`
    /// a swap at j < i inserts A[i] into the prefix and a swap at j > i
    /// only makes A[i] larger, which keeps a sorted prefix sorted; so any
    /// inner range containing 1…i−1 with an outer range reaching n sorts
    /// ascending. Negating the comparison mirrors the order.
    static let predictedLess: [[V]] = [
        [.asc, .asc, .desc, .asc],
        [.neither, .neither, .desc, .neither],
        [.asc, .asc, .neither, .asc],
    ]

    static func predicted(_ c: Candidate) -> V {
        let o = Candidate.Outer.allCases.firstIndex(of: c.outer)!
        let i = Candidate.Inner.allCases.firstIndex(of: c.inner)!
        let v = predictedLess[o][i]
        guard c.comparison == .greater else { return v }
        switch v {
        case .asc: return .desc
        case .desc: return .asc
        case .neither: return .neither
        }
    }

    @Test func the24Classified() throws {
        var rows: [String] = ["| program | verdict | not asc | not desc |", "|---|---|---|---|"]
        var corrections: [String] = []
        var totals: [V: Int] = [:]
        for c in Candidate.all {
            let notAsc = try counterexample { c.run($0) == $0.sorted() }
            let notDesc = try counterexample { c.run($0) == $0.sorted(by: >) }
            #expect(notAsc != nil || notDesc != nil, "\(c) sorts both ways: fixture bug")
            let verdict: V = notAsc == nil ? .asc : notDesc == nil ? .desc : .neither
            totals[verdict, default: 0] += 1
            rows.append("| `\(c)` | \(verdict.rawValue) | \(notAsc.map { "\($0)" } ?? "") | \(notDesc.map { "\($0)" } ?? "") |")
            if verdict != Self.predicted(c) { corrections.append("\(c): predicted \(Self.predicted(c)), got \(verdict)") }
            if verdict == .neither {
                #expect((notAsc!.count <= 3) && (notDesc!.count <= 3), "\(c): \(notAsc!) \(notDesc!)")
            }
        }
        print(rows.joined(separator: "\n"))
        print("totals: asc \(totals[.asc] ?? 0), desc \(totals[.desc] ?? 0), neither \(totals[.neither] ?? 0)")
        #expect(corrections.isEmpty, "\(corrections)")
    }

    struct Refuted: Error {}

    /// The shrunk input on which `holds` fails, or nil after 1000 cases.
    func counterexample(_ holds: @escaping @Sendable ([Int]) -> Bool) throws -> [Int]? {
        do {
            try forAll(Self.arrays, testCases: 1000, seed: 1, database: "") { a in if !holds(a) { throw Refuted() } }
            return nil
        } catch let failure as PropertyFailure {
            return try replay(Self.arrays, blob: try #require(failure.failures.first?.reproduceBlob))
        }
    }
}
