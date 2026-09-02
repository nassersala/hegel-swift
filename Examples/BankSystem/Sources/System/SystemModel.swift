import Hegel
import Ledger
import Teller

// The composed relation, Phase A section 4 `Init_S` / `Next_S`: `Next_2`
// (two tellers on one account over a network that delivers in any order)
// plus `Dup(m)` and `Drop(m)`. The decisions are the components' (P1a, P2a,
// P3a, P4b with K = 3, P5a, P6a). The component clauses are not written
// again: `Arrive` calls `LedgerModel.apply`, and Submit, Timeout, GiveUp,
// Take and Ignore call `Session.apply`. This file adds the network, the
// bridge between the two id types, and one history variable, `applied`,
// the order π of the Apply steps, which Once, Serial and the composed
// equation of section 5 read.
//
// A step is one teller step, one ledger arrival, or one network action on
// one message. Delay is not a step: Arrive and Deliver pick any message.

/// The wire: what the tellers put on it and what the ledger's replies are.
public enum Msg: Hashable, Sendable, CustomStringConvertible {
    case request(TellerRequest)
    case reply(TellerReply)
    public var description: String {
        switch self {
        case .request(let q): "\(q)"
        case .reply(let r): "r\(r)"
        }
    }
}

public enum Step: Hashable, Sendable, CustomStringConvertible {
    case submit(Int, TellerReq)
    case timeout(Int)
    case giveUp(Int)
    case arrive(TellerRequest)
    case deliver(Int, TellerReply)
    case dup(Msg)
    case drop(Msg)
    public var description: String {
        switch self {
        case .submit(let k, let r): "submit_\(k + 1) \(r)"
        case .timeout(let k): "timeout_\(k + 1)"
        case .giveUp(let k): "giveUp_\(k + 1)"
        case .arrive(let q): "arrive \(q)"
        case .deliver(let k, let r): "deliver_\(k + 1) r\(r)"
        case .dup(let m): "dup \(m)"
        case .drop(let m): "drop \(m)"
        }
    }
    public var teller: Int? {
        switch self {
        case .submit(let k, _), .timeout(let k), .giveUp(let k), .deliver(let k, _): k
        case .arrive, .dup, .drop: nil
        }
    }
    public var isFault: Bool {
        switch self { case .dup, .drop: true; default: false }
    }
}

public struct SystemModel: Equatable, Sendable, CustomStringConvertible {
    public static let tellerNames = ["t1", "t2"]
    public static var tellers: Int { tellerNames.count }
    public static let K = Session.K

    public let b0: Int
    /// `bal`, `seen`, `out`: the ledger's record, one account.
    public var ledger: LedgerModel
    /// `tl`: each teller's ⟨pend, seq, tries, out⟩.
    public var tellers: [Session]
    /// `net`: a bag.
    public var net: [Msg: Int] = [:]
    /// History: π, the identity of every Apply step in order.
    public var applied: [TellerId] = []
    /// History: the request under each identity ever submitted.
    public var requestOf: [TellerId: TellerReq] = [:]
    /// History: what each request ended as at its teller, Take or GiveUp.
    public var outs: [TellerId: Out] = [:]

    /// `Init_S`.
    public init(bal: Int) {
        b0 = bal
        ledger = LedgerModel(accounts: [Bridge.acct], initial: bal)
        tellers = SystemModel.tellerNames.map { Session(teller: $0) }
    }

    public var bal: Int { ledger.bal[Bridge.acct]! }

    public var description: String {
        let bag = net.sorted { "\($0.key)" < "\($1.key)" }.map { "\($0.key)\($0.value > 1 ? "×\($0.value)" : "")" }
        let seen = ledger.seen.keys.sorted { ($0.teller, $0.seq) < ($1.teller, $1.seq) }.map { "\($0) ↦ \(ledger.seen[$0]!)" }
        return "[bal: \(bal), seen: {\(seen.joined(separator: ", "))}, net: ⦃\(bag.joined(separator: ", "))⦄, "
            + tellers.enumerated().map { "t\($0 + 1): \($1)" }.joined(separator: ", ") + ", π: \(applied)]"
    }

