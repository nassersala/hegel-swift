import Testing
@testable import Hegel

@Suite struct OutputTests {
    /// With an output closure installed, engine output arrives there as
    /// whole lines instead of stderr.
    @Test func verboseOutputArrivesLineByLine() throws {
        var lines: [String] = []
        try forAll(
            .int(in: 0...100),
            settings: Settings(testCases: 5, database: "", verbosity: .verbose),
            output: { lines.append($0) }
        ) { _ in }
        #expect(!lines.isEmpty)
        // Lines arrive without trailing newlines, per the ABI contract.
        #expect(lines.allSatisfy { !$0.hasSuffix("\n") })
    }

    /// Failing runs narrate through the same channel (shrink progress,
    /// final verdict) — and the run still reports its failure normally.
    @Test func failingRunNarratesAndStillThrows() {
        var lines: [String] = []
        #expect(throws: PropertyFailure.self) {
            try forAll(
                .int(in: 0...1000),
                settings: Settings(database: "", verbosity: .verbose),
                output: { lines.append($0) }
            ) { n in
                if n >= 10 { throw HegelError.internalError("n >= 10") }
            }
        }
        #expect(!lines.isEmpty)
    }

    /// Quiet verbosity keeps the channel silent on a passing run.
    @Test func quietPassingRunEmitsNothing() throws {
        var lines: [String] = []
        try forAll(
            .int(in: 0...100),
            settings: Settings(testCases: 5, database: "", verbosity: .quiet),
            output: { lines.append($0) }
        ) { _ in }
        #expect(lines.isEmpty)
    }
}
