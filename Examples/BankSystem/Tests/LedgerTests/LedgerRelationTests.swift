import Testing
import Hegel
import HegelTesting
import Ledger

/// Step 5: the relation's own properties on drawn traces of arrivals
/// (duplicated, reordered, dropped). Every drawn trace is a behaviour of
/// `Next_L`, so what is checked is what the relation keeps true of itself.
@Suite struct LedgerRelation {
    /// The drawing at the top of the reply, replayed through the relation.
    @Test func drawingB() {
        let s = Scenario(accounts: ["a"], b0: 10, honest: [], arrivals: [
            Request(Id("t", 1), "a", .withdraw(4)),
            Request(Id("t", 2), "a", .withdraw(4)),
            Request(Id("t", 1), "a", .withdraw(4)),
            Request(Id("t", 3), "a", .withdraw(7)),
        ])
        let run: [LedgerModel.Event] = LedgerModel.behaviour(s)
        print(run.map { $0.description }.joined(separator: "\n"))
        let outs: [Rep?] = run.map { $0.state.out }
        #expect(outs == [.ok(6), .ok(2), .ok(6), .refused(2)])
        let clauses: [LedgerModel.Clause] = run.map { $0.clause }
        #expect(clauses == [.apply, .apply, .again, .apply])
        #expect(run.last?.state.bal == ["a": 2])
    }

    /// NonNegative: ∀ a: bal[a] ≥ 0, in every state of every behaviour.
    @Test(.propertyTesting) func nonNegative() {
        expectAll(Scenario.gen(), database: "") { s in
            for e in LedgerModel.behaviour(s) {
                #expect(e.state.bal.values.allSatisfy { $0 >= 0 })
            }
        }
    }

    /// Once, as the ledger alone can state it: an identity is applied at
    /// most once, and once iff it arrived at all. As a temporal formula:
    /// always(applied(i) ⇒ weakNext(always(¬applied(i)))), one per identity.
    @Test(.propertyTesting) func once() {
        expectAll(Scenario.gen(), database: "") { s in
            let run = LedgerModel.behaviour(s)
            let ids = Set(s.arrivals.map(\.id))
            for i in ids {
                let applied = now { (e: LedgerModel.Event) in e.clause == .apply && e.arrival.id == i }
                let onceOnly = always(applied => weakNext(always(!applied)))
                #expect(evaluate(onceOnly, over: run), "\(i) applied twice at \(firstFailure(of: onceOnly, over: run) ?? -1)")
                #expect(run.filter { $0.clause == .apply && $0.arrival.id == i }.count == 1)
            }
            // dom seen is exactly the identities that arrived (P3a: never shrinks).
            #expect(Set(run.last.map { Array($0.state.seen.keys) } ?? []) == ids)
        }
    }

    /// seen never shrinks (P3a): always(weakNext(prev.seen ⊆ cur.seen)).
    @Test(.propertyTesting) func seenNeverShrinks() {
        expectAll(Scenario.gen(), database: "") { s in
            let run = LedgerModel.behaviour(s)
            let grows = always(weakNext(changed { (p: LedgerModel.Event, c: LedgerModel.Event) in
                p.state.seen.allSatisfy { c.state.seen[$0.key] == $0.value }
            }))
            #expect(evaluate(grows, over: run))
        }
    }

    /// Serial: bal is the fold of ⟦ ⟧ over the applied requests in the
    /// order the Apply steps occurred, and seen[i] is the reply that fold
    /// produced at i. This is also the equation of section 5 for the
    /// ledger: copies do not count twice, a drop is a no-op.
    @Test(.propertyTesting) func serial() {
        expectAll(Scenario.gen(), database: "") { s in
            let run = LedgerModel.behaviour(s)
            var bal = s.initial.bal
            var replies: [Id: Rep] = [:]
            for e in run where e.clause == .apply {
                let (b, rep) = meaning(e.arrival.req, bal[e.arrival.acct]!)
                bal[e.arrival.acct] = b
                replies[e.arrival.id] = rep
            }
            #expect(run.last?.state.bal ?? s.initial.bal == bal)
            #expect(run.last?.state.seen ?? [:] == replies)
        }
    }

    /// P2(a) as a property: every arrival of an identity produces the same
    /// reply, the one stored at its Apply; out′ = seen′[id(m)] at every step.
    @Test(.propertyTesting) func everyCopyGetsTheStoredReply() {
        expectAll(Scenario.gen(), database: "") { s in
            let run = LedgerModel.behaviour(s)
            for e in run {
                #expect(e.state.out == e.state.seen[e.arrival.id])
            }
            for i in Set(s.arrivals.map(\.id)) {
                #expect(Set(run.filter { $0.arrival.id == i }.map { $0.state.out! }).count == 1)
            }
        }
    }

    /// Section 5, ∀ net ∈ Net₁: the final balance is the fold of the honest
    /// sequence when every message arrived at least once and the network
    /// kept the order. Reordering across tellers is the network's pick-any
    /// and changes the fold; the ledger can state only Serial for it.
    @Test(.propertyTesting) func atLeastOnceInOrderIsTheHonestFold() {
        expectAll(Scenario.gen(copies: 1...2), database: "") { s in
            // The first arrival of each identity, in the honest order.
            let firsts = s.arrivals.reduce(into: [Request]()) { acc, m in if !acc.contains(m) { acc.append(m) } }
            try require(firsts == s.honest, "the network reordered")
            let run = LedgerModel.behaviour(s)
            var bal = s.initial.bal
            for m in s.honest { bal[m.acct] = meaning(m.req, bal[m.acct]!).bal }
            #expect(run.last?.state.bal ?? s.initial.bal == bal)
        }
    }

    /// Drawing B's first row, the relation without `seen`: every arrival
    /// applies, and Once is refuted by the smallest trace, one request
    /// delivered twice.
    @Test func withoutSeenOnceIsRefuted() throws {
        do {
            try forAll(Scenario.gen(), seed: 1, database: "") { s in
                var bal = s.initial.bal
                var applied: [Id: Int] = [:]
                for m in s.arrivals {
                    bal[m.acct] = meaning(m.req, bal[m.acct]!).bal
                    applied[m.id, default: 0] += 1
                }
                if applied.values.contains(where: { $0 > 1 }) { throw AppliedTwice(scenario: s) }
            }
            Issue.record("Once held without seen")
        } catch let failure as PropertyFailure {
            let minimal = try replay(Scenario.gen(), blob: try #require(failure.failures.first?.reproduceBlob))
            print("without seen, Once refuted by: \(minimal)")
            #expect(minimal.arrivals.count == 2)
            #expect(minimal.arrivals[0] == minimal.arrivals[1])
        }
    }
    struct AppliedTwice: Error { let scenario: Scenario }
}

/// `HegelError.assume` as a precondition: rejects the drawn case.
func require(_ condition: Bool, _ why: String) throws {
    if !condition { throw HegelError.assume }
}
