/// The code under the relation in `Auth.swift`: a session with no UIKit
/// or SwiftUI in it. The app owns one on the main actor, hands it every
/// request, and reads `credentials == nil` as "show the sign-in screen".
/// The transport is a protocol, so a test can hold every response and
/// deliver them in a drawn order.
///
/// A 401 is answered by looking at which token the request went out
/// under. If the session has already moved on, the request is resent
/// under the current token and nothing is refreshed. If a refresh is in
/// flight, the request joins the queue. Otherwise this 401 is the first
/// news that the current token is bad: the request joins the queue and
/// one refresh starts with the current refresh token. Requests sent
/// while a refresh is in flight also queue: the token they would go out
/// under is known to be bad. When the refresh succeeds the queue is
/// resent under the new access token; when it fails the session signs
/// out and the queue fails.
public final class AuthSession {
    public struct Request: Hashable, Sendable {
        public let id: Int
        public init(id: Int) { self.id = id }
    }

    public enum Failure: Error, Equatable, Sendable {
        case signedOut
    }

    /// One-line deviations from the design, each a bug the refinement
    /// check reports as the first pair that is not a `Next` step.
    public enum Bug: Sendable, CaseIterable {
        /// A 401 under the current token starts a refresh even when one
        /// is in flight: the second refresh hands the server a spent
        /// token.
        case refreshesTwice
        /// A 401 refreshes whatever token the request went out under.
        case ignoresStaleness
        /// The queue is resent under the token each request had when it
        /// queued, captured in the closure, not the new one.
        case retriesUnderOldToken
        /// A failed refresh signs out and forgets the queue; its
        /// completions never run.
        case dropsWaitersOnFailure
        /// A successful refresh stores the new access token and keeps the
        /// old refresh token.
        case forgetsRotatedRefreshToken
        /// A failed refresh fails the queue and keeps the credentials.
        case keepsCredentialsOnRefreshFailure
        /// No bound: a 401 on the token the last refresh returned
        /// refreshes again, and again.
        case refreshesForever
    }

    /// `nil` is signed out.
    public private(set) var credentials: Auth.Credentials?
    /// The access token came from a refresh and has not been accepted
    /// yet. A 401 on it signs out rather than refreshing again.
    public private(set) var unproven = false
    /// Requests held back until the refresh in flight completes. The
    /// refinement mapping needs it; an app can count it for a spinner.
    public var queued: [Request] { waiting.map(\.request) }

    private struct Waiter {
        let request: Request
        /// The access token the request would have gone out under when
        /// it queued. Only `retriesUnderOldToken` reads it.
        let token: String
        let deliver: (Result<String, Failure>) -> Void
    }

    private var waiting: [Waiter] = []
    private var refreshInFlight = false
    private let transport: any AuthTransport
    private let bug: Bug?

    public init(credentials: Auth.Credentials, transport: any AuthTransport, bug: Bug? = nil) {
        self.credentials = credentials
        self.transport = transport
        self.bug = bug
    }

    /// Sends one request. `deliver` is called exactly once: with the
    /// body on a 2xx, or `signedOut` once the session has no credentials
    /// that the server accepts.
    public func send(_ request: Request, deliver: @escaping (Result<String, Failure>) -> Void) {
        guard let credentials else { return deliver(.failure(.signedOut)) }
        if refreshInFlight {
            waiting.append(Waiter(request: request, token: credentials.access, deliver: deliver))
            return
        }
        dispatch(request, under: credentials.access, deliver)
    }

    private func dispatch(_ request: Request, under token: String, _ deliver: @escaping (Result<String, Failure>) -> Void) {
        transport.send(request, accessToken: token) { [weak self] status in
            self?.received(status, for: request, sentUnder: token, deliver)
        }
    }

