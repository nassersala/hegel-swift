import Hegel

/// Token refresh, above the code. An API with short-lived access tokens
/// and single-use refresh tokens: each refresh returns a new pair and
/// invalidates the old refresh token. Several requests are in flight at
/// once, any of them can get a 401, and the refresh can itself fail.
/// Drawn first on two requests under ⟨a0, f0⟩, both rejected:
///
///     [creds: ⟨a0,f0⟩, reqs: {}, refreshing: no]
///      ─send 0─▶       [creds: ⟨a0,f0⟩, reqs: {0: sent a0},            refreshing: no]
///      ─send 1─▶       [creds: ⟨a0,f0⟩, reqs: {0: sent a0, 1: sent a0}, refreshing: no]
///      ─0 gets 401─▶   [creds: ⟨a0,f0⟩, reqs: {0: waiting, 1: sent a0}, refreshing: f0]
///      ─1 gets 401─▶   [creds: ⟨a0,f0⟩, reqs: {0: waiting, 1: waiting}, refreshing: f0]   one refresh
///      ─refresh ok ⟨a1,f1⟩─▶ [creds: ⟨a1,f1⟩, reqs: {0: sent a1, 1: sent a1}, refreshing: no]
///      ─1 ok─▶         [creds: ⟨a1,f1⟩, reqs: {0: sent a1},            refreshing: no]
///      ─0 ok─▶         [creds: ⟨a1,f1⟩, reqs: {},                      refreshing: no]
///
/// The other order of the same two 401s, the refresh landing between them:
///
///      ─0 gets 401─▶   [creds: ⟨a0,f0⟩, reqs: {0: waiting, 1: sent a0}, refreshing: f0]
///      ─refresh ok ⟨a1,f1⟩─▶ [creds: ⟨a1,f1⟩, reqs: {0: sent a1, 1: sent a0}, refreshing: no]
///      ─1 gets 401─▶   [creds: ⟨a1,f1⟩, reqs: {0: sent a1, 1: sent a1}, refreshing: no]   stale: resend
///
/// And the refresh failing:
///
///      ─0 gets 401─▶   [creds: ⟨a0,f0⟩, reqs: {0: waiting, 1: sent a0}, refreshing: f0]
///      ─refresh fails─▶ [creds: out, reqs: {1: sent a0}, refreshing: no, done: {0: failed}]
///      ─1 gets 401─▶   [creds: out, reqs: {}, done: {0: failed, 1: failed}]
///
/// Two variables had to be written in for the rows to follow from the
/// arrows. Each request carries the access token it was sent under: at
/// the stale "1 gets 401" the next row needs to know that 1 went out
/// under a0 and the session now holds a1, or it would refresh again and
/// burn f1. And `refreshing` carries the refresh token in flight: at the
/// second 401 of the first drawing the next row needs to know f0 is
/// already spent. `rejected`, the access tokens that have received a
/// 401, is a history variable; the invariant needs it.
///
/// A step is one send, one response to one request, or one completion
/// of the refresh. The network is not a step.
///
///     Init:  creds = ⟨a0,f0⟩ ∧ reqs = {} ∧ refreshing = none ∧ rejected = {} ∧ done = {} ∧ n = 0
///     Next:  Send:  n′ = n+1 ∧ if creds = out then done′ = done ∪ {n ↦ failed}
///                             else if refreshing ≠ none then reqs′ = reqs ∪ {n ↦ waiting}
///                             else reqs′ = reqs ∪ {n ↦ sent(creds.access)}
///          ∨ Ok(i):  reqs[i] = sent(_) ∧ reqs′ = reqs \ {i} ∧ done′ = done ∪ {i ↦ ok}
///          ∨ Unauthorized(i):  reqs[i] = sent(a) ∧ rejected′ = rejected ∪ {a}
///                     ∧ if creds = out then reqs′ = reqs \ {i} ∧ done′ = done ∪ {i ↦ failed}
///                       else if refreshing ≠ none then reqs′[i] = waiting
///                       else if a ≠ creds.access then reqs′[i] = sent(creds.access)          (stale)
///                       else reqs′[i] = waiting ∧ refreshing′ = creds.refresh
///          ∨ Refreshed(c):  refreshing ≠ none ∧ c fresh ∧ creds′ = c ∧ refreshing′ = none
///                     ∧ reqs′ = [i ↦ if reqs[i] = waiting then sent(c.access) else reqs[i]]
///          ∨ RefreshFailed:  refreshing ≠ none ∧ creds′ = out ∧ refreshing′ = none
///                     ∧ reqs′ = reqs ↾ sent ∧ done′ = done ∪ {i ↦ failed : reqs[i] = waiting}
///
///     Inv:  (refreshing ≠ none ⇔ creds ≠ out ∧ creds.access ∈ rejected)
///         ∧ (refreshing ≠ none ⇒ refreshing = creds.refresh)
///         ∧ (∃ i: reqs[i] = waiting ⇒ refreshing ≠ none)
///
/// Every variable not mentioned in a clause is unchanged. The "pick
/// any"s: which in-flight request answers and with what, whether the
/// refresh succeeds, when the app sends. Inv is what the session
/// promises: it is refreshing exactly when the token it holds has been
/// rejected, so a good token is never traded away and a bad one is never
/// sat on; the token traded is always the current one, which is what
/// rotation requires; and nobody waits for a refresh that is not
/// happening.
///
/// Two wrong designs are kept for refutation: `refreshesOnEvery401`
/// ignores which token a request went out under, and `staysSignedIn`
/// keeps the credentials when the refresh fails.
public struct Auth: Equatable, Sendable, CustomStringConvertible {
    public struct Credentials: Hashable, Sendable, CustomStringConvertible {
        public var access: String
        public var refresh: String
        public init(access: String, refresh: String) {
            self.access = access
            self.refresh = refresh
        }
        public var description: String { "⟨\(access),\(refresh)⟩" }
    }

