import CHegel
import Testing
@testable import Hegel

/// The Swift enums that mirror a C enum carry its raw values as literals,
/// because a raw-value enum cannot take them from the imported constants.
/// libhegel 0.43 swapped HEGEL_VERBOSITY_QUIET and HEGEL_VERBOSITY_NORMAL,
/// which compiles and links and silently means the other thing. Each
/// mirror is held to the header here.
@Suite struct AbiMirrorTests {
    @Test func verbosity() {
        #expect(Settings.Verbosity.normal.rawValue == HEGEL_VERBOSITY_NORMAL.rawValue)
        #expect(Settings.Verbosity.quiet.rawValue == HEGEL_VERBOSITY_QUIET.rawValue)
        #expect(Settings.Verbosity.verbose.rawValue == HEGEL_VERBOSITY_VERBOSE.rawValue)
        #expect(Settings.Verbosity.debug.rawValue == HEGEL_VERBOSITY_DEBUG.rawValue)
    }

    @Test func phases() {
        #expect(Settings.Phases.explicit.rawValue == HEGEL_PHASE_EXPLICIT.rawValue)
        #expect(Settings.Phases.reuse.rawValue == HEGEL_PHASE_REUSE.rawValue)
        #expect(Settings.Phases.generate.rawValue == HEGEL_PHASE_GENERATE.rawValue)
        #expect(Settings.Phases.target.rawValue == HEGEL_PHASE_TARGET.rawValue)
        #expect(Settings.Phases.shrink.rawValue == HEGEL_PHASE_SHRINK.rawValue)
        #expect(Settings.Phases.all.rawValue == HEGEL_PHASE_ALL.rawValue)
    }

    @Test func testCaseStatus() {
        #expect(TestCaseStatus.valid.rawValue == HEGEL_STATUS_VALID.rawValue)
        #expect(TestCaseStatus.invalid.rawValue == HEGEL_STATUS_INVALID.rawValue)
        #expect(TestCaseStatus.overrun.rawValue == HEGEL_STATUS_OVERRUN.rawValue)
        #expect(TestCaseStatus.interesting.rawValue == HEGEL_STATUS_INTERESTING.rawValue)
    }

    @Test func runStatus() {
        #expect(RunStatus.passed.rawValue == HEGEL_RUN_STATUS_PASSED.rawValue)
        #expect(RunStatus.failed.rawValue == HEGEL_RUN_STATUS_FAILED.rawValue)
        #expect(RunStatus.error.rawValue == HEGEL_RUN_STATUS_ERROR.rawValue)
        #expect(RunStatus.failedNondeterministic.rawValue == HEGEL_RUN_STATUS_FAILED_NONDETERMINISTIC.rawValue)
    }

    /// `TestCase.label(_:)` computes the FNV-1a hash in Swift rather than
    /// crossing the FFI for a constant; libhegel's is the definition.
    @Test func labelIsLibhegelsHash() throws {
        let ctx = Context()
        for name in ["", "a", "hegel-swift.list", "hegel-swift.stateful.rule", "hegel.vec", "naïve ✓"] {
            var expected: UInt64 = 0
            try check(hegel_label_from_name(ctx.raw, name, &expected), ctx.lastError)
            #expect(TestCase.label(name) == expected, "\(name)")
        }
    }

    @Test func combinedLabelIsLibhegelsHash() throws {
        let ctx = Context()
        let a = TestCase.label("hegel-swift.list"), b = TestCase.label("Swift.Int64")
        for labels in [[], [a], [a, b], [b, a], [a, b, a], [0, .max]] as [[UInt64]] {
            var expected: UInt64 = 0
            try check(hegel_label_combine(ctx.raw, labels, labels.count, &expected), ctx.lastError)
            #expect(TestCase.label(combining: labels) == expected, "\(labels)")
        }
        #expect(TestCase.label(combining: [a]) != a)
        #expect(TestCase.label(combining: [a, b]) != TestCase.label(combining: [b, a]))
    }
}