    // MARK: Next_S

    public func enabled(_ step: Step) -> Bool {
        switch step {
        case .submit(let k, let r):
            return tellers[k].enabled(.submit(r)) && amount(r) >= 1
        case .timeout(let k):
            return tellers[k].enabled(.timeout)
        case .giveUp(let k):
            return tellers[k].enabled(.giveUp)
        case .arrive(let q):
            return net[.request(q), default: 0] > 0 && ledger.enabled(Bridge.ledgerRequest(q))
        case .deliver(let k, let r):
            return r.id.teller == SystemModel.tellerNames[k] && net[.reply(r), default: 0] > 0
        case .dup(let m), .drop(let m):
            return net[m, default: 0] > 0
        }
    }

    /// Precondition: `enabled(step)`. Returns what the step emitted (a
    /// teller's request) and, for a reply, the clause the teller took.
    @discardableResult
    public mutating func apply(_ step: Step) -> (emitted: TellerRequest?, kind: Session.Kind?, clause: LedgerModel.Clause?) {
        precondition(enabled(step), "\(step) is not enabled at \(self)")
        switch step {
        case .submit(let k, let r):
            let q = tellers[k].apply(.submit(r))!
            requestOf[q.id] = r
            emit(.request(q))
            return (q, .submit, nil)
        case .timeout(let k):
            let q = tellers[k].apply(.timeout)!
            emit(.request(q))
            return (q, .timeout, nil)
        case .giveUp(let k):
            let id = tellers[k].pendingId
            tellers[k].apply(.giveUp)
            outs[id] = .unknown
            return (nil, .giveUp, nil)
        case .arrive(let q):
            remove(.request(q))
            let lm = Bridge.ledgerRequest(q)
            let clause = ledger.clause(lm)
            ledger.apply(lm)                                   // Apply or Again: Next_L
            if clause == .apply { applied.append(q.id); requestOf[q.id] = q.req }
            emit(.reply(TellerReply(id: q.id, rep: Bridge.tellerRep(ledger.out!))))
            return (nil, nil, clause)
        case .deliver(let k, let r):
            remove(.reply(r))
            let kind = tellers[k].kind(of: .reply(r))
            tellers[k].apply(.reply(r))                        // Take or Ignore: Next_T
            if kind == .take { outs[r.id] = .taken(r.rep) }
            return (nil, kind, nil)
        case .dup(let m):
            emit(m)
            return (nil, nil, nil)
        case .drop(let m):
            remove(m)
            return (nil, nil, nil)
        }
    }

    private mutating func emit(_ m: Msg) { net[m, default: 0] += 1 }
    private mutating func remove(_ m: Msg) {
        net[m]! -= 1
        if net[m] == 0 { net[m] = nil }
    }
    private func amount(_ r: TellerReq) -> Int {
        switch r { case .dep(let n), .wd(let n): n }
    }

    /// Every step enabled here, in a fixed order, given each teller's next
    /// scripted request and whether the network may still dup or drop.
    public func enabledSteps(next: [TellerReq?], faults: Bool) -> [Step] {
        var steps: [Step] = []
        for k in 0..<SystemModel.tellers {
            if let r = next[k], enabled(.submit(k, r)) { steps.append(.submit(k, r)) }
        }
        let messages = net.keys.sorted { "\($0)" < "\($1)" }
        for m in messages {
            switch m {
            case .request(let q): steps.append(.arrive(q))
            case .reply(let r): steps.append(.deliver(SystemModel.tellerNames.firstIndex(of: r.id.teller)!, m: r))
            }
        }
        for k in 0..<SystemModel.tellers {
            if enabled(.timeout(k)) { steps.append(.timeout(k)) }
            if enabled(.giveUp(k)) { steps.append(.giveUp(k)) }
        }
        if faults {
            for m in messages { steps.append(.dup(m)); steps.append(.drop(m)) }
        }
        return steps
    }

