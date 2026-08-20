import CHegel

/// Control-flow signals and errors surfaced by libhegel calls.
///
/// Two of libhegel's "error" codes are ordinary control flow and have their
/// own cases: `stopTest` (choice budget exhausted → the runner marks the test
/// case OVERRUN) and `assume` (a precondition/filter rejected the test case →
/// the runner marks it INVALID). Everything else is a genuine error.
public enum HegelError: Error {
    /// HEGEL_E_STOP_TEST (-1): abort the test body; mark the case OVERRUN.
    case stopTest
    /// HEGEL_E_ASSUME (-2): the test case is invalid; mark it INVALID.
    case assume
    /// HEGEL_E_BACKEND (-3)
    case backend(String)
    /// HEGEL_E_INVALID_HANDLE (-4) / HEGEL_E_INVALID_ARG (-5)
    case invalidArgument(String)
    /// HEGEL_E_ALREADY_COMPLETE (-6) / HEGEL_E_NOT_COMPLETE (-7)
    case lifecycle(String)
    /// HEGEL_E_INTERNAL (-8)
    case internalError(String)
    /// HEGEL_E_CONCURRENT_USE (-9)
    case concurrentUse(String)
    /// Any code this binding does not know yet.
    case unknown(code: Int32, message: String)
}

/// Maps a `hegel_result_t` return code onto Swift control flow.
///
/// `message` supplies the diagnostic recorded on the `hegel_context_t` by
/// the failing call (empty when the call succeeded).
@inline(__always)
func check(_ code: hegel_result_t, _ message: @autoclosure () -> String) throws(HegelError) {
    switch code {
    case HEGEL_OK: return
    case HEGEL_E_STOP_TEST: throw .stopTest
    case HEGEL_E_ASSUME: throw .assume
    case HEGEL_E_BACKEND: throw .backend(message())
    case HEGEL_E_INVALID_HANDLE, HEGEL_E_INVALID_ARG: throw .invalidArgument(message())
    case HEGEL_E_ALREADY_COMPLETE, HEGEL_E_NOT_COMPLETE: throw .lifecycle(message())
    case HEGEL_E_INTERNAL: throw .internalError(message())
    case HEGEL_E_CONCURRENT_USE: throw .concurrentUse(message())
    default: throw .unknown(code: numericCast(code.rawValue), message: message())
    }
}

/// `hegel_status_t`: how a test case ended. Passed to `hegel_mark_complete`.
public enum TestCaseStatus: UInt32 {
    case valid = 0        // HEGEL_STATUS_VALID
    case invalid = 1      // HEGEL_STATUS_INVALID
    case overrun = 2      // HEGEL_STATUS_OVERRUN
    case interesting = 3  // HEGEL_STATUS_INTERESTING
}

/// `hegel_run_status_t`: the verdict of a finished run.
public enum RunStatus: UInt32 {
    case passed = 0  // HEGEL_RUN_STATUS_PASSED
    case failed = 1  // HEGEL_RUN_STATUS_FAILED
    case error = 2   // HEGEL_RUN_STATUS_ERROR — no verdict on the property
}
