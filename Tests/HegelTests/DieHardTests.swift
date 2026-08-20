import Testing
@testable import Hegel

// The Die Hard jug puzzle as a stateful property, after the classic TLA+
// example and https://hypothesis.works/articles/how-not-to-die-hard-with-hypothesis/:
// a 3-gallon jug, a 5-gallon jug, and the "invariant" that the big jug
// never holds exactly 4 gallons. The invariant is false — the puzzle has a
// solution — so the run must fail, and the shrunk counterexample must be
// the solution itself: the unique minimal 6-step pour sequence.

private struct Jugs: CustomStringConvertible {
    var small = 0  // capacity 3
    var big = 0    // capacity 5
    var description: String { "(small: \(small), big: \(big))" }
}

private struct DieHardSolved: Error {}
private struct PhysicsViolated: Error {}

@Suite struct DieHardTests {
    @Test func shrinkerSolvesDieHard() throws {
        do {
            try forAll(
                initial: Gen<Jugs> { _ in Jugs() },
                rules: [
                    Rule("fill small") { jugs, _ in jugs.small = 3 },
                    Rule("fill big") { jugs, _ in jugs.big = 5 },
                    Rule("empty small") { jugs, _ in jugs.small = 0 },
                    Rule("empty big") { jugs, _ in jugs.big = 0 },
                    Rule("pour small into big") { jugs, _ in
                        let amount = min(jugs.small, 5 - jugs.big)
                        jugs.small -= amount
                        jugs.big += amount
                    },
                    Rule("pour big into small") { jugs, _ in
                        let amount = min(jugs.big, 3 - jugs.small)
                        jugs.big -= amount
                        jugs.small += amount
                    },
                ],
                invariants: [
                    Invariant("physics") { jugs in
                        guard (0...3).contains(jugs.small), (0...5).contains(jugs.big) else {
                            throw PhysicsViolated()
                        }
                    },
                    Invariant("big is never 4") { jugs in
                        if jugs.big == 4 { throw DieHardSolved() }
                    },
                ],
                // Generation biases stateful walks toward short runs, so
                // unseeded discovery misses big == 4 in ~8% of 3000-case
                // runs. Seeded, discovery and shrink are deterministic:
                // seeds 1-10 all solve, and 9 of them shrink to the
                // canonical 6-step solution (seed 7 lands in the valid
                // 8-step small-jug alternative — a local minimum).
                testCases: 3000,
                seed: 1,
                database: "")
            Issue.record("the engine failed to solve Die Hard")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            // Rule lines sit between "initial: ..." and the invariant/
            // violation tail.
            let steps = trace.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("initial:") && !$0.hasPrefix("invariant") && !$0.hasPrefix("violated:") }
            #expect(steps == [
                "fill big",
                "pour big into small",
                "empty small",
                "pour big into small",
                "fill big",
                "pour big into small",
            ])
        }
    }
}
