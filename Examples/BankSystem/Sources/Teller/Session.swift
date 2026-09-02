import Hegel

/// The teller session, above the code: Phase A section 4 `Init_T`/`Next_T`
/// with the product decisions substituted (P1a: `Id = Teller × ℕ⁺`; P4b:
/// `Timeout` requires `tries < K` and `GiveUp` ends the request with
/// `out = unknown`; P5a: one outstanding request; P6a: `refused b`).
/// Drawn first with K = 3:
///
///     [pend: –, seq: 0, tries: 0, out: –]
///       ─submit wd 4─▶       [pend: wd 4, seq: 1, tries: 1, out: –]       emit q(t·1, wd 4)
///       ─timeout─▶           [pend: wd 4, seq: 1, tries: 2, out: –]       emit q(t·1, wd 4)
///       ─timeout─▶           [pend: wd 4, seq: 1, tries: 3, out: –]       emit q(t·1, wd 4)
///       ─give up─▶           [pend: –,    seq: 1, tries: 0, out: unknown]
///       ─reply ⟨t·1, ok 6⟩─▶ [pend: –,    seq: 1, tries: 0, out: unknown] ignored: pend = –
///       ─submit wd 7─▶       [pend: wd 7, seq: 2, tries: 1, out: –]       emit q(t·2, wd 7)
///       ─reply ⟨t·1, ok 6⟩─▶ [pend: wd 7, seq: 2, tries: 1, out: –]       ignored: wrong id
///       ─reply ⟨t·2, refused 6⟩─▶ [pend: –, seq: 2, tries: 0, out: refused 6]
///
/// A step is one submit, one timeout, one give-up, or the arrival of one
/// reply, taken or ignored. `emit` is a label on the arrow: the request
/// message the step puts on the wire, returned by `apply`.
///
///     Init_T:  pend = – ∧ seq = 0 ∧ tries = 0 ∧ out = –
///     Next_T:
///        Submit:  pend = – ∧ pick any r ∈ Req:
///                 pend′ = r ∧ seq′ = seq + 1 ∧ tries′ = 1 ∧ out′ = – ∧ emit q(t·seq′, r)
///      ∨ Timeout: pend ≠ – ∧ tries < K ∧ tries′ = tries + 1 ∧ unchanged pend, seq, out
///                 ∧ emit q(t·seq, pend)
///      ∨ GiveUp:  pend ≠ – ∧ tries = K ∧ pend′ = – ∧ tries′ = 0 ∧ out′ = unknown ∧ seq′ = seq
///      ∨ Take:    pick any arriving ⟨i, rep⟩: pend ≠ – ∧ i = t·seq
///                 ∧ pend′ = – ∧ tries′ = 0 ∧ out′ = rep ∧ seq′ = seq
///      ∨ Ignore:  pick any arriving ⟨i, rep⟩: (pend = – ∨ i ≠ t·seq) ∧ unchanged
///
/// The relation is fixed; `Design` carries two wrong versions of it that
/// the trace formula `bound` refutes and the invariant does not.
public enum Req: Hashable, Sendable, CustomStringConvertible {
    case dep(Int)
    case wd(Int)
    public var description: String {
        switch self {
        case .dep(let n): return "dep \(n)"
        case .wd(let n): return "wd \(n)"
        }
    }
}

public enum Rep: Hashable, Sendable, CustomStringConvertible {
    case ok(Int)
    case refused(Int)
    public var description: String {
        switch self {
        case .ok(let b): return "ok \(b)"
        case .refused(let b): return "refused \(b)"
        }
    }
}

/// `t·n`.
public struct Id: Hashable, Sendable, CustomStringConvertible {
    public let teller: String
    public let n: Int
    public init(teller: String, n: Int) {
        self.teller = teller
        self.n = n
    }
    public var description: String { "\(teller)·\(n)" }
}

/// `q(i, r)`.
public struct Request: Hashable, Sendable, CustomStringConvertible {
    public let id: Id
    public let req: Req
    public init(id: Id, req: Req) {
        self.id = id
        self.req = req
    }
    public var description: String { "q(\(id), \(req))" }
}

/// `r(i, rep)`.
public struct Reply: Hashable, Sendable, CustomStringConvertible {
    public let id: Id
    public let rep: Rep
    public init(id: Id, rep: Rep) {
        self.id = id
        self.rep = rep
    }
    public var description: String { "⟨\(id), \(rep)⟩" }
}

/// `Rep ∪ {–, unknown}`.
public enum Out: Hashable, Sendable, CustomStringConvertible {
    case none
    case taken(Rep)
    case unknown
    public var description: String {
        switch self {
        case .none: return "–"
        case .taken(let r): return r.description
        case .unknown: return "unknown"
        }
    }
}

public struct Session: Equatable, Sendable, CustomStringConvertible {
    /// The bound on `tries`: copies of one request on the wire, the
    /// submit counted.
    public static let K = 3