    // MARK: Invariants (Phase A section 4)

    public var nonNegative: Bool { bal >= 0 }
    /// Every identity in `dom seen` was applied exactly once.
    public var once: Bool {
        Set(applied).count == applied.count && Set(applied.map(Bridge.ledgerId)) == Set(ledger.seen.keys)
    }
    /// `bal` is the fold of ⟦ ⟧ over the Apply steps in order.
    public var serial: Bool {
        applied.reduce(b0) { meaning(Bridge.ledgerReq(requestOf[$1]!), $0).bal } == bal
    }
    /// A teller showing a reply shows the one stored for its request.
    /// `unknown` is not a reply and is exempt (Race's reading; see the
    /// verdict list).
    public var agree: Bool {
        tellers.allSatisfy { t in
            if case .taken(let r) = t.out { return ledger.seen[Bridge.ledgerId(t.pendingId)] == Bridge.ledgerRep(r) }
            return true
        }
    }
    public var brokenInvariant: String? {
        if !nonNegative { return "NonNegative" }
        if !once { return "Once" }
        if !serial { return "Serial" }
        if !agree { return "Agree" }
        return nil
    }
    public var invariantsHold: Bool { brokenInvariant == nil }

    /// Quiescent: nothing in flight, no teller waiting.
    public var settled: Bool { net.isEmpty && tellers.allSatisfy { $0.pend == nil } }

    // MARK: The composed equation (Phase A section 5)

    /// ∃ π, a linear order on the applied requests extending each teller's
    /// own order, such that `bal` is the fold over π and every settled
    /// request's `out` is the reply at the balance before it in π. π is
    /// the history variable, so ∃ is a check. `unknown` is allowed for a
    /// request the teller gave up on, applied or not (P4b with P3a).
    ///
    /// `orderAmongGivenUp` is what the composed check found (see the
    /// tests): with P4b and P3a a copy of a request the teller gave up on
    /// may apply after the teller's next request, so π does not extend
    /// the teller's order as Phase A section 5 states it. `true` is the
    /// equation as written; `false` asks the order only of requests the
    /// teller did not give up on, which is what the drawings used.
    public func equation(orderAmongGivenUp: Bool = true) -> String? {
        for k in 0..<SystemModel.tellers {
            let seqs = applied.filter { $0.teller == SystemModel.tellerNames[k] }
                .filter { orderAmongGivenUp || outs[$0] != .unknown }.map(\.n)
            guard seqs == seqs.sorted(), Set(seqs).count == seqs.count else { return "π = \(applied) does not extend t\(k + 1)'s order" }
        }
        var b = b0
        var before: [TellerId: Int] = [:]
        for i in applied {
            before[i] = b
            b = meaning(Bridge.ledgerReq(requestOf[i]!), b).bal
        }
        guard b == bal else { return "bal \(bal) is not the fold over π = \(applied), which gives \(b)" }
        for (i, out) in outs.sorted(by: { ($0.key.teller, $0.key.n) < ($1.key.teller, $1.key.n) }) {
            switch out {
            case .taken(let rep):
                guard let bb = before[i] else { return "\(i) shows \(rep) but is not in π = \(applied)" }
                let expected = Bridge.tellerRep(meaning(Bridge.ledgerReq(requestOf[i]!), bb).rep)
                guard rep == expected else { return "\(i) shows \(rep), the reply at balance \(bb) before it in π = \(applied) is \(expected)" }
            case .unknown, .none:
                break
            }
        }
        return nil
    }

    // MARK: Behaviours

    public struct Run: Sendable, CustomStringConvertible {
        public var steps: [Step]
        public var states: [SystemModel]
        public var final: SystemModel
        public var description: String {
            steps.enumerated().map { "─\($1)─▶ \(states[$0])" }.joined(separator: "\n")
        }
    }