    /// Where one request is.
    public enum Phase: Hashable, Sendable, CustomStringConvertible {
        /// In flight, under this access token.
        case sent(String)
        /// Held back until the refresh completes.
        case waiting
        public var description: String {
            switch self {
            case .sent(let a): return "sent \(a)"
            case .waiting: return "waiting"
            }
        }
    }

    public enum Outcome: Hashable, Sendable {
        case ok
        case failed
    }

    /// The arrow words.
    public enum Event: Hashable, Sendable, CustomStringConvertible {
        case send
        case ok(Int)
        case unauthorized(Int)
        case refreshed(Credentials)
        case refreshFailed

        public var description: String {
            switch self {
            case .send: return "send"
            case .ok(let i): return "\(i) ok"
            case .unauthorized(let i): return "\(i) gets 401"
            case .refreshed(let c): return "refresh ok \(c)"
            case .refreshFailed: return "refresh fails"
            }
        }
    }

    /// Which Unauthorized and RefreshFailed clauses. `checked` is the
    /// design; the other two are wrong and refuted on drawn behaviours.
    public enum Design: Sendable, CaseIterable {
        /// A 401 refreshes whenever no refresh is in flight, whatever
        /// token the request went out under.
        case refreshesOnEvery401
        /// A failed refresh fails the waiters and keeps the credentials.
        case staysSignedIn
        /// The relation above.
        case checked
    }

    /// `nil` is `out`.
    public var creds: Credentials?
    public var requests: [Int: Phase]
    /// The refresh token in flight, or `none`.
    public var refreshing: String?
    public var rejected: Set<String>
    public var done: [Int: Outcome]
    public var next: Int
    /// How many credential pairs have been issued; names the fresh ones.
    public var generation: Int

    public init() {
        creds = Auth.credentials(0)
        requests = [:]
        refreshing = nil
        rejected = []
        done = [:]
        next = 0
        generation = 0
    }
    public init(creds: Credentials?, requests: [Int: Phase], refreshing: String?, rejected: Set<String>,
                done: [Int: Outcome], next: Int, generation: Int) {
        self.creds = creds
        self.requests = requests
        self.refreshing = refreshing
        self.rejected = rejected
        self.done = done
        self.next = next
        self.generation = generation
    }

    /// The g-th credential pair. The relation says only "fresh"; the
    /// behaviours name them so a trace reads.
    public static func credentials(_ g: Int) -> Credentials { Credentials(access: "a\(g)", refresh: "f\(g)") }

    /// Quiescent: nothing in flight, nothing waiting, no refresh.
    public var quiescent: Bool { requests.isEmpty && refreshing == nil }
    /// Every request the app sent has an outcome.
    public var settled: Bool { quiescent && done.count == next }
    /// `Inv`.
    public var truthful: Bool {
        let holdsRejected = creds.map { rejected.contains($0.access) } ?? false
        return (refreshing != nil) == holdsRejected
            && (refreshing == nil || refreshing == creds?.refresh)
            && (!requests.values.contains(.waiting) || refreshing != nil)
    }

