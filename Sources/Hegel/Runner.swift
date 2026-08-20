import CHegel

/// Carries a Swift closure across the C callback boundary. The trampoline
/// below recovers it from the `user_data` pointer.
final class OutputBox {
    let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }
}

/// The C-convention trampoline libhegel invokes once per output line. Runs
/// on whichever thread is inside `hegel_next_test_case` (ours), and must
/// not call back into libhegel on the same run.
let outputTrampoline: hegel_output_callback_t = { userData, line, len in
    guard let userData, let line else { return }
    let box = Unmanaged<OutputBox>.fromOpaque(userData).takeUnretainedValue()
    box.handler(String(
        decoding: UnsafeRawBufferPointer(start: line, count: len), as: UTF8.self))
}

/// A shrunk counterexample: one distinct bug found by a run.
public struct Failure: Sendable {
    /// The origin string the failures were grouped under (here: the
    /// `file:line` of the failing `forAll`).
    public let origin: String
    /// Base64 choice sequence replaying the minimal counterexample.
    /// Version-pinned: only replays on the libhegel version that made it.
    public let reproduceBlob: String?
    /// The minimal counterexample itself, recovered by replaying the blob
    /// through the generator. `String(describing:)` of the value.
    public let counterexample: String?
}

/// Thrown by `forAll` when the property fails (with counterexamples) or the
/// run errors (health check, flaky test — no verdict on the property).
public struct PropertyFailure: Error, CustomStringConvertible {
    public let failures: [Failure]
    public let runError: String?

    public var description: String {
        if let runError { return "hegel run errored: \(runError)" }
        let lines = failures.map { f in
            "  counterexample: \(f.counterexample ?? "<unavailable>")"
                + (f.reproduceBlob.map { "\n  reproduce blob: \($0)" } ?? "")
        }
        return "property failed with \(failures.count) distinct bug(s)\n"
            + lines.joined(separator: "\n")
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
    testCases: UInt64? = nil,
    seed: UInt64? = nil,
    database: String? = nil,
    settings: Settings = Settings(),
    output: ((String) -> Void)? = nil,
    origin explicitOrigin: String? = nil,
    file: StaticString = #fileID,
    line: UInt = #line,
    _ property: (A) throws -> Void
) throws {
    // The convenience parameters override the corresponding Settings
    // fields, so the common knobs stay one label away.
    var settings = settings
    if let testCases { settings.testCases = testCases }
    if let seed { settings.seed = seed }
    if let database { settings.database = database }

    // Engine output (per Settings.verbosity) goes to `output` line by line
    // instead of stderr. The box must outlive the run: lines are emitted
    // inside hegel_next_test_case calls, so pin it until after run free
    // (defers run in reverse order — this one is declared first).
    let outputBox = output.map(OutputBox.init)
    defer { withExtendedLifetime(outputBox) {} }

    let ctx = Context()
    // Failures with the same origin are the same bug; the call site is the
    // stable identity of this property. Wrappers (HegelTesting's expectAll)
    // pass their own caller's location through `origin`.
    let origin = explicitOrigin ?? "\(file):\(line)"

    let rawSettings = try settings.makeHandle(ctx)
    defer { _ = hegel_settings_free(ctx.raw, rawSettings) }

    var run: OpaquePointer?
    try check(
        hegel_run_start(
            ctx.raw, rawSettings,
            outputBox == nil ? nil : outputTrampoline,
            outputBox.map { Unmanaged.passUnretained($0).toOpaque() },
            &run),
        ctx.lastError)
    defer { _ = hegel_run_free(ctx.raw, run) }

    while true {
        var rawCase: OpaquePointer?
        try check(hegel_next_test_case(ctx.raw, run, &rawCase), ctx.lastError)
        guard let rawCase else { break }  // NULL: the run is finished.
        defer { _ = hegel_test_case_free(ctx.raw, rawCase) }

        let tc = TestCase(ctx: ctx, raw: rawCase)

        // Generation first, handled separately from the property: an error
        // out of a draw is not a verdict on the property. Control flow maps
        // to OVERRUN/INVALID; anything else (an FFI failure, a broken
        // generator) aborts the run rather than masquerading as a
        // counterexample. hegel_run_free completes the in-flight case.
        let value: A
        do {
            value = try gen.run(tc)
        } catch HegelError.stopTest {
            try check(
                hegel_mark_complete(ctx.raw, rawCase, TestCaseStatus.overrun.rawValue, nil),
                ctx.lastError)
            continue
        } catch HegelError.assume {
            try check(
                hegel_mark_complete(ctx.raw, rawCase, TestCaseStatus.invalid.rawValue, nil),
                ctx.lastError)
            continue
        }

        let status: TestCaseStatus
        var bugOrigin: String?
        do {
            try property(value)
            status = .valid
        } catch HegelError.stopTest {
            status = .overrun
        } catch HegelError.assume {
            status = .invalid
        } catch {
            status = .interesting
            // Suffix the thrown error's type so different failure modes of
            // one property count as distinct bugs — that is what makes
            // reportMultipleFailures able to report more than one.
            bugOrigin = "\(origin) [\(String(reflecting: type(of: error)))]"
        }
        try check(
            hegel_mark_complete(ctx.raw, rawCase, status.rawValue, bugOrigin),
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
            let blob = blobPtr.map { String(cString: $0) }
            // Recover the shrunk value for display by replaying the blob
            // through the same generator. Best-effort: a replay failure
            // leaves the blob as the fallback.
            let counterexample = blob.flatMap { b in
                (try? replay(gen, blob: b)).map { String(describing: $0) }
            }
            failures.append(Failure(
                origin: originPtr.map { String(cString: $0) } ?? origin,
                reproduceBlob: blob,
                counterexample: counterexample))
        }
        throw PropertyFailure(failures: failures, runError: nil)
    }
}

