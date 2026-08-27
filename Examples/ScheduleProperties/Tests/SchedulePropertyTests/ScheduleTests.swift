import Testing
import Hegel
import HegelTesting
import Schedules

/// E2b/E2c: hegel draws the schedule; the counterexample shrinks to the
/// minimal set of deviations from the depth-first default.
@Suite struct DrawnSchedules {
    static let schedules: Gen<Schedule> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...40), Gen<Int64>.int(in: 0...7))
            .map { Schedule.Deviation(choice: Int($0), index: Int($1)) },
        count: 0...8
    ).map(Schedule.init)

    /// `G(✓commit ⇒ balance ≥ 0)`.
    static let solvent: Pred<Step> = always(.event("commit") => .event("commit", { $0 >= 0 }))

    /// The bug is behind the schedule; hegel finds it and the shrunk
    /// schedule is one deviation. Depth-first, the second withdrawal
    /// starts (choice 0), passes its check and hops to the auditor
    /// (choice 1); the deviation at choice point 2 runs the first
    /// withdrawal there instead of letting the second finish, so both
    /// checks see the full balance. Earlier deviations do not break it:
    /// starting the first withdrawal at choice 1 just runs it to
    /// completion first.
    ///
    /// The property is a formula over the event trace, not the final
    /// balance: `G(✓commit ⇒ balance ≥ 0)`. The report is the step at
    /// which it fails, in its context.
    @Test func theRaceShrinksToOneDeviation() throws {
        do {
            try forAll(Self.schedules, seed: 1, database: "") { schedule in
                let (outcome, _, trace) = twoWithdrawals(schedule.policy)
                guard case .completed = outcome else { throw ScheduleError.didNotComplete(outcome, trace) }
                try check("G(✓commit ⇒ balance ≥ 0)", Self.solvent, over: trace)
            }
            Issue.record("the race was not found")
        } catch let failure as PropertyFailure {
            let f = try #require(failure.failures.first)
            let minimal = try replay(Self.schedules, blob: try #require(f.reproduceBlob))
            #expect(minimal.deviations.count == 1)
            #expect(minimal.deviations.first?.choice == 2)
            #expect(minimal.deviations.first?.index == 0)
            let (_, balance, trace) = twoWithdrawals(minimal.policy)
            #expect(balance == -100)
            #expect(throws: TemporalViolation.self) {
                try check("G(✓commit ⇒ balance ≥ 0)", Self.solvent, over: trace)
            }
            do { try check("G(✓commit ⇒ balance ≥ 0)", Self.solvent, over: trace) } catch { print("minimal schedule: \(minimal)\n\(error)") }
        }
    }

    /// The mechanism, not just the damage: between a check and its
    /// commit no other check runs, `G(✓check ⇒ X(¬✓check W ✓commit))`.
    /// The buggy fixture fails it on the racing schedule; the fix holds
    /// it on every schedule. `weakUntil` because a trace that ends
    /// before the commit is not a violation.
    @Test func noCheckBetweenCheckAndCommit() throws {
        let atomicity: Pred<Step> = always(.event("check") => next(weakUntil(!.event("check"), .event("commit"))))
        let racing = Schedule(deviations: [.init(choice: 2, index: 0)])
        #expect(throws: TemporalViolation.self) {
            try check("atomicity", atomicity, over: twoWithdrawals(racing.policy).trace)
        }
        try forAll(Self.schedules, database: "") { schedule in
            try check("atomicity", atomicity, over: twoWithdrawals(schedule.policy, safe: true).trace)
        }
    }

    /// Same seed, same blob, same trace: the schedule replays byte-for-byte.
    @Test func replayIsByteStable() throws {
        var blobs: [String] = []
        var traces: [[String]] = []
        for _ in 0..<3 {
            do {
                try forAll(Self.schedules, seed: 7, database: "") { schedule in
                    if twoWithdrawals(schedule.policy).balance < 0 { throw ScheduleError.invariantBroken(0, []) }
                }
            } catch let failure as PropertyFailure {
                let blob = try #require(failure.failures.first?.reproduceBlob)
                blobs.append(blob)
                traces.append(twoWithdrawals(try replay(Self.schedules, blob: blob).policy).trace)
            }
        }
        #expect(Set(blobs).count == 1)
        #expect(Set(traces).count == 1)
    }

    /// The fixed implementation survives every schedule.
    @Test(.propertyTesting) func theFixSurvivesEverySchedule() {
        expectAll(Self.schedules, database: "") { schedule in
            let (outcome, balance, _) = twoWithdrawals(schedule.policy, safe: true)
            #expect(balance == 0)
            if case .completed = outcome {} else { Issue.record("\(outcome)") }
        }
    }

    /// Instrumentation, as the spec asks before refining the generator:
    /// how often a drawn schedule actually met a choice point.
    @Test func generatorInstrumentation() throws {
        var withChoice = 0, widths: [Int] = [], choices: [Int] = [], hashes = Set<Int>()
        try forAll(Self.schedules, testCases: 200, database: "") { schedule in
            let scheduler = Scheduler()
            let account = Account(balance: 100, executor: scheduler.serialExecutor("account"))
            let auditor = Auditor(executor: scheduler.serialExecutor("auditor"))
            _ = scheduler.run(policy: schedule.policy) {
                async let a = account.withdraw(100, auditedBy: auditor)
                async let b = account.withdraw(100, auditedBy: auditor)
                _ = await (a, b)
            }
            if scheduler.choicePoints > 0 { withChoice += 1 }
            widths.append(scheduler.maxReadyWidth)
            choices.append(scheduler.choicePoints)
            hashes.insert(scheduler.trace.hashValue)
        }
        print("""
            instrumentation over 200 schedules: runs with ≥1 choice point \(withChoice)/200, \
            max ready width \(widths.max() ?? 0), choice points per run \(choices.min() ?? 0)...\(choices.max() ?? 0), \
            unique traces \(hashes.count)
            """)
        #expect(withChoice == 200)
        #expect(hashes.count >= 2)
    }
}

enum ScheduleError: Error {
    case didNotComplete(Scheduler.Outcome, [String])
    case invariantBroken(Int, [String])
    case notEquivalent([Step], [Step])
}
