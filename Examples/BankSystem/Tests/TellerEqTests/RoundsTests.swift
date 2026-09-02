import Testing
import Hegel
@testable import TellerEq

/// One test per round. Each prints the counterexample Hegel found and the
/// goal at it; the assertion pins the goal so the round stays reproducible.
@Suite struct Rounds {
    func goal(_ born: Birth) throws -> String {
        let g = try Session.stuckGoal(born: born)
        print("\n== born = \(born) ==\n\(g ?? "holds")")
        return g ?? "holds"
    }
    @Test func round0() throws { #expect(try goal(.nothing).contains("retry (deposit n)")) }
    @Test func round1() throws { #expect(try goal(.credit).contains("retry (withdraw n)")) }
    @Test func round2() throws { #expect(try goal(.debit).contains("timeout")) }
    @Test func round3() throws { #expect(try goal(.pend) != "holds") }
    @Test func round4() throws { #expect(try goal(.tries).contains("no reply constructor")) }
    @Test func round5() throws { #expect(try goal(.reply).contains("the state has no out")) }
    @Test func round6() throws { #expect(try goal(.out).contains("out has no such value")) }
    @Test func round7() throws { #expect(try goal(.unknown).contains("apply* (net (retry r)) b ∈")) }
    @Test func round8() throws { #expect(try goal(.id).contains("once a reply has been taken")) }
    @Test func final() throws { #expect(try goal(.settle) == "holds") }

    /// Round 8, the other alternative: no id on the wire, the ledger keys
    /// `seen` by the message's content. The single-request equations accept
    /// it too; that is why the round is not decidable from the equation.
    @Test func round8Alternative() throws {
        let g = try Session.stuckGoal(born: .settle, byContent: true)
        print("\n== born = settle, dedup by content ==\n\(g ?? "holds")")
        #expect(g == nil)
    }

    /// The equations on drawn nets, more cases and more seeds.
    @Test func equationsHold() throws {
        for seed in UInt64(1)...5 {
            #expect(try Session.stuckGoal(born: .settle, seed: seed, testCases: 10_000) == nil)
        }
    }

    /// What the equation does not decide: a reply that arrives after the
    /// session gave up. As defined, the teller takes it (out = rep) and
    /// the harness does not count it as taken while waiting; the equation
    /// holds either way. Pinned as a product decision, not derived.
    @Test func lateReplyAfterGiveUp() throws {
        let net: [Event] = [.timeout, .timeout, .timeout, .timeout, .request(0), .reply(0)]
        let t = try Session.run(.deposit(2), 1, net, born: .settle)
        try Session.check(.deposit(2), 1, t)
        #expect(t.teller.out == .rep(.ok(3)))
        #expect(t.ledger.bal == 3)   // P3a: a copy of a given-up request may still apply
    }

    /// A duplicated reply after settle: harmless with one request per
    /// session, which is why no reply carries an id in this lane.
    @Test func duplicateReply() throws {
        let net: [Event] = [.request(0), .reply(0), .reply(0), .timeout]
        let t = try Session.run(.withdraw(5), 3, net, born: .settle)
        try Session.check(.withdraw(5), 3, t)
        #expect(t.teller.out == .rep(.refused(3)))
        #expect(t.wire.count == 1)   // the timeout after settle sends nothing
    }
}
