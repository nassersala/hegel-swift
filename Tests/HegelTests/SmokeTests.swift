import Testing
import CHegel
import Hegel

/// Layer 0: hermetic end-to-end drive of the raw C protocol, after
/// hegel-go's `libhegel_smoke_test.go`. Pinned seed, derandomized, database
/// disabled. This tests OUR marshalling and lifecycle sequencing; the
/// engine itself is trusted (it is the tested-upstream Hypothesis core).
@Suite struct LibhegelSmokeTests {
    @Test func rawProtocolEndToEnd() throws {
        let ctx = hegel_context_new()
        defer { _ = hegel_context_free(ctx) }

        var settings: OpaquePointer?
        #expect(hegel_settings_new(ctx, &settings) == HEGEL_OK)
        defer { _ = hegel_settings_free(ctx, settings) }
        #expect(hegel_settings_set_test_cases(ctx, settings, 10) == HEGEL_OK)
        #expect(hegel_settings_set_seed(ctx, settings, 42, true) == HEGEL_OK)
        #expect(hegel_settings_set_derandomize(ctx, settings, true) == HEGEL_OK)
        #expect(hegel_settings_set_database(ctx, settings, "") == HEGEL_OK)

        var run: OpaquePointer?
        #expect(hegel_run_start(ctx, settings, nil, nil, &run) == HEGEL_OK)
        defer { _ = hegel_run_free(ctx, run) }

        var cases = 0
        while true {
            var tc: OpaquePointer?
            #expect(hegel_next_test_case(ctx, run, &tc) == HEGEL_OK)
            guard let tc else { break }
            defer { _ = hegel_test_case_free(ctx, tc) }

            var value: Int64 = -1
            #expect(hegel_generate_integer(ctx, tc, 0, 100, &value) == HEGEL_OK)
            #expect((0...100).contains(value))
            #expect(hegel_mark_complete(ctx, tc, TestCaseStatus.valid.rawValue, nil) == HEGEL_OK)
            cases += 1
        }
        // Guards the self-bootstrap layer against vacuous passes: the loop
        // must actually have run test cases.
        #expect(cases >= 10)

        var result: OpaquePointer?
        #expect(hegel_run_result(ctx, run, &result) == HEGEL_OK)
        defer { _ = hegel_run_result_free(ctx, result) }
        var status = HEGEL_RUN_STATUS_ERROR
        #expect(hegel_run_result_status(ctx, result, &status) == HEGEL_OK)
        #expect(status == HEGEL_RUN_STATUS_PASSED)
    }

    @Test func versionIsReadable() throws {
        let ctx = hegel_context_new()
        defer { _ = hegel_context_free(ctx) }
        var version: UnsafePointer<CChar>?
        #expect(hegel_version(ctx, &version) == HEGEL_OK)
        let string = version.map { String(cString: $0) } ?? ""
        #expect(!string.isEmpty)
    }
}
