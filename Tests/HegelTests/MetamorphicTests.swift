import Testing
@testable import Hegel

// Metamorphic relations: the subject under test is a plain function; the
// relations are values; a violation must shrink to the minimal metamorphic
// group and name the violated relation.

private struct Boom: Error {}

@Suite struct MetamorphicTests {
    static let ints = Gen<Int64>.int(in: -1000...1000)
    static let lists = array(of: Gen<Int64>.int(in: -50...50), count: 0...20)

    /// Permutation invariance of sorting (the "symmetry" pattern): reversing
    /// the input leaves the sorted output unchanged.
    @Test func sortIsInvariantUnderReversal() throws {
        try forAll(
            source: Self.lists,
            relations: [
                .invariant("reversed input, same sorted output") { xs, _ in xs.reversed() }
            ],
            database: ""
        ) { xs in xs.sorted() }
    }

    /// A true relation over inputs and outputs: doubling is additive.
    @Test func trueRelationOverInputsAndOutputsPasses() throws {
        try forAll(
            source: Self.ints,
            relations: [
                Relation("f(x + k) == f(x) + 2k",
                    followUp: { x, tc in x + (try tc.drawInteger(in: 0...100)) },
                    relates: { x, fx, x2, fx2 in
                        guard fx2 == fx + 2 * (x2 - x) else { throw RelationViolated("not additive") }
                    })
            ],
            database: ""
        ) { x in 2 * x }
    }

    /// A false relation fails, shrinks to the minimal group (source 0, the
    /// smallest follow-up that differs), and the counterexample names the
    /// relation and displays all four parts of the group.
    @Test func falseRelationShrinksToMinimalGroup() throws {
        do {
            try forAll(
                source: Gen<Int64>.int(in: 0...1000),
                relations: [
                    Relation("f(x + k) == f(x) + 2k",
                        followUp: { x, tc in x + (try tc.drawInteger(in: 0...100)) },
                        relates: { x, fx, x2, fx2 in
                            guard fx2 == fx + 2 * (x2 - x) else { throw RelationViolated("not additive") }
                        }),
                    .invariant("doubling is invariant under +1 (false)") { x, _ in x + 1 },
                ],
                testCases: 300,
                database: ""
            ) { x in 2 * x }
            Issue.record("the false relation should have failed")
        } catch let failure as PropertyFailure {
            let group = try #require(failure.failures.first?.counterexample)
            #expect(group.contains("relation: doubling is invariant under +1 (false)"))
            #expect(group.contains("source:       0\n"))
            #expect(group.contains("follow-up:    1\n"))
            #expect(group.contains("f(source):    0\n"))
            #expect(group.contains("f(follow-up): 2\n"))
            #expect(group.contains("violated: outputs differ"))
        }
    }

    /// The change-direction pattern: squaring is non-decreasing on the
    /// non-negatives, and claiming non-increasing fails with a message that
    /// shows both values.
    @Test func monotonePattern() throws {
        let nonNegative = Gen<Int64>.int(in: 0...1000)
        let bump: @Sendable (Int64, TestCase) throws -> Int64 = { x, tc in
            x + (try tc.drawInteger(in: 1...10))
        }
        try forAll(
            source: nonNegative,
            relations: [.monotone("square grows with x", followUp: bump, { $0 }, .nonDecreasing)],
            database: ""
        ) { x in x * x }

        do {
            try forAll(
                source: nonNegative,
                relations: [.monotone("square shrinks with x (false)", followUp: bump, { $0 }, .nonIncreasing)],
                testCases: 300,
                database: ""
            ) { x in x * x }
            Issue.record("the false monotone relation should have failed")
        } catch let failure as PropertyFailure {
            let group = try #require(failure.failures.first?.counterexample)
            #expect(group.contains("violated: expected non-increasing, got 0 then 1"))
        }
    }

    /// `HegelError.assume` in a follow-up transform rejects the case rather
    /// than failing it: a relation that applies only to even sources.
    @Test func assumeInFollowUpRejectsTheCase() throws {
        try forAll(
            source: Self.ints,
            relations: [
                Relation("halving an even number, then doubling, is the identity",
                    followUp: { x, _ in
                        guard x % 2 == 0 else { throw HegelError.assume }
                        return x / 2
                    },
                    relates: { x, _, x2, _ in
                        guard x2 * 2 == x else { throw RelationViolated("not halved") }
                    })
            ],
            database: ""
        ) { x in x }
    }

    /// A subject that throws on an input is a violation, and the group shows
    /// which execution had no output.
    @Test func subjectThrowingIsAViolation() throws {
        do {
            try forAll(
                source: Gen<Int64>.int(in: 0...100),
                relations: [.invariant("identity under +1 (not the point)") { x, _ in x + 1 }],
                testCases: 300,
                database: ""
            ) { x in
                if x == 5 { throw Boom() }
                return 0 as Int64
            }
            Issue.record("the throwing subject should have failed")
        } catch let failure as PropertyFailure {
            let group = try #require(failure.failures.first?.counterexample)
            // Minimal: the source 4 is fine, the follow-up 5 throws.
            #expect(group.contains("source:       4\n"))
            #expect(group.contains("follow-up:    5\n"))
            #expect(group.contains("f(follow-up): <none: subject threw>"))
            #expect(group.contains("violated: Boom()"))
        }
    }
}
