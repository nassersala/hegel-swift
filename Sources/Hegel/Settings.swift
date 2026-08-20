import CHegel

/// Run configuration for `forAll`, mirroring libhegel's settings surface.
///
/// Every optional field means "leave the engine's default alone" when nil —
/// which matters, because the defaults are context-sensitive: in CI
/// (detected via `CI`, `GITHUB_ACTIONS`, …) libhegel disables the example
/// database and enables derandomization on its own.
public struct Settings: Sendable {
    /// Maximum number of valid test cases before the property is declared
    /// held. Rejected (assumption-failed) cases don't count.
    public var testCases: UInt64
    /// Fixed RNG seed. nil lets the engine pick (or derandomize).
    public var seed: UInt64?
    /// Derive the seed from a stable hash of the database key instead of
    /// fresh randomness. Repeated runs of one test become deterministic
    /// while different tests still see different inputs.
    public var derandomize: Bool?
    /// Example-database root. nil = engine default (`.hegel/examples/`,
    /// auto-disabled in CI); `""` disables the database entirely.
    public var database: String?
    /// Scopes stored and replayed examples within the database (and seeds
    /// derandomized runs). nil = unscoped.
    public var databaseKey: String?
    /// Which phases of the loop run. nil = all.
    public var phases: Phases?
    /// Keep generating after the first failure to surface additional
    /// distinct bugs (grouped by origin). nil = engine default (off).
    public var reportMultipleFailures: Bool?
    /// Engine output verbosity. nil = engine default (.normal).
    public var verbosity: Verbosity?
    /// Full test run, or a single generated case with no shrinking
    /// (replay/exploration tooling). nil = engine default (.testRun).
    public var mode: Mode?
    /// Target steps per stateful test case (at least 1; each case runs
    /// 1...n steps). nil = engine default (50).
    public var statefulStepCount: Int64?

    public init(
        testCases: UInt64 = 100,
        seed: UInt64? = nil,
        derandomize: Bool? = nil,
        database: String? = nil,
        databaseKey: String? = nil,
        phases: Phases? = nil,
        reportMultipleFailures: Bool? = nil,
        verbosity: Verbosity? = nil,
        mode: Mode? = nil,
        statefulStepCount: Int64? = nil
    ) {
        self.testCases = testCases
        self.seed = seed
        self.derandomize = derandomize
        self.database = database
        self.databaseKey = databaseKey
        self.phases = phases
        self.reportMultipleFailures = reportMultipleFailures
        self.verbosity = verbosity
        self.mode = mode
        self.statefulStepCount = statefulStepCount
    }

    /// Phases of the property-test loop (`hegel_phase_t` bit flags).
    public struct Phases: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// Run hard-coded explicit examples (reserved upstream).
        public static let explicit = Phases(rawValue: 1 << 0)
        /// Replay counterexamples persisted from previous runs.
        public static let reuse = Phases(rawValue: 1 << 1)
        /// Randomly generate fresh test cases.
        public static let generate = Phases(rawValue: 1 << 2)
        /// Hill-climb toward observed `hegel_target` scores.
        public static let target = Phases(rawValue: 1 << 3)
        /// Shrink discovered failing examples.
        public static let shrink = Phases(rawValue: 1 << 4)
        public static let all: Phases = [.explicit, .reuse, .generate, .target, .shrink]
    }

    /// `hegel_verbosity_t`.
    public enum Verbosity: UInt32, Sendable {
        case quiet = 0
        case normal = 1
        case verbose = 2
        case debug = 3
    }

    /// `hegel_mode_t`.
    public enum Mode: UInt32, Sendable {
        /// Full generate / shrink / replay loop. The engine default.
        case testRun = 0
        /// Exactly one generated test case, no shrinking.
        case singleTestCase = 1
    }

    /// Builds and configures a `hegel_settings_t` handle. The caller owns
    /// it and must free it with `hegel_settings_free`.
    func makeHandle(_ ctx: Context) throws(HegelError) -> OpaquePointer {
        var handle: OpaquePointer?
        try check(hegel_settings_new(ctx.raw, &handle), ctx.lastError)
        do {
            try check(hegel_settings_set_test_cases(ctx.raw, handle, testCases), ctx.lastError)
            if let seed {
                try check(hegel_settings_set_seed(ctx.raw, handle, seed, true), ctx.lastError)
            }
            if let derandomize {
                try check(hegel_settings_set_derandomize(ctx.raw, handle, derandomize), ctx.lastError)
            }
            if let database {
                try check(hegel_settings_set_database(ctx.raw, handle, database), ctx.lastError)
            }
            if let databaseKey {
                try check(hegel_settings_set_database_key(ctx.raw, handle, databaseKey), ctx.lastError)
            }
            if let phases {
                try check(hegel_settings_set_phases(ctx.raw, handle, phases.rawValue), ctx.lastError)
            }
            if let reportMultipleFailures {
                try check(
                    hegel_settings_set_report_multiple_failures(
                        ctx.raw, handle, reportMultipleFailures),
                    ctx.lastError)
            }
            if let verbosity {
                try check(hegel_settings_set_verbosity(ctx.raw, handle, verbosity.rawValue), ctx.lastError)
            }
            if let mode {
                try check(hegel_settings_set_mode(ctx.raw, handle, mode.rawValue), ctx.lastError)
            }
            if let statefulStepCount {
                try check(
                    hegel_settings_set_stateful_step_count(ctx.raw, handle, statefulStepCount),
                    ctx.lastError)
            }
        } catch {
            _ = hegel_settings_free(ctx.raw, handle)
            throw error
        }
        return handle!
    }
}
