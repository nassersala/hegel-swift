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

/// Thrown by the async `forAll` when one property invocation exceeds its
/// `timeout`. Not a verdict on the property: a hang is neither a pass nor
/// a shrinkable counterexample, so the run is abandoned instead.
///
/// The timeout is delivered by cancelling the property's task, so it can
/// only fire once the property reaches a cancellation-aware suspension
/// point (`Task.sleep`, a checked continuation that honours cancellation,
/// any structured child that does). A property that ignores cancellation
/// still hangs; that is Swift's cooperative model, not something the
/// runner can override.
public struct PropertyTimeout: Error, CustomStringConvertible {
    public let origin: String
    public let timeout: Duration
    public var description: String {
        "property at \(origin) did not complete within \(timeout)"
    }
}

// MARK: - Run plumbing shared by the sync and async loops

/// One libhegel run: settings, output callback, run handle, and the
/// generation/verdict/report logic that does not depend on whether the
/// property is synchronous. The loops in `forAll` are thin on top of it.
///
/// Not `Sendable`, and not meant to be: the run stays on one task and
/// draws stay sequential, which is all the engine's threading contract
/// asks (a test-case handle may be driven by one thread at a time; it does
/// not care which thread, so resuming after `await` elsewhere is fine).
final class Run<A> {
    let ctx = Context()
    let gen: Gen<A>
    let origin: String
    /// Kept for replaying failures: a blob only means what it meant under
    /// the settings that produced it.
    let settings: Settings
    private let outputBox: OutputBox?
    private let rawSettings: OpaquePointer?
    private var run: OpaquePointer?

    init(
        gen: Gen<A>,
        settings: Settings,
        output: ((String) -> Void)?,
        origin: String
    ) throws {
        self.gen = gen
        self.origin = origin
        self.settings = settings
        // Engine output (per Settings.verbosity) goes to `output` line by
        // line instead of stderr. Lines are emitted inside
        // hegel_next_test_case calls, so the box lives as long as the run.
        self.outputBox = output.map(OutputBox.init)
        self.rawSettings = try settings.makeHandle(ctx)
        // From here every stored property is set, so a throw runs `deinit`,
        // which is the one place the handles are freed. No catch here: a
        // second free on this path would be a double free.
        var run: OpaquePointer?
        try check(
            hegel_run_start(
                ctx.raw, rawSettings,
                outputBox == nil ? nil : outputTrampoline,
                outputBox.map { Unmanaged.passUnretained($0).toOpaque() },
                &run),
            ctx.lastError)
        self.run = run
    }

    deinit {
        // The sole owner of both handles; reverse order of acquisition, and
        // `ctx` is released after this body. Both frees accept NULL, so a
        // deinit reached from a throwing init is fine. hegel_run_free
        // completes any in-flight test case, which is what makes throwing
        // out of the loop (cancellation, timeout, an engine error) safe.
        _ = hegel_run_free(ctx.raw, run)
        _ = hegel_settings_free(ctx.raw, rawSettings)
        withExtendedLifetime(outputBox) {}
    }

    /// The next test case, or nil when the run is finished. The returned
    /// handle must be released with `free`.
    func next() throws -> TestCase? {
        var rawCase: OpaquePointer?
        try check(hegel_next_test_case(ctx.raw, run, &rawCase), ctx.lastError)
        return rawCase.map { TestCase(ctx: ctx, raw: $0) }
    }

    func free(_ tc: TestCase) {
        _ = hegel_test_case_free(ctx.raw, tc.raw)
    }

    func complete(_ tc: TestCase, _ status: TestCaseStatus, bugOrigin: String? = nil) throws {
        try check(hegel_mark_complete(ctx.raw, tc.raw, status.rawValue, bugOrigin), ctx.lastError)
    }

    /// Runs the generator. Handled separately from the property: an error
    /// out of a draw is not a verdict on the property. Control flow maps
    /// to OVERRUN/INVALID (the case is completed and nil returned);
    /// anything else (an FFI failure, a broken generator) aborts the run
    /// rather than masquerading as a counterexample.
    func generate(_ tc: TestCase) throws -> A? {
        do {
            return try gen.run(tc)
        } catch HegelError.stopTest {
            try complete(tc, .overrun)
        } catch HegelError.assume {
            try complete(tc, .invalid)
        }
        return nil
    }

    /// The verdict for a property invocation that threw `error`.
    /// Cancellation and a timeout are neither: they propagate to the caller.
    func verdict(for error: any Error) throws -> (TestCaseStatus, bugOrigin: String?) {
        switch error {
        case HegelError.stopTest: return (.overrun, nil)
        case HegelError.assume: return (.invalid, nil)
        case is CancellationError, is PropertyTimeout: throw error
        default:
            // Suffix the thrown error's type so different failure modes of
            // one property count as distinct bugs — that is what makes
            // reportMultipleFailures able to report more than one.
            return (.interesting, "\(origin) [\(String(reflecting: type(of: error)))]")
        }
    }

    /// Reads the run's result: returns on a pass, throws `PropertyFailure`
    /// otherwise.
    func result() throws {
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
                // Recover the shrunk value for display by replaying the
                // blob through the same generator. Best-effort: a replay
                // failure leaves the blob as the fallback.
                let counterexample = blob.flatMap { b in
                    (try? replay(gen, blob: b, settings: settings)).map { String(describing: $0) }
                }
                failures.append(Failure(
                    origin: originPtr.map { String(cString: $0) } ?? origin,
                    reproduceBlob: blob,
                    counterexample: counterexample))
            }
            throw PropertyFailure(failures: failures, runError: nil)
        }
    }
}

