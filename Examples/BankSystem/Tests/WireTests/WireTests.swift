import Testing
import HegelTesting
import Wire

/// The wire format as propose and refute: Hegel prints each stuck goal,
/// the constructor for it is proposed outside (`Birth` stands in for the
/// proposal), the next run prints the next goal.
@Suite struct WireCalculation {
    /// The rounds in order. Round 1: ⟦ dep 1 ⟧ 0, `DEPOSIT n` born.
    /// Round 2: ⟦ wd 1 ⟧ 0 with n > b, `WITHDRAW n` born, `apply` in the
    /// refused case. Round 3: ⟦ wd 1 ⟧ 1 with n ≤ b, nothing born, the other
    /// case of `apply`. Then nothing is stuck: `send` is total.
    @Test func theStuckGoalsInOrder() throws {
        var goals: [Stuck?] = []
        for born in Birth.allCases {
            let stuck = try Calculation.stuckGoal(born: born)
            print("\(born): \(stuck.map(\.description) ?? "nothing stuck")")
            goals.append(stuck)
        }
        #expect(goals[0]?.r == .dep(1) && goals[0]?.b == 0)
        #expect(goals[1]?.r == .wd(1) && goals[1]?.b == 0)
        #expect(goals[2]?.r == .wd(1) && goals[2]?.b == 1)
        #expect(goals[3] == nil)
    }

    /// The equation once everything is born, balance and reply both.
    @Test(.propertyTesting) func theWireSatisfiesTheEquation() {
        expectAll(Calculation.inputs, database: "") { r, b in
            let got = Msg.apply(Msg.send(r)!, b)!
            #expect(got == r.meaning(b))
        }
    }

    /// `send` is total: every drawn request has a message.
    @Test(.propertyTesting) func sendIsTotal() {
        expectAll(Req.gen, database: "") { r in
            #expect(Msg.send(r) != nil)
        }
    }

    /// The stream form. `apply* (send r m) b ≡ apply* m (bal⟦ r ⟧ b)` on
    /// the balance, `rep⟦ r ⟧ b` first among the replies, and the top
    /// level `m = DONE` is the equation itself.
    @Test(.propertyTesting) func theStreamSatisfiesTheContinuationEquation() {
        let ms = array(of: Req.gen, count: 0...3).map { $0.map { Msg.send($0)! } }
        expectAll(Hegel.zip(Calculation.inputs, ms), database: "") { input, m in
            let (r, b) = input
            let lhs = Msg.applyAll(Msg.send(r, then: m), b)
            let rhs = Msg.applyAll(m, r.meaning(b).bal)
            #expect(lhs.bal == rhs.bal)
            #expect(lhs.reps == [r.meaning(b).rep] + rhs.reps)
            let top = Msg.applyAll(Msg.sendAll(r), b)
            #expect(top.bal == r.meaning(b).bal && top.reps == [r.meaning(b).rep])
        }
    }

    /// Monus, the meaning Examples/AboveTheCode used, is refuted here and
    /// refuted through the reply alone: at ⟦ wd 1 ⟧ 0 both give balance 0,
    /// and the wire says `ok 0` where the meaning says `refused 0`. That
    /// is why the equation is over the pair (P6a) and not the balance.
    @Test func monusIsRefutedThroughTheReply() throws {
        do {
            _ = try Calculation.stuckGoal(born: .withdrawBothCases) { r, b, _ in
                switch r {
                case .dep(let n): return (b + n, .ok(b + n))
                case .wd(let n): return (max(0, b - n), .ok(max(0, b - n)))
                }
            }
            Issue.record("monus was accepted")
        } catch let u as Unequal {
            print("wrong birth: \(u)")
            #expect(u.r == .wd(1) && u.b == 0)
            #expect(u.got.bal == u.r.meaning(u.b).bal && u.got.rep == .ok(0))
        }
    }
}
