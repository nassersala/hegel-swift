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
/// unrelated value.
public func replay<A>(_ gen: Gen<A>, blob: String) throws -> A {
    let ctx = Context()

    var settings: OpaquePointer?
    try check(hegel_settings_new(ctx.raw, &settings), ctx.lastError)
    defer { _ = hegel_settings_free(ctx.raw, settings) }
    // Hermetic: replay must not touch the example database.
    try check(hegel_settings_set_database(ctx.raw, settings, ""), ctx.lastError)

    var rawCase: OpaquePointer?
    try check(hegel_test_case_from_blob(ctx.raw, settings, blob, nil, nil, &rawCase), ctx.lastError)
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