    private func received(_ status: AuthTransport.Status, for request: Request, sentUnder token: String,
                          _ deliver: @escaping (Result<String, Failure>) -> Void) {
        switch status {
        case .ok(let body):
            if token == credentials?.access { unproven = false }
            deliver(.success(body))
        case .unauthorized:
            guard let credentials else { return deliver(.failure(.signedOut)) }
            if refreshInFlight && bug != .refreshesTwice {
                waiting.append(Waiter(request: request, token: token, deliver: deliver))
                return
            }
            if token != credentials.access && bug != .ignoresStaleness {
                dispatch(request, under: credentials.access, deliver)
                return
            }
            if token == credentials.access && unproven && bug != .refreshesForever {
                self.credentials = nil
                return deliver(.failure(.signedOut))
            }
            waiting.append(Waiter(request: request, token: token, deliver: deliver))
            refreshInFlight = true
            transport.refresh(credentials.refresh) { [weak self] result in self?.refreshed(result) }
        }
    }

    private func refreshed(_ result: Result<Auth.Credentials, any Error>) {
        refreshInFlight = false
        let waiters = waiting
        waiting = []
        switch result {
        case .success(let fresh):
            if bug == .forgetsRotatedRefreshToken, let old = credentials {
                credentials = Auth.Credentials(access: fresh.access, refresh: old.refresh)
            } else {
                credentials = fresh
            }
            unproven = true
            for w in waiters {
                dispatch(w.request, under: bug == .retriesUnderOldToken ? w.token : fresh.access, w.deliver)
            }
        case .failure:
            if bug != .keepsCredentialsOnRefreshFailure { credentials = nil }
            if bug == .dropsWaitersOnFailure { return }
            for w in waiters { w.deliver(.failure(.signedOut)) }
        }
    }
}

public protocol AuthTransport: AnyObject {
    typealias Status = AuthTransportStatus
    /// Sends one request under `accessToken`. `deliver` is called once,
    /// when the response arrives, on the session's thread.
    func send(_ request: AuthSession.Request, accessToken: String, deliver: @escaping (Status) -> Void)
    /// Trades `refreshToken` for a new pair. `deliver` is called once.
    func refresh(_ refreshToken: String, deliver: @escaping (Result<Auth.Credentials, any Error>) -> Void)
}

public enum AuthTransportStatus: Sendable {
    case ok(String)
    case unauthorized
}

/// A transport that holds every response until told which to deliver.
/// It records what it was asked, which is what the refinement mapping
/// reads: the calls in flight and the tokens they carry.
public final class FakeAPI: AuthTransport {
    public struct RefreshRejected: Error, CustomStringConvertible {
        public var description: String { "refresh rejected" }
    }

    private struct Call {
        let request: AuthSession.Request
        let token: String
        let deliver: (Status) -> Void
    }

    private var calls: [Call] = []
    private var refreshes: [(token: String, deliver: (Result<Auth.Credentials, any Error>) -> Void)] = []
    /// Access tokens this server has answered 401 to.
    public private(set) var rejected: Set<String> = []
    /// Credential pairs this server has issued.
    public private(set) var issued = 0

    public init() {}

    /// What is in flight, by request id: the access token each call
    /// carries. More than one call per request is not a relation state;
    /// the mapping reports it.
    public var inFlight: [Int: [String]] {
        Dictionary(grouping: calls, by: \.request.id).mapValues { $0.map(\.token) }
    }
    /// The refresh tokens handed to the server and not yet answered.
    public var refreshing: [String] { refreshes.map(\.token) }

    public func send(_ request: AuthSession.Request, accessToken: String, deliver: @escaping (Status) -> Void) {
        calls.append(Call(request: request, token: accessToken, deliver: deliver))
    }

    public func refresh(_ refreshToken: String, deliver: @escaping (Result<Auth.Credentials, any Error>) -> Void) {
        refreshes.append((refreshToken, deliver))
    }

    /// Answers the one call in flight for request `id`. Returns false
    /// when there is not exactly one.
    @discardableResult
    public func answer(_ id: Int, _ status: Status) -> Bool {
        let matching = calls.indices.filter { calls[$0].request.id == id }
        guard matching.count == 1, let i = matching.first else { return false }
        let call = calls.remove(at: i)
        if case .unauthorized = status { rejected.insert(call.token) }
        call.deliver(status)
        return true
    }

