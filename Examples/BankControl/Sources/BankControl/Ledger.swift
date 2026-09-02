/// The ledger service. It is the only place balances live, so a withdrawal
/// is decided against the true balance no matter how many tellers share the
/// account. It remembers the reply it gave to every request name, so a
/// duplicate or retried request gets the same reply and is not applied
/// twice.
public struct Ledger: Sendable {
    public private(set) var balances: [AccountID: Int]
    public private(set) var replies: [RequestID: Outcome] = [:]
    /// The order in which requests were first applied, for the tests.
    public private(set) var applied: [RequestID] = []

    public init(balances: [AccountID: Int]) {
        precondition(balances.values.allSatisfy { $0 >= 0 }, "opening balances are non-negative")
        self.balances = balances
    }

    public func balance(of account: AccountID) -> Int? { balances[account] }

    /// Handle a request, deciding it once. A second call with the same
    /// request id returns the reply from the first and changes nothing.
    public mutating func handle(_ request: Request) -> Reply {
        if let earlier = replies[request.id] {
            return Reply(id: request.id, outcome: earlier)
        }
        let outcome = decide(request.operation)
        replies[request.id] = outcome
        applied.append(request.id)
        return Reply(id: request.id, outcome: outcome)
    }

    private mutating func decide(_ operation: Operation) -> Outcome {
        guard let balance = balances[operation.account] else { return .noSuchAccount }
        switch operation {
        case .balance:
            return .accepted(balance: balance)
        case .deposit(let account, let amount):
            guard amount > 0 else { return .refused(balance: balance) }
            balances[account] = balance + amount
            return .accepted(balance: balance + amount)
        case .withdraw(let account, let amount):
            guard amount > 0, amount <= balance else { return .refused(balance: balance) }
            balances[account] = balance - amount
            return .accepted(balance: balance - amount)
        }
    }
}
