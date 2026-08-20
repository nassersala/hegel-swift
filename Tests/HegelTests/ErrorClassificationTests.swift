import Testing
@testable import Hegel

// Regression tests for review findings: errors from generation must abort
// the run (not masquerade as counterexamples), rejected stateful rules must
// leave no state behind, and invalid temporal bounds must throw instead of
// trapping.

private struct GeneratorBroke: Error {}
private struct LeakObserved: Error {}

@Suite struct ErrorClassificationTests {
    /// A custom generator that errors mid-draw aborts the run with its own
    /// error — it must NOT be shrunk and reported as a PropertyFailure.
    @Test func generatorErrorsAbortTheRun() {
        let broken = Gen<Int64> { _ in throw GeneratorBroke() }
        #expect(throws: GeneratorBroke.self) {
            try forAll(broken, database: "") { _ in }
        }
    }

    /// Same for FFI-level errors: an empty alphabet makes
    /// hegel_string_generator_text return INVALID_ARG inside the draw.
    @Test func ffiErrorsInsideDrawsAbortTheRun() {
        #expect(throws: HegelError.self) {
            try forAll(.string(count: 1...8, categories: []), database: "") { _ in }
        }
    }

    /// The same error thrown by the PROPERTY is still a violation.
    @Test func propertyErrorsAreStillViolations() {
        #expect(throws: PropertyFailure.self) {
            try forAll(.int(in: 0...100), database: "") { _ in throw GeneratorBroke() }
        }
    }

    /// A stateful rule that mutates and then rejects (assume) rolls its
    /// mutation back: the engine is told the step never happened, so the
    /// state must agree.
    @Test func rejectedRuleLeavesNoStateBehind() throws {
        try forAll(
            initial: Gen<Int> { _ in 0 },
            rules: [
                Rule("inc") { state, _ in state += 1 },
                Rule("mutateThenReject") { state, _ in
                    state += 1000
                    throw HegelError.assume
                },
            ],
            invariants: [
                Invariant("no leaked mutation") { state in
                    if state >= 1000 { throw LeakObserved() }
                }
            ],
            database: "")
    }

    /// Out-of-domain temporal bounds throw invalidArgument instead of
    /// trapping in a fixed-width conversion.
    @Test func invalidTemporalBoundsThrowInsteadOfTrapping() {
        #expect(throws: HegelError.self) {
            try forAll(.time(in: TimeOfDay(hour: -1, minute: 0) ... .endOfDay), database: "") { _ in }
        }
        #expect(throws: HegelError.self) {
            try forAll(
                .date(in: CalendarDate(year: 2000, month: 1, day: 1)
                    ... CalendarDate(year: 2000, month: 99, day: 1)),
                database: ""
            ) { _ in }
        }
    }
}
