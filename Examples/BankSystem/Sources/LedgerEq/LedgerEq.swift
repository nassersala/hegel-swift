import Hegel

// The ledger derived from its equation, with the network as a drawn term
// (Phase A section 5):
//
//   ∀ net ∈ Net₁:  apply* (net (send r)) b  ≡  ⟦ r ⟧ b
//   ∀ net ∈ Net:   apply* (net (send r)) b  ∈  { b, ⟦ r ⟧ b }
//
// and for every arrival, the reply the ledger produces equals rep⟦ r ⟧ at
// the balance before r. `Msg` and `State` start with nothing; each round
// is one stuck goal (Hegel's shrunk counterexample with the values in
// scope) answered by one constructor or one field. The rounds are the
// `Round1…Round4` ledgers below, kept as written so the rounds replay.

public indirect enum Req: Hashable, Sendable, CustomStringConvertible {
    case deposit(Int)
    case withdraw(Int)
    case then(Req, Req)

    public var description: String {
        switch self {
        case .deposit(let n): return "deposit \(n)"
        case .withdraw(let n): return "withdraw \(n)"
        case .then(let r, let s): return "(\(r) then \(s))"
        }
    }

    /// The leaves in order: the requests `then` sequences.
    public var leaves: [Req] {
        if case .then(let r, let s) = self { return r.leaves + s.leaves }
        return [self]
    }

    /// `⟦ r ⟧ b = ⟨bal, rep⟩`: withdraw refused when n > b, the reply carries the balance.
    public func meaning(_ b: Int) -> (bal: Int, rep: Rep) {
        switch self {
        case .deposit(let n): return (b + n, .ok(b + n))
        case .withdraw(let n): return n > b ? (b, .refused(b)) : (b - n, .ok(b - n))
        case .then(let r, let s): return s.meaning(r.meaning(b).bal)
        }
    }

    public static func gen(depth: Int) -> Gen<Req> { Gen { tc in try draw(tc, depth: depth) } }

    private static func draw(_ tc: TestCase, depth: Int) throws -> Req {
        switch try tc.drawInteger(in: Int64(0)...(depth > 0 ? 2 : 1)) {
        case 0: return .deposit(Int(try tc.drawInteger(in: Int64(0)...9)))
        case 1: return .withdraw(Int(try tc.drawInteger(in: Int64(0)...9)))
        default: return .then(try draw(tc, depth: depth - 1), try draw(tc, depth: depth - 1))
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

/// The environment as a drawn term: one multiplicity per message of the
/// stream and one permutation of the copies. `Net₁` draws multiplicity
/// in 1...2, `Net` in 0...2. `.whole` permutes the entire stream, the
/// equation as written; `.perRequest` permutes copies only within one
/// request's messages and keeps requests in order (a teller with one
/// request outstanding at a time, P5a as a clause on `net`); `.delayed`
/// is `.perRequest` with the last copy of every duplicated message held
/// back until after everything else (the resend whose original is still
/// in flight, the teller having moved on).
public struct Net: Sendable, CustomStringConvertible {
    public var mults: [Int]
    public var picks: [Int]
    public enum Order: Sendable { case whole, perRequest, delayed }

    public static func gen(messages: Int, minMultiplicity: Int) -> Gen<Net> {
        Gen { tc in
            var mults: [Int] = []
            for _ in 0..<messages { mults.append(Int(try tc.drawInteger(in: Int64(minMultiplicity)...2))) }
            let total = mults.reduce(0, +)
            var picks: [Int] = []
            for i in 0..<total { picks.append(Int(try tc.drawInteger(in: 0...Int64(max(0, total - 1 - i))))) }
            return Net(mults: mults, picks: picks)
        }
    }

    /// `net s`, with `s` given as one group of messages per request.
    /// Returns the arrivals tagged with the index of the request each came from.
    public func apply<M>(_ groups: [[M]], order: Order) -> [(request: Int, msg: M)] {
        var copies: [[(Int, M)]] = []
        var k = 0
        for (j, g) in groups.enumerated() {
            var group: [(Int, M)] = []
            for m in g {
                let c = k < mults.count ? mults[k] : 1
                for _ in 0..<c { group.append((j, m)) }
                k += 1
            }
            copies.append(group)
        }
        var p = picks[...]
        func permute(_ xs: [(Int, M)]) -> [(Int, M)] {
            var rest = xs, out: [(Int, M)] = []
            while !rest.isEmpty {
                let i = (p.popFirst() ?? 0) % rest.count
                out.append(rest.remove(at: i))
            }
            return out
        }
        switch order {
        case .whole: return permute(copies.flatMap { $0 }).map { (request: $0.0, msg: $0.1) }
        case .perRequest: return copies.flatMap(permute).map { (request: $0.0, msg: $0.1) }
        case .delayed:
            var late: [(Int, M)] = []
            let early = copies.map { g -> [(Int, M)] in
                var g = permute(g)
                if g.count >= 2 { late.append(g.removeLast()) }
                return g
            }
            return (early.flatMap { $0 } + late).map { (request: $0.0, msg: $0.1) }
        }
    }

    public var description: String { "copies \(mults), picks \(picks)" }
}

/// One round's ledger: `send` and `apply` partial, `nil` is the stuck goal.
public protocol Ledger {
    associatedtype Msg: Hashable & Sendable & CustomStringConvertible
    associatedtype State: Sendable & CustomStringConvertible
    static func initial(_ b: Int) -> State
    static func bal(_ s: State) -> Int
    /// One list of messages per leaf request, in order; nil where undefined.
    static func send(_ r: Req) -> [[Msg]]?
    static func apply(_ m: Msg, _ s: State) -> (State, Rep)?
}

/// The stuck goal as a concrete term, or the equation refuted on a defined case.
public struct Goal: Error, CustomStringConvertible {
    public enum Kind: Sendable { case sendUndefined, applyUndefined, balanceUnequal, replyUnequal }
    public let kind: Kind
    public let r: Req
    public let b: Int
    public let net: Net
    public let detail: String
    public var description: String {
        let k: String
        switch kind {
        case .sendUndefined: k = "stuck: send undefined"
        case .applyUndefined: k = "stuck: apply undefined"
        case .balanceUnequal: k = "balance unequal"
        case .replyUnequal: k = "reply unequal"
        }
        return "\(k) at ⟦ \(r) ⟧ \(b) = \(r.meaning(b).bal), net = \(net); \(detail)"
    }
}

public enum Calculation {
    /// The property for one round. `minMultiplicity` 1 is Net₁, 0 is Net.
    public static func check<L: Ledger>(
        _ ledger: L.Type, minMultiplicity: Int, order: Net.Order, depth: Int = 0, seed: UInt64 = 1
    ) throws -> Goal? {
        let inputs: Gen<(Req, Int, Net)> = Req.gen(depth: depth).flatMap { r in
            Hegel.zip(Gen<Int>.int(in: 0...9), Net.gen(messages: r.leaves.count, minMultiplicity: minMultiplicity)).map { (r, $0, $1) }
        }
        do {
            try forAll(inputs, seed: seed, database: "") { r, b, net in try run(ledger, r, b, net, order: order) }
            return nil
        } catch let failure as PropertyFailure {
            let (r, b, net) = try replay(inputs, blob: failure.failures.first!.reproduceBlob!)
            do { try run(ledger, r, b, net, order: order) } catch let g as Goal { return g }
            return nil
        }
    }

    static func run<L: Ledger>(_ ledger: L.Type, _ r: Req, _ b: Int, _ net: Net, order: Net.Order) throws {
        let leaves = r.leaves
        guard let groups = L.send(r) else { throw Goal(kind: .sendUndefined, r: r, b: b, net: net, detail: "in scope: r = \(r), b = \(b)") }
        let arrivals = net.apply(groups, order: order)
        // Expected: the leaves with at least one copy, folded in order; each leaf's reply at the balance before it.
        var expectedBal = b
        var expectedRep: [Int: Rep] = [:]
        for (j, leaf) in leaves.enumerated() where arrivals.contains(where: { $0.request == j }) {
            let m = leaf.meaning(expectedBal)
            expectedRep[j] = m.rep
            expectedBal = m.bal
        }
        var s = L.initial(b)
        var trace: [String] = []
        for a in arrivals {
            guard let (s2, rep) = L.apply(a.msg, s) else {
                throw Goal(kind: .applyUndefined, r: r, b: b, net: net, detail: "arrivals \(arrivals.map(\.msg)); at \(a.msg) with state \(s); in scope: \(a.msg), state \(s)")
            }
            trace.append("\(a.msg) → \(s2), reply \(rep)")
            if rep != expectedRep[a.request]! {
                throw Goal(kind: .replyUnequal, r: r, b: b, net: net, detail: "arrivals \(arrivals.map(\.msg)); expected \(expectedRep[a.request]!) got \(rep); trace \(trace)")
            }
            s = s2
        }
        if L.bal(s) != expectedBal {
            throw Goal(kind: .balanceUnequal, r: r, b: b, net: net, detail: "arrivals \(arrivals.map(\.msg)); expected \(expectedBal) got \(L.bal(s)); trace \(trace)")
        }
    }
}

// MARK: - Rounds

/// Round 0: nothing born.
public enum Round0: Ledger {
    public enum Msg: Hashable, Sendable, CustomStringConvertible { public var description: String { "" } }
    public struct State: Sendable, CustomStringConvertible { public var bal: Int; public var description: String { "[bal: \(bal)]" } }
    public static func initial(_ b: Int) -> State { State(bal: b) }
    public static func bal(_ s: State) -> Int { s.bal }
    public static func send(_ r: Req) -> [[Msg]]? { nil }
    public static func apply(_ m: Msg, _ s: State) -> (State, Rep)? { nil }
}

/// Round 1: CREDIT n born (n in scope). Round 2: DEBIT n born (n in scope).
public enum Round2: Ledger {
    public enum Msg: Hashable, Sendable, CustomStringConvertible {
        case credit(Int), debit(Int)
        public var description: String {
            switch self { case .credit(let n): return "CREDIT \(n)"; case .debit(let n): return "DEBIT \(n)" }
        }
    }
    public typealias State = Round0.State
    public static func initial(_ b: Int) -> State { State(bal: b) }
    public static func bal(_ s: State) -> Int { s.bal }
    public static func send(_ r: Req) -> [[Msg]]? {
        switch r {
        case .deposit(let n): return [[.credit(n)]]
        case .withdraw(let n): return [[.debit(n)]]
        case .then: return nil
        }
    }
    public static func apply(_ m: Msg, _ s: State) -> (State, Rep)? {
        switch m {
        case .credit(let n): return (State(bal: s.bal + n), .ok(s.bal + n))
        case .debit(let n): return n > s.bal ? (s, .refused(s.bal)) : (State(bal: s.bal - n), .ok(s.bal - n))
        }
    }
}

/// Round 3: the copy. `last : Msg?` born on the ledger state, its value the
/// message in scope; a message equal to `last` is not applied again and
/// gets the reply the balance now gives, which for one request is the
/// stored reply.
public enum Round3: Ledger {
    public typealias Msg = Round2.Msg
    public struct State: Sendable, CustomStringConvertible {
        public var bal: Int
        public var last: Msg?
        public var description: String { "[bal: \(bal), last: \(last.map(\.description) ?? "–")]" }
    }
    public static func initial(_ b: Int) -> State { State(bal: b, last: nil) }
    public static func bal(_ s: State) -> Int { s.bal }
    public static func send(_ r: Req) -> [[Msg]]? {
        switch r {
        case .deposit(let n): return [[.credit(n)]]
        case .withdraw(let n): return [[.debit(n)]]
        case .then: return nil
        }
    }
    public static func apply(_ m: Msg, _ s: State) -> (State, Rep)? {
        if m == s.last { return (s, .ok(s.bal)) }
        switch m {
        case .credit(let n): return (State(bal: s.bal + n, last: m), .ok(s.bal + n))
        case .debit(let n): return n > s.bal ? (State(bal: s.bal, last: m), .refused(s.bal)) : (State(bal: s.bal - n, last: m), .ok(s.bal - n))
        }
    }
}

/// Round 4: the copy of a refused withdraw. The reply to a copy is what
/// the message says at the balance now (m and s.bal in scope): refused
/// bal when n > bal, ok bal otherwise. No new field.
public enum Round4: Ledger {
    public typealias Msg = Round2.Msg
    public typealias State = Round3.State
    public static func initial(_ b: Int) -> State { State(bal: b, last: nil) }
    public static func bal(_ s: State) -> Int { s.bal }
    public static func send(_ r: Req) -> [[Msg]]? { Round3.send(r) }
    public static func apply(_ m: Msg, _ s: State) -> (State, Rep)? {
        if m == s.last {
            if case .debit(let n) = m, n > s.bal { return (s, .refused(s.bal)) }
            return (s, .ok(s.bal))
        }
        return Round3.apply(m, s)
    }
}

/// Round 5: the copy of a withdraw that was accepted at the balance before
/// and would be refused at the balance now. The reply to a copy cannot be
/// computed from the balance now; what is in scope at the first
/// application is the reply itself, so `lastRep : Rep` is born on the
/// state, its value the `rep` in scope there.
public enum Round5: Ledger {
    public typealias Msg = Round2.Msg
    public struct State: Sendable, CustomStringConvertible {
        public var bal: Int
        public var last: Msg?
        public var lastRep: Rep?
        public var description: String { "[bal: \(bal), last: \(last.map(\.description) ?? "–"), lastRep: \(lastRep.map(\.description) ?? "–")]" }
    }
    public static func initial(_ b: Int) -> State { State(bal: b, last: nil, lastRep: nil) }
    public static func bal(_ s: State) -> Int { s.bal }
    public static func send(_ r: Req) -> [[Msg]]? { Round3.send(r) }
    public static func apply(_ m: Msg, _ s: State) -> (State, Rep)? {
        if m == s.last { return (s, s.lastRep!) }
        let (bal, rep): (Int, Rep)
        switch m {
        case .credit(let n): (bal, rep) = (s.bal + n, .ok(s.bal + n))
        case .debit(let n): (bal, rep) = n > s.bal ? (s.bal, .refused(s.bal)) : (s.bal - n, .ok(s.bal - n))
        }
        return (State(bal: bal, last: m, lastRep: rep), rep)
    }
}

/// Round 6: `then`. send (r₁ then r₂) = send r₁ ++ send r₂, nothing born.
public enum Round6: Ledger {
    public typealias Msg = Round2.Msg
    public typealias State = Round5.State
    public static func initial(_ b: Int) -> State { Round5.initial(b) }
    public static func bal(_ s: State) -> Int { s.bal }
    public static func send(_ r: Req) -> [[Msg]]? {
        switch r {
        case .deposit(let n): return [[.credit(n)]]
        case .withdraw(let n): return [[.debit(n)]]
        case .then(let x, let y):
            guard let a = send(x), let b = send(y) else { return nil }
            return a + b
        }
    }
    public static func apply(_ m: Msg, _ s: State) -> (State, Rep)? { Round5.apply(m, s) }
}

/// Round 7: two equal messages from two requests (deposit 1 then deposit 1).
/// Nothing in CREDIT n tells them apart and nothing in scope at the goal
/// does either, except which of the two requests the message came from:
/// its position in the sequence. An identity is invented; its value is
/// that position. `send` numbers the leaves in order.
public enum Round7: Ledger {
    public enum Msg: Hashable, Sendable, CustomStringConvertible {
        case credit(Int, id: Int), debit(Int, id: Int)
        public var description: String {
            switch self { case .credit(let n, let i): return "CREDIT \(n) #\(i)"; case .debit(let n, let i): return "DEBIT \(n) #\(i)" }
        }
    }
    public struct State: Sendable, CustomStringConvertible {
        public var bal: Int
        public var last: Msg?
        public var lastRep: Rep?
        public var description: String { "[bal: \(bal), last: \(last.map(\.description) ?? "–"), lastRep: \(lastRep.map(\.description) ?? "–")]" }
    }
    public static func initial(_ b: Int) -> State { State(bal: b, last: nil, lastRep: nil) }
    public static func bal(_ s: State) -> Int { s.bal }
    public static func send(_ r: Req) -> [[Msg]]? {
        r.leaves.enumerated().map { i, leaf in
            switch leaf {
            case .deposit(let n): return [.credit(n, id: i)]
            case .withdraw(let n): return [.debit(n, id: i)]
            case .then: fatalError("leaves")
            }
        }
    }
    public static func apply(_ m: Msg, _ s: State) -> (State, Rep)? {
        if m == s.last { return (s, s.lastRep!) }
        let (bal, rep): (Int, Rep)
        switch m {
        case .credit(let n, _): (bal, rep) = (s.bal + n, .ok(s.bal + n))
        case .debit(let n, _): (bal, rep) = n > s.bal ? (s.bal, .refused(s.bal)) : (s.bal - n, .ok(s.bal - n))
        }
        return (State(bal: bal, last: m, lastRep: rep), rep)
    }
}

/// Round 8: a copy held back past a later request. `last` is one message;
/// the copy in scope is not it. What was in scope at its first application
/// was `(m, rep)`, so `last, lastRep` become `seen : Msg ⇸ Rep`, every pair
/// kept. That is P3a; nothing removes from `seen`.
public enum Round8: Ledger {
    public typealias Msg = Round7.Msg
    public struct State: Sendable, CustomStringConvertible {
        public var bal: Int
        public var seen: [Msg: Rep]
        public var description: String { "[bal: \(bal), seen: \(seen.map { "\($0.key) ↦ \($0.value)" }.sorted())]" }
    }
    public static func initial(_ b: Int) -> State { State(bal: b, seen: [:]) }
    public static func bal(_ s: State) -> Int { s.bal }
    public static func send(_ r: Req) -> [[Msg]]? { Round7.send(r) }
    public static func apply(_ m: Msg, _ s: State) -> (State, Rep)? {
        if let rep = s.seen[m] { return (s, rep) }
        let (bal, rep): (Int, Rep)
        switch m {
        case .credit(let n, _): (bal, rep) = (s.bal + n, .ok(s.bal + n))
        case .debit(let n, _): (bal, rep) = n > s.bal ? (s.bal, .refused(s.bal)) : (s.bal - n, .ok(s.bal - n))
        }
        var s2 = s
        s2.bal = bal
        s2.seen[m] = rep
        return (s2, rep)
    }
}
