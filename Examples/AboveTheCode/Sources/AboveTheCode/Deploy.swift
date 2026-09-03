import Hegel

/// Zero-downtime deployment, above the code. N servers run version 1 and
/// must all end at version 2; a server is offline while it upgrades; at
/// least k must be online at every moment; and the clients must see one
/// version, never a mix. Drawn first on two servers, k = 1:
///
///     [s0: v1, s1: v1 | lb: v1]   online {s0, s1}
///      ─start 0─▶  [s0: off, s1: v1 | lb: v1]   online {s1}
///      ─finish 0─▶ [s0: v2,  s1: v1 | lb: v1]   online {s1}      s0 is up and nobody is sent to it
///      ─switch─▶   [s0: v2,  s1: v1 | lb: v2]   online {s0}      s1 is up and nobody is sent to it
///      ─start 1─▶  [s0: v2,  s1: off | lb: v2]  online {s0}
///      ─finish 1─▶ [s0: v2,  s1: v2 | lb: v2]   online {s0, s1}
///      ─done─▶     the same row, forever
///
/// One variable had to be written in: the balancer. Without it the row
/// after "finish 0" has two servers up on two versions and nothing in
/// the row says which one clients see. With it, "online" is not a phase
/// of a server but a set computed from the row, the servers at the
/// balancer's version. The drawing did not care which v1 server starts
/// first; that is the pick-any. What it did care about is the row before
/// "start 1": it must show that taking s1 offline leaves a server online.
/// So the guard reads the online set, not "is anyone else offline".
///
/// A step is one server going offline, one server coming back at v2, or
/// the balancer switching. The upgrade itself is not a step.
///
///     Init:  servers = [s ∈ 1..N ↦ v1]  ∧  lb = v1  ∧  N ≥ 2k
///     Online == {s : servers[s] = lb}
///     Next:  Start(s):   servers[s] = v1 ∧ |Online \ {s}| ≥ k ∧ servers′ = [servers EXCEPT ![s] = off]
///          ∨ Finish(s):  servers[s] = off ∧ servers′ = [servers EXCEPT ![s] = v2]
///          ∨ Switch:     lb = v1 ∧ |{s : servers[s] = v2}| ≥ k ∧ lb′ = v2
///          ∨ Done:       ∀ s: servers[s] = v2 ∧ lb = v2 ∧ UNCHANGED
///
///     ZeroDowntime:  |Online| ≥ k
///     SameVersion:   ∀ s, t ∈ Online: servers[s] = servers[t]
///
/// Every variable not mentioned is unchanged. `N ≥ 2k` is a finding of
/// the relation, not an input: at the switch the online set becomes the
/// v2 servers, so k of them must be up, while the v1 side still has to
/// keep k online until that moment. Three servers cannot keep two online
/// through an upgrade; the relation deadlocks there, and TLC says so.
///
/// Two wrong designs are kept for refutation, in the order Wlaschin's
/// talk proposes them. `anyServer` lets any v1 server start, and two
/// starts take every server offline. `oneOffline` is the talk's first
/// fix, start only if nobody else is offline: zero downtime holds, and
/// the first finish puts a v2 server next to a v1 server with both
/// online. Both have no balancer; their online set is "not offline".
///
/// What the guard says that the talk's fix does not: `|Online \ {s}| ≥ k`
/// is a batch. With five servers and k = 2, three can be offline at once
/// before the switch, and after it the rest go together. The batch size
/// is read off the relation, not chosen.
public struct Deploy: Equatable, Sendable, CustomStringConvertible {
    public enum Phase: Hashable, Sendable, CustomStringConvertible {
        case v1, offline, v2
        public var description: String {
            switch self {
            case .v1: return "v1"
            case .offline: return "off"
            case .v2: return "v2"
            }
        }
    }

    public enum Version: Hashable, Sendable, CustomStringConvertible {
        case v1, v2
        public var description: String { self == .v1 ? "v1" : "v2" }
        var phase: Phase { self == .v1 ? .v1 : .v2 }
    }

    /// The arrow words. `idle` is the stutter: nothing happens, and the
    /// relation allows it at every state.
    public enum Event: Hashable, Sendable, CustomStringConvertible {
        case start(Int)
        case finish(Int)
        case switchBalancer
        case idle

        public var description: String {
            switch self {
            case .start(let s): return "start \(s)"
            case .finish(let s): return "finish \(s)"
            case .switchBalancer: return "switch"
            case .idle: return "idle"
            }
        }
    }

    /// Which Start guard and which online set. `balanced` is the
    /// relation above; the other two are refuted on drawn behaviours.
    public enum Design: Sendable, CaseIterable, CustomStringConvertible {
        /// Any v1 server may start. No balancer.
        case anyServer
        /// A v1 server may start if no server is offline. No balancer.
        case oneOffline
        /// The relation: the balancer names the online set, and a server
        /// may start if the online set stays at k without it.
        case balanced

