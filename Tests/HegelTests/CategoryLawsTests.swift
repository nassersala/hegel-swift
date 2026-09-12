import Testing
@testable import Hegel

// Categories and functors as witnesses: a many-object category (integer
// matrices, objects are dimensions), monoids recovered as one-object
// categories, and functors between them — the same square Essence03/04
// prove in Agda, here tested.

/// An `m×n` matrix is an arrow from `n` to `m`; composition is the product.
private struct Matrix: Equatable, Sendable, CustomStringConvertible {
    let rows: Int, cols: Int
    let entries: [Int]  // row-major

    subscript(i: Int, j: Int) -> Int { entries[i * cols + j] }

    static func identity(_ n: Int) -> Matrix {
        Matrix(rows: n, cols: n, entries: (0..<n * n).map { $0 / n == $0 % n ? 1 : 0 })
    }

    static func * (g: Matrix, f: Matrix) -> Matrix {
        precondition(g.cols == f.rows, "shape: \(g.rows)×\(g.cols) after \(f.rows)×\(f.cols)")
        var out = [Int](repeating: 0, count: g.rows * f.cols)
        for i in 0..<g.rows {
            for j in 0..<f.cols {
                var s = 0
                for k in 0..<g.cols { s &+= g[i, k] &* f[k, j] }
                out[i * f.cols + j] = s
            }
        }
        return Matrix(rows: g.rows, cols: f.cols, entries: out)
    }

    func map(_ h: (Int) -> Int) -> Matrix { Matrix(rows: rows, cols: cols, entries: entries.map(h)) }
    var description: String { "\(rows)×\(cols)\(entries)" }
}

private func mod7(_ x: Int) -> Int { ((x % 7) + 7) % 7 }

/// Matrices over dimensions 1…3 with the given entries; `normalize` is
/// applied after each product (identity for ℤ, `mod7` for ℤ/7).
private func matrices(
    entries: Gen<Int>, normalize: @escaping @Sendable (Int) -> Int = { $0 }
) -> Category<Int, Matrix> {
    let dims = Gen<Int>.int(in: 1...3)
    return Category(
        objects: dims,
        arrows: { n in
            dims.flatMap { m in
                array(of: entries, count: UInt64(m * n)...UInt64(m * n))
                    .map { Matrix(rows: m, cols: n, entries: $0) }
            }
        },
        codomain: { $0.rows },
        identity: Matrix.identity,
        compose: { g, f in (g * f).map(normalize) },
        label: "×",
        equal: ==)
}

@Suite struct CategoryLawsTests {
    static let ints = Gen<Int>.int(in: -1000...1000)
    static let small = Gen<Int>.int(in: -5...5)
    static let lists = array(of: Gen<Int>.int(in: -50...50), count: 0...12)
    static let strings = array(of: element(of: ["a", "b", "c"]), count: 0...6).map { $0.joined() }

    @Test func integerMatricesFormACategory() throws {
        try forAll(Laws.category(matrices(entries: Self.small)), database: "")
    }

    @Test func stringConcatenationIsAOneObjectCategory() throws {
        try forAll(Laws.category(.monoid(Self.strings, "+", +, identity: "")), database: "")
    }

    /// Subtraction is not a monoid: `0 - f ≠ f` and it is not associative.
    /// `f - 0 = f` and congruence hold, so exactly two laws are violated.
    @Test func integerSubtractionIsNotAOneObjectCategory() throws {
        let found = try counterexamples(Laws.category(.monoid(Self.ints, "-", -, identity: 0)))
        #expect(found.count == 2)
        #expect(found.contains { $0.contains("law: id - f = f") })
        #expect(found.contains { $0.contains("law: associativity") })
    }

    /// The monoid homomorphism of `LawsTests`, as a functor between
    /// one-object categories.
    @Test func countIsAFunctorBetweenOneObjectCategories() throws {
        try forAll(
            Laws.functor(
                "count", objects: { $0 }, arrows: { $0.count },
                from: .monoid(Self.lists, "+", +, identity: []),
                to: .monoid(Self.ints, "+", +, identity: 0)),
            database: "")
    }

    /// Entrywise reduction mod 7 is a functor from ℤ-matrices to
    /// ℤ/7-matrices; entrywise `abs` is not (`[1 -1]·[1 1]ᵀ = 0`, but
    /// `[1 1]·[1 1]ᵀ = 2`).
    @Test func reductionMod7IsAFunctorAndAbsIsNot() throws {
        let integers = matrices(entries: Self.small)
        let mod = matrices(entries: Gen<Int>.int(in: 0...6), normalize: mod7)
        try forAll(
            Laws.functor("mod7", objects: { $0 }, arrows: { $0.map(mod7) }, from: integers, to: mod),
            database: "")
        let nonNegative = matrices(entries: Gen<Int>.int(in: 0...5))
        let found = try counterexamples(
            Laws.functor("abs", objects: { $0 }, arrows: { $0.map(abs) }, from: integers, to: nonNegative))
        #expect(found.count == 1)
        #expect(try #require(found.first).contains("law: abs(g × f) = abs(g) × abs(f)"))
    }
}

/// Runs a suite expected to fail; returns the counterexamples, one per
/// violated law, in report order.
private func counterexamples(
    _ suite: LawSuite, testCases: UInt64 = 300, seed: UInt64? = nil, fileID: String = #fileID, line: Int = #line
) throws -> [String] {
    do {
        try forAll(suite, testCases: testCases, seed: seed, database: "")
    } catch let failure as PropertyFailure {
        return try failure.failures.map { try #require($0.counterexample) }
    }
    Issue.record("expected \(suite.name) to fail", sourceLocation: SourceLocation(fileID: fileID, filePath: #filePath, line: line, column: 1))
    return []
}
