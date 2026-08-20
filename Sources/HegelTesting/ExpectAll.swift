import Testing
import os
@_exported import Hegel

/// Signal thrown into the run loop when the property body recorded a Swift
/// Testing issue: the engine sees it as INTERESTING and shrinks.
private struct ExpectationViolation: Error {}

/// Set on the current task while `expectAll` is searching/shrinking. The
/// `.propertyTesting` trait reads it to suppress (and count) the storm of
/// intermediate expectation failures the search inevitably records.
enum ExpectAllSearch {
    @TaskLocal static var violationFlag: OSAllocatedUnfairLock<Bool>?
}

extension Trait where Self == IssueHandlingTrait {
    /// Attach to tests that use `expectAll`: intermediate `#expect` failures
    /// recorded while the engine searches and shrinks are counted for the
    /// engine but dropped from the test's results, so a failing property
    /// reports exactly two issues — the minimal counterexample summary and
    /// the body's own expectation failure replayed at that input — instead
    /// of one per probed case. Without the trait `expectAll` still works;
    /// the intermediate failures just show up as (non-failing) known issues.
    public static var propertyTesting: Self {
        .compactMapIssues { issue in
            guard let flag = ExpectAllSearch.violationFlag else { return issue }
            flag.withLock { $0 = true }
            return nil
        }
    }
}

/// `forAll` for Swift Testing bodies: `#expect` failures shrink.
///
/// Plain `forAll` needs the property to *throw* on violation — a bare
/// `#expect` records an issue but returns normally, so the engine counts the
/// case as valid and never shrinks it (the adhan dogfood lesson). `expectAll`
/// closes that gap: issues recorded by the body are intercepted and bridged
/// into thrown signals the engine shrinks on. When the run fails, the shrunk
/// counterexample and its reproduce blob are surfaced with `Issue.record`,
/// and the body is replayed once at the minimal input with interception off,
/// so the genuine `#expect` failure lands in the test results pointing at
/// the exact expectation that broke.
///
/// Pair with `@Test(.propertyTesting)` to keep the search phase out of the
/// test's recorded issues entirely.
///
/// Thrown errors still work exactly as in `forAll`: `HegelError.assume`
/// rejects the case (INVALID), any other error is a violation (INTERESTING).
/// Unlike `forAll`, `expectAll` does not throw — like `#expect` itself, it
/// records and returns, one bug per distinct origin.
public func expectAll<A>(
    _ gen: Gen<A>,
    testCases: UInt64 = 100,
    seed: UInt64? = nil,
    database: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ property: (A) throws -> Void
) {
    let origin = "\(sourceLocation.fileID):\(sourceLocation.line)"
    let flag = OSAllocatedUnfairLock(initialState: false)
    do {
        try ExpectAllSearch.$violationFlag.withValue(flag) {
            try forAll(
                gen, testCases: testCases, seed: seed, database: database,
                origin: origin
            ) { value in
                // Two interception layers, whichever is installed wins:
                // the .propertyTesting trait swallows the issue and sets
                // `flag`; without it, withKnownIssue records the issue as
                // known (non-failing, but visible) and the matcher fires.
                // Errors the body *throws* are control flow for the engine
                // (assume/stopTest/violation) and must reach the runner
                // unswallowed, so they bypass the interception.
                flag.withLock { $0 = false }
                var thrown: (any Error)?
                withKnownIssue(isIntermittent: true) {
                    do { try property(value) } catch { thrown = error }
                } matching: { _ in
                    flag.withLock { $0 = true }
                    return true
                }
                if let thrown { throw thrown }
                if flag.withLock({ $0 }) { throw ExpectationViolation() }
            }
        }
    } catch let failure as PropertyFailure {
        if let runError = failure.runError {
            Issue.record("hegel run errored: \(runError)", sourceLocation: sourceLocation)
            return
        }
        for f in failure.failures {
            Issue.record(
                """
                property failed; minimal counterexample: \
                \(f.counterexample ?? "<unavailable>")\
                \(f.reproduceBlob.map { "\n reproduce blob: \($0)" } ?? "")
                """,
                sourceLocation: sourceLocation)
            // Replay the minimal case with interception off: the body's own
            // #expect failure is recorded at the shrunk input, pointing at
            // the exact expectation that broke.
            guard let blob = f.reproduceBlob, let value = try? replay(gen, blob: blob) else {
                continue
            }
            do { try property(value) } catch {
                Issue.record(error, sourceLocation: sourceLocation)
            }
        }
    } catch {
        // Engine-level error (bad settings, backend failure) — not a verdict.
        Issue.record(error, sourceLocation: sourceLocation)
    }
}
