import Hegel

// The ledger service's relation, Phase A section 4 `Init_L`/`Next_L` with
// the decisions substituted: P1(a) Id = Teller × ℕ⁺, P2(a) a copy gets the
// stored reply, P3(a) seen never shrinks, P6(a) a refusal carries the
// balance. A step is the arrival of one message. The relation is fixed;
// this file is it as a Swift value, nothing more.

public typealias Acct = String
public typealias Teller = String

/// `Id = Teller × ℕ⁺`, written t·n.
public struct Id: Hashable, Sendable, CustomStringConvertible {
    public let teller: Teller
    public let seq: Int
    public init(_ teller: Teller, _ seq: Int) { self.teller = teller; self.seq = seq }
    public var description: String { "\(teller)·\(seq)" }
}

/// `Req = { dep n } ∪ { wd n }`, n ∈ ℕ⁺.
public enum Req: Hashable, Sendable, CustomStringConvertible {
    case deposit(Int)
    case withdraw(Int)
    public var amount: Int {
        switch self { case .deposit(let n), .withdraw(let n): return n }
    }
    public var description: String {
        switch self { case .deposit(let n): return "dep \(n)"; case .withdraw(let n): return "wd \(n)" }
    }
}

/// `Rep = { ok b } ∪ { refused b }`.
public enum Rep: Hashable, Sendable, CustomStringConvertible {
    case ok(Int)
    case refused(Int)
    public var balance: Int {
        switch self { case .ok(let b), .refused(let b): return b }
    }
    public var description: String {
        switch self { case .ok(let b): return "ok \(b)"; case .refused(let b): return "refused \(b)" }
    }
}

/// What the arrival of a request message determines: `id(m)`, `acct(m)`,
/// `req(m)`. The constructors of `Msg` are the wire format's; this is the
/// projection the ledger reads.
public struct Request: Hashable, Sendable, CustomStringConvertible {
    public let id: Id
    public let acct: Acct
    public let req: Req
    public init(_ id: Id, _ acct: Acct, _ req: Req) { self.id = id; self.acct = acct; self.req = req }
    public var description: String { "⟨\(id), \(acct), \(req)⟩" }
}

/// `⟦ r ⟧ b`, defined once, used by every component.
public func meaning(_ r: Req, _ b: Int) -> (bal: Int, rep: Rep) {
    switch r {
    case .deposit(let n): return (b + n, .ok(b + n))
    case .withdraw(let n): return n <= b ? (b - n, .ok(b - n)) : (b, .refused(b))
    }
}

/// The record read off drawing B: `bal ∈ [Acct → Bal]`, `seen ∈ (Id ⇸ Rep)`,
/// `out ∈ Rep ∪ {–}`.
public struct LedgerModel: Hashable, Sendable, CustomStringConvertible {
    public var bal: [Acct: Int]
    public var seen: [Id: Rep]
    public var out: Rep?

    /// `Init_L`: every account at b₀, nothing seen, no reply.
    public init(accounts: [Acct], initial b0: Int) {
        bal = Dictionary(uniqueKeysWithValues: accounts.map { ($0, b0) })
        seen = [:]
        out = nil
    }

    /// Which disjunct of `Next_L` the arrival of `m` takes.
    public enum Clause: Hashable, Sendable { case apply, again }

    public func clause(_ m: Request) -> Clause { seen[m.id] == nil ? .apply : .again }

    /// `Next_L` on `m`: the relation is defined for every message whose
    /// account exists and whose amount is in ℕ⁺ (TypeOK); an arriving
    /// message outside that is not a step of this relation.
    public func enabled(_ m: Request) -> Bool { bal[m.acct] != nil && m.req.amount >= 1 }

    /// Precondition: `enabled(m)`. Apply or Again, exactly one.
    public mutating func apply(_ m: Request) {
        precondition(enabled(m))
        if let stored = seen[m.id] {
            // Again: i ∈ dom seen, bal and seen unchanged, out′ = seen[i] (P2a).
            out = stored
        } else {
            // Apply: i ∉ dom seen.
            let (b, rep) = meaning(m.req, bal[m.acct]!)
            bal[m.acct] = b
            seen[m.id] = rep
            out = rep
        }
    }

    public var description: String {
        let balances = bal.keys.sorted().map { "\($0): \(bal[$0]!)" }.joined(separator: ", ")
        let seenText = seen.keys.sorted { ($0.teller, $0.seq) < ($1.teller, $1.seq) }
            .map { "\($0) ↦ \(seen[$0]!)" }.joined(separator: ", ")
        return "[bal: {\(balances)}, seen: {\(seenText)}, out: \(out.map(\.description) ?? "–")]"
    }

