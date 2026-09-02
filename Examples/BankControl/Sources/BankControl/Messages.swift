/// Identifies a teller app. Two tellers may work the same account.
public struct TellerID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public static func < (a: TellerID, b: TellerID) -> Bool { a.raw < b.raw }
    public var description: String { "teller\(raw)" }
}

public struct AccountID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public static func < (a: AccountID, b: AccountID) -> Bool { a.raw < b.raw }
    public var description: String { "acct\(raw)" }
}

/// A request is named by the teller that made it and that teller's own
/// sequence number. The name is what makes retries and duplicates safe: the
/// ledger applies each name at most once, whatever the network does.
public struct RequestID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let teller: TellerID
    public let sequence: Int
    public init(teller: TellerID, sequence: Int) {
        self.teller = teller
        self.sequence = sequence
    }
    public static func < (a: RequestID, b: RequestID) -> Bool {
        (a.teller, a.sequence) < (b.teller, b.sequence)
    }
    public var description: String { "\(teller)#\(sequence)" }
}

public enum Operation: Hashable, Sendable {
    case deposit(AccountID, amount: Int)
    case withdraw(AccountID, amount: Int)
    case balance(AccountID)

    public var account: AccountID {
        switch self {
        case .deposit(let a, _), .withdraw(let a, _), .balance(let a): return a
        }
    }
}

public struct Request: Hashable, Sendable {
    public let id: RequestID
    public let operation: Operation
    public init(id: RequestID, operation: Operation) {
        self.id = id
        self.operation = operation
    }
}

/// What the ledger decided. Every outcome carries the balance the ledger
/// held when it decided, so the teller can show it.
public enum Outcome: Hashable, Sendable {
    case accepted(balance: Int)
    case refused(balance: Int)
    case noSuchAccount

    public var isAccepted: Bool {
        if case .accepted = self { return true } else { return false }
    }
}

public struct Reply: Hashable, Sendable {
    public let id: RequestID
    public let outcome: Outcome
    public init(id: RequestID, outcome: Outcome) {
        self.id = id
        self.outcome = outcome
    }
}

public enum Endpoint: Hashable, Sendable, CustomStringConvertible {
    case ledger
    case teller(TellerID)
    public var description: String {
        switch self {
        case .ledger: return "ledger"
        case .teller(let t): return t.description
        }
    }
}

public enum Message: Hashable, Sendable {
    case request(Request)
    case reply(Reply)
}

public struct Envelope: Hashable, Sendable {
    public let from: Endpoint
    public let to: Endpoint
    public let message: Message
    public init(from: Endpoint, to: Endpoint, message: Message) {
        self.from = from
        self.to = to
        self.message = message
    }
}
