import Testing
@testable import BankControl

/// The bank end to end. Random scripts over a hostile network, with the
/// invariants checked after every tick and the final state checked against
/// a sequential replay.
@Suite struct BankTests {
    static let accounts = [AccountID(1), AccountID(2)]
    static let tellers = [TellerID(1), TellerID(2)]
    static let opening: [AccountID: Int] = [AccountID(1): 50, AccountID(2): 0]

    /// A random script: two tellers, two shared accounts, a dozen operations
    /// spread over the first twenty ticks.
    static func script(seed: UInt64) -> [Simulation.Action] {
        var rng = SeededGenerator(seed: seed &* 31 &+ 7)
        let count = Int.random(in: 1...12, using: &rng)
        return (0..<count).map { _ in
            let account = accounts.randomElement(using: &rng)!
            let amount = Int.random(in: 1...40, using: &rng)
            let op: Operation
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: op = .balance(account)
            case 1, 2: op = .deposit(account, amount: amount)
            default: op = .withdraw(account, amount: amount)
            }
            return Simulation.Action(
                at: Int.random(in: 0..<20, using: &rng),
                teller: tellers.randomElement(using: &rng)!,
                operation: op)
        }
    }

    static func bank(seed: UInt64, faults: Faults, script: [Simulation.Action]) -> Simulation {
        Simulation(
            ledger: Ledger(balances: opening),
            tellers: tellers.map { Teller(id: $0, timeout: 4) },
            faults: faults,
            script: script,
            seed: seed)
    }

    /// Replay the ledger's applied order over the opening balances with no
    /// network in the way; the replies must be the ones the ledger gave.
    static func sequentialReplay(of sim: Simulation, requests: [RequestID: Request]) -> Ledger {
        var reference = Ledger(balances: opening)
        for id in sim.ledger.applied {
            _ = reference.handle(requests[id]!)
        }
        return reference
    }

    static func allRequests(_ sim: Simulation) -> [RequestID: Request] {
        var out: [RequestID: Request] = [:]
        for teller in sim.tellers.values {
            for event in teller.events {
                if case .submitted(let id, let op) = event { out[id] = Request(id: id, operation: op) }
            }
        }
        return out
    }

    static func checkInvariants(_ sim: Simulation, seed: UInt64) {
        // Balances are never negative at any tick.
        for (account, balance) in sim.ledger.balances {
            #expect(balance >= 0, "seed \(seed) tick \(sim.now): \(account) overdrawn to \(balance)")
        }
        // Each request name is applied at most once.
        #expect(Set(sim.ledger.applied).count == sim.ledger.applied.count,
                "seed \(seed) tick \(sim.now): a request was applied twice")
        // What a teller believes matches what the ledger decided.
        for teller in sim.tellers.values {
            for (id, outcome) in teller.completed {
                #expect(sim.ledger.replies[id] == outcome,
                        "seed \(seed) tick \(sim.now): \(id) teller saw \(outcome), ledger has \(String(describing: sim.ledger.replies[id]))")
            }
        }
    }

    @Test(arguments: [Faults.perfect, .hostile, Faults(drop: 0.5, duplicate: 0.5, delay: 1...12)])
    func randomScriptsKeepTheInvariants(faults: Faults) {
        var retried = 0
        var duplicatesSeenByLedger = 0
        for seed in UInt64(0)..<300 {
            let script = Self.script(seed: seed)
            var sim = Self.bank(seed: seed, faults: faults, script: script)
            let quiet = sim.run(limit: 2_000) { Self.checkInvariants($0, seed: seed) }
            #expect(quiet, "seed \(seed): still busy after 2000 ticks")

            let requests = Self.allRequests(sim)
            // Every submitted request completed with the ledger's reply.
            #expect(requests.count == script.count)
            for (id, _) in requests {
                let status = sim.tellers[id.teller]!.status[id]
                guard case .completed(let outcome)? = status else {
                    Issue.record("seed \(seed): \(id) ended \(String(describing: status))")
                    continue
                }
                #expect(sim.ledger.replies[id] == outcome)
            }
            // Conservation: the balance is the opening balance plus the
            // accepted deposits minus the accepted withdrawals, once each.
            for account in Self.accounts {
                var expected = Self.opening[account]!
                for (id, outcome) in sim.ledger.replies where outcome.isAccepted {
                    switch requests[id]!.operation {
                    case .deposit(account, let amount): expected += amount
                    case .withdraw(account, let amount): expected -= amount
                    default: break
                    }
                }
                #expect(sim.ledger.balance(of: account) == expected, "seed \(seed) \(account)")
            }
            // The replay agrees with the ledger.
            let reference = Self.sequentialReplay(of: sim, requests: requests)
            #expect(reference.balances == sim.ledger.balances, "seed \(seed)")
            #expect(reference.replies == sim.ledger.replies, "seed \(seed)")

            for teller in sim.tellers.values {
                for event in teller.events {
                    if case .sent(_, let attempt) = event, attempt > 1 { retried += 1 }
                }
            }
            duplicatesSeenByLedger += sim.network.duplicated
        }
        // The hostile runs must actually exercise retries and duplicates.
        if faults.drop > 0 { #expect(retried > 0, "no retry ever happened") }
        if faults.duplicate > 0 { #expect(duplicatesSeenByLedger > 0, "no duplicate ever happened") }
    }

    @Test func perfectNetworkMatchesTheScriptOrder() {
        // With no faults and one-tick delivery, the ledger applies requests
        // in script order (tick, then teller), so the outcomes are the fold
        // of the script.
        for seed in UInt64(0)..<100 {
            let script = Self.script(seed: seed)
            var sim = Self.bank(seed: seed, faults: .perfect, script: script)
            let quiet = sim.run(limit: 200)
            #expect(quiet)
            var reference = Ledger(balances: Self.opening)
            var sequence: [TellerID: Int] = [:]
            let ordered = script.sorted { ($0.at, $0.teller) < ($1.at, $1.teller) }
            for action in ordered {
                let n = sequence[action.teller, default: 0]
                sequence[action.teller] = n + 1
                _ = reference.handle(Request(id: RequestID(teller: action.teller, sequence: n),
                                             operation: action.operation))
            }
            #expect(reference.replies == sim.ledger.replies, "seed \(seed)")
            #expect(sim.network.sent == 2 * script.count, "one request and one reply each")
        }
    }

    @Test func twoTellersRacingForTheLastOfTheMoney() {
        // Both tellers withdraw the whole balance at the same tick. Exactly
        // one wins, whatever the network does to the order of arrival, and
        // the loser is told the balance is now zero.
        let account = AccountID(1)
        var wins: [TellerID: Int] = [:]
        for seed in UInt64(0)..<300 {
            var sim = Simulation(
                ledger: Ledger(balances: [account: 100]),
                tellers: Self.tellers.map { Teller(id: $0, timeout: 3) },
                faults: .hostile,
                script: Self.tellers.map {
                    Simulation.Action(at: 0, teller: $0, operation: .withdraw(account, amount: 100))
                },
                seed: seed)
            let quiet = sim.run(limit: 2_000) { Self.checkInvariants($0, seed: seed) }
            #expect(quiet, "seed \(seed)")
            let outcomes = Self.tellers.compactMap { sim.tellers[$0]!.completed[RequestID(teller: $0, sequence: 0)] }
            #expect(outcomes.count == 2, "seed \(seed): both tellers hear back")
            #expect(outcomes.sorted { $0.isAccepted && !$1.isAccepted } == [.accepted(balance: 0), .refused(balance: 0)],
                    "seed \(seed): \(outcomes)")
            #expect(sim.ledger.balance(of: account) == 0)
            wins[sim.ledger.applied.first!.teller, default: 0] += 1
        }
        #expect(wins.count == 2, "the network decides who wins; both should win sometimes: \(wins)")
    }

    @Test func retryStormWithdrawsOnce() {
        // A short timeout against a slow, lossy network: the teller resends
        // the same withdrawal many times, and copies of it pile up at the
        // ledger. The money leaves once.
        let account = AccountID(1)
        var maxAttempts = 0
        for seed in UInt64(0)..<200 {
            var sim = Simulation(
                ledger: Ledger(balances: [account: 30]),
                tellers: [Teller(id: TellerID(1), timeout: 1)],
                faults: Faults(drop: 0.4, duplicate: 0.5, delay: 2...10),
                script: [Simulation.Action(at: 0, teller: TellerID(1), operation: .withdraw(account, amount: 30))],
                seed: seed)
            let quiet = sim.run(limit: 5_000) { Self.checkInvariants($0, seed: seed) }
            #expect(quiet, "seed \(seed)")
            let id = RequestID(teller: TellerID(1), sequence: 0)
            #expect(sim.tellers[TellerID(1)]!.completed[id] == .accepted(balance: 0), "seed \(seed)")
            #expect(sim.ledger.balance(of: account) == 0)
            #expect(sim.ledger.applied == [id])
            for event in sim.tellers[TellerID(1)]!.events {
                if case .sent(_, let attempt) = event { maxAttempts = max(maxAttempts, attempt) }
            }
        }
        #expect(maxAttempts >= 5, "the storm should have been a storm: max attempts \(maxAttempts)")
    }

    @Test func aTellerThatGivesUpDoesNotKnowTheOutcome() {
        // Bounded retries on a network that drops everything: the teller
        // abandons the request. It cannot tell whether the ledger applied
        // it; here nothing arrived, so the ledger did not. The simulation
        // reports what it knows and nothing more.
        let account = AccountID(1)
        var sim = Simulation(
            ledger: Ledger(balances: [account: 10]),
            tellers: [Teller(id: TellerID(1), timeout: 2, maxAttempts: 3)],
            faults: Faults(drop: 1),
            script: [Simulation.Action(at: 0, teller: TellerID(1), operation: .withdraw(account, amount: 10))],
            seed: 0)
        let quiet = sim.run(limit: 100)
        #expect(quiet)
        let id = RequestID(teller: TellerID(1), sequence: 0)
        #expect(sim.tellers[TellerID(1)]!.status[id] == .abandoned(attempts: 3))
        #expect(sim.ledger.replies[id] == nil)
        #expect(sim.ledger.balance(of: account) == 10)
    }

    @Test func sameSeedSameHistory() {
        let script = Self.script(seed: 5)
        var a = Self.bank(seed: 5, faults: .hostile, script: script)
        var b = Self.bank(seed: 5, faults: .hostile, script: script)
        a.run(limit: 2_000)
        b.run(limit: 2_000)
        #expect(a.ledger.applied == b.ledger.applied)
        #expect(a.tellers.mapValues(\.events) == b.tellers.mapValues(\.events))
        #expect(a.now == b.now)
    }
}
