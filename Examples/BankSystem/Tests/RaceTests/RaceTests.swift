import Testing
import Hegel
import HegelTesting
import Schedules
@testable import Race

/// Steps 5 to 7 for two tellers on one account over an honest network:
/// the relation on drawn behaviours, then the actors under drawn schedules.
@Suite(.serialized) struct RaceTests {
    static let req: Gen<Req> = Hegel.zip(Gen<Bool>.bool, Gen<Int>.int(in: 1...12)).map { $0 ? .dep($1) : .wd($1) }
    static let scripts: Gen<[[Req]]> = Hegel.zip(array(of: req, count: 0...2), array(of: req, count: 0...2)).map { [$0, $1] }
    static let onePair: Gen<[[Req]]> = Hegel.zip(req, req).map { [[$0], [$1]] }
    static let balance = Gen<Int>.int(in: 0...12)
    static let schedules: Gen<Schedule> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...40), Gen<Int64>.int(in: 0...7))
            .map { Schedule.Deviation(choice: Int($0), index: Int($1)) },
        count: 0...8
    ).map(Schedule.init)
    static let delays: Gen<Delays> = array(
        of: Hegel.zip(Gen<Int>.int(in: 0...9), Gen<Int>.int(in: 1...5)), count: 0...3
    ).map { Delays(Dictionary($0, uniquingKeysWith: { a, _ in a })) }

    /// Drawn balance, drawn scripts, drawn behaviour.
    static let behaviours: Gen<(Int, [[Req]], Race.Run)> = Hegel.zip(balance, scripts).flatMap { b, s in
        Race.behaviour(bal: b, scripts: s).map { (b, s, $0) }
    }
    static let pairs: Gen<(Int, [[Req]], Race.Run)> = Hegel.zip(balance, onePair).flatMap { b, s in
        Race.behaviour(bal: b, scripts: s).map { (b, s, $0) }
    }

    // MARK: Step 1 as a test: drawing D replayed against the relation

    @Test func drawingD() {
        var s = Race(bal: 10)
        let steps: [Step] = [
            .submit(0, .wd(7)), .submit(1, .wd(7)),
            .arrive(.request(Id(1, 1), .wd(7))), .arrive(.request(Id(0, 1), .wd(7))),
            .deliver(0, .reply(Id(0, 1), .refused(3))), .deliver(1, .reply(Id(1, 1), .ok(3))),
        ]
        for step in steps { #expect(s.enabled(step)); s.apply(step) }
        #expect(s.bal == 3)
        #expect(s.seen == [Id(1, 1): .ok(3), Id(0, 1): .refused(3)])
        #expect(s.tl == [TellerState(seq: 1, out: .rep(.refused(3))), TellerState(seq: 1, out: .rep(.ok(3)))])
        #expect(s.settled && s.invariantsHold)
        // P4b: from ⟨wd 7, 1, 1, –⟩ two timeouts, a third is not enabled, giveUp is.
        var t = Race(bal: 10)
        t.apply(.submit(0, .wd(7)))
        t.apply(.timeout(0)); t.apply(.timeout(0))
        #expect(!t.enabled(.timeout(0)) && t.enabled(.giveUp(0)))
        #expect(t.net[.request(Id(0, 1), .wd(7))] == 3)
        t.apply(.giveUp(0))
        #expect(t.tl[0] == TellerState(seq: 1, out: .unknown))
        t.apply(.arrive(.request(Id(0, 1), .wd(7))))
        #expect(t.bal == 3)                                   // a copy of the given-up request applies (P3a)
        t.apply(.arrive(.request(Id(0, 1), .wd(7))))
        #expect(t.bal == 3 && t.net[.reply(Id(0, 1), .ok(3))] == 2)   // Again: the stored reply
        t.apply(.deliver(0, .reply(Id(0, 1), .ok(3))))
        #expect(t.tl[0].out == .unknown)                      // Ignore: pend = –
        #expect(t.invariantsHold)
    }

    // MARK: Step 5: the relation on drawn behaviours

    /// NonNegative, Once, Serial, Agree at every state of every drawn
    /// behaviour, and every behaviour drains to settled.
    @Test(.propertyTesting) func invariantsOnDrawnBehaviours() {
        expectAll(Self.behaviours, testCases: 500, database: "") { bal, scripts, run in
            for (i, s) in run.states.enumerated() {
                if let broken = s.brokenInvariant {
                    Issue.record("\(broken) fails after step \(i) \(run.steps[i]) at \(s)\n\(run)")
                    return
                }
            }
            #expect(run.final.settled)
            #expect(run.final.applied.count == scripts[0].count + scripts[1].count)
        }
    }

    /// The two-teller equation of section 5: one request each, the final
    /// balance one of the two serial orders, each `out` the reply at the
    /// balance before it in the order the ledger took.
    @Test(.propertyTesting) func twoTellersSerialise() {
        expectAll(Self.pairs, testCases: 500, database: "") { bal, scripts, run in
            let gaveUp = (0..<2).map { k in run.steps.contains(.giveUp(k)) }
            if let why = run.final.twoTellerEquation(r: [scripts[0][0], scripts[1][0]], gaveUp: gaveUp) {
                Issue.record("\(why)\n\(run)")
            }
        }
    }

    /// Both orders happen: the drawn behaviours reach both serial orders
    /// where they differ, and both `refused` outcomes of drawing D.
    @Test func bothOrdersAreReached() throws {
        var finals: Set<[Out]> = []
        try forAll(Race.behaviour(bal: 10, scripts: [[.wd(7)], [.wd(7)]]), testCases: 200, database: "") { run in
            finals.insert(run.final.tl.map(\.out))
        }
        #expect(finals.contains([.rep(.ok(3)), .rep(.refused(3))]))
        #expect(finals.contains([.rep(.refused(3)), .rep(.ok(3))]))
    }

    // MARK: Step 6: the code refines the relation under drawn schedules

    static func check(_ run: SystemRun, bal: Int, scripts: [[Req]]) throws {
        guard case .completed = run.outcome else { throw NotCompleted(outcome: run.outcome, trace: run.trace) }
        if let v = run.refinement.violation { throw NotARefinement(violation: v, records: run.records, network: run.network) }
        let final = run.refinement.final
        #expect(final.bal == run.bal)
        #expect(final.tl == run.tellers)
        #expect(final.settled, "\(final)")
        if let broken = final.brokenInvariant { Issue.record("\(broken) at \(final)") }
        if scripts.allSatisfy({ $0.count == 1 }),
           let why = final.twoTellerEquation(r: [scripts[0][0], scripts[1][0]], gaveUp: run.gaveUp) {
            Issue.record(Comment(rawValue: why))
        }
    }

    @Test(.propertyTesting) func codeRefinesUnderEverySchedule() {
        expectAll(Hegel.zip(Self.balance, Self.scripts, Self.delays, Self.schedules), testCases: 300, database: "") { bal, scripts, delays, schedule in
            let run = runSystem(bal: bal, scripts: scripts, delays: delays, policy: schedule.policy)
            #expect(throws: Never.self) { try Self.check(run, bal: bal, scripts: scripts) }
        }
    }

    /// One request each, so the two-teller equation is checked of the code too.
    @Test(.propertyTesting) func codeSerialisesTwoTellers() {
        expectAll(Hegel.zip(Self.balance, Self.onePair, Self.delays, Self.schedules), testCases: 300, database: "") { bal, scripts, delays, schedule in
            let run = runSystem(bal: bal, scripts: scripts, delays: delays, policy: schedule.policy)
            #expect(throws: Never.self) { try Self.check(run, bal: bal, scripts: scripts) }
        }
    }

    /// The timeout path is exercised: some delayed run has a `timeout`
    /// and some has a `giveUp`, and both refine.
    @Test func timeoutsAndGiveUpsAreReached() throws {
        var timeouts = 0, giveUps = 0
        try forAll(Hegel.zip(Self.delays, Self.schedules), testCases: 200, database: "") { delays, schedule in
            let run = runSystem(bal: 10, scripts: [[.wd(4)], [.wd(7)]], delays: delays, policy: schedule.policy)
            try Self.check(run, bal: 10, scripts: [[.wd(4)], [.wd(7)]])
            if run.records.contains(where: { if case .timeout = $0.step { true } else { false } }) { timeouts += 1 }
            if run.records.contains(where: { if case .giveUp = $0.step { true } else { false } }) { giveUps += 1 }
        }
        print("timeouts in \(timeouts) runs, give-ups in \(giveUps) of 200")
        #expect(timeouts > 0)
        #expect(giveUps > 0)
    }

    // MARK: 6a: the planted await between the check and the debit

    /// Two tellers withdrawing the whole balance: under some schedule both
    /// get `ok`. The refinement reports the second `arrive` as not a step
    /// (the relation replies `refused 0`), and the schedule shrinks.
    @Test func awaitInsideTheStepDoubleSpendsAndShrinks() throws {
        let scripts: [[Req]] = [[.wd(10)], [.wd(10)]]
        do {
            try forAll(Hegel.zip(Self.delays, Self.schedules), testCases: 300, seed: 1, database: "") { delays, schedule in
                let run = runSystem(bal: 10, scripts: scripts, delays: delays, awaitInsideStep: true, policy: schedule.policy)
                try Self.check(run, bal: 10, scripts: scripts)
            }
            Issue.record("the await was never exploited")
        } catch let failure as PropertyFailure {
            let (delays, minimal) = try replay(Hegel.zip(Self.delays, Self.schedules), blob: try #require(failure.failures.first?.reproduceBlob))
            let run = runSystem(bal: 10, scripts: scripts, delays: delays, awaitInsideStep: true, policy: minimal.policy)
            let v = try #require(run.refinement.violation)
            print("await between check and debit, \(delays), schedule \(minimal):\n"
                  + run.records.enumerated().map { "\($0 == v.index ? "→" : " ") \($1)" }.joined(separator: "\n")
                  + "\n\(v)\nfinal bal \(run.bal), tellers \(run.tellers)")
            #expect(delays == Delays())
            #expect(minimal.deviations.count <= 2)
            // Is one deviation enough? Every single deviation, tried by hand.
            let single = (0...20).flatMap { c in (0...3).map { Schedule(deviations: [.init(choice: c, index: $0)]) } }
                .first { runSystem(bal: 10, scripts: scripts, delays: Delays(), awaitInsideStep: true, policy: $0.policy).refinement.violation != nil }
            print("one deviation suffices: \(single.map { "\($0)" } ?? "no")")
            if case .arrive = v.record.step {} else { Issue.record("first non-step is \(v.record.step)") }
            #expect(v.record.reply == .ok(0))
            #expect(run.tellers.map(\.out) == [.rep(.ok(0)), .rep(.ok(0))])
            // The same schedule with the await after the step: a refinement, one ok and one refused.
            let fixed = runSystem(bal: 10, scripts: scripts, delays: delays, awaitInsideStep: false, policy: minimal.policy)
            #expect(fixed.refinement.violation == nil)
            #expect(Set(fixed.tellers.map(\.out)) == [.rep(.ok(0)), .rep(.refused(0))])
        }
    }

    struct NotCompleted: Error, CustomStringConvertible {
        let outcome: Scheduler.Outcome, trace: [String]
        var description: String { "\(outcome)\n" + trace.suffix(30).joined(separator: "\n") }
    }
    struct NotARefinement: Error, CustomStringConvertible {
        let violation: Race.Violation, records: [Race.Record], network: [String]
        var description: String {
            "does not refine Next_2: \(violation)\nrecords:\n"
                + records.enumerated().map { "\($0 == violation.index ? "→" : " ") \($1)" }.joined(separator: "\n")
                + "\nnetwork:\n" + network.joined(separator: "\n")
        }
    }
}
