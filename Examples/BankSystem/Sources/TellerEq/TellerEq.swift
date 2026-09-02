import Hegel

/// The teller session derived from its equation, not from a drawing.
/// Phase A section 5 states the teller as three equations over a network
/// term `net` that reorders, drops and duplicates:
///
///     ∀ net ∈ Net_fin:  apply* (net (retry r)) b  ≡  ⟦ r ⟧ b
///     ∀ net ∈ Net_fin:  out  ≡  rep⟦ r ⟧ b                    once a reply has been taken
///     ∀ net ∈ Net:      apply* (net (retry r)) b  ∈  { b, ⟦ r ⟧ b }
///                       and if no reply ever comes, out = unknown  (P4b, K = 3)
///
/// `Msg` starts with no constructors, the teller's state with no fields,
/// `retry` undefined. Hegel is the refute half, as in
/// `AboveTheCode/Bank.swift`: `net` is drawn, every undefined case throws
/// `Stuck` with the values in scope, the shrunk counterexample is the
/// goal, and `Birth` records how far the calculation has gone. Each
/// `born >= .x` guard below is one round.
public enum Req: Hashable, Sendable, CustomStringConvertible {
    case deposit(Int)
    case withdraw(Int)

    public var description: String {
        switch self {
        case .deposit(let n): return "deposit \(n)"
        case .withdraw(let n): return "withdraw \(n)"
        }
    }

    /// `bal⟦ r ⟧ b`. Withdraw is monus: a refused withdrawal leaves b.
    public func bal(_ b: Int) -> Int {
        switch self {
        case .deposit(let n): return b + n
        case .withdraw(let n): return n <= b ? b - n : b
        }
    }

    /// `rep⟦ r ⟧ b`, the reply the customer is owed (P6a: a refusal carries the balance).
    public func rep(_ b: Int) -> Rep {
        switch self {
        case .deposit(let n): return .ok(b + n)
        case .withdraw(let n): return n <= b ? .ok(b - n) : .refused(b)
        }
    }