    // MARK: Behaviours

    /// One step of a behaviour: the arrival, which clause it took, the state after.
    public struct Event: Sendable, CustomStringConvertible {
        public let arrival: Request
        public let clause: Clause
        public let state: LedgerModel
        public var description: String { "arrive \(arrival) [\(clause)] → \(state)" }
    }

    /// The behaviour of the relation on a trace of arrivals. Every trace is
    /// a behaviour: the pick-any of `Next_L` is the arriving message.
    public static func behaviour(_ scenario: Scenario) -> [Event] {
        var s = scenario.initial
        return scenario.arrivals.map { m in
            let clause = s.clause(m)
            s.apply(m)
            return Event(arrival: m, clause: clause, state: s)
        }
    }

    // MARK: Refinement

    public struct Violation: Error, CustomStringConvertible {
        public let index: Int
        public let arrival: Request
        public let before: LedgerModel
        public let expected: LedgerModel
        public let recorded: LedgerModel
        public var description: String {
            "arrival \(index) \(arrival) is not a Next_L step: from \(before) the relation gives \(expected), the code recorded \(recorded)"
        }
    }

    /// Every consecutive pair of recorded states, with the arrival between
    /// them, is a `Next_L` step. The first pair that is not is the bug.
    public static func refines(
        _ recorded: [(arrival: Request, state: LedgerModel)], from initial: LedgerModel
    ) -> (violation: Violation?, final: LedgerModel) {
        var s = initial
        for (i, r) in recorded.enumerated() {
            guard s.enabled(r.arrival) else {
                return (Violation(index: i, arrival: r.arrival, before: s, expected: s, recorded: r.state), s)
            }
            var next = s
            next.apply(r.arrival)
            if next != r.state {
                return (Violation(index: i, arrival: r.arrival, before: s, expected: next, recorded: r.state), s)
            }
            s = next
        }
        return (nil, s)
    }
}

/// A drawn input: the initial state, the honest sequence each teller put
/// on the wire (t·1, t·2, … in order, P1a), and what the network made of
/// it: each message with multiplicity 0, 1 or 2 (dropped, delivered,
/// duplicated), in any order (delay). Every arrivals list is a behaviour.
public struct Scenario: Sendable, CustomStringConvertible {
    public let accounts: [Acct]
    public let b0: Int
    public let honest: [Request]
    public let arrivals: [Request]
    public init(accounts: [Acct], b0: Int, honest: [Request], arrivals: [Request]) {
        self.accounts = accounts; self.b0 = b0; self.honest = honest; self.arrivals = arrivals
    }
    public var initial: LedgerModel { LedgerModel(accounts: accounts, initial: b0) }
    public var description: String {
        "b₀ = \(b0), accounts \(accounts), honest \(honest), arrivals \(arrivals)"
    }

    public static let tellers: [Teller] = ["t1", "t2"]

    /// `requestsPerTeller` bounds each teller's sequence; `copies` bounds
    /// the multiplicity the network gives one message.
    public static func gen(requestsPerTeller: ClosedRange<Int64> = 0...3, copies: ClosedRange<Int64> = 0...2) -> Gen<Scenario> {
        Gen { tc in
            let accounts = try tc.drawInteger(in: Int64(1)...2) == 1 ? ["a"] : ["a", "b"]
            let b0 = Int(try tc.drawInteger(in: Int64(0)...10))
            var honest: [Request] = []
            for t in tellers {
                let k = try tc.drawInteger(in: requestsPerTeller)
                for n in 0..<k {
                    let acct = accounts[Int(try tc.drawInteger(in: 0...Int64(accounts.count - 1)))]
                    let amount = Int(try tc.drawInteger(in: Int64(1)...9))
                    let req: Req = try tc.drawBool() ? .withdraw(amount) : .deposit(amount)
                    honest.append(Request(Id(t, Int(n) + 1), acct, req))
                }
            }
            // The network: multiplicity, then order.
            var bag: [Request] = []
            for m in honest {
                let mult = try tc.drawInteger(in: copies)
                bag.append(contentsOf: Array(repeating: m, count: Int(mult)))
            }
            var arrivals: [Request] = []
            while !bag.isEmpty {
                let i = Int(try tc.drawInteger(in: 0...Int64(bag.count - 1)))
                arrivals.append(bag.remove(at: i))
            }
            return Scenario(accounts: accounts, b0: b0, honest: honest, arrivals: arrivals)
        }
    }
}