        public var description: String {
            switch self {
            case .anyServer: return "anyServer"
            case .oneOffline: return "oneOffline"
            case .balanced: return "balanced"
            }
        }
    }

    public var servers: [Phase]
    public var balancer: Version
    public let k: Int
    public let design: Design

    public init(servers n: Int, atLeast k: Int, design: Design = .balanced) {
        precondition(n >= 1 && k >= 1, "at least one server and k ≥ 1")
        servers = Array(repeating: .v1, count: n)
        balancer = .v1
        self.k = k
        self.design = design
    }

    public var n: Int { servers.count }

    /// `Online`. Without a balancer, the servers that are not offline.
    public var online: Set<Int> {
        switch design {
        case .anyServer, .oneOffline:
            return Set(servers.indices.filter { servers[$0] != .offline })
        case .balanced:
            return Set(servers.indices.filter { servers[$0] == balancer.phase })
        }
    }
    public var offline: [Int] { servers.indices.filter { servers[$0] == .offline } }
    public var atV1: [Int] { servers.indices.filter { servers[$0] == .v1 } }
    public var atV2: [Int] { servers.indices.filter { servers[$0] == .v2 } }

    /// `ZeroDowntime`.
    public var zeroDowntime: Bool { online.count >= k }
    /// `SameVersion`.
    public var sameVersion: Bool { Set(online.map { servers[$0] }).count <= 1 }
    /// `Done`: every server at v2 and the balancer pointing at them.
    public var done: Bool {
        servers.allSatisfy { $0 == .v2 } && (design != .balanced || balancer == .v2)
    }

    public var description: String {
        let row = servers.indices.map { "s\($0): \(servers[$0])" }.joined(separator: ", ")
        let lb = design == .balanced ? " | lb: \(balancer)" : ""
        return "[\(row)\(lb)]  online \(online.sorted().map { "s\($0)" })"
    }

    // MARK: Next

    /// `Next(self, event)` is enabled.
    public func enabled(_ e: Event) -> Bool {
        switch e {
        case .start(let s):
            guard servers.indices.contains(s), servers[s] == .v1 else { return false }
            switch design {
            case .anyServer: return true
            case .oneOffline: return offline.isEmpty
            case .balanced: return online.subtracting([s]).count >= k
            }
        case .finish(let s):
            return servers.indices.contains(s) && servers[s] == .offline
        case .switchBalancer:
            return design == .balanced && balancer == .v1 && atV2.count >= k
        case .idle:
            return true
        }
    }

    /// Precondition: `enabled(e)`.
    public mutating func apply(_ e: Event) {
        precondition(enabled(e), "\(e) is not enabled at \(self)")
        switch e {
        case .start(let s): servers[s] = .offline
        case .finish(let s): servers[s] = .v2
        case .switchBalancer: balancer = .v2
        case .idle: break
        }
    }

    /// The enabled steps other than idle, finishes first so a story
    /// shrinks toward servers coming back.
    public var enabledSteps: [Event] {
        let starts = atV1.map(Event.start).filter(enabled)
        let sw: [Event] = enabled(.switchBalancer) ? [.switchBalancer] : []
        return offline.map(Event.finish) + sw + starts
    }

    /// The "pick any"s as draws: which enabled step, and now and then
    /// nothing at all. Idle is the rare draw so a story shrinks away
    /// from it.
    public func draw(_ tc: TestCase) throws -> Event {
        let steps = enabledSteps
        let stutters = try tc.drawInteger(in: Int64(0)...7) == 7
        if steps.isEmpty || stutters { return .idle }
        return steps[Int(try tc.drawInteger(in: 0...Int64(steps.count - 1)))]
    }

    /// The step that finishes without drawing: bring a server back,
    /// switch, or start the lowest server the guard allows. `nil` when
    /// nothing but idle is enabled, which is the relation's deadlock.
    public var drain: Event? {
        let steps = enabledSteps
        return steps.isEmpty ? nil : steps[0]
    }

    public struct Run: Sendable {
        public let events: [Event]
        /// The state after each event.
        public let states: [Deploy]
        public let final: Deploy
        /// The most servers offline in any state.
        public var maxOffline: Int { states.map { $0.offline.count }.max() ?? 0 }
    }

    /// A complete behaviour: drawn steps and idles, then the drain until
    /// done or stuck. Every behaviour of a design with `n ≥ 2k` ends done;
    /// the drain stopping short is the deadlock.
    public static func behaviour(servers n: Int, atLeast k: Int, design: Design = .balanced) -> Gen<Run> {
        Gen { tc in
            var s = Deploy(servers: n, atLeast: k, design: design)
            var states: [Deploy] = []
            var events = try tc.drawCollection(count: 0...UInt64(3 * n)) {
                let e = try s.draw(tc)
                s.apply(e)
                states.append(s)
                return e
            }
            while !s.done, let e = s.drain {
                s.apply(e)
                states.append(s)
                events.append(e)
            }
            return Run(events: events, states: states, final: s)
        }
    }

