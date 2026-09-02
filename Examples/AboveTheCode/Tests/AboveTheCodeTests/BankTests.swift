import Testing
import HegelTesting
import AboveTheCode

/// The calculation as propose and refute. Hegel finds each stuck goal as
/// the smallest request `send` does not cover; the constructor for it is
/// proposed outside (`Birth` stands in for the proposal), and the next
/// run finds the next goal.
@Suite struct BankCalculation {
    /// The stuck goals come in the order of the proof: deposit, withdraw,
    /// then; each the smallest term of its kind, with the balance in scope.
    /// After `SEQ` nothing is stuck.
    @Test func theStuckGoalsInOrder() throws {
        var goals: [String] = []
        for born in Birth.allCases {
            let stuck = try Calculation.stuckGoal(born: born) { r, b, born in Tree.send(r, born: born).map { Tree.apply($0, b) } }
            goals.append("\(born): \(stuck.map(\.description) ?? "nothing stuck")")
        }
        print(goals.joined(separator: "\n"))
        let stuckAt = try Birth.allCases.map { born in
            try Calculation.stuckGoal(born: born) { r, b, born in Tree.send(r, born: born).map { Tree.apply($0, b) } }?.r
        }
        #expect(stuckAt[0] == .deposit(0))
        #expect(stuckAt[1] == .withdraw(0))
        #expect(stuckAt[2] == .then(.deposit(0), .deposit(0)))
        #expect(stuckAt[3] == nil)
    }

    /// Fork A, once everything is born: the equation on drawn requests.
    @Test(.propertyTesting) func theTreeSatisfiesTheEquation() {
        expectAll(Calculation.inputs, database: "") { r, b in
            #expect(Tree.apply(Tree.send(r, born: .sequence)!, b) == r.meaning(b))
        }
    }

    /// Fork B, both spellings. Append passes; the continuation passes; the
    /// property cannot tell that one needs a lemma and the other computes.
    @Test(.propertyTesting) func theStreamSatisfiesTheEquationEitherWay() {
        expectAll(Hegel.zip(Calculation.inputs, array(of: Gen<Int>.int(in: 0...9), count: 0...3)), database: "") { input, ns in
            let (r, b) = input
            #expect(Wire.apply(Wire.send(r, born: .sequence)!, b) == r.meaning(b))
            // The continuation's own equation: apply m (⟦ r ⟧ b) = apply (send r m) b, m drawn.
            let m = ns.map { Wire.credit($0) }
            #expect(Wire.apply(Wire.send(r, then: m, born: .sequence)!, b) == Wire.apply(m, r.meaning(b)))
            // And the top level, m = DONE.
            #expect(Wire.apply(Wire.send(r, then: [], born: .sequence)!, b) == r.meaning(b))
        }
    }

    /// The continuation has no `then` birth: with `credit` and `debit`
    /// born, nothing is stuck, where the append spelling still needs
    /// `sequence` to be born.
    @Test func theContinuationNeedsNoBirthAtThen() throws {
        let appendStuck = try Calculation.stuckGoal(born: .debit) { r, b, born in Wire.send(r, born: born).map { Wire.apply($0, b) } }
        let continuationStuck = try Calculation.stuckGoal(born: .debit) { r, b, born in Wire.send(r, then: [], born: born).map { Wire.apply($0, b) } }
        print("append at debit: \(appendStuck.map(\.description) ?? "nothing stuck"); continuation at debit: \(continuationStuck.map(\.description) ?? "nothing stuck")")
        #expect(appendStuck?.r == .then(.deposit(0), .deposit(0)))
        #expect(continuationStuck == nil)
    }

    /// A wrong proposal is a different failure: `DEBIT` applied as
    /// `b + n` is refuted with the values in scope, not reported as stuck.
    @Test func aWrongBirthIsRefutedNotStuck() throws {
        do {
            _ = try Calculation.stuckGoal(born: .sequence) { r, b, _ in
                func wrong(_ r: Req, _ b: Int) -> Int {
                    switch r {
                    case .deposit(let n): return b + n
                    case .withdraw(let n): return b + n   // the wrong apply for DEBIT
                    case .then(let x, let y): return wrong(y, wrong(x, b))
                    }
                }
                return wrong(r, b)
            }
            Issue.record("the wrong DEBIT was accepted")
        } catch let u as Unequal {
            print("wrong birth: \(u)")
            #expect(u.r == .withdraw(1) && u.b == 0 && u.got == 1)
        }
    }
}
