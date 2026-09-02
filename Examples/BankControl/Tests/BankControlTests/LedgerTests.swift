import Testing
@testable import BankControl

@Suite struct LedgerTests {
    let a = AccountID(1)
    let t = TellerID(1)
    func req(_ n: Int, _ op: Operation) -> Request {
        Request(id: RequestID(teller: t, sequence: n), operation: op)
    }

    @Test func depositAndWithdraw() {
        var ledger = Ledger(balances: [a: 10])
        #expect(ledger.handle(req(0, .deposit(a, amount: 5))).outcome == .accepted(balance: 15))
        #expect(ledger.handle(req(1, .withdraw(a, amount: 15))).outcome == .accepted(balance: 0))
        #expect(ledger.balance(of: a) == 0)
    }

    @Test func overdrawIsRefusedAndChangesNothing() {
        var ledger = Ledger(balances: [a: 10])
        #expect(ledger.handle(req(0, .withdraw(a, amount: 11))).outcome == .refused(balance: 10))
        #expect(ledger.balance(of: a) == 10)
        #expect(ledger.handle(req(1, .withdraw(a, amount: 10))).outcome == .accepted(balance: 0))
        #expect(ledger.handle(req(2, .withdraw(a, amount: 1))).outcome == .refused(balance: 0))
    }

    @Test func duplicateRequestIsAppliedOnceAndAnsweredTheSame() {
        var ledger = Ledger(balances: [a: 10])
        let first = ledger.handle(req(0, .withdraw(a, amount: 4)))
        let again = ledger.handle(req(0, .withdraw(a, amount: 4)))
        #expect(first == again)
        #expect(ledger.balance(of: a) == 6)
        #expect(ledger.applied == [RequestID(teller: t, sequence: 0)])
    }

    @Test func nonPositiveAmountsAndUnknownAccounts() {
        var ledger = Ledger(balances: [a: 10])
        #expect(ledger.handle(req(0, .deposit(a, amount: 0))).outcome == .refused(balance: 10))
        #expect(ledger.handle(req(1, .withdraw(a, amount: -3))).outcome == .refused(balance: 10))
        #expect(ledger.handle(req(2, .balance(AccountID(9)))).outcome == .noSuchAccount)
        #expect(ledger.balance(of: a) == 10)
    }
}