    public let teller: String
    public var pend: Req?
    public var seq: Int
    public var tries: Int
    public var out: Out

    /// `Init_T`.
    public init(teller: String) {
        self.teller = teller
        pend = nil
        seq = 0
        tries = 0
        out = .none
    }
    public init(teller: String, pend: Req?, seq: Int, tries: Int, out: Out) {
        self.teller = teller
        self.pend = pend
        self.seq = seq
        self.tries = tries
        self.out = out
    }

    public var description: String {
        "[pend: \(pend.map(\.description) ?? "–"), seq: \(seq), tries: \(tries), out: \(out)]"
    }

    /// The arrow words. A reply is one step whether taken or ignored;
    /// which of the two it is, the state decides (`kind(of:)`).
    public enum Step: Hashable, Sendable, CustomStringConvertible {
        case submit(Req)
        case timeout
        case giveUp
        case reply(Reply)
        public var description: String {
            switch self {
            case .submit(let r): return "submit \(r)"
            case .timeout: return "timeout"
            case .giveUp: return "give up"
            case .reply(let r): return "reply \(r)"
            }
        }
    }

    public enum Kind: Hashable, Sendable {
        case submit, timeout, giveUp, take, ignore
    }

    /// `checked` is the relation above. The other two are wrong on
    /// purpose: `unbounded` is P4(a), `Timeout` with no bound and no
    /// `GiveUp`; `restartsOnStray` keeps the bound clause but an
    /// ignored reply while pending sets `tries′ = 1` ("the line is
    /// alive, start the count again"), so the invariant `tries ≤ K`
    /// holds and the request is still resent forever.
    public enum Design: Sendable, CaseIterable {
        case checked
        case unbounded
        case restartsOnStray
    }

    public var pendingId: Id { Id(teller: teller, n: seq) }

    /// `Next_T(self, step)` is enabled.
    public func enabled(_ step: Step, design: Design = .checked) -> Bool {
        switch step {
        case .submit: return pend == nil
        case .timeout: return pend != nil && (design == .unbounded || tries < Session.K)
        case .giveUp: return pend != nil && tries == Session.K && design != .unbounded
        case .reply: return true
        }
    }

    /// Which clause a step is at this state.
    public func kind(of step: Step) -> Kind {
        switch step {
        case .submit: return .submit
        case .timeout: return .timeout
        case .giveUp: return .giveUp
        case .reply(let r): return pend != nil && r.id == pendingId ? .take : .ignore
        }
    }

    /// Precondition: `enabled(step)`. Returns what the step emits.
    @discardableResult
    public mutating func apply(_ step: Step, design: Design = .checked) -> Request? {
        precondition(enabled(step, design: design), "\(step) is not enabled at \(self)")
        switch step {
        case .submit(let r):
            pend = r
            seq += 1
            tries = 1
            out = .none
            return Request(id: pendingId, req: r)
        case .timeout:
            tries += 1
            return Request(id: pendingId, req: pend!)
        case .giveUp:
            pend = nil
            tries = 0
            out = .unknown
            return nil
        case .reply(let r):
            if kind(of: step) == .take {
                pend = nil
                tries = 0
                out = .taken(r.rep)
            } else if design == .restartsOnStray, pend != nil {
                tries = 1
            }
            return nil
        }
    }

    /// `Inv`: what every drawn row kept true. `tries` counts the copies
    /// of the pending request, none when nothing is pending, never more
    /// than K; a pending request has no answer yet.
    public var inv: Bool {
        (pend == nil) == (tries == 0) && tries <= Session.K && (pend == nil || out == .none)
    }

    /// The "pick any"s as draws: which kind of step among those enabled,
    /// then the request, or the arriving reply, whose identity is any of
    /// this teller's numbers up to the next one (0 is nobody's, seq + 1 is
    /// not yet issued) or another teller's, and whose reply is any
    /// balance. The relation does not know the balance.
    public func draw(_ tc: TestCase, design: Design = .checked) throws -> Step {
        var kinds = ["reply"]
        if enabled(.submit(.dep(1)), design: design) { kinds.append("submit") }
        if enabled(.timeout, design: design) { kinds.append("timeout") }
        if enabled(.giveUp, design: design) { kinds.append("giveUp") }
        switch kinds[Int(try tc.drawInteger(in: 0...Int64(kinds.count - 1)))] {
        case "submit":
            let n = Int(try tc.drawInteger(in: Int64(1)...9))
            return .submit(try tc.drawBool() ? .dep(n) : .wd(n))
        case "timeout":
            return .timeout
        case "giveUp":
            return .giveUp
        default:
            let other = try tc.drawBool(probability: 0.2)
            let n = Int(try tc.drawInteger(in: 0...Int64(seq + 1)))
            let b = Int(try tc.drawInteger(in: Int64(0)...20))
            let rep: Rep = try tc.drawBool(probability: 0.3) ? .refused(b) : .ok(b)
            return .reply(Reply(id: Id(teller: other ? "u" : teller, n: n), rep: rep))
        }
    }

