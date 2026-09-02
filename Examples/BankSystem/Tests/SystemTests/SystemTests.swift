import Testing
import Hegel
import HegelTesting
import Schedules
import Ledger
import Teller
@testable import Composed

/// Phase C, steps 5 to 7 for the composed system: `Next_S` on drawn
/// behaviours where every pick-any and every network move is a draw, then
/// the real ledger and teller sessions under drawn schedules and drawn
/// faults, then the planted seam bug.
@Suite(.serialized) struct SystemTests {
    static let req: Gen<TellerReq> = Hegel.zip(Gen<Bool>.bool, Gen<Int>.int(in: 1...12)).map { $0 ? .dep($1) : .wd($1) }
    static let scripts: Gen<[[TellerReq]]> = Hegel.zip(array(of: req, count: 0...2), array(of: req, count: 0...2)).map { [$0, $1] }
    static let balance = Gen<Int>.int(in: 0...12)
    static let schedules: Gen<Schedule> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...40), Gen<Int64>.int(in: 0...7))
            .map { Schedule.Deviation(choice: Int($0), index: Int($1)) },
        count: 0...8
    ).map(Schedule.init)
    static let delays: Gen<Delays> = array(
        of: Hegel.zip(Gen<Int>.int(in: 0...9), Gen<Int>.int(in: 1...5)), count: 0...3
    ).map { Delays(Dictionary($0, uniquingKeysWith: { a, _ in a })) }
    static let faults: Gen<Faults> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...15), Gen<Bool>.bool)
            .map { Faults.Fault(message: Int($0), kind: $1 ? .duplicate : .drop) },
        count: 0...3
    ).map(Faults.init)

    static let behaviours: Gen<(Int, [[TellerReq]], SystemModel.Run)> = Hegel.zip(balance, scripts).flatMap { b, s in
        SystemModel.behaviour(bal: b, scripts: s).map { (b, s, $0) }
    }
    static let inputs = Hegel.zip(balance, scripts, delays, faults, schedules)

    // MARK: Step 1 as a test: the drawing replayed against the relation

    /// The drawing at the top of the report: t1 wd 4 dropped, t2 wd 7
    /// applied first, t1's resend duplicated, one copy Again, one reply ignored.
    @Test func drawing() {
        var s = SystemModel(bal: 10)
        let q1 = TellerRequest(id: TellerId(teller: "t1", n: 1), req: .wd(4))
        let q2 = TellerRequest(id: TellerId(teller: "t2", n: 1), req: .wd(7))
        let r1 = TellerReply(id: q1.id, rep: .refused(3)), r2 = TellerReply(id: q2.id, rep: .ok(3))
        let steps: [Step] = [
            .submit(0, .wd(4)), .submit(1, .wd(7)), .drop(.request(q1)), .arrive(q2), .timeout(0), .dup(.request(q1)),
            .arrive(q1), .deliver(0, r1), .arrive(q1), .deliver(1, r2), .deliver(0, r1),
        ]
        for step in steps {
            #expect(s.enabled(step), "\(step) at \(s)")
            s.apply(step)
            #expect(s.invariantsHold, "\(s.brokenInvariant ?? "") after \(step) at \(s)")
        }
        #expect(s.bal == 3 && s.settled)
        #expect(s.applied == [q2.id, q1.id])
        #expect(s.tellers.map(\.out) == [.taken(.refused(3)), .taken(.ok(3))])
        #expect(s.equation() == nil)
    }

    // MARK: Step 5: the relation on drawn behaviours

    /// NonNegative, Once, Serial, Agree at every state; every behaviour
    /// drains to settled; the composed equation holds at the end.
    @Test(.propertyTesting) func invariantsAndEquationOnDrawnBehaviours() {
        var faults = 0, giveUps = 0, agains = 0
        expectAll(Self.behaviours, testCases: 500, database: "") { bal, scripts, run in
            for (i, s) in run.states.enumerated() {
                if let broken = s.brokenInvariant {
                    Issue.record("\(broken) fails after step \(i) \(run.steps[i]) at \(s)\n\(run)")
                    return
                }
            }
            #expect(run.final.settled, "\(run.final)")
            if let why = run.final.equation(orderAmongGivenUp: false) { Issue.record("\(why)\n\(run)") }
            #expect(run.final.outs.count == scripts[0].count + scripts[1].count)
            if run.steps.contains(where: \.isFault) { faults += 1 }
            if run.steps.contains(where: { if case .giveUp = $0 { true } else { false } }) { giveUps += 1 }
            if run.states.contains(where: { $0.ledger.seen.count < $0.applied.count + 1 && false }) { agains += 1 }
        }
        print("drawn behaviours: faults in \(faults) runs, give-ups in \(giveUps) of 500")
        #expect(faults > 0 && giveUps > 0)
        _ = agains
    }

    /// Drawing F's point, on the relation: a request duplicated on the
    /// wire applies once. And a given-up request's late copy applies
    /// (P4b with P3a): Once and Serial hold, the teller shows unknown.
    @Test func aDuplicateAppliesOnce() throws {
        var finals: Set<Int> = []
        try forAll(SystemModel.behaviour(bal: 10, scripts: [[.wd(4)], []], faultBudget: 4), testCases: 300, database: "") { run in
            #expect(run.final.invariantsHold)
            finals.insert(run.final.bal)
        }
        #expect(finals == [6, 10])   // applied once, or every copy dropped and given up
    }

    // MARK: Step 6: the real components under drawn schedules and faults

    static func check(_ run: SystemRun, bal: Int) throws {
        guard case .completed = run.outcome else { throw NotCompleted(outcome: run.outcome, trace: run.trace) }
        if let v = run.refinement.violation { throw NotARefinement(violation: v, records: run.records, network: run.network) }
        let final = run.refinement.final
        #expect(final.ledger == run.ledger)
        #expect(final.tellers == run.tellers)
        #expect(final.settled, "\(final)")
        if let broken = final.brokenInvariant { Issue.record("\(broken) at \(final)") }
        if let why = final.equation(orderAmongGivenUp: false) { Issue.record("\(why)\n\(run.records.map(\.description).joined(separator: "\n"))") }
    }

    @Test(.propertyTesting) func codeRefinesUnderEveryScheduleAndFaultList() {
        var dups = 0, drops = 0, giveUps = 0
        expectAll(Self.inputs, testCases: 400, database: "") { bal, scripts, delays, faults, schedule in
            let run = runSystem(bal: bal, scripts: scripts, delays: delays, faults: faults, policy: schedule.policy)
            #expect(throws: Never.self) { try Self.check(run, bal: bal) }
            if run.records.contains(where: { if case .dup = $0.step { true } else { false } }) { dups += 1 }
            if run.records.contains(where: { if case .drop = $0.step { true } else { false } }) { drops += 1 }
            if run.records.contains(where: { if case .giveUp = $0.step { true } else { false } }) { giveUps += 1 }
        }
        print("code under schedules and faults: dups in \(dups), drops in \(drops), give-ups in \(giveUps) of 400 runs")
    }

    /// The seam list's cases, forced: drawing F (the resend and the
    /// original both arrive) and drawing E (drop, resend, duplicated reply).
    @Test func drawingsEAndFOnTheCode() throws {
        let scripts: [[TellerReq]] = [[.wd(4)], []]
        // F: request 0 delayed past the timeout, then both copies arrive.
        try forAll(Self.schedules, testCases: 100, database: "") { schedule in
            let run = runSystem(bal: 10, scripts: scripts, delays: Delays([0: 2]), policy: schedule.policy)
            try Self.check(run, bal: 10)
            #expect(run.ledger?.bal["a"] == 6)
            #expect(run.results == [[.taken(.ok(6))], []])
        }
        // E: request 0 dropped, the resend's reply duplicated.
        try forAll(Self.schedules, testCases: 100, database: "") { schedule in
            let run = runSystem(bal: 10, scripts: scripts, faults: Faults([.init(message: 0, kind: .drop), .init(message: 2, kind: .duplicate)]), policy: schedule.policy)
            try Self.check(run, bal: 10)
            #expect(run.ledger?.bal["a"] == 6)
            #expect(run.results == [[.taken(.ok(6))], []])
        }
    }

    // MARK: What the composed check found

    /// Found by `codeRefinesUnderEveryScheduleAndFaultList` with the
    /// equation as Phase A section 5 states it, shrunk by Hegel to: balance
    /// 0, t2 alone, `wd 1` twice, the first copy delayed 3 ticks, both
    /// resends dropped, default schedule. The teller gives up on t2·1 and
    /// submits t2·2; t2·2 applies; then the delayed copy of t2·1 arrives
    /// and applies (P4b with P3a: a copy of a given-up request may still
    /// apply). π = [t2·2, t2·1] does not extend t2's own order. Every
    /// step is a `Next_S` step and the four invariants hold, so it is the
    /// equation's order clause that is wrong, not the code and not the
    /// relation: the clause follows from P5a only for requests the teller
    /// did not give up on. The same behaviour, drawn on the relation.
    @Test func aGivenUpRequestsLateCopyAppliesOutOfOrder() throws {
        let input = (0, [[], [TellerReq.wd(1), .wd(1)]] as [[TellerReq]], Delays([0: 3]),
                     Faults([.init(message: 1, kind: .drop), .init(message: 2, kind: .drop)]), Schedule())
        let run = runSystem(bal: input.0, scripts: input.1, delays: input.2, faults: input.3, policy: input.4.policy)
        #expect(run.refinement.violation == nil)
        #expect(run.refinement.final.brokenInvariant == nil)
        #expect(run.refinement.final.applied == [TellerId(teller: "t2", n: 2), TellerId(teller: "t2", n: 1)])
        let why = run.refinement.final.equation(orderAmongGivenUp: true)
        print("composed check finding: \(why ?? "no violation")")
        #expect(why?.contains("does not extend t2's order") == true)
        #expect(run.refinement.final.equation(orderAmongGivenUp: false) == nil)
        // On the relation alone, the same rows.
        var s = SystemModel(bal: 0)
        let q1 = TellerRequest(id: TellerId(teller: "t2", n: 1), req: .wd(1)), q2 = TellerRequest(id: TellerId(teller: "t2", n: 2), req: .wd(1))
        for step in [Step.submit(1, .wd(1)), .timeout(1), .drop(.request(q1)), .timeout(1), .drop(.request(q1)), .giveUp(1),
                     .submit(1, .wd(1)), .arrive(q2), .deliver(1, TellerReply(id: q2.id, rep: .refused(0))), .arrive(q1)] {
            #expect(s.enabled(step)); s.apply(step); #expect(s.invariantsHold)
        }
        #expect(s.equation(orderAmongGivenUp: true)?.contains("does not extend") == true)
        #expect(s.equation(orderAmongGivenUp: false) == nil)
    }

    // MARK: The planted seam bug

    /// The bridge gives every forwarded copy a fresh sequence number. The
    /// composed check must find it, and the shrunk counterexample is one
    /// request duplicated once: the second copy is applied where the
    /// relation says Again.
    @Test func plantedFreshSeqIsFoundAndShrinksToOneDuplicate() throws {
        let (input, run, v) = try Self.shrunkFailure(bug: .freshSeqPerCopy)
        let (bal, scripts, delays, faults, schedule) = input
        print("planted freshSeqPerCopy: bal \(bal), scripts \(scripts), \(delays), \(faults), \(schedule)\n"
              + run.records.enumerated().map { "\($0 == v.index ? "→" : " ") \($1)" }.joined(separator: "\n") + "\n\(v)")
        #expect(scripts[0].count + scripts[1].count == 1)
        #expect(delays == Delays())
        #expect(schedule.deviations.isEmpty)
        #expect(faults.faults.count == 1 && faults.faults.first?.kind == .duplicate)
        if case .arrive = v.record.step {} else { Issue.record("first non-step is \(v.record.step)") }
        #expect(v.record.ledger?.seen.count == 2)
        #expect(v.before.ledger.seen.count == 1)
    }

    /// The bridge drops the teller from the id: two tellers' first
    /// requests collide. Found at the first arrival whose stored identity
    /// is not the relation's; the shrunk input is one request.
    @Test func plantedIdWithoutTellerIsFound() throws {
        let (input, run, v) = try Self.shrunkFailure(bug: .idWithoutTeller)
        let (bal, scripts, delays, faults, schedule) = input
        print("planted idWithoutTeller: bal \(bal), scripts \(scripts), \(delays), \(faults), \(schedule)\n"
              + run.records.enumerated().map { "\($0 == v.index ? "→" : " ") \($1)" }.joined(separator: "\n") + "\n\(v)")
        if case .arrive = v.record.step {} else { Issue.record("first non-step is \(v.record.step)") }
        // And the collision itself, forced: both tellers wd 7 at 10, one honest network.
        let run2 = runSystem(bal: 10, scripts: [[.wd(7)], [.wd(7)]], bug: .idWithoutTeller, policy: Schedule().policy)
        print("collision: bal \(run2.ledger?.bal["a"] ?? -1), results \(run2.results)")
        #expect(run2.refinement.violation != nil)
        #expect(run2.results.flatMap { $0 } == [.taken(.ok(3)), .taken(.ok(3))])   // both told ok for one debit: drawing D refuted
    }

    static func shrunkFailure(bug: Bridge.Bug) throws -> ((Int, [[TellerReq]], Delays, Faults, Schedule), SystemRun, SystemModel.Violation) {
        do {
            try forAll(Self.inputs, testCases: 500, seed: 1, database: "") { bal, scripts, delays, faults, schedule in
                try Self.check(runSystem(bal: bal, scripts: scripts, delays: delays, faults: faults, bug: bug, policy: schedule.policy), bal: bal)
            }
            throw NotFound()
        } catch let failure as PropertyFailure {
            let input = try replay(Self.inputs, blob: try #require(failure.failures.first?.reproduceBlob))
            let run = runSystem(bal: input.0, scripts: input.1, delays: input.2, faults: input.3, bug: bug, policy: input.4.policy)
            let v = try #require(run.refinement.violation)
            return (input, run, v)
        }
    }

    struct NotFound: Error {}
    struct NotCompleted: Error, CustomStringConvertible {
        let outcome: Scheduler.Outcome, trace: [String]
        var description: String { "\(outcome)\n" + trace.suffix(30).joined(separator: "\n") }
    }
    struct NotARefinement: Error, CustomStringConvertible {
        let violation: SystemModel.Violation, records: [SystemModel.Record], network: [String]
        var description: String {
            "does not refine Next_S: \(violation)\nrecords:\n"
                + records.enumerated().map { "\($0 == violation.index ? "→" : " ") \($1)" }.joined(separator: "\n")
                + "\nnetwork:\n" + network.joined(separator: "\n")
        }
    }
}