    /// A drawn behaviour: each teller submits its script in order (P5a),
    /// every other choice, which enabled step, is a draw; Dup and Drop
    /// are drawn while `faultBudget` lasts; then the run is drained with
    /// no faults so it ends settled (a dropped request times out K times
    /// and is given up).
    public static func behaviour(bal: Int, scripts: [[TellerReq]], maxSteps: UInt64 = 24, faultBudget: Int = 3) -> Gen<Run> {
        Gen { tc in
            var s = SystemModel(bal: bal)
            var cursor = Array(repeating: 0, count: tellers)
            var budget = faultBudget
            var steps: [Step] = [], states: [SystemModel] = []
            func next() -> [TellerReq?] { (0..<tellers).map { cursor[$0] < scripts[$0].count ? scripts[$0][cursor[$0]] : nil } }
            func take(_ step: Step) {
                if case .submit(let k, _) = step { cursor[k] += 1 }
                if step.isFault { budget -= 1 }
                s.apply(step); steps.append(step); states.append(s)
            }
            _ = try tc.drawCollection(count: 0...maxSteps) {
                let enabled = s.enabledSteps(next: next(), faults: budget > 0)
                if !enabled.isEmpty { take(enabled[Int(try tc.drawInteger(in: 0...Int64(enabled.count - 1)))]) }
            }
            while let step = s.enabledSteps(next: next(), faults: false).first { take(step) }
            return Run(steps: steps, states: states, final: s)
        }
    }

    // MARK: Refinement

    /// What the code records at one `Next_S` step: the step, and the
    /// stepping component's own state after it, the ledger's record for
    /// an arrival, the teller's record (clause, emission, state) for a
    /// teller step; nothing for a network fault.
    public struct Record: Sendable, Equatable, CustomStringConvertible {
        public var step: Step
        public var ledger: LedgerModel?
        public var kind: Session.Kind?
        public var emitted: TellerRequest?
        public var teller: Session?
        public init(_ step: Step, ledger: LedgerModel? = nil, kind: Session.Kind? = nil, emitted: TellerRequest? = nil, teller: Session? = nil) {
            self.step = step; self.ledger = ledger; self.kind = kind; self.emitted = emitted; self.teller = teller
        }
        public var description: String {
            "\(step)" + (kind == .ignore ? " (ignored)" : "") + (ledger.map { " → \($0)" } ?? "")
                + (teller.map { " → \($0)" } ?? "") + (emitted.map { " emit \($0)" } ?? "")
        }
    }

    public struct Violation: Error, CustomStringConvertible {
        public let index: Int
        public let record: Record
        public let before: SystemModel
        public let reason: String
        public var description: String { "record \(index) `\(record)` \(reason) at \(before)" }
    }

    /// Every recorded step must be a `Next_S` step where it fires, with the
    /// component's recorded state, clause and emission the relation's.
    public static func refines(_ records: [Record], bal: Int) -> (violation: Violation?, final: SystemModel) {
        var s = SystemModel(bal: bal)
        for (i, rec) in records.enumerated() {
            guard s.enabled(rec.step) else { return (Violation(index: i, record: rec, before: s, reason: "is not enabled"), s) }
            let before = s
            let (emitted, kind, _) = s.apply(rec.step)
            if let l = rec.ledger, l != s.ledger {
                return (Violation(index: i, record: rec, before: before, reason: "recorded ledger \(l), the relation has \(s.ledger)"), s)
            }
            if let k = rec.kind, k != kind {
                return (Violation(index: i, record: rec, before: before, reason: "the code says \(k), the relation says \(kind.map { "\($0)" } ?? "nothing")"), s)
            }
            if rec.kind != nil, rec.emitted != emitted {
                return (Violation(index: i, record: rec, before: before, reason: "the relation emits \(emitted.map { "\($0)" } ?? "nothing")"), s)
            }
            if let t = rec.teller, let k = rec.step.teller, t != s.tellers[k] {
                return (Violation(index: i, record: rec, before: before, reason: "recorded \(t), the relation has \(s.tellers[k])"), s)
            }
        }
        return (nil, s)
    }
}

extension Step {
    fileprivate static func deliver(_ k: Int, m r: TellerReply) -> Step { .deliver(k, r) }
}
