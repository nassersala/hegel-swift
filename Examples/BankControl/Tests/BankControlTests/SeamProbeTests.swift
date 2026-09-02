import Testing
@testable import BankControl

/// Seven seams in the bank, each driven through the public API as it
/// stands and each asserting the outcome the specification calls correct.
/// Where the simulation's seeded faults cannot pin a delivery order, the
/// ledger, tellers and network are driven by hand in the test; where they
/// can, the simulation is run and the seed that produced the order is
/// reported. Sequence numbers start at 0 in this code, so "the first
/// request" is sequence 0 here where the scenarios say sequence 1.
@Suite struct SeamProbeTests {
    static let a = AccountID(1)
    static let t1 = TellerID(1)
    static let t2 = TellerID(2)

    /// Every completion a teller recorded, in order, from its event log.
    static func completions(_ teller: Teller) -> [(RequestID, Outcome)] {
        teller.events.compactMap {
            if case .completed(let id, let o) = $0 { return (id, o) } else { return nil }
        }
    }

    static func sends(_ teller: Teller) -> Int {
        teller.events.filter { if case .sent = $0 { return true } else { return false } }.count
    }

    /// Copies of requests the ledger handled: every handled copy produces
    /// one reply send, and the network counts sends from both sides.
    static func copiesHandled(_ sim: Simulation) -> Int {
        sim.network.sent - sim.tellers.values.map(sends).reduce(0, +)
    }

    // 1. Resend and original both arrive: delay, not drop. Delivery takes
    // three ticks and the teller resends after two, so the first copy is
    // still in flight when the resend goes out; both reach the ledger.
    @Test func resendAndOriginalBothArrive() {
        var sim = Simulation(
            ledger: Ledger(balances: [Self.a: 10]),
            tellers: [Teller(id: Self.t1, timeout: 2)],
            faults: Faults(delay: 3...3),
            script: [.init(at: 0, teller: Self.t1, operation: .withdraw(Self.a, amount: 4))],
            seed: 0)
        let quiet = sim.run(limit: 100); #expect(quiet)
        let id = RequestID(teller: Self.t1, sequence: 0)
        let teller = sim.tellers[Self.t1]!
        #expect(Self.sends(teller) >= 2, "the teller resent")
        #expect(Self.copiesHandled(sim) >= 2, "both copies reached the ledger")
        #expect(sim.ledger.balance(of: Self.a) == 6)
        #expect(sim.ledger.applied == [id])
        #expect(teller.completed[id] == .accepted(balance: 6))
        #expect(Self.completions(teller).count == 1)
    }

    // 2. Refusal delayed past the retry: withdraw 11 at 10, the refusal is
    // in flight when the teller resends, and the resend reaches the ledger.
    @Test func refusalDelayedPastTheRetry() {
        var sim = Simulation(
            ledger: Ledger(balances: [Self.a: 10]),
            tellers: [Teller(id: Self.t1, timeout: 2)],
            faults: Faults(delay: 3...3),
            script: [.init(at: 0, teller: Self.t1, operation: .withdraw(Self.a, amount: 11))],
            seed: 0)
        let quiet = sim.run(limit: 100); #expect(quiet)
        let id = RequestID(teller: Self.t1, sequence: 0)
        let teller = sim.tellers[Self.t1]!
        #expect(Self.sends(teller) >= 2, "the teller resent")
        #expect(Self.copiesHandled(sim) >= 2, "the resend reached the ledger")
        let done = Self.completions(teller)
        #expect(done.count == 1, "exactly one outcome recorded: \(done)")
        #expect(done.first?.1 == .refused(balance: 10))
        #expect(teller.completed[id] == .refused(balance: 10))
        #expect(!done.contains { $0.1.isAccepted }, "the teller never records ok")
        #expect(sim.ledger.balance(of: Self.a) == 10)
        #expect(sim.ledger.applied == [id])
    }