    public static let gen = Gen<Req> { tc in
        let n = Int(try tc.drawInteger(in: Int64(0)...9))
        return try tc.drawInteger(in: Int64(0)...1) == 0 ? .deposit(n) : .withdraw(n)
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

/// How far the calculation has gone. One case per round, in the order the
/// stuck goals came.
public enum Birth: Int, Comparable, Sendable, CaseIterable {
    case nothing
    case credit     // round 1: CREDIT n
    case debit      // round 2: DEBIT n
    case pend       // round 3: state field pend, the message to copy at a timeout
    case tries      // round 4: state field tries (invented)
    case reply      // round 5: REPLY rep (born at the ledger's goal)
    case out        // round 6: state field out := rep
    case unknown    // round 7: out gains the value unknown, GiveUp
    case id         // round 8: id on the request, seq in the state (not decidable; P1a/P2a)
    case settle     // round 9: a taken reply clears pend
    public static func < (a: Birth, b: Birth) -> Bool { a.rawValue < b.rawValue }
}

/// The wire format as born so far. `id` is `nil` until round 8.
public enum Msg: Hashable, Sendable, CustomStringConvertible {
    case credit(Int, id: Int?)
    case debit(Int, id: Int?)
    case reply(Rep)

    public var description: String {
        func tag(_ id: Int?) -> String { id.map { " · id \($0)" } ?? "" }
        switch self {
        case .credit(let n, let id): return "CREDIT \(n)\(tag(id))"
        case .debit(let n, let id): return "DEBIT \(n)\(tag(id))"
        case .reply(let r): return "REPLY (\(r))"
        }
    }
}

public enum Outcome: Hashable, Sendable, CustomStringConvertible {
    case unknown
    case rep(Rep)
    public var description: String {
        switch self {
        case .unknown: return "unknown"
        case .rep(let r): return "\(r)"
        }
    }
}

/// The goal the definitions do not cover, with the values in scope.
public struct Stuck: Error, CustomStringConvertible {
    public let goal: String
    public let scope: String
    public var description: String { "stuck: \(goal)\n  in scope: \(scope)" }
}

/// A defined case that the equation refutes.
public struct Unequal: Error, CustomStringConvertible {
    public let equation: String
    public let detail: String
    public var description: String { "refuted: \(equation)\n  \(detail)" }
}

public let K = 3  // P4b

/// The teller's state. Every field is born at a round; before its round
/// the code below never reads it.
public struct Teller: Hashable, Sendable, CustomStringConvertible {
    public let born: Birth
    /// The alternative at round 8: no id on the wire, the ledger keys `seen` by content.
    public var byContent = false
    public var pend: Msg? = nil      // round 3
    public var out: Outcome? = nil   // round 6 (nil is –, no outcome yet)
    public var seq: Int = 0          // round 8
    public var tries: Int = 0        // round 4

    public init(born: Birth, byContent: Bool = false) { self.born = born; self.byContent = byContent }

    public var description: String {
        var fields: [String] = []
        if born >= .pend { fields.append("pend: \(pend.map { "\($0)" } ?? "–")") }
        if born >= .out { fields.append("out: \(out.map { "\($0)" } ?? "–")") }
        if born >= .id { fields.append("seq: \(seq)") }
        if born >= .tries { fields.append("tries: \(tries)") }
        return "{\(fields.joined(separator: ", "))}"
    }

    /// Submit: the first element of `retry r`.
    public mutating func submit(_ r: Req) throws -> Msg {
        let m: Msg
        switch r {
        case .deposit(let n):
            guard born >= .credit else {
                throw Stuck(goal: "submit (\(r)): retry (deposit n) must put a message on the wire, Msg has no constructor",
                            scope: "n = \(n), state = \(self)")
            }
            m = .credit(n, id: born >= .id && !byContent ? seq + 1 : nil)
        case .withdraw(let n):
            guard born >= .debit else {
                throw Stuck(goal: "submit (\(r)): retry (withdraw n) must put a message on the wire, Msg has no constructor for it",
                            scope: "n = \(n), state = \(self)")
            }
            m = .debit(n, id: born >= .id && !byContent ? seq + 1 : nil)
        }
        if born >= .id { seq += 1 }          // P1a
        if born >= .pend { pend = m }
        return m
    }

    /// Timeout: the next element of `retry r`, or nothing.
    public mutating func timeout() throws -> Msg? {
        guard born >= .pend else {
            throw Stuck(goal: "timeout: retry says a timeout puts one more copy of the request on the wire; the state holds nothing to copy",
                        scope: "state = \(self)")
        }
        guard let m = pend else { return nil }   // nothing outstanding
        guard born >= .tries else { return m }   // unbounded resend
        if tries < K { tries += 1; return m }
        guard born >= .unknown else {
            throw Stuck(goal: "timeout with tries = K = \(K): the bound forbids another copy; the equation says out = unknown when no reply ever comes; out has no such value",
                        scope: "state = \(self)")
        }
        pend = nil; tries = 0; out = .unknown    // GiveUp (P4b)
        return nil
    }

    /// A reply arrives from the network.
    public mutating func receive(_ m: Msg) throws {
        guard case .reply(let rep) = m else { return }  // the harness only delivers replies here
        guard born >= .out else {
            throw Stuck(goal: "\(m) arrives: the equation says out ≡ rep⟦ r ⟧ b once a reply has been taken; the state has no out",
                        scope: "rep = \(rep), state = \(self)")
        }
        out = .rep(rep)
        if born >= .settle { pend = nil; tries = 0 }
    }
}

/// The smallest ledger that makes the equations checkable. Everything
/// here is an assumption about the other component (LedgerEq): it applies
/// CREDIT as +n and DEBIT as monus with a refusal carrying the balance
/// (P6a); it answers every request with a reply (round 5); from round 8 it
/// remembers `seen : Id ⇸ Rep` and answers a copy with the stored reply
/// (P2a), and nothing removes from `seen` (P3a).
public struct Ledger: Hashable, Sendable {
    public let born: Birth
    public var byContent: Bool
    public var bal: Int
    public var seen: [Int: Rep] = [:]        // P2a: keyed by id
    public var seenContent: [Msg: Rep] = [:] // the alternative: keyed by the message itself

    public init(born: Birth, bal: Int, byContent: Bool = false) { self.born = born; self.bal = bal; self.byContent = byContent }

    public mutating func receive(_ m: Msg) throws -> Msg {
        let n: Int, id: Int?, isCredit: Bool
        switch m {
        case .credit(let k, let i): (n, id, isCredit) = (k, i, true)
        case .debit(let k, let i): (n, id, isCredit) = (k, i, false)
        case .reply: preconditionFailure("the harness delivers only requests to the ledger")
        }
        if born >= .id, byContent, let stored = seenContent[m] { return .reply(stored) }  // a copy, by content
        if born >= .id, let id, let stored = seen[id] { return .reply(stored) }  // a copy: P2a
        let before = bal
        let rep: Rep
        if isCredit { bal += n; rep = .ok(bal) }
        else if n <= bal { bal -= n; rep = .ok(bal) }
        else { rep = .refused(bal) }
        guard born >= .reply else {
            throw Stuck(goal: "the ledger applied \(m) at b = \(before): bal′ = \(bal), rep = \(rep); the teller's out must become this rep; Msg has no reply constructor",
                        scope: "rep = \(rep), bal′ = \(bal), m = \(m)  (the ledger's scope: this names the other component)")
        }
        if born >= .id, byContent { seenContent[m] = rep }
        if born >= .id, let id { seen[id] = rep }
        return .reply(rep)
    }
}

/// One element of a drawn `net`. `request k` delivers a copy of the k-th
/// message the teller has put on the wire to the ledger; `reply k` delivers
/// a copy of the k-th reply the ledger produced to the teller. Any order,
/// any multiplicity: an index never drawn is a drop, drawn twice a
/// duplicate. An index beyond what exists is a no-op.
public enum Event: Hashable, Sendable, CustomStringConvertible {
    case timeout
    case request(Int)
    case reply(Int)
    public var description: String {
        switch self {
        case .timeout: return "timeout"
        case .request(let k): return "request \(k)"
        case .reply(let k): return "reply \(k)"
        }
    }

    public static let gen = Gen<Event> { tc in
        let kind = try tc.drawInteger(in: Int64(0)...2)
        let k = Int(try tc.drawInteger(in: Int64(0)...3))
        switch kind {
        case 0: return .timeout
        case 1: return .request(k)
        default: return .reply(k)
        }
    }
}

/// What one run of the session under one drawn `net` left behind.
public struct Trace: CustomStringConvertible {
    public var teller: Teller
    public var ledger: Ledger
    public var wire: [Msg] = []          // retry r, as far as it went
    public var replies: [Msg] = []       // what the ledger produced
    public var requestsDelivered = 0
    public var repliesDelivered = 0
    public var repliesTakenWhileWaiting = 0  // delivered before the (K+1)-th timeout
    public var timeouts = 0
    public var log: [String] = []

    public var description: String {
        "wire = \(wire), replies = \(replies), ledger.bal = \(ledger.bal), teller = \(teller)\n  events: \(log.joined(separator: " → "))"
    }
}

public enum Session {
    public static let inputs: Gen<(Req, Int, [Event])> = Hegel.zip(
        Req.gen,
        Gen<Int>.int(in: 0...9),
        Gen<[Event]>.array(of: Event.gen, count: 0...8))

    /// The session under one drawn net, with the definitions as far as `born`.
    public static func run(_ r: Req, _ b: Int, _ net: [Event], born: Birth, byContent: Bool = false) throws -> Trace {
        var t = Trace(teller: Teller(born: born, byContent: byContent), ledger: Ledger(born: born, bal: b, byContent: byContent))
        t.wire.append(try t.teller.submit(r))
        t.log.append("submit → \(t.wire[0])")
        for ev in net {
            switch ev {
            case .timeout:
                t.timeouts += 1
                if let m = try t.teller.timeout() { t.wire.append(m); t.log.append("timeout → \(m)") }
                else { t.log.append("timeout → nothing, state \(t.teller)") }
            case .request(let k):
                guard k < t.wire.count else { continue }
                t.requestsDelivered += 1
                let rep = try t.ledger.receive(t.wire[k])
                t.replies.append(rep)
                t.log.append("ledger gets \(t.wire[k]) → bal \(t.ledger.bal), \(rep)")
            case .reply(let k):
                guard k < t.replies.count else { continue }
                t.repliesDelivered += 1
                if t.timeouts <= K { t.repliesTakenWhileWaiting += 1 }
                try t.teller.receive(t.replies[k])
                t.log.append("teller gets \(t.replies[k]) → state \(t.teller)")
            }
        }
        return t
    }

    /// The three equations, and the P4b bound as a clause.
    public static func check(_ r: Req, _ b: Int, _ t: Trace) throws {
        if t.wire.count > K + 1 {
            throw Unequal(equation: "retry r is bounded: at most K + 1 = \(K + 1) copies (P4b)",
                          detail: "the wire holds \(t.wire.count) copies after \(t.timeouts) timeouts\n  \(t)")
        }
        if ![b, r.bal(b)].contains(t.ledger.bal) {
            throw Unequal(equation: "∀ net ∈ Net: apply* (net (retry r)) b ∈ { b, ⟦ r ⟧ b }",
                          detail: "apply* = \(t.ledger.bal), b = \(b), ⟦ r ⟧ b = \(r.bal(b))\n  \(t)")
        }
        if t.requestsDelivered >= 1, t.ledger.bal != r.bal(b) {
            throw Unequal(equation: "∀ net ∈ Net_fin: apply* (net (retry r)) b ≡ ⟦ r ⟧ b",
                          detail: "net delivered \(t.requestsDelivered) copies: apply* = \(t.ledger.bal), ⟦ r ⟧ b = \(r.bal(b))\n  \(t)")
        }
        if t.repliesTakenWhileWaiting >= 1, t.teller.out != .rep(r.rep(b)) {
            throw Unequal(equation: "∀ net ∈ Net_fin: out ≡ rep⟦ r ⟧ b once a reply has been taken",
                          detail: "out = \(t.teller.out.map { "\($0)" } ?? "–"), rep⟦ r ⟧ b = \(r.rep(b))\n  \(t)")
        }
        if t.repliesDelivered == 0, t.timeouts > K, t.teller.out != .unknown {
            throw Unequal(equation: "∀ net ∈ Net: if no reply ever comes, out = unknown (P4b, K = \(K))",
                          detail: "\(t.timeouts) timeouts, no reply, out = \(t.teller.out.map { "\($0)" } ?? "–")\n  \(t)")
        }
    }

    /// Hegel's half: the shrunk counterexample and the goal at it, or nil
    /// when the equations hold on every drawn net.
    public static func stuckGoal(born: Birth, byContent: Bool = false, seed: UInt64 = 1, testCases: UInt64? = 3000) throws -> String? {
        do {
            try forAll(inputs, testCases: testCases, seed: seed, database: "") { r, b, net in
                try check(r, b, try run(r, b, net, born: born, byContent: byContent))
            }
            return nil
        } catch let failure as PropertyFailure {
            let (r, b, net) = try replay(inputs, blob: failure.failures.first!.reproduceBlob!)
            do {
                try check(r, b, try run(r, b, net, born: born, byContent: byContent))
                return "counterexample (\(r), b = \(b), net = \(net)) did not fail on replay"
            } catch {
                return "counterexample: r = \(r), b = \(b), net = \(net)\n\(error)"
            }
        }
    }
}
