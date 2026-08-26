import Testing
@testable import Hegel

// Laws: named suites over stdlib carriers that pass, and deliberate
// failures that must shrink to their known minimal counterexample and name
// the violated law. Every suite is one run per law, so a suite with two
// violated laws must report two bugs.

/// Runs a suite expected to fail; returns the counterexamples, one per
/// violated law, in report order.
private func counterexamples(
    _ suite: LawSuite, testCases: UInt64 = 300, fileID: String = #fileID, line: Int = #line
) throws -> [String] {
    do {
        try forAll(suite, testCases: testCases, database: "")
    } catch let failure as PropertyFailure {
        return try failure.failures.map { try #require($0.counterexample) }
    }
    Issue.record("expected \(suite.name) to fail", sourceLocation: SourceLocation(fileID: fileID, filePath: #filePath, line: line, column: 1))
    return []
}

@Suite struct LawsTests {
    static let ints = Gen<Int>.int(in: -1000...1000)
    static let small = Gen<Int>.int(in: -3...3)
    static let lists = array(of: Gen<Int>.int(in: -50...50), count: 0...12)
    static let strings = array(of: element(of: ["a", "b", "c"]), count: 0...6).map { $0.joined() }
    static let sets = lists.map(Set.init)

    // MARK: Algebraic structures on stdlib carriers

    @Test func stringConcatenationIsAMonoid() throws {
        try forAll(Laws.monoid(Self.strings, "+", +, identity: ""), database: "")
    }

    @Test func wrappingIntegersAreARing() throws {
        try forAll(Laws.fixedWidthRing(Gen<Int>.int(in: Int.min...Int.max)), database: "")
        try forAll(Laws.fixedWidthRing(Gen<Int>.int(in: Int.min...Int.max).map(UInt8.init(truncatingIfNeeded:))), database: "")
    }

    @Test func boundedIntegersAreAdditiveArithmetic() throws {
        try forAll(Laws.additiveArithmetic(Self.ints), database: "")
    }

    @Test func setsFormALattice() throws {
        try forAll(
            Laws.lattice(Self.sets, join: "∪", { $0.union($1) }, meet: "∩", { $0.intersection($1) }),
            database: "")
    }

    /// `semilattice` is the sum `monoid + commutative + idempotent` — the
    /// CRDT merge contract — and `Set.union` with `[]` is the canonical one.
    @Test func minMaxFormALatticeAndMaxAndUnionAreBoundedSemilattices() throws {
        try forAll(Laws.lattice(Self.ints, join: "max", max, meet: "min", min), database: "")
        try forAll(Laws.semilattice(Self.ints, "max", max, identity: Int.min), database: "")
        try forAll(Laws.semilattice(Self.sets, "∪", { $0.union($1) }, identity: []), database: "")
    }

    @Test func optionalCoalescingIsAMonoid() throws {
        let optionals: Gen<Int?> = oneOf([element(of: [nil]), Self.ints.map(Optional.some)])
        try forAll(Laws.monoid(optionals, "??", { $0 ?? $1 }, identity: nil), database: "")
    }

    @Test func sortedIsIdempotentAndReversedIsAnInvolution() throws {
        try forAll(Laws.idempotent(Self.lists, "sorted", { $0.sorted() }), database: "")
        try forAll(Laws.involution(Self.lists, "reversed", { $0.reversed() }), database: "")
    }

    @Test func countIsAHomomorphismFromConcatenationToAddition() throws {
        try forAll(
            Laws.homomorphism(Self.lists, "count", { $0.count }, from: "+", +, to: "+", +),
            database: "")
    }

    @Test func losslessStringConversionIsARetraction() throws {
        try forAll(
            Laws.retraction(Self.ints, to: "String", { String($0) }, from: "Int", { Int($0)! }),
            database: "")
    }

    @Test func negationIsAnIsomorphismBetweenIntsAndInts() throws {
        try forAll(
            Laws.isomorphism(Self.ints, Self.ints, to: "negate", { -$0 }, from: "negate", { -$0 }),
            database: "")
    }

    // MARK: Conformance laws on stdlib carriers

    @Test func stdlibConformancesPass() throws {
        try forAll(Laws.equatable(Self.small), database: "")
        try forAll(Laws.hashable(Self.small), database: "")
        try forAll(Laws.comparable(Self.small), database: "")
        try forAll(Laws.equatable(Self.strings), database: "")
        try forAll(Laws.hashable(Self.sets), database: "")
        try forAll(Laws.comparable(Gen<Double>.double(in: -10...10)), database: "")
    }

    @Test func stdlibCollectionsPass() throws {
        try forAll(Laws.randomAccessCollection(Self.lists), database: "")
        try forAll(Laws.bidirectionalCollection(Self.strings), database: "")
        try forAll(Laws.collection(Self.sets), database: "")
        try forAll(Laws.collection(Self.lists.map { $0.lazy.filter { $0 % 2 == 0 } }), database: "")
    }

    // MARK: Functor and lens

    @Test func arrayAndOptionalMapAreFunctors() throws {
        try forAll(Laws.functor(Self.lists) { xs, f in xs.map(f) }, database: "")
        let optionals: Gen<Int?> = oneOf([element(of: [nil]), Self.ints.map(Optional.some)])
        try forAll(Laws.functor(optionals) { x, f in x.map(f) }, database: "")
    }

    struct Settings: Equatable { var volume: Int; var name: String }

    @Test func writableKeyPathIsALens() throws {
        let states = zip(Self.ints, Self.strings).map { Settings(volume: $0, name: $1) }
        try forAll(
            Laws.lens(states, Self.ints, get: { $0.volume }, set: { s, v in var s = s; s.volume = v; return s }),
            database: "")
    }

    // MARK: Deliberate failures, pinned

    @Test func doubleAdditionIsNotAssociative() throws {
        let doubles = Gen<Double>.double(in: -10...10)
        let found = try counterexamples(Laws.monoid(doubles, "+", +, identity: 0))
        #expect(found.count == 1)
        let c = try #require(found.first)
        #expect(c.hasPrefix("suite: monoid over Double (+)\n  law: associativity\n"))
        #expect(c.contains("violated: (a + b) + c = "))
    }

    @Test func doubleWithNaNViolatesTrichotomy() throws {
        // allowNaN is only valid without bounds (libhegel's "no restriction");
        // the passing Double suite above draws a bounded range.
        let found = try counterexamples(Laws.comparable(Gen<Double>.double(allowNaN: true)))
        #expect(found.contains { $0.contains("law: trichotomy") && $0.contains("nan") })
    }

    @Test func stringCountIsNotAHomomorphism() throws {
        let strings = array(of: element(of: ["e", "\u{301}"]), count: 0...3).map { $0.joined() }
        let found = try counterexamples(
            Laws.homomorphism(strings, "count", { $0.count }, from: "+", +, to: "+", +))
        let c = try #require(found.first)
        // A tuple prints its strings with debugDescription, so U+0301 is escaped.
        #expect(c.contains("(a: \"e\", b: \"\\u{0301}\")"))
        #expect(c.contains("violated: count(a + b) = 1, count(a) + count(b) = 2"))
    }

    /// `==` ignores `cache`; `hash(into:)` includes it. The default batch
    /// finds it here even over the full `Int` range, because the engine
    /// draws boundary and small values often enough that two keys collide at
    /// 0 — but that is the engine's bias, not a guarantee. `equivalents:`
    /// is the reliable form and both report the same two laws.
    struct Memo: Hashable {
        let key: Int, cache: Int
        static func == (l: Memo, r: Memo) -> Bool { l.key == r.key }
    }

    @Test func hashableIgnoringAFieldNeedsEquivalents() throws {
        let memos = zip(Gen<Int>.int(in: Int.min...Int.max), Self.ints).map { Memo(key: $0, cache: $1) }
        let classes: Gen<[Memo]> = zip(Self.ints, array(of: Self.ints, count: 2...3))
            .map { key, caches in caches.map { Memo(key: key, cache: $0) } }
        // Default batch: the engine's bias finds it, not always in both laws.
        let byDefault = try counterexamples(Laws.hashable(memos))
        #expect(!byDefault.isEmpty)
        // Equivalence classes: both laws, the minimal class.
        let found = try counterexamples(Laws.hashable(memos, equivalents: classes))
        #expect(found.count == 2)
        #expect(found.contains {
            $0.contains("law: a == b ⇒ hash(a) == hash(b)\n  [HegelTests.LawsTests.Memo(key: 0, cache: 0), HegelTests.LawsTests.Memo(key: 0, cache: 1)]")
        })
        #expect(found.contains { $0.contains("law: Set counts ==-distinct values") && $0.contains("violated: Set(xs).count = 2, ==-distinct count = 1") })
    }

    @Test func intStringBindingIsNotALens() throws {
        let strings = array(of: element(of: ["0", "1", "a"]), count: 0...3).map { $0.joined() }
        let found = try counterexamples(
            Laws.lens(Self.ints, strings, get: { String($0) }, set: { _, v in Int(v) ?? 0 }))
        let c = try #require(found.first)
        #expect(c.hasPrefix("suite: lens Int → String\n  law: put-get\n  (s: 0, v: \"\")\nviolated: get(set(s, v)) = 0, v = "))
    }

    /// Two violated laws are two bugs: subtraction is neither associative
    /// nor left-unital, and the report names both.
    @Test func suiteWithTwoViolatedLawsReportsTwoBugs() throws {
        let found = try counterexamples(Laws.monoid(Self.ints, "-", -, identity: 0))
        #expect(found.count == 2)
        #expect(found.contains { $0.contains("law: associativity") })
        #expect(found.contains { $0.contains("law: left identity") && $0.contains("violated: 0 - a = -1, a = 1") })
    }

    // MARK: Gen's own functor laws, by replay

    /// The choice-sequence model makes functor laws checkable by equality:
    /// the same blob through `gen.map(f).map(g)` and `gen.map(g ∘ f)` is the
    /// same value. Blobs are generator-shaped, so each law's blobs come from
    /// a run of its own left-hand side that fails on purpose; both sides of
    /// an equation consume the same draws in the same order.
    @Test func genSatisfiesFunctorAndFlatMapAssociativity() throws {
        struct Probe: Error {}
        func blobs<A>(_ gen: Gen<A>) throws -> [String] {
            do {
                try forAll(gen, testCases: 20, database: "") { _ in throw Probe() }
            } catch let failure as PropertyFailure {
                return failure.failures.compactMap(\.reproduceBlob)
            }
            return []
        }
        let gen = Gen<Int>.int(in: 0...1_000_000)
        let f: @Sendable (Int) -> Int = { $0 &* 3 }
        let g: @Sendable (Int) -> Int = { $0 &+ 7 }
        let k: @Sendable (Int) -> Gen<Int> = { n in Gen<Int>.int(in: 0...max(n, 1)) }
        let h: @Sendable (Int) -> Gen<Int> = { n in Gen<Int>.int(in: n...n + 5) }

        let mapBlobs = try blobs(gen)
        try #require(!mapBlobs.isEmpty)
        for blob in mapBlobs {
            #expect(try replay(gen.map { $0 }, blob: blob) == replay(gen, blob: blob))
            #expect(try replay(gen.map(f).map(g), blob: blob) == replay(gen.map { g(f($0)) }, blob: blob))
        }
        let bindBlobs = try blobs(gen.flatMap(k).flatMap(h))
        try #require(!bindBlobs.isEmpty)
        for blob in bindBlobs {
            #expect(try replay(gen.flatMap(k).flatMap(h), blob: blob) == replay(gen.flatMap { k($0).flatMap(h) }, blob: blob))
        }
    }
}
