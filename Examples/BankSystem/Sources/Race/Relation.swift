import Hegel

// Two tellers on one account over an honest network: Phase A section 4,
// `Init_2` / `Next_2`, with the decisions substituted (P1a, P2a, P3a, P4b
// with K = 3, P5a, P6a). One account, so `bal` is a number, not a
// function on `Acct`. The relation is fixed; this file is it as a value.

public enum Req: Hashable, Sendable, CustomStringConvertible {
    case dep(Int), wd(Int)
    public var description: String {
        switch self { case .dep(let n): "dep \(n)"; case .wd(let n): "wd \(n)" }
    }
}

public enum Rep: Hashable, Sendable, CustomStringConvertible {
    case ok(Int), refused(Int)
    public var description: String {
        switch self { case .ok(let b): "ok \(b)"; case .refused(let b): "refused \(b)" }
    }
}

/// ⟦ r ⟧ b, defined once and used by every component.
public func meaning(_ r: Req, _ b: Int) -> (bal: Int, rep: Rep) {
    switch r {
    case .dep(let n): (b + n, .ok(b + n))
    case .wd(let n): n <= b ? (b - n, .ok(b - n)) : (b, .refused(b))
    }
}

/// Id = Teller × ℕ⁺, written t·n (P1a).
public struct Id: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var teller: Int, seq: Int
    public init(_ teller: Int, _ seq: Int) { self.teller = teller; self.seq = seq }
    public var description: String { "t\(teller)·\(seq)" }
    public static func < (a: Id, b: Id) -> Bool { (a.teller, a.seq) < (b.teller, b.seq) }
}

public enum Msg: Hashable, Sendable, CustomStringConvertible {
    case request(Id, Req)
    case reply(Id, Rep)
    public var id: Id { switch self { case .request(let i, _), .reply(let i, _): i } }
    public var description: String {
        switch self { case .request(let i, let r): "q(\(i), \(r))"; case .reply(let i, let r): "r(\(i), \(r))" }
    }
}

/// A teller's `out`: –, a reply, or `unknown` after giving up (P4b).
public enum Out: Hashable, Sendable, CustomStringConvertible {
    case none, rep(Rep), unknown
    public var description: String {
        switch self { case .none: "–"; case .rep(let r): "\(r)"; case .unknown: "unknown" }
    }
}

public struct TellerState: Hashable, Sendable, CustomStringConvertible {
    public var pend: Req? = nil
    public var seq = 0
    public var tries = 0
    public var out: Out = .none
    public init(pend: Req? = nil, seq: Int = 0, tries: Int = 0, out: Out = .none) {
        self.pend = pend; self.seq = seq; self.tries = tries; self.out = out
    }
    public var description: String { "⟨\(pend.map { "\($0)" } ?? "–"), \(seq), \(tries), \(out)⟩" }
}

/// One `Next_2` step. `k` is the teller.
public enum Step: Hashable, Sendable, CustomStringConvertible {
    case submit(Int, Req)
    case timeout(Int)
    case giveUp(Int)
    case arrive(Msg)
    case deliver(Int, Msg)
    public var description: String {
        switch self {
        case .submit(let k, let r): "submit_\(k) \(r)"
        case .timeout(let k): "timeout_\(k)"
        case .giveUp(let k): "giveUp_\(k)"
        case .arrive(let m): "arrive \(m)"
        case .deliver(let k, let m): "deliver_\(k) \(m)"
        }
    }
}

/// The state of `Init_2` / `Next_2`: `bal`, `seen`, `tl`, `net` as a bag,
/// plus one history variable, `applied`, the Apply steps in order, which
/// the invariants Once and Serial and the two-teller equation read.
public struct Race: Hashable, Sendable, CustomStringConvertible {
    public static let K = 3
    public static let tellers = 2

    public let b0: Int
    public var bal: Int
    public var seen: [Id: Rep] = [:]
    public var tl: [TellerState] = Array(repeating: TellerState(), count: Race.tellers)
    public var net: [Msg: Int] = [:]
    /// History: the identity and request of every Apply step, in order.
    public var applied: [Id] = []
    public var requestOf: [Id: Req] = [:]

    public init(bal: Int) { self.b0 = bal; self.bal = bal }

    public var description: String {
        let bag = net.sorted { "\($0.key)" < "\($1.key)" }.map { "\($0.key)\($0.value > 1 ? "×\($0.value)" : "")" }
        let s = seen.sorted { $0.key < $1.key }.map { "\($0.key) ↦ \($0.value)" }
        return "[bal: \(bal), seen: {\(s.joined(separator: ", "))}, net: ⦃\(bag.joined(separator: ", "))⦄, " + tl.enumerated().map { "t\($0): \($1)" }.joined(separator: ", ") + "]"
    }