    /// Completes the one refresh in flight. Returns false when there is
    /// not exactly one.
    @discardableResult
    public func completeRefresh(_ result: Result<Auth.Credentials, any Error>) -> Bool {
        guard refreshes.count == 1 else { return false }
        let r = refreshes.removeFirst()
        if case .success = result { issued += 1 }
        r.deliver(result)
        return true
    }
}

extension Auth {
    /// The refinement mapping: the session's state, the transport's
    /// queues, and the outcomes delivered so far, read as an `Auth`
    /// state. `nil` when the code is in no state of the relation at all:
    /// two calls for one request, or two refreshes.
    public static func project(_ session: AuthSession, _ api: FakeAPI, delivered: [Int: Outcome], sent: Int)
        -> (state: Auth?, reason: String?)
    {
        var requests: [Int: Phase] = [:]
        for (id, tokens) in api.inFlight {
            guard tokens.count == 1 else { return (nil, "the code has \(tokens.count) calls in flight for request \(id)") }
            requests[id] = .sent(tokens[0])
        }
        for r in session.queued {
            guard requests[r.id] == nil else { return (nil, "request \(r.id) is both in flight and queued") }
            requests[r.id] = .waiting
        }
        guard api.refreshing.count <= 1 else { return (nil, "the code has \(api.refreshing.count) refreshes in flight") }
        return (Auth(creds: session.credentials, requests: requests, refreshing: api.refreshing.first,
                     rejected: api.rejected, done: delivered, next: sent, generation: api.issued,
                     unproven: session.unproven), nil)
    }

    public struct Violation: CustomStringConvertible, Sendable {
        /// Index of the event in the run.
        public let step: Int
        public let from: Auth
        public let event: Event
        public let expected: Auth
        public let got: Auth?
        public let reason: String

        public var description: String {
            """
            step \(step): \(event) is not a Next step, \(reason)
              from:     \(from)
              expected: \(expected)
              got:      \(got.map(\.description) ?? "no relation state")
            """
        }
    }

    /// Drives a fresh session through `events`, one send, one answer or
    /// one refresh completion per event, and checks after each that the
    /// projected state is the relation's. Returns the first violation, if
    /// any, and the state reached.
    public static func refines(
        _ events: [Event], bug: AuthSession.Bug? = nil, design: Design = .checked
    ) -> (violation: Violation?, final: Auth) {
        let api = FakeAPI()
        let session = AuthSession(credentials: Auth.credentials(0), transport: api, bug: bug)
        var delivered: [Int: Outcome] = [:]
        var sent = 0
        var s = Auth()
        for (i, e) in events.enumerated() {
            var expected = s
            expected.apply(e, design: design)
            var missing: String?
            switch e {
            case .send:
                let id = sent
                sent += 1
                session.send(AuthSession.Request(id: id)) { result in
                    switch result {
                    case .success: delivered[id] = .ok
                    case .failure: delivered[id] = .failed
                    }
                }
            case .ok(let id):
                if !api.answer(id, .ok("body")) { missing = "the code has no single call in flight for request \(id)" }
            case .unauthorized(let id):
                if !api.answer(id, .unauthorized) { missing = "the code has no single call in flight for request \(id)" }
            case .refreshed(let c):
                if !api.completeRefresh(.success(c)) { missing = "the code has no single refresh in flight" }
            case .refreshFailed:
                if !api.completeRefresh(.failure(FakeAPI.RefreshRejected())) { missing = "the code has no single refresh in flight" }
            }
            let (got, reason) = project(session, api, delivered: delivered, sent: sent)
            if let missing {
                return (Violation(step: i, from: s, event: e, expected: expected, got: got, reason: missing), s)
            }
            guard let got else {
                return (Violation(step: i, from: s, event: e, expected: expected, got: nil, reason: reason!), s)
            }
            guard got == expected else {
                return (Violation(step: i, from: s, event: e, expected: expected, got: got, reason: "states differ"), s)
            }
            s = expected
        }
        return (nil, s)
    }
}