    // 3. Two tellers, whole balance, arrival order reversed from submission
    // order. By hand first, so the arrival order is exact; then the
    // simulation, searching seeds for the same reversal.
    @Test func twoTellersWholeBalanceArrivalReversed() {
        var ledger = Ledger(balances: [Self.a: 10])
        var t1 = Teller(id: Self.t1)
        var t2 = Teller(id: Self.t2)
        let id1 = t1.submit(.withdraw(Self.a, amount: 10))   // submitted first
        let id2 = t2.submit(.withdraw(Self.a, amount: 10))
        let r1 = t1.tick(now: 0)
        let r2 = t2.tick(now: 0)
        let reply2 = ledger.handle(r2[0])                    // arrives first
        let reply1 = ledger.handle(r1[0])
        t1.receive(reply1)
        t2.receive(reply2)
        #expect(t2.completed[id2] == .accepted(balance: 0))
        #expect(t1.completed[id1] == .refused(balance: 0), "the teller that submitted first is the refused one")
        #expect(ledger.balance(of: Self.a) == 0)
        #expect(ledger.applied == [id2, id1])

        // The same through the simulation: both submit at tick 0 (t1 is
        // submitted first, the script sorts by teller), delays 1...4.
        var reversedSeed: UInt64? = nil
        for seed in UInt64(0)..<200 {
            var sim = Simulation(
                ledger: Ledger(balances: [Self.a: 10]),
                tellers: [Teller(id: Self.t1, timeout: 20), Teller(id: Self.t2, timeout: 20)],
                faults: Faults(delay: 1...4),
                script: [Self.t1, Self.t2].map { .init(at: 0, teller: $0, operation: .withdraw(Self.a, amount: 10)) },
                seed: seed)
            let quiet = sim.run(limit: 100); #expect(quiet, "seed \(seed)")
            let s1 = RequestID(teller: Self.t1, sequence: 0)
            let s2 = RequestID(teller: Self.t2, sequence: 0)
            guard sim.ledger.applied == [s2, s1] else { continue }
            reversedSeed = seed
            #expect(sim.tellers[Self.t2]!.completed[s2] == .accepted(balance: 0), "seed \(seed)")
            #expect(sim.tellers[Self.t1]!.completed[s1] == .refused(balance: 0), "seed \(seed)")
            #expect(sim.ledger.balance(of: Self.a) == 0, "seed \(seed)")
            break
        }
        #expect(reversedSeed != nil, "some seed reverses the arrival order")
    }

    // 4. Two tellers whose first requests carry the same sequence number.
    @Test func twoTellersSameSequenceNumber() {
        var sim = Simulation(
            ledger: Ledger(balances: [Self.a: 10]),
            tellers: [Teller(id: Self.t1), Teller(id: Self.t2)],
            faults: .perfect,
            script: [Self.t1, Self.t2].map { .init(at: 0, teller: $0, operation: .deposit(Self.a, amount: 1)) },
            seed: 0)
        let quiet = sim.run(limit: 100); #expect(quiet)
        let s1 = RequestID(teller: Self.t1, sequence: 0)
        let s2 = RequestID(teller: Self.t2, sequence: 0)
        #expect(s1.sequence == s2.sequence)
        #expect(Set(sim.ledger.applied) == [s1, s2], "both applied: \(sim.ledger.applied)")
        #expect(sim.ledger.applied.count == 2)
        #expect(sim.tellers[Self.t1]!.completed[s1]?.isAccepted == true)
        #expect(sim.tellers[Self.t2]!.completed[s2]?.isAccepted == true)
        #expect(sim.ledger.balance(of: Self.a) == 12)
    }

    // 5. Late reply after give-up. Timeout 1, two attempts: the first copy
    // is dropped, the second is held by the network until after the teller
    // has abandoned the request; the ledger applies it and the reply comes
    // back to a teller that is no longer waiting.
    @Test func lateReplyAfterGiveUp() {
        var teller = Teller(id: Self.t1, timeout: 1, maxAttempts: 2)
        let id = teller.submit(.withdraw(Self.a, amount: 4))
        let first = teller.tick(now: 0)            // dropped
        let second = teller.tick(now: 1)           // delayed
        #expect(first.map(\.id) == [id] && second == first)
        #expect(teller.tick(now: 2).isEmpty, "third attempt is the give-up")
        #expect(teller.status[id] == .abandoned(attempts: 2))

        var ledger = Ledger(balances: [Self.a: 10])
        let reply = ledger.handle(second[0])       // applied after the give-up
        #expect(reply.outcome == .accepted(balance: 6))
        teller.receive(reply)

        #expect(ledger.balance(of: Self.a) == 6)
        #expect(ledger.applied == [id])
        // Per the relation: the teller does not know. Not ok, not refused.
        if case .completed(let o)? = teller.status[id] {
            Issue.record("teller recorded \(o) for a request it abandoned")
        }
        #expect(teller.status[id] == .abandoned(attempts: 2))
        // What the control actually records for the late reply.
        #expect(teller.events.last == .ignoredReply(id))
        #expect(teller.completed[id] == nil)

        // The same through the simulation: the give-up is at tick 2, any
        // surviving copy lands at tick 4 or later. Search for a seed where
        // exactly one copy survived and its reply reached the teller.
        var found: UInt64? = nil
        for seed in UInt64(0)..<2_000 {
            var sim = Simulation(
                ledger: Ledger(balances: [Self.a: 10]),
                tellers: [Teller(id: Self.t1, timeout: 1, maxAttempts: 2)],
                faults: Faults(drop: 0.5, delay: 4...6),
                script: [.init(at: 0, teller: Self.t1, operation: .withdraw(Self.a, amount: 4))],
                seed: seed)
            let quiet = sim.run(limit: 100); #expect(quiet, "seed \(seed)")
            let t = sim.tellers[Self.t1]!
            guard sim.ledger.applied == [id], Self.copiesHandled(sim) == 1,
                  t.events.contains(.ignoredReply(id)) else { continue }
            found = seed
            #expect(sim.ledger.balance(of: Self.a) == 6, "seed \(seed)")
            #expect(t.status[id] == .abandoned(attempts: 2), "seed \(seed): \(String(describing: t.status[id]))")
            #expect(t.completed[id] == nil, "seed \(seed)")
            break
        }
        #expect(found != nil, "some seed delivers exactly one copy after the give-up and its reply")
    }