    // MARK: Next

    public func enabled(_ step: Step) -> Bool {
        switch step {
        case .submit(let k, _):
            return tl[k].pend == nil
        case .timeout(let k):
            return tl[k].pend != nil && tl[k].tries < Race.K
        case .giveUp(let k):
            return tl[k].pend != nil && tl[k].tries == Race.K
        case .arrive(let m):
            guard case .request = m else { return false }
            return net[m, default: 0] > 0
        case .deliver(let k, let m):
            guard case .reply(let i, _) = m else { return false }
            return i.teller == k && net[m, default: 0] > 0
        }
    }

    /// Precondition: `enabled(step)`.
    public mutating func apply(_ step: Step) {
        precondition(enabled(step), "\(step) is not enabled at \(self)")
        switch step {
        case .submit(let k, let r):
            tl[k].pend = r; tl[k].seq += 1; tl[k].tries = 1; tl[k].out = .none
            emit(.request(Id(k, tl[k].seq), r))
        case .timeout(let k):
            tl[k].tries += 1
            emit(.request(Id(k, tl[k].seq), tl[k].pend!))
        case .giveUp(let k):
            tl[k].pend = nil; tl[k].tries = 0; tl[k].out = .unknown
        case .arrive(let m):
            guard case .request(let i, let r) = m else { return }
            remove(m)
            let out: Rep
            if let stored = seen[i] {                     // Again (P2a): the stored reply
                out = stored
            } else {                                      // Apply
                let (b, rep) = meaning(r, bal)
                bal = b; seen[i] = rep; out = rep
                applied.append(i); requestOf[i] = r
            }
            emit(.reply(i, out))
        case .deliver(let k, let m):
            guard case .reply(let i, let rep) = m else { return }
            remove(m)
            if tl[k].pend != nil && i == Id(k, tl[k].seq) {   // Take
                tl[k].pend = nil; tl[k].tries = 0; tl[k].out = .rep(rep)
            }                                                 // else Ignore
        }
    }

    private mutating func emit(_ m: Msg) { net[m, default: 0] += 1 }
    private mutating func remove(_ m: Msg) {
        net[m]! -= 1
        if net[m] == 0 { net[m] = nil }
    }

    /// Every step enabled here, in a fixed order, given each teller's next
    /// scripted request (`nil` when its script is spent).
    public func enabledSteps(next: [Req?]) -> [Step] {
        var steps: [Step] = []
        for k in 0..<Race.tellers {
            if let r = next[k], enabled(.submit(k, r)) { steps.append(.submit(k, r)) }
        }
        let messages = net.keys.sorted { "\($0)" < "\($1)" }
        for m in messages {
            switch m {
            case .request: steps.append(.arrive(m))
            case .reply(let i, _): steps.append(.deliver(i.teller, m))
            }
        }
        for k in 0..<Race.tellers {
            if enabled(.timeout(k)) { steps.append(.timeout(k)) }
            if enabled(.giveUp(k)) { steps.append(.giveUp(k)) }
        }
        return steps
    }

    /// The "pick any"s as one draw: which enabled step.
    public func draw(_ tc: TestCase, next: [Req?]) throws -> Step? {
        let steps = enabledSteps(next: next)
        guard !steps.isEmpty else { return nil }
        return steps[Int(try tc.drawInteger(in: 0...Int64(steps.count - 1)))]
    }

    // MARK: Invariants (Phase A section 4)

    public var nonNegative: Bool { bal >= 0 }
    /// Every identity in `dom seen` was applied exactly once.
    public var once: Bool { Set(applied).count == applied.count && Set(applied) == Set(seen.keys) }
    /// `bal` is the fold of ⟦ ⟧ over the Apply steps in order.
    public var serial: Bool { applied.reduce(b0) { meaning(requestOf[$1]!, $0).bal } == bal }
    /// A teller showing a reply shows the one stored for its request.
    /// `unknown` (P4b) is not a reply and is exempt; see the verdict list.
    public var agree: Bool {
        tl.enumerated().allSatisfy { k, t in
            if case .rep(let r) = t.out { return seen[Id(k, t.seq)] == r }
            return true
        }
    }
    public var invariantsHold: Bool { nonNegative && once && serial && agree }
    public var brokenInvariant: String? {
        if !nonNegative { return "NonNegative" }
        if !once { return "Once" }
        if !serial { return "Serial" }
        if !agree { return "Agree" }
        return nil
    }

    /// Quiescent: nothing in flight, no teller waiting.
    public var settled: Bool { net.isEmpty && tl.allSatisfy { $0.pend == nil } }

    // MARK: Behaviours

