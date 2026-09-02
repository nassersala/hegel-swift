import Testing
import Hegel
import HegelTesting
import Schedules
import AboveTheCode
import os

/// "Steps are whole" is a claim the relation makes without saying so. The
/// synchronous session keeps it by construction. An actor session has
/// suspension points, and whether a 401 handler is one step or two depends
/// on where they are. Two requests under an expired token, both rejected;
/// the drawn input is the schedule; the check is the one from the Lean
/// account race: every event the session logs must be a `Next` step of
/// the relation where it fires.
@Suite struct AboveAuthUnderSchedules {
    /// Test-only event recording at the semantic boundary, synchronous
    /// inside the actor, so it adds no suspension.
    final class EventLog: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [Auth.Event]())
        func record(_ e: Auth.Event) { lock.withLock { $0.append(e) } }
        var events: [Auth.Event] { lock.withLock { $0 } }
    }

    struct RefreshRejected: Error {}

    /// The server: a0 has expired, f0 buys ⟨a1, f1⟩ once, a spent refresh
    /// token is rejected. On its own lane so a call is a suspension.
    actor Server {
        let executor: ControlledSerialExecutor
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        private var accepted: Set<String> = []
        private var refreshToken = "f0"
        private var generation = 0
        private(set) var refreshes = 0
        init(executor: ControlledSerialExecutor) { self.executor = executor }

        func send(_ token: String) -> AuthTransportStatus { accepted.contains(token) ? .ok("body") : .unauthorized }

        func refresh(_ token: String) -> Result<Auth.Credentials, RefreshRejected> {
            refreshes += 1
            guard token == refreshToken else { return .failure(RefreshRejected()) }
            generation += 1
            let fresh = Auth.credentials(generation)
            accepted.insert(fresh.access)
            refreshToken = fresh.refresh
            return .success(fresh)
        }
    }

    /// Where the realistic suspension lives: the app reads the stored
    /// credentials before deciding to refresh.
    actor Keychain {
        let executor: ControlledSerialExecutor
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        private var stored: Auth.Credentials?
        init(executor: ControlledSerialExecutor, stored: Auth.Credentials) {
            self.executor = executor
            self.stored = stored
        }
        func load() -> Auth.Credentials? { stored }
    }

    /// The session as an actor. Two things the synchronous session got
    /// for free have to be done on purpose here, and the scheduler found
    /// both when they were not:
    ///
    /// - The decision on a 401 is a synchronous function. Its first
    ///   version was `await decide(...)` on the same actor, and the
    ///   scheduler ran another request's send in that gap, under a token
    ///   the relation already knew was bad. A same-actor `await` is a
    ///   suspension point; the two-phase commit example found the same.
    /// - Waiting for the refresh registers the continuation and re-checks
    ///   inside it. The first version checked, then suspended to register,
    ///   and one schedule finished the refresh in between: a lost wakeup,
    ///   the run stuck. The threshold cell in the quicksort example had it.
    ///
    /// `claimFirst` is the planted bug: look in the Keychain before
    /// claiming the refresh, or after.
    actor Session {
        let executor: ControlledSerialExecutor
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        private(set) var credentials: Auth.Credentials?
        /// Requests are numbered in the order the session logs them,
        /// which is the relation's numbering.
        private var nextId = 0
        private var refreshInFlight = false
        private var waiters: [CheckedContinuation<Auth.Credentials?, Never>] = []
        private let server: Server
        private let keychain: Keychain
        private let log: EventLog
        private let claimFirst: Bool

        init(executor: ControlledSerialExecutor, server: Server, keychain: Keychain, log: EventLog, claimFirst: Bool) {
            self.executor = executor
            self.server = server
            self.keychain = keychain
            self.log = log
            self.claimFirst = claimFirst
            credentials = Auth.credentials(0)
        }

        func send() async -> Result<String, AuthSession.Failure> {
            guard var creds = credentials else { return .failure(.signedOut) }
            let id = nextId
            nextId += 1
            log.record(.send)
            if refreshInFlight {
                guard let fresh = await refreshedCredentials() else { return .failure(.signedOut) }
                creds = fresh
            }
            switch await server.send(creds.access) {
            case .ok(let body):
                log.record(.ok(id))
                return .success(body)
            case .unauthorized:
                log.record(.unauthorized(id))
                let retryUnder: Auth.Credentials?
                switch decide(rejected: creds.access) {
                case .out: retryUnder = nil
                case .retry(let current): retryUnder = current
                case .wait: retryUnder = await refreshedCredentials()
                case .refresh(let spent):
                    if claimFirst { claim() }
                    _ = await keychain.load()
                    if !claimFirst { claim() }
                    retryUnder = await refresh(with: spent)
                }
                guard let fresh = retryUnder else { return .failure(.signedOut) }
                switch await server.send(fresh.access) {
                case .ok(let body):
                    log.record(.ok(id))
                    return .success(body)
                case .unauthorized:
                    log.record(.unauthorized(id))
                    return .failure(.signedOut)
                }
            }
        }

        enum Decision { case out, retry(Auth.Credentials), wait, refresh(spent: String) }

        /// The whole 401 step, with no suspension in it.
        private func decide(rejected token: String) -> Decision {
            guard let creds = credentials else { return .out }
            if token != creds.access { return .retry(creds) }
            if refreshInFlight { return .wait }
            return .refresh(spent: creds.refresh)
        }

        private func claim() { refreshInFlight = true }

        private func refresh(with token: String) async -> Auth.Credentials? {
            switch await server.refresh(token) {
            case .success(let fresh):
                credentials = fresh
                log.record(.refreshed(fresh))
            case .failure:
                credentials = nil
                log.record(.refreshFailed)
            }
            refreshInFlight = false
            let ws = waiters
            waiters = []
            for w in ws { w.resume(returning: credentials) }
            return credentials
        }

        /// Registers and re-checks inside the continuation, so a refresh
        /// that completes between the check and the registration is seen.
        private func refreshedCredentials() async -> Auth.Credentials? {
            await withCheckedContinuation { c in
                if refreshInFlight { waiters.append(c) } else { c.resume(returning: credentials) }
            }
        }
    }

    struct Run {
        let outcome: Scheduler.Outcome
        let events: [Auth.Event]
        let results: [Result<String, AuthSession.Failure>]
        let credentials: Auth.Credentials?
        let refreshes: Int
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    static func twoRequests(_ policy: @escaping Scheduler.Policy, claimFirst: Bool) -> Run {
        let scheduler = Scheduler()
        let log = EventLog()
        let server = Server(executor: scheduler.serialExecutor("server"))
        let keychain = Keychain(executor: scheduler.serialExecutor("keychain"), stored: Auth.credentials(0))
        let session = Session(executor: scheduler.serialExecutor("session"), server: server, keychain: keychain,
                              log: log, claimFirst: claimFirst)
        let results = Box<[Result<String, AuthSession.Failure>]>([])
        let creds = Box<Auth.Credentials?>(nil)
        let refreshes = Box(0)
        let outcome = scheduler.run(policy: policy) {
            async let a = session.send()
            async let b = session.send()
            results.value = await [a, b]
            creds.value = await session.credentials
            refreshes.value = await server.refreshes
        }
        return Run(outcome: outcome, events: log.events, results: results.value, credentials: creds.value,
                   refreshes: refreshes.value)
    }

    static let schedules: Gen<Schedule> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...40), Gen<Int64>.int(in: 0...7))
            .map { Schedule.Deviation(choice: Int($0), index: Int($1)) },
        count: 0...8
    ).map(Schedule.init)

    struct NotAStep: Error, CustomStringConvertible {
        let index: Int
        let event: Auth.Event
        let state: Auth
        let events: [Auth.Event]
        var description: String { "event \(index) \(event) is not a Next step at \(state); trace \(events)" }
    }
    struct DidNotComplete: Error { let outcome: Scheduler.Outcome }

    /// Every logged event is enabled in the relation where it fires, and
    /// the run ends settled.
    static func checkRefines(_ run: Run) throws -> Auth {
        guard case .completed = run.outcome else { throw DidNotComplete(outcome: run.outcome) }
        var s = Auth()
        for (i, e) in run.events.enumerated() {
            guard s.enabled(e) else { throw NotAStep(index: i, event: e, state: s, events: run.events) }
            s.apply(e)
        }
        return s
    }

    /// Claim before suspending: one step, and the session refines the
    /// relation under every drawn schedule, one refresh, both requests
    /// answered under ⟨a1, f1⟩.
    @Test func claimingBeforeSuspendingRefinesUnderEverySchedule() throws {
        try forAll(Self.schedules, testCases: 300, database: "") { schedule in
            let run = Self.twoRequests(schedule.policy, claimFirst: true)
            let final = try Self.checkRefines(run)
            #expect(final.settled)
            #expect(run.refreshes == 1)
            #expect(run.credentials == Auth.credentials(1))
            #expect(run.results.allSatisfy { if case .success = $0 { return true } else { return false } })
        }
    }

    /// Suspend between the check and the claim, and the 401 step is two
    /// steps. The shortest schedule that shows it, one deviation, sends a
    /// request under a token the relation already knows is bad; the
    /// refinement reports the 401 that follows as not a step. The double
    /// refresh, with the user signed out, needs more deviations, and the
    /// second test finds it.
    @Test func suspendingBetweenCheckAndClaimIsNotAStep() throws {
        do {
            try forAll(Self.schedules, seed: 1, database: "") { schedule in
                _ = try Self.checkRefines(Self.twoRequests(schedule.policy, claimFirst: false))
            }
            Issue.record("the suspension was never exploited")
        } catch let failure as PropertyFailure {
            let minimal = try replay(Self.schedules, blob: try #require(failure.failures.first?.reproduceBlob))
            let run = Self.twoRequests(minimal.policy, claimFirst: false)
            var s = Auth()
            var firstBad: (Int, Auth.Event)?
            for (i, e) in run.events.enumerated() {
                if !s.enabled(e) { firstBad = (i, e); break }
                s.apply(e)
            }
            print("await between check and claim, schedule \(minimal): \(run.events.map(\.description).joined(separator: ", ")); first non-step \(firstBad.map { "\($0.1) at \($0.0)" } ?? "none")")
            #expect(minimal.deviations.count == 1)
            #expect(firstBad?.1 == .unauthorized(1))
            #expect(s.requests[1] == .waiting)
        }
    }

    /// The incident: two refreshes, the second with a spent token, the
    /// user signed out. Some drawn schedule reaches it.
    @Test func someScheduleRefreshesTwiceAndSignsOut() throws {
        var witness: (Schedule, Run)?
        try forAll(Self.schedules, testCases: 300, database: "") { schedule in
            let run = Self.twoRequests(schedule.policy, claimFirst: false)
            if run.refreshes == 2, witness == nil { witness = (schedule, run) }
        }
        let (schedule, run) = try #require(witness)
        print("double refresh, schedule \(schedule): \(run.events.map(\.description).joined(separator: ", ")); credentials \(run.credentials.map(\.description) ?? "out")")
        #expect(run.credentials == nil)
        #expect(run.events.contains(.refreshFailed))
        #expect(run.results.contains { if case .failure = $0 { return true } else { return false } })
    }
}