    /// Drawn fleet sizes with the relation's own precondition, `n ≥ 2k`.
    public static let fleets: Gen<(n: Int, k: Int)> = Gen<Int64>.int(in: 1...2).flatMap { k in
        Gen<Int64>.int(in: (2 * k)...6).map { n in (n: Int(n), k: Int(k)) }
    }

    // MARK: Refinement

    public struct Violation: Equatable, CustomStringConvertible, Sendable {
        public let step: Int
        public let event: Event
        public let state: Deploy
        public var description: String {
            "step \(step): \(event) is not a Next step at \(state)"
        }
    }

    /// Replay recorded events against the relation: the first that is not
    /// enabled is the violation, and the state it was attempted at is the
    /// report.
    public static func refines(_ recorded: [Event], servers n: Int, atLeast k: Int) -> (violation: Violation?, final: Deploy) {
        var s = Deploy(servers: n, atLeast: k)
        for (i, e) in recorded.enumerated() {
            guard s.enabled(e) else { return (Violation(step: i, event: e, state: s), s) }
            s.apply(e)
        }
        return (nil, s)
    }
}

// MARK: - The code

/// A fleet as the code sees it: phases, the balancer, and the events it
/// records at the granularity of the relation's step.
public struct Fleet: Sendable {
    public private(set) var servers: [Deploy.Phase]
    public private(set) var balancer: Deploy.Version = .v1
    public private(set) var events: [Deploy.Event] = []

    public init(servers n: Int) { servers = Array(repeating: .v1, count: n) }

    public var atV1: [Int] { servers.indices.filter { servers[$0] == .v1 } }
    public var atV2: [Int] { servers.indices.filter { servers[$0] == .v2 } }
    public var offline: [Int] { servers.indices.filter { servers[$0] == .offline } }
    public var online: [Int] { servers.indices.filter { servers[$0] == balancer.phase } }
    public var allAtV2: Bool { servers.allSatisfy { $0 == .v2 } && balancer == .v2 }

    public mutating func start(_ s: Int) { servers[s] = .offline; events.append(.start(s)) }
    public mutating func finish(_ s: Int) { servers[s] = .v2; events.append(.finish(s)) }
    public mutating func switchBalancer() { balancer = .v2; events.append(.switchBalancer) }
}

/// Two refinements of the relation, and three seeded bugs.
///
/// - `oneAtATime`: the talk's procedure with the balancer added. Take
///   one server offline, bring it back, switch once k are at v2.
/// - `batched`: read the batch off the guard. While the balancer is at
///   v1, take `|online| − k` servers offline together; after the switch,
///   the v1 servers are not online, so the rest go together.
public enum Rollout: Sendable, CaseIterable, CustomStringConvertible {
    case oneAtATime
    case batched

    public var description: String { self == .oneAtATime ? "oneAtATime" : "batched" }

    public enum Bug: Sendable, CaseIterable, CustomStringConvertible {
        /// Switch as soon as one server is at v2, whatever k is.
        case switchesOnFirst
        /// One more in the batch than the guard allows.
        case batchTooLarge
        /// The talk's first fix as code: a balancer that is never switched.
        case neverSwitches

        public var description: String {
            switch self {
            case .switchesOnFirst: return "switchesOnFirst"
            case .batchTooLarge: return "batchTooLarge"
            case .neverSwitches: return "neverSwitches"
            }
        }
    }

    /// Runs the rollout and returns the recorded events. Stops when every
    /// server is at v2, or when nothing can be started and the balancer
    /// cannot switch, which is the code's deadlock.
    public func run(servers n: Int, atLeast k: Int, bug: Bug? = nil) -> [Deploy.Event] {
        var fleet = Fleet(servers: n)
        while !fleet.allAtV2 {
            let candidates = fleet.atV1
            let room = fleet.balancer == .v1 ? fleet.online.count - k : candidates.count
            var batch = self == .oneAtATime ? min(1, room) : room
            if bug == .batchTooLarge { batch += 1 }
            let starting = Array(candidates.prefix(max(batch, 0)))
            for s in starting { fleet.start(s) }
            for s in fleet.offline { fleet.finish(s) }
            let switchAt = bug == .switchesOnFirst ? 1 : k
            if fleet.balancer == .v1 && fleet.atV2.count >= switchAt && bug != .neverSwitches {
                fleet.switchBalancer()
            } else if starting.isEmpty {
                break
            }
        }
        return fleet.events
    }
}
