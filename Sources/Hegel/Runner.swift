import CHegel

/// A shrunk counterexample: one distinct bug found by a run.
public struct Failure: Sendable {
    /// The origin string the failures were grouped under (here: the
    /// `file:line` of the failing `forAll`).
    public let origin: String
    /// Base64 choice sequence replaying the minimal counterexample.
    /// Version-pinned: only replays on the libhegel version that made it.
    public let reproduceBlob: String?
}

/// Thrown by `forAll` when the property fails (with counterexamples) or the
/// run errors (health check, flaky test — no verdict on the property).
public struct PropertyFailure: Error, CustomStringConvertible {
    public let failures: [Failure]
    public let runError: String?

    public var description: String {
        if let runError { return "hegel run errored: \(runError)" }
        let blobs = failures.compactMap(\.reproduceBlob)
        return "property failed with \(failures.count) distinct bug(s)"
            + (blobs.isEmpty ? "" : "; reproduce blobs: \(blobs.joined(separator: ", "))")
    }
}

/// Checks `property` against `testCases` generated values.
///
/// The libhegel run loop: start a run, ask for test cases, interpret each
/// through `gen`, run the body, and report VALID / INVALID / OVERRUN /
/// INTERESTING back to the engine. On failure libhegel shrinks and this
/// throws a `PropertyFailure` carrying the minimal counterexample's
/// reproduce blob.
public func forAll<A>(
    _ gen: Gen<A>,
    testCases: UInt64 = 100,
    seed: UInt64? = nil,
    database: String? = nil,
    file: StaticString = #fileID,
    line: UInt = #line,
    _ property: (A) throws -> Void
) throws {
    let ctx = Context()
    // Failures with the same origin are the same bug; the call site is the
    // stable identity of this property.
    let origin = "\(file):\(line)"

    var settings: OpaquePointer?
    try check(hegel_settings_new(ctx.raw, &settings), ctx.lastError)
    defer { _ = hegel_settings_free(ctx.raw, settings) }
    try check(hegel_settings_set_test_cases(ctx.raw, settings, testCases), ctx.lastError)
    if let seed {
        try check(hegel_settings_set_seed(ctx.raw, settings, seed, true), ctx.lastError)
    }
    if let database {
        // "" disables the example database entirely; nil keeps the engine
        // default (.hegel/examples/, auto-disabled in CI).
        try check(hegel_settings_set_database(ctx.raw, settings, database), ctx.lastError)
    }

    var run: OpaquePointer?
    try check(hegel_run_start(ctx.raw, settings, nil, nil, &run), ctx.lastError)
    defer { _ = hegel_run_free(ctx.raw, run) }

    while true {
        var rawCase: OpaquePointer?
        try check(hegel_next_test_case(ctx.raw, run, &rawCase), ctx.lastError)
        guard let rawCase else { break }  // NULL: the run is finished.
        defer { _ = hegel_test_case_free(ctx.raw, rawCase) }

        let tc = TestCase(ctx: ctx, raw: rawCase)
        let status: TestCaseStatus
        do {
            let value = try gen.run(tc)
            try property(value)
            status = .valid
        } catch HegelError.stopTest {
            status = .overrun
        } catch HegelError.assume {
            status = .invalid
        } catch {
            status = .interesting
        }
        try check(
            hegel_mark_complete(
                ctx.raw, rawCase, status.rawValue,
                status == .interesting ? origin : nil),
            ctx.lastError)
    }

    var rawResult: OpaquePointer?
    try check(hegel_run_result(ctx.raw, run, &rawResult), ctx.lastError)
    defer { _ = hegel_run_result_free(ctx.raw, rawResult) }

    var rawStatus: hegel_run_status_t = HEGEL_RUN_STATUS_PASSED
    try check(hegel_run_result_status(ctx.raw, rawResult, &rawStatus), ctx.lastError)

    switch RunStatus(rawValue: rawStatus.rawValue) {
    case .passed, nil:
        return
    case .error:
        var message: UnsafePointer<CChar>?
        _ = hegel_run_result_error(ctx.raw, rawResult, &message)
        throw PropertyFailure(
            failures: [],
            runError: message.map { String(cString: $0) } ?? "unknown run error")
    case .failed:
        var count = 0
        try check(hegel_run_result_failure_count(ctx.raw, rawResult, &count), ctx.lastError)
        var failures: [Failure] = []
        for index in 0..<count {
            var rawFailure: OpaquePointer?
            try check(hegel_run_result_failure(ctx.raw, rawResult, index, &rawFailure), ctx.lastError)
            defer { _ = hegel_failure_free(ctx.raw, rawFailure) }
            var originPtr: UnsafePointer<CChar>?
            var blobPtr: UnsafePointer<CChar>?
            _ = hegel_failure_origin(ctx.raw, rawFailure, &originPtr)
            _ = hegel_failure_reproduction_blob(ctx.raw, rawFailure, &blobPtr)
            failures.append(Failure(
                origin: originPtr.map { String(cString: $0) } ?? origin,
                reproduceBlob: blobPtr.map { String(cString: $0) }))
        }
        throw PropertyFailure(failures: failures, runError: nil)
    }
}

// TODO: replay(blob:) via hegel_test_case_from_blob — rerun a stored
//       counterexample so the frontend can display the drawn values.
// TODO: surface more settings (seed, database path/key, phases,
//       report_multiple_failures) as forAll parameters or a Settings struct.
// TODO: route libhegel's output callback into a Swift closure instead of
//       leaving it on stderr.
