import Testing
import os
@testable import Hegel

// Targeted PBT (hegel_target): the engine hill-climbs toward higher
// recorded scores. The list-sum landscape is where it shines: generation
// biases toward short lists, so sum >= 800 over 0...10 elements is
// essentially unreachable by random search (0/20 unseeded 200-case runs)
// but routinely reached with targeting (18/20). Both tests below are
// seeded, making the contrast deterministic against the vendored engine.
//
// Honest limitation, measured on Die Hard: a deceptive gradient
// (maximize -|big - 4|, where big=3 and big=5 both score -1 but sit far
// from the solution structurally) made discovery WORSE than random
// search. Targeting needs a landscape whose gradient actually points at
// the bug.

@Suite struct TargetTests {
    @Test func targetingClimbsToRareSums() throws {
        let lists = array(of: Gen<Int64>.int(in: 0...10), count: 0...200)
        do {
            try forAll(lists, testCases: 200, seed: 1, database: "") { (xs: [Int64], tc: TestCase) in
                let sum = xs.reduce(0, +)
                try tc.target(Double(sum))
                if sum >= 800 { throw HegelError.internalError("sum >= 800") }
            }
            Issue.record("targeting should have driven the sum to 800")
        } catch let failure as PropertyFailure {
            // The shrunk counterexample is locally minimal: exactly 800.
            let blob = try #require(failure.failures.first?.reproduceBlob)
            let shrunk = try replay(lists, blob: blob)
            #expect(shrunk.reduce(0, +) == 800)
        }
    }

    /// The same search without targeting never gets close — the contrast
    /// that justifies the feature. (Deterministic under the same seed.)
    @Test func randomSearchMissesRareSums() throws {
        try forAll(
            array(of: Gen<Int64>.int(in: 0...10), count: 0...200),
            testCases: 200, seed: 1, database: ""
        ) { (xs: [Int64]) in
            if xs.reduce(0, +) >= 800 { throw HegelError.internalError("sum >= 800") }
        }
    }

    /// Stateful plumbing: maximize is scored on the initial state and
    /// after every step, and the run completes normally.
    @Test func statefulMaximizeIsObserved() throws {
        let observations = OSAllocatedUnfairLock(initialState: 0)
        try forAll(
            initial: Gen<Int> { _ in 0 },
            rules: [Rule("inc") { state, _ in state += 1 }],
            maximize: { state in
                observations.withLock { $0 += 1 }
                return Double(state)
            },
            testCases: 20,
            database: "")
        #expect(observations.withLock { $0 } > 20)
    }
}
