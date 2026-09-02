import CHegel

/// Replays a reproduce blob through a generator, returning the value it
/// encodes.
///
/// This is how a stored counterexample becomes a value again: the blob is
/// the choice sequence, the generator re-interprets it. There is no run
/// loop involved — libhegel hands back a single test case.
///
/// Blobs are version-pinned (they replay only on the libhegel version that
/// produced them) and generator-shaped: replaying a blob through a
/// *different* generator than the one that failed overruns or produces an
/// unrelated value. They are also settings-shaped: `settings` must be the
/// run's, because the engine interprets the choice sequence under them (a
/// stateful blob of 80 steps overruns at the default step count of 50 and
/// replays as a shorter, passing run). `forAll` passes its own; pass the
/// same when replaying a stored blob by hand.
public func replay<A>(
    _ gen: Gen<A>,
    blob: String,
    settings: Settings = Settings(),
    output: ((String) -> Void)? = nil
) throws -> A {
    let ctx = Context()

    let rawSettings = try settings.makeHandle(ctx)
    defer { _ = hegel_settings_free(ctx.raw, rawSettings) }
    // Hermetic: replay must not touch the example database, whatever the
    // run's settings said.
    try check(hegel_settings_set_database(ctx.raw, rawSettings, ""), ctx.lastError)

    // Unlike a run's callback, this one is only invoked during the call
    // below and need not outlive it.
    let outputBox = output.map(OutputBox.init)
    var rawCase: OpaquePointer?
    try withExtendedLifetime(outputBox) {
        try check(
            hegel_test_case_from_blob(
                ctx.raw, rawSettings, blob,
                outputBox == nil ? nil : outputTrampoline,
                outputBox.map { Unmanaged.passUnretained($0).toOpaque() },
                &rawCase),
            ctx.lastError)
    }
    defer { _ = hegel_test_case_free(ctx.raw, rawCase) }

    let tc = TestCase(ctx: ctx, raw: rawCase!)
    do {
        let value = try gen.run(tc)
        _ = hegel_mark_complete(ctx.raw, rawCase, TestCaseStatus.valid.rawValue, nil)
        return value
    } catch {
        _ = hegel_mark_complete(ctx.raw, rawCase, TestCaseStatus.overrun.rawValue, nil)
        throw error
    }
}
