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
    let replayed = try ReplayedCase(blob: blob, settings: settings, output: output)
    do {
        let value = try gen.run(replayed.tc)
        replayed.complete(.valid)
        return value
    } catch {
        replayed.complete(.overrun)
        throw error
    }
}

/// One test case rebuilt from a blob, outside any run. The case holds the
/// whole choice sequence, so after the generator has read its prefix a
/// property can keep drawing from it exactly as it did when the case
/// failed; that is what lets the runner re-run a property at its minimal
/// counterexample. Frees the handles when it goes away.
final class ReplayedCase {
    private let ctx = Context()
    private let rawSettings: OpaquePointer?
    private let rawCase: OpaquePointer?
    private let outputBox: OutputBox?
    let tc: TestCase

    init(blob: String, settings: Settings, output: ((String) -> Void)? = nil) throws {
        let rawSettings = try settings.makeHandle(ctx)
        do {
            // Hermetic: replay must not touch the example database, whatever
            // the run's settings said.
            try check(hegel_settings_set_database(ctx.raw, rawSettings, ""), ctx.lastError)
            var rawCase: OpaquePointer?
            let outputBox = output.map(OutputBox.init)
            try check(
                hegel_test_case_from_blob(
                    ctx.raw, rawSettings, blob,
                    outputBox == nil ? nil : outputTrampoline,
                    outputBox.map { Unmanaged.passUnretained($0).toOpaque() },
                    &rawCase),
                ctx.lastError)
            self.rawSettings = rawSettings
            self.rawCase = rawCase
            self.outputBox = outputBox
            self.tc = TestCase(ctx: ctx, raw: rawCase!)
        } catch {
            _ = hegel_settings_free(ctx.raw, rawSettings)
            throw error
        }
    }

    func complete(_ status: TestCaseStatus) {
        _ = hegel_mark_complete(ctx.raw, rawCase, status.rawValue, nil)
    }

    deinit {
        _ = hegel_test_case_free(ctx.raw, rawCase)
        _ = hegel_settings_free(ctx.raw, rawSettings)
        withExtendedLifetime(outputBox) {}
    }
}
