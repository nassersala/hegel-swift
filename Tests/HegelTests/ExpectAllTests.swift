import Testing
import os
import HegelTesting

/// The known-issue matcher is @Sendable; collect issue descriptions behind a lock.
private typealias IssueLog = OSAllocatedUnfairLock<[String]>

// The whole point of expectAll: bare #expect failures inside the body must
// drive the engine (INTERESTING → shrink) instead of silently passing.

@Suite struct ExpectAllTests {
    @Test func passingExpectationsJustPass() {
        expectAll(.int(in: -5...5), database: "") { n in
            #expect((-5...5).contains(n))
        }
    }

    /// A failing #expect must shrink to the known minimal counterexample
    /// (10, same false property as the core shrink test) and surface it via
    /// Issue.record — asserted by intercepting the recorded issues.
    @Test func failingExpectationShrinksToMinimum() {
        let log = IssueLog(initialState: [])
        withKnownIssue(isIntermittent: true) {
            // Narrow range: every failing search probe becomes a (visible)
            // known issue on this trait-less path, so keep the count small.
            expectAll(.int(in: 0...15), database: "") { n in
                #expect(n < 10)
            }
        } matching: { issue in
            log.withLock { $0.append(String(describing: issue)) }
            return true
        }
        let issues = log.withLock { $0 }
        // One summary record naming the shrunk value + blob, then the
        // replayed #expect failure at exactly that input.
        #expect(issues.contains { $0.contains("minimal counterexample: 10") })
        #expect(issues.contains { $0.contains("reproduce blob:") })
        #expect(issues.contains { $0.contains("(n → 10) < 10") })
    }

    /// With the .propertyTesting trait, the search phase is silent: a
    /// failing property records exactly two issues — the counterexample
    /// summary and the replayed expectation failure — not one per probe.
    @Test(.propertyTesting) func traitSuppressesSearchPhaseIssues() {
        let log = IssueLog(initialState: [])
        withKnownIssue(isIntermittent: true) {
            expectAll(.int(in: 0...1000), database: "") { n in
                #expect(n < 10)
            }
        } matching: { issue in
            log.withLock { $0.append(String(describing: issue)) }
            return true
        }
        let issues = log.withLock { $0 }
        #expect(issues.count == 2)
        #expect(issues.contains { $0.contains("minimal counterexample: 10") })
        #expect(issues.contains { $0.contains("(n → 10) < 10") })
    }

    /// Thrown errors keep working through expectAll, same as forAll.
    @Test func thrownViolationsAlsoShrink() {
        let log = IssueLog(initialState: [])
        withKnownIssue(isIntermittent: true) {
            expectAll(.int(in: 0...1000), database: "") { n in
                if n >= 10 { throw HegelError.internalError("n >= 10") }
            }
        } matching: { issue in
            log.withLock { $0.append(String(describing: issue)) }
            return true
        }
        let issues = log.withLock { $0 }
        #expect(issues.contains { $0.contains("minimal counterexample: 10") })
    }

    /// HegelError.assume thrown from the body must stay a rejection
    /// (INVALID, redrawn), not get misread as a violation.
    @Test func assumeStillRejectsInsteadOfFailing() {
        expectAll(.int(in: 0...100), database: "") { n in
            guard n % 2 == 0 else { throw HegelError.assume }
            #expect(n % 2 == 0)
        }
    }

    /// Filters on the generator (assume below the body) are untouched.
    @Test func generatorFiltersAreUntouched() {
        expectAll(Gen<Int64>.int(in: 0...100).filter { $0 % 2 == 0 }, database: "") { n in
            #expect(n % 2 == 0)
        }
    }
}