    public struct Run: Sendable, CustomStringConvertible {
        public var steps: [Step]
        public var states: [Race]
        public var final: Race
        public var description: String {
            steps.enumerated().map { "─\($1)─▶ \(states[$0])" }.joined(separator: "\n")
        }
    }

    /// A drawn behaviour: each teller submits its script in order (P5a,
    /// one at a time), every other choice is a draw, then the run is
    /// drained without timeouts so it ends settled.
    public static func behaviour(bal: Int, scripts: [[Req]], maxSteps: UInt64 = 24) -> Gen<Run> {
        Gen { tc in
            var s = Race(bal: bal)
            var cursor = Array(repeating: 0, count: tellers)
            var steps: [Step] = [], states: [Race] = []
            func next() -> [Req?] { (0..<tellers).map { cursor[$0] < scripts[$0].count ? scripts[$0][cursor[$0]] : nil } }
            func take(_ step: Step) {
                if case .submit(let k, _) = step { cursor[k] += 1 }
                s.apply(step); steps.append(step); states.append(s)
            }
            _ = try tc.drawCollection(count: 0...maxSteps) {
                if let step = try s.draw(tc, next: next()) { take(step) }
            }
            while let step = s.enabledSteps(next: next()).first(where: { if case .timeout = $0 { false } else { true } }) {
                take(step)
            }
            return Run(steps: steps, states: states, final: s)
        }
    }

    // MARK: The two-teller equation (Phase A section 5)

    /// For scripts of one request each: the final balance is one of the
    /// two serial orders, and each teller's `out` is the reply for its
    /// request at the balance before it in the order π the ledger took;
    /// `unknown` only for a teller that gave up (P4b).
    public func twoTellerEquation(r: [Req], gaveUp: [Bool]) -> String? {
        let orders = [[0, 1], [1, 0]].map { $0.reduce(b0) { meaning(r[$1], $0).bal } }
        guard orders.contains(bal) else { return "bal \(bal) is neither serial order \(orders)" }
        guard applied.count == 2, Set(applied.map(\.teller)) == [0, 1] else { return "π = \(applied) is not both requests once" }
        var b = b0
        for i in applied {
            let (nb, rep) = meaning(r[i.teller], b)
            switch tl[i.teller].out {
            case .rep(let got) where got == rep: break
            case .unknown where gaveUp[i.teller]: break
            default: return "t\(i.teller).out = \(tl[i.teller].out), expected \(rep) at balance \(b) in π = \(applied)"
            }
            b = nb
        }
        return nil
    }

    // MARK: Refinement

    /// What the code records at one step: the step and the stepping
    /// actor's own state after it (the ledger's balance, a teller's record).
    public struct Record: Sendable, Hashable, CustomStringConvertible {
        public var step: Step
        public var bal: Int?
        public var reply: Rep?
        public var teller: TellerState?
        public init(_ step: Step, bal: Int? = nil, reply: Rep? = nil, teller: TellerState? = nil) {
            self.step = step; self.bal = bal; self.reply = reply; self.teller = teller
        }
        public var description: String {
            "\(step)" + (bal.map { " → bal \($0)" } ?? "") + (reply.map { ", replied \($0)" } ?? "") + (teller.map { " → \($0)" } ?? "")
        }
    }

    public struct Violation: Error, CustomStringConvertible {
        public let index: Int
        public let record: Record
        public let state: Race
        public let reason: String
        public var description: String { "record \(index) `\(record)` \(reason) at \(state)" }
    }

    /// Every recorded step must be a `Next_2` step where it fires, and the
    /// recorded state must be the relation's.
    public static func refines(_ records: [Record], bal: Int) -> (violation: Violation?, final: Race) {
        var s = Race(bal: bal)
        for (i, rec) in records.enumerated() {
            guard s.enabled(rec.step) else { return (Violation(index: i, record: rec, state: s, reason: "is not enabled"), s) }
            s.apply(rec.step)
            if let b = rec.bal, b != s.bal {
                return (Violation(index: i, record: rec, state: s, reason: "recorded bal \(b), the relation has \(s.bal)"), s)
            }
            if let r = rec.reply, case .arrive(let m) = rec.step, s.seen[m.id] != r {
                return (Violation(index: i, record: rec, state: s, reason: "replied \(r), the relation replies \(s.seen[m.id].map { "\($0)" } ?? "–")"), s)
            }
            if let t = rec.teller, case .some(let k) = rec.step.teller, t != s.tl[k] {
                return (Violation(index: i, record: rec, state: s, reason: "recorded \(t), the relation has \(s.tl[k])"), s)
            }
        }
        return (nil, s)
    }
}

extension Step {
    public var teller: Int? {
        switch self {
        case .submit(let k, _), .timeout(let k), .giveUp(let k), .deliver(let k, _): k
        case .arrive: nil
        }
    }
}
