import Testing
@testable import Hegel

private struct HighBug: Error {}
private struct MidBug: Error {}

@Suite struct SettingsTests {
    /// Derandomized runs with the same database key draw identical
    /// sequences with no explicit seed.
    @Test func derandomizeIsDeterministicPerKey() throws {
        func drawnValues() throws -> [Int64] {
            var values: [Int64] = []
            try forAll(
                .int(in: 0...1_000_000),
                settings: Settings(derandomize: true, database: "", databaseKey: "settings-test")
            ) { values.append($0) }
            return values
        }
        let first = try drawnValues()
        #expect(first == (try drawnValues()))
        #expect(first.count == 100)
    }

    /// With the shrink phase disabled, a failure still carries a reproduce
    /// blob, but it stays wherever generation found it (>= 10) instead of
    /// being minimized to exactly 10 — the shrink itself is what the other
    /// suite's known-minimum tests pin down.
    @Test func disablingShrinkPhaseKeepsRawCounterexample() throws {
        let gen = Gen<Int64>.int(in: 0...1000)
        do {
            try forAll(gen, settings: Settings(database: "", phases: [.generate])) { n in
                if n >= 10 { throw HegelError.internalError("n >= 10") }
            }
            Issue.record("property should have failed")
        } catch let failure as PropertyFailure {
            let blob = try #require(failure.failures.first?.reproduceBlob)
            #expect(try replay(gen, blob: blob) >= 10)
        }
    }

    /// reportMultipleFailures surfaces distinct bugs (distinct thrown error
    /// types) from one run, each shrunk to its own minimum.
    @Test func multipleFailuresAreDistinctBugs() throws {
        let gen = Gen<Int64>.int(in: 0...1000)
        do {
            try forAll(gen, settings: Settings(database: "", reportMultipleFailures: true)) { n in
                if n >= 100 { throw HighBug() }
                if n >= 10 { throw MidBug() }
            }
            Issue.record("property should have failed")
        } catch let failure as PropertyFailure {
            #expect(failure.failures.count == 2)
            let minima = Set(try failure.failures.map { f in
                try replay(gen, blob: #require(f.reproduceBlob))
            })
            #expect(minima == [10, 100])
            #expect(Set(failure.failures.map(\.origin)).count == 2)
        }
    }

    /// Single-test-case mode generates exactly one case and stops.
    @Test func singleTestCaseModeRunsOnce() throws {
        var runs = 0
        try forAll(
            .int(in: 0...1000),
            settings: Settings(database: "", mode: .singleTestCase)
        ) { _ in runs += 1 }
        #expect(runs == 1)
    }

    /// Quiet verbosity is accepted (output routing is asserted once the
    /// output callback lands).
    @Test func quietVerbosityIsAccepted() throws {
        try forAll(
            .int(in: 0...10),
            settings: Settings(database: "", verbosity: .quiet)
        ) { _ in }
    }

    /// The convenience parameters override the corresponding Settings
    /// fields.
    @Test func convenienceParametersOverrideSettings() throws {
        var runs = 0
        try forAll(
            .int(in: 0...1000),
            testCases: 7,
            settings: Settings(testCases: 500, database: "")
        ) { _ in runs += 1 }
        #expect(runs == 7)
    }
}
