import Testing
import Hegel
import LedgerEq

/// The ledger from its equation, round by round. Each round's goal is
/// Hegel's shrunk counterexample with the values in scope; the next round
/// is the one constructor or field proposed for it. The rounds are
/// pinned so the record replays.
@Suite struct LedgerEqRounds {
    func goal<L: Ledger>(_ name: String, _ l: L.Type, min: Int, order: Net.Order, depth: Int = 0) throws -> Goal? {
        let g = try Calculation.check(l, minMultiplicity: min, order: order, depth: depth)
        print("\(name): \(g.map(\.description) ?? "holds")")
        return g
    }

    @Test func theGoalsInOrder() throws {
        let g0 = try goal("round 0, Net₁", Round0.self, min: 1, order: .whole)
        #expect(g0?.kind == .sendUndefined && g0?.r == .deposit(0))
        let g2 = try goal("round 2, Net₁", Round2.self, min: 1, order: .whole)          // CREDIT, DEBIT born
        #expect(g2?.kind == .replyUnequal && g2?.r == .deposit(1) && g2?.net.mults == [2])
        let g3 = try goal("round 3, Net₁", Round3.self, min: 1, order: .whole)          // last born
        #expect(g3?.kind == .replyUnequal && g3?.r == .withdraw(1) && g3?.b == 0)
        let g4 = try goal("round 4, Net₁", Round4.self, min: 1, order: .whole)          // reply from the balance now: refuted
        #expect(g4?.kind == .replyUnequal && g4?.r == .withdraw(1) && g4?.b == 1)
        #expect(try goal("round 5, Net₁", Round5.self, min: 1, order: .whole) == nil)   // lastRep born
        #expect(try goal("round 5, Net", Round5.self, min: 0, order: .whole) == nil)
        let g5 = try goal("round 5, then, Net₁", Round5.self, min: 1, order: .whole, depth: 1)
        #expect(g5?.kind == .sendUndefined && g5?.r == .then(.deposit(0), .deposit(0)))
        let g6w = try goal("round 6, then, Net₁ whole", Round6.self, min: 1, order: .whole, depth: 1)  // append
        #expect(g6w?.kind == .replyUnequal && g6w?.r == .then(.deposit(0), .deposit(1)) && g6w?.net.picks == [1, 0])
        let g6 = try goal("round 6, then, Net₁ per request", Round6.self, min: 1, order: .perRequest, depth: 1)
        #expect(g6?.kind == .replyUnequal && g6?.r == .then(.deposit(1), .deposit(1)))
        #expect(try goal("round 7, then, Net₁ per request", Round7.self, min: 1, order: .perRequest, depth: 1) == nil)  // id born
        #expect(try goal("round 7, then, Net per request", Round7.self, min: 0, order: .perRequest, depth: 1) == nil)
        #expect(try goal("round 7, depth 2, Net₁ per request", Round7.self, min: 1, order: .perRequest, depth: 2) == nil)
        #expect(try goal("round 7, depth 2, Net per request", Round7.self, min: 0, order: .perRequest, depth: 2) == nil)
        // Identity does not restore order: the whole-stream permutation still refutes `then`.
        let g7w = try goal("round 7, then, Net₁ whole", Round7.self, min: 1, order: .whole, depth: 1)
        #expect(g7w?.kind == .replyUnequal && g7w?.net.picks == [1, 0])
        // A copy delayed past a later request: `last` is refuted, `seen` (round 8) holds.
        let g7d = try goal("round 7, then, Net₁ delayed", Round7.self, min: 1, order: .delayed, depth: 1)
        #expect(g7d?.kind == .replyUnequal && g7d?.r == .then(.deposit(0), .deposit(1)) && g7d?.net.mults == [2, 1])
        #expect(try goal("round 8, then, Net₁ delayed", Round8.self, min: 1, order: .delayed, depth: 2) == nil)
        #expect(try goal("round 8, then, Net delayed", Round8.self, min: 0, order: .delayed, depth: 2) == nil)
    }

    /// Both equations on the final ledger at several seeds.
    @Test func theFinalLedgerHoldsAtManySeeds() throws {
        for seed in UInt64(1)...10 {
            #expect(try Calculation.check(Round7.self, minMultiplicity: 1, order: .perRequest, depth: 2, seed: seed) == nil)
            #expect(try Calculation.check(Round7.self, minMultiplicity: 0, order: .perRequest, depth: 2, seed: seed) == nil)
            #expect(try Calculation.check(Round8.self, minMultiplicity: 1, order: .delayed, depth: 2, seed: seed) == nil)
            #expect(try Calculation.check(Round8.self, minMultiplicity: 0, order: .delayed, depth: 2, seed: seed) == nil)
        }
    }
}