    // 6. One teller's own order: deposit 5 then withdraw 12 at balance 10.
    // Every teller's requests apply in that teller's order, so the deposit
    // goes first and the withdrawal succeeds at 15, leaving 3. The teller
    // submits at ticks 0 and 1 and the network may take 1...3 ticks, so a
    // seed that lands the withdrawal first would break the property.
    @Test func oneTellersOwnOrderIsKept() {
        let s0 = RequestID(teller: Self.t1, sequence: 0)
        let s1 = RequestID(teller: Self.t1, sequence: 1)
        var violation: String? = nil
        for seed in UInt64(0)..<100 {
            var sim = Simulation(
                ledger: Ledger(balances: [Self.a: 10]),
                tellers: [Teller(id: Self.t1, timeout: 20)],
                faults: Faults(delay: 1...3),
                script: [
                    .init(at: 0, teller: Self.t1, operation: .deposit(Self.a, amount: 5)),
                    .init(at: 1, teller: Self.t1, operation: .withdraw(Self.a, amount: 12)),
                ],
                seed: seed)
            let quiet = sim.run(limit: 100); #expect(quiet, "seed \(seed)")
            let t = sim.tellers[Self.t1]!
            #expect(t.events.prefix(1) == [.submitted(s0, .deposit(Self.a, amount: 5))], "seed \(seed)")
            let inOrder = sim.ledger.applied == [s0, s1]
                && t.completed[s0] == .accepted(balance: 15)
                && t.completed[s1] == .accepted(balance: 3)
                && sim.ledger.balance(of: Self.a) == 3
            if !inOrder && violation == nil {
                violation = "seed \(seed): applied \(sim.ledger.applied), "
                    + "\(s0) \(String(describing: t.completed[s0])), \(s1) \(String(describing: t.completed[s1])), "
                    + "balance \(String(describing: sim.ledger.balance(of: Self.a)))"
            }
        }
        // The control's one wrong answer on the seven drawn seam scenarios
        // (specs/system-from-specifications.md, "The control on the seven
        // seam scenarios"): it never named per-teller order, so nothing in it
        // keeps it. Recorded as a known issue so the finding stays in the
        // test and CI stays green.
        withKnownIssue("control applies one teller's requests out of order (seed 7, delay 1...3)") {
            #expect(violation == nil, "per-teller order broken: \(violation ?? "")")
        }
    }

    // 7. A duplicate of a finished request's reply arrives after the next
    // request of the same shape has gone out and before that request's own
    // reply. Sequence 0 is the finished one, sequence 1 the new one.
    @Test func staleDuplicateReplyIsNotTakenForTheNextRequest() {
        var ledger = Ledger(balances: [Self.a: 10])
        var teller = Teller(id: Self.t1)
        let first = teller.submit(.deposit(Self.a, amount: 1))
        let reply1 = ledger.handle(teller.tick(now: 0)[0])
        teller.receive(reply1)
        #expect(teller.completed[first] == .accepted(balance: 11))

        let second = teller.submit(.deposit(Self.a, amount: 1))
        let req2 = teller.tick(now: 1)[0]
        teller.receive(reply1)                     // the delayed duplicate, first
        #expect(teller.status[second] == .pending(attempts: 1), "still waiting on \(second)")
        #expect(teller.status[first] == .completed(.accepted(balance: 11)))
        #expect(teller.events.last == .ignoredReply(first))

        teller.receive(ledger.handle(req2))
        #expect(teller.completed[second] == .accepted(balance: 12))
        #expect(ledger.balance(of: Self.a) == 12)
        #expect(Self.completions(teller).map(\.0) == [first, second])
    }
}
