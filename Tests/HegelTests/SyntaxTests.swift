import Hegel
import Testing

private struct Person: Equatable, Sendable {
    var id: Int64; var age: Int; var active: Bool; var name: String; var score: Double
}

@Suite struct SyntaxTests {
    @Test func packZipHandlesAnyArity() throws {
        let person = zip(
            Gen<Int64>.int(in: 0...1000), Gen<Int>.int(in: 18...65), Gen.bool(),
            Gen.asciiString(count: 0...8), Gen.double(in: 0...1)
        ).map { Person(id: $0, age: $1, active: $2, name: $3, score: $4) }
        try forAll(person, testCases: 50, database: "") { u in
            #expect((18...65).contains(u.age) && (0...1).contains(u.score))
        }
        let one = zip(Gen.int(in: 1...1))
        try forAll(one, testCases: 5, database: "") { n in #expect(n == 1) }
    }

    @Test func drawBuildsDependentGenerators() throws {
        let sizedList = Gen<[Int]> { tc in
            let n = try tc.draw(.int(in: 0...5))
            return try tc.draw(.array(of: .int(in: 0...9), count: UInt64(n)...UInt64(n)))
        }
        try forAll(sizedList, testCases: 50, database: "") { xs in #expect(xs.count <= 5) }
    }

    @Test func leadingDotCombinatorsInArgumentPosition() throws {
        try forAll(.array(of: .int(in: 0...3), count: 1...4), testCases: 30, database: "") { xs in
            #expect(!xs.isEmpty && xs.count <= 4)
        }
        try forAll(.oneOf([.constant(1), .constant(2)]), testCases: 30, database: "") { n in
            #expect(n == 1 || n == 2)
        }
        try forAll(.element(of: ["GET", "POST"]), testCases: 30, database: "") { v in
            #expect(v == "GET" || v == "POST")
        }
        try forAll(.frequency([(weight: 3, gen: .constant(0)), (weight: 1, gen: .constant(1))]),
                   testCases: 30, database: "") { n in #expect(n == 0 || n == 1) }
    }

    @Test func rangesStandWhereAGeneratorIsExpected() throws {
        try forAll(1...100, testCases: 50, database: "") { n in #expect((1...100).contains(n)) }
    }

    @Test func subjectFirstLaws() throws {
        try forAll({ (xs: [Int]) in xs.sorted() }, is: .idempotent, on: .array(of: .int(in: 0...9)),
                   label: "sorted", testCases: 50, database: "")
        try forAll({ (xs: [Int]) in Array(xs.reversed()) }, is: .involution, on: .array(of: .int(in: 0...9)),
                   label: "reversed", testCases: 50, database: "")
        try forAll(+, is: .associative, on: .int(in: -100...100), label: "+", testCases: 50, database: "")
        try forAll(max, is: .idempotent, on: .int(in: -100...100), label: "max", testCases: 50, database: "")
        try forAll(+, 0, are: .monoid, on: .int(in: -100...100), label: "+", testCases: 50, database: "")
        try forAll(max, Int.min, are: .semilattice, on: .int(in: -100...100), label: "max", testCases: 50, database: "")
        try forAll({ (n: Int) in String(n) }, { (s: String) in Int(s)! }, are: .retraction,
                   on: .int(in: -100...100), labels: ("String", "Int"), testCases: 50, database: "")
    }

    @Test func subjectFirstLawFailsWithTheCatalogsDisplay() throws {
        do {
            try forAll({ (n: Int) in n + 1 }, is: .idempotent, on: .int(in: 0...9), label: "succ",
                       testCases: 50, database: "")
            Issue.record("succ is not idempotent")
        } catch let failure as PropertyFailure {
            let c = try #require(failure.failures.first?.counterexample)
            #expect(c.contains("idempotence"), "\(c)")
            #expect(c.contains("succ(succ(a))"), "\(c)")
        }
    }

    struct Query: Sendable { var angle: Double; var longitude: Double }
    struct Times: Equatable, Sendable { var fajr: Double }
    static let subject: @Sendable (Query) -> Times = { q in
        Times(fajr: 360 - q.angle * 4 + (q.longitude.truncatingRemainder(dividingBy: 360)) * 0)
    }

    @Test func keyPathRelations() throws {
        let queries = zip(Gen.double(in: 10...20), Gen.double(in: -180...180)).map(Query.init)
        try forAll(
            source: queries,
            relations: [
                .monotone("angle up ⇒ fajr earlier", bumping: \.angle, by: .double(in: 1...6),
                          observing: \.fajr, .nonIncreasing),
                .invariant("longitude period", shifting: \.longitude, by: .constant(360)),
            ],
            testCases: 100, database: "", subject: Self.subject)
    }

    @Test func keyPathRelationCatchesTheWrongDirection() throws {
        let queries = zip(Gen.double(in: 10...20), Gen.double(in: -180...180)).map(Query.init)
        do {
            try forAll(
                source: queries,
                relations: [.monotone("angle up ⇒ fajr later (wrong)", bumping: \.angle, by: .double(in: 1...6),
                                      observing: \.fajr, .nonDecreasing)],
                testCases: 100, database: "", subject: Self.subject)
            Issue.record("should fail")
        } catch let failure as PropertyFailure {
            let c = try #require(failure.failures.first?.counterexample)
            #expect(c.contains("expected non-decreasing"), "\(c)")
        }
    }
}