/// The convenience parameters override the corresponding Settings fields,
/// so the common knobs stay one label away.
private func resolve(
    _ settings: Settings, testCases: UInt64?, seed: UInt64?, database: String?
) -> Settings {
    var settings = settings
    if let testCases { settings.testCases = testCases }
    if let seed { settings.seed = seed }
    if let database { settings.database = database }
    return settings
}

// MARK: - Synchronous forAll

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
    try forAll(
        gen, testCases: testCases, seed: seed, database: database,
        settings: settings, output: output, origin: explicitOrigin,
        file: file, line: line
    ) { value, _ in try property(value) }
}

/// `forAll` whose property also receives the live `TestCase`, for bodies
/// that record targeting observations (`tc.target(score)`) or make
/// additional draws.
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
    _ property: (A, TestCase) throws -> Void
) throws {
    // Failures with the same origin are the same bug; the call site is the
    // stable identity of this property. Wrappers (HegelTesting's expectAll)
    // pass their own caller's location through `origin`.
    let run = try Run(
        gen: gen,
        settings: resolve(settings, testCases: testCases, seed: seed, database: database),
        output: output,
        origin: explicitOrigin ?? "\(file):\(line)")

    while let tc = try run.next() {
        defer { run.free(tc) }
        guard let value = try run.generate(tc) else { continue }
        do {
            try property(value, tc)
            try run.complete(tc, .valid)
        } catch {
            let (status, bugOrigin) = try run.verdict(for: error)
            try run.complete(tc, status, bugOrigin: bugOrigin)
        }
    }
    try run.result()
}

// MARK: - Async forAll

/// `forAll` for an `async` property.
///
/// Same engine, same shrinking, same reproduce blobs as the synchronous
/// form: a failing async property shrinks to the same counterexample as
/// its synchronous twin under the same seed. The run stays on the calling
/// task; the property may suspend freely, including between draws on the
/// live `TestCase` (see the two-argument overload).
///
/// - Cancelling the calling task cancels the property and propagates
///   `CancellationError` out of `forAll`; it is never a counterexample.
/// - `timeout` bounds one property invocation. Exceeding it throws
///   `PropertyTimeout`; see its note on cooperative cancellation.
public func forAll<A>(
    _ gen: Gen<A>,
    testCases: UInt64? = nil,
    seed: UInt64? = nil,
    database: String? = nil,
    settings: Settings = Settings(),
    timeout: Duration? = nil,
    output: ((String) -> Void)? = nil,
    origin explicitOrigin: String? = nil,
    file: StaticString = #fileID,
    line: UInt = #line,
    _ property: (A) async throws -> Void
) async throws {
    try await forAll(
        gen, testCases: testCases, seed: seed, database: database,
        settings: settings, timeout: timeout, output: output,
        origin: explicitOrigin, file: file, line: line
    ) { value, _ in try await property(value) }
}

/// Async `forAll` whose property also receives the live `TestCase`.
///
/// `TestCase` is not `Sendable` and draws must stay sequential: draw,
/// `await`, draw again is fine; drawing from two concurrent child tasks is
/// not (the engine reports `HegelError.concurrentUse`).
public func forAll<A>(
    _ gen: Gen<A>,
    testCases: UInt64? = nil,
    seed: UInt64? = nil,
    database: String? = nil,
    settings: Settings = Settings(),
    timeout: Duration? = nil,
    output: ((String) -> Void)? = nil,
    origin explicitOrigin: String? = nil,
    file: StaticString = #fileID,
    line: UInt = #line,
    _ property: (A, TestCase) async throws -> Void
) async throws {
    let run = try Run(
        gen: gen,
        settings: resolve(settings, testCases: testCases, seed: seed, database: database),
        output: output,
        origin: explicitOrigin ?? "\(file):\(line)")

    while let tc = try run.next() {
        defer { run.free(tc) }
        // A cancelled caller stops asking for cases; hegel_run_free
        // completes the one in flight.
        try Task.checkCancellation()
        guard let value = try run.generate(tc) else { continue }
        do {
            if let timeout {
                try await withTimeout(timeout, origin: run.origin) {
                    try await property(value, tc)
                }
            } else {
                try await property(value, tc)
            }
            try run.complete(tc, .valid)
        } catch {
            let (status, bugOrigin) = try run.verdict(for: error)
            try run.complete(tc, status, bugOrigin: bugOrigin)
        }
    }
    try run.result()
}

/// Smuggles non-`Sendable` state (the property closure, the value, the
/// `TestCase`) into a child task. Sound here because exactly one child
/// touches it and the parent only sleeps.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T
}

/// Races `body` against the clock. On timeout the body's task is cancelled
/// and `PropertyTimeout` is thrown once the body has actually stopped (a
/// task group never abandons a child, so the engine's "one driver at a
/// time" contract holds: nothing draws on the case after we return).
private func withTimeout(
    _ timeout: Duration,
    origin: String,
    _ body: () async throws -> Void
) async throws {
    try await withoutActuallyEscaping(body) { body in
        let boxed = Unchecked(value: body)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await boxed.value()
                return true
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            let finished = try await group.next()!
            group.cancelAll()
            if !finished {
                // Wait for the property to unwind before reporting, so the
                // case is not still being driven. A body that ignores
                // cancellation hangs here: see PropertyTimeout.
                while !group.isEmpty { _ = try? await group.next() }
                throw PropertyTimeout(origin: origin, timeout: timeout)
            }
        }
    }
}