    public var description: String {
        let reqs = requests.keys.sorted().map { "\($0): \(requests[$0]!)" }.joined(separator: ", ")
        let outcomes = done.keys.sorted().map { "\($0): \(done[$0]!)" }.joined(separator: ", ")
        return "creds = \(creds.map(\.description) ?? "out"), reqs = {\(reqs)}, refreshing = \(refreshing ?? "no"), "
            + "rejected = \(rejected.sorted()), done = {\(outcomes)}"
    }

    // MARK: Next

    /// `Next(self, event)` is enabled.
    public func enabled(_ e: Event) -> Bool {
        switch e {
        case .send: return true
        case .ok(let i), .unauthorized(let i):
            if case .sent = requests[i] { return true } else { return false }
        case .refreshed(let c):
            return refreshing != nil && !rejected.contains(c.access) && c.refresh != refreshing
        case .refreshFailed: return refreshing != nil
        }
    }

    /// Precondition: `enabled(e)`.
    public mutating func apply(_ e: Event, design: Design = .checked) {
        precondition(enabled(e), "\(e) is not enabled at \(self)")
        switch e {
        case .send:
            if let creds {
                requests[next] = refreshing == nil ? .sent(creds.access) : .waiting
            } else {
                done[next] = .failed
            }
            next += 1
        case .ok(let i):
            requests[i] = nil
            done[i] = .ok
        case .unauthorized(let i):
            guard case .sent(let a) = requests[i] else { preconditionFailure() }
            rejected.insert(a)
            guard let creds else {
                requests[i] = nil
                done[i] = .failed
                return
            }
            if refreshing != nil {
                requests[i] = .waiting
            } else if a != creds.access && design != .refreshesOnEvery401 {
                requests[i] = .sent(creds.access)
            } else {
                requests[i] = .waiting
                refreshing = creds.refresh
            }
        case .refreshed(let c):
            creds = c
            refreshing = nil
            generation += 1
            for (i, p) in requests where p == .waiting { requests[i] = .sent(c.access) }
        case .refreshFailed:
            if design != .staysSignedIn { creds = nil }
            refreshing = nil
            for (i, p) in requests where p == .waiting {
                requests[i] = nil
                done[i] = .failed
            }
        }
    }

    /// The requests in flight, in id order.
    var inFlight: [Int] {
        requests.keys.sorted().filter { if case .sent = requests[$0] { return true } else { return false } }
    }

    /// The "pick any"s as draws: what kind of step, then which request
    /// and how it answers, or how the refresh completes. A 401 is the
    /// `true` draw and a failed refresh the rarer one, so a story shrinks
    /// toward sends and 200s.
    public func draw(_ tc: TestCase) throws -> Event {
        var kinds = ["send"]
        if !inFlight.isEmpty { kinds.append("answer") }
        if refreshing != nil { kinds.append("refresh") }
        switch kinds[Int(try tc.drawInteger(in: 0...Int64(kinds.count - 1)))] {
        case "send":
            return .send
        case "answer":
            let i = inFlight[Int(try tc.drawInteger(in: 0...Int64(inFlight.count - 1)))]
            return try tc.drawBool() ? .unauthorized(i) : .ok(i)
        default:
            return try tc.drawBool(probability: 0.3) ? .refreshFailed : .refreshed(Auth.credentials(generation + 1))
        }
    }

    /// The step that drains without drawing: an ok to the lowest request
    /// in flight, or the refresh completing.
    var drain: Event? {
        if let i = inFlight.first { return .ok(i) }
        if refreshing != nil { return .refreshed(Auth.credentials(generation + 1)) }
        return nil
    }

    public struct Run: Sendable {
        /// The environment's moves in order.
        public let events: [Event]
        /// The state after each event, under `design`.
        public let states: [Auth]
        public let final: Auth
    }

    /// A complete behaviour: drawn sends, responses and refresh
    /// completions, then everything in flight answers ok and any refresh
    /// completes, so the run ends settled. The events are the same under
    /// every design; only the states differ.
    public static func behaviour(design: Design = .checked) -> Gen<Run> {
        Gen { tc in
            var s = Auth()
            var states: [Auth] = []
            var events = try tc.drawCollection(count: 0...12) {
                let e = try s.draw(tc)
                s.apply(e, design: design)
                states.append(s)
                return e
            }
            while let e = s.drain {
                s.apply(e, design: design)
                states.append(s)
                events.append(e)
            }
            return Run(events: events, states: states, final: s)
        }
    }
}
