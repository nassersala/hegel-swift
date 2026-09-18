import Testing
@testable import Hegel

/// The error a failure reports must come from its shrunk counterexample.
/// The engine keeps executing shrink candidates that fail but are not
/// smaller after it has found the minimum, so "the last error seen" is
/// usually a larger case's; the report re-runs the property on the
/// replayed blob instead.
@Suite struct ReportedErrorTests {
    struct Fail: Error { let x: Int }

    @Test func errorComesFromTheShrunkCase() throws {
        for seed in 1...20 {
            do {
                try forAll(Gen<Int>.int(in: 0...100_000), testCases: 100, seed: UInt64(seed), database: "") { x in
                    if x >= 10 { throw Fail(x: x) }
                }
                Issue.record("seed \(seed) did not fail")
            } catch let f as PropertyFailure {
                #expect(f.failures.count == 1)
                #expect(f.failures.first?.counterexample == "10")
                #expect((f.failures.first?.error as? Fail)?.x == 10, "seed \(seed)")
            }
        }
    }

    @Test func asyncErrorComesFromTheShrunkCase() async throws {
        for seed in 1...10 {
            do {
                try await forAll(Gen<Int>.int(in: 0...100_000), testCases: 100, seed: UInt64(seed), database: "") { x in
                    if x >= 10 { throw Fail(x: x) }
                }
                Issue.record("seed \(seed) did not fail")
            } catch let f as PropertyFailure {
                #expect((f.failures.first?.error as? Fail)?.x == 10, "seed \(seed)")
            }
        }
    }

    /// Draws made inside the property are part of the blob, so the re-run
    /// sees the same ones.
    @Test func drawsInsideThePropertyReplay() throws {
        struct Pair: Error { let x: Int; let y: Int64 }
        do {
            try forAll(Gen<Int>.int(in: 0...1000), testCases: 100, seed: 1, database: "") { x, tc in
                let y = try tc.drawInteger(in: Int64(0)...1000)
                if x + Int(y) >= 10 { throw Pair(x: x, y: y) }
            }
            Issue.record("did not fail")
        } catch let f as PropertyFailure {
            let bug = try #require(f.failures.first)
            let error = try #require(bug.error as? Pair)
            #expect(bug.counterexample == String(error.x))
            #expect(error.x + Int(error.y) == 10)
        }
    }
}