    public struct Run: Sendable {
        public let steps: [Step]
        public let kinds: [Kind]
        public let emitted: [Request?]
        public let states: [Session]
        public let final: Session
    }

    /// A complete behaviour: drawn steps, then if something is pending a
    /// reply for it arrives, so the run ends with `pend = –`.
    public static func behaviour(teller: String = "t", design: Design = .checked) -> Gen<Run> {
        Gen { tc in
            var s = Session(teller: teller)
            var kinds: [Kind] = []
            var emitted: [Request?] = []
            var states: [Session] = []
            func take(_ step: Step) {
                kinds.append(s.kind(of: step))
                emitted.append(s.apply(step, design: design))
                states.append(s)
            }
            var steps = try tc.drawCollection(count: 0...16) {
                let step = try s.draw(tc, design: design)
                take(step)
                return step
            }
            if s.pend != nil {
                let step = Step.reply(Reply(id: s.pendingId, rep: .ok(0)))
                take(step)
                steps.append(step)
            }
            return Run(steps: steps, kinds: kinds, emitted: emitted, states: states, final: s)
        }
    }

    // MARK: The bound as a trace formula

    /// One position of the trace: the clause that led here, and the state.
    public struct Moment: Sendable {
        public let kind: Kind?
        public let state: Session
        public init(kind: Kind?, state: Session) {
            self.kind = kind
            self.state = state
        }
    }

    public static func moments(_ run: Run, teller: String = "t") -> [Moment] {
        [Moment(kind: nil, state: Session(teller: teller))] + zip(run.kinds, run.states).map { Moment(kind: $0, state: $1) }
    }

    public static let submits: Pred<Moment> = now { $0.kind == .submit }
    public static let timesOut: Pred<Moment> = now { $0.kind == .timeout }
    /// A Take or a GiveUp: the pending request is over.
    public static let settles: Pred<Moment> = now { $0.kind == .take || $0.kind == .giveUp }

    /// From here, fewer than `n + 1` positions where `p` holds before the
    /// first where `q` holds; `q` need never hold. The count is the
    /// nesting depth: `atMost(0)` is `¬p W q`, and `atMost(n)` lets the
    /// first `p` through if `atMost(n − 1)` holds right after it.
    public static func atMost(_ n: Int, _ p: Pred<Moment>, before q: Pred<Moment>) -> Pred<Moment> {
        n == 0 ? weakUntil(!p, q) : weakUntil(!p, q || (p && weakNext(atMost(n - 1, p, before: q))))
    }

    /// The bound of P4(b) as a safety formula over the clauses alone, no
    /// reading of `tries`: after a Submit, at most K − 1 Timeouts before
    /// a Take or a GiveUp, so no K Timeouts without one of those between
    /// them. The invariant cannot say it (a state with `tries = 2` is
    /// legal), and a design that resets the counter keeps the invariant
    /// and fails this at the K-th resend.
    public static let bound: Pred<Moment> = always(submits => weakNext(atMost(K - 1, timesOut, before: settles)))

    // MARK: Refinement

    /// What the code records at each step: the step, which clause the
    /// code believed it was, what it put on the wire, and its state after.
    public struct Record: Equatable, Sendable, CustomStringConvertible {
        public let step: Step
        public let kind: Kind
        public let emitted: Request?
        public let state: Session
        public init(step: Step, kind: Kind, emitted: Request?, state: Session) {
            self.step = step
            self.kind = kind
            self.emitted = emitted
            self.state = state
        }
        public var description: String {
            "─\(step)\(kind == .ignore ? " (ignored)" : "")─▶ \(state)\(emitted.map { " emit \($0)" } ?? "")"
        }
    }

    public struct Violation: Error, CustomStringConvertible, Sendable {
        public let index: Int
        public let before: Session
        public let record: Record
        public let reason: String
        public var description: String { "record \(index) \(record) is not a Next_T step at \(before): \(reason)" }
    }

    /// Every consecutive pair of recorded states is a `Next_T` step with
    /// the recorded emission, and the code's clause is the relation's.
    public static func refines(_ records: [Record], from initial: Session) -> (violation: Violation?, final: Session) {
        var s = initial
        for (i, r) in records.enumerated() {
            guard s.enabled(r.step) else {
                return (Violation(index: i, before: s, record: r, reason: "not enabled"), s)
            }
            let kind = s.kind(of: r.step)
            guard kind == r.kind else {
                return (Violation(index: i, before: s, record: r, reason: "the relation says \(kind), the code says \(r.kind)"), s)
            }
            let emitted = s.apply(r.step)
            guard emitted == r.emitted else {
                return (Violation(index: i, before: s, record: r, reason: "the relation emits \(emitted.map(\.description) ?? "nothing")"), s)
            }
            guard s == r.state else {
                return (Violation(index: i, before: s, record: r, reason: "the relation reaches \(s)"), s)
            }
        }
        return (nil, s)
    }
}
