import Testing
@testable import BankControl

@Suite struct TellerTests {
    let a = AccountID(1)

    @Test func sendsOnFirstTickAndResendsSameRequestAfterTimeout() {
        var teller = Teller(id: TellerID(1), timeout: 3)
        let id = teller.submit(.withdraw(a, amount: 5))
        let first = teller.tick(now: 0)
        #expect(first.map(\.id) == [id])
        #expect(teller.tick(now: 1).isEmpty)
        #expect(teller.tick(now: 2).isEmpty)
        let retry = teller.tick(now: 3)
        #expect(retry == first, "a retry is the same request under the same name")
        #expect(teller.status[id] == .pending(attempts: 2))
    }

    @Test func replyCompletesAndLaterDuplicateReplyIsIgnored() {
        var teller = Teller(id: TellerID(1))
        let id = teller.submit(.deposit(a, amount: 5))
        _ = teller.tick(now: 0)
        teller.receive(Reply(id: id, outcome: .accepted(balance: 5)))
        #expect(teller.status[id] == .completed(.accepted(balance: 5)))
        #expect(teller.isIdle)
        teller.receive(Reply(id: id, outcome: .accepted(balance: 5)))
        #expect(teller.status[id] == .completed(.accepted(balance: 5)))
        #expect(teller.events.last == .ignoredReply(id))
        #expect(teller.tick(now: 10).isEmpty, "nothing to resend once completed")
    }

    @Test func replyForUnknownRequestIsIgnored() {
        var teller = Teller(id: TellerID(1))
        let stray = RequestID(teller: TellerID(2), sequence: 0)
        teller.receive(Reply(id: stray, outcome: .accepted(balance: 0)))
        #expect(teller.status[stray] == nil)
        #expect(teller.events == [.ignoredReply(stray)])
    }

    @Test func boundedRetriesAbandon() {
        var teller = Teller(id: TellerID(1), timeout: 1, maxAttempts: 3)
        let id = teller.submit(.balance(a))
        var sends = 0
        for now in 0..<10 { sends += teller.tick(now: now).count }
        #expect(sends == 3)
        #expect(teller.status[id] == .abandoned(attempts: 3))
        #expect(teller.isIdle)
    }

    @Test func requestNamesAreUniquePerTeller() {
        var teller = Teller(id: TellerID(1))
        let ids = (0..<5).map { _ in teller.submit(.balance(a)) }
        #expect(Set(ids).count == 5)
        #expect(ids.map(\.sequence) == [0, 1, 2, 3, 4])
    }
}
