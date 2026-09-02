import Testing
import Hegel
import Schedules

/// Affordance correctness in time. `Examples/AffordanceProperties` checks
/// "what the user sees as possible is possible" at every state of a
/// synchronous session. Here the same claim is checked at every step of an
/// interleaving: between an accepted tap and its completion the button
/// must not look enabled, and there is no second submission.
@Suite struct AffordanceInTime {
    /// The affordance: once a tap is accepted, no tap sees the button
    /// enabled until the submission completes.
    /// `G(✓tap(1) ⇒ X(¬✓tap(1) W ✓completed))`
    static let tellsTheTruth: Pred<Step> = always(
        .event("tap", { $0 == 1 }) => weakNext(weakUntil(!.event("tap", { $0 == 1 }), .event("completed"))))

    /// The consequence: no second submit between a submit and its completion.
    /// `G(✓submit ⇒ X(¬✓submit W ✓completed))`
    static let oneAtATime: Pred<Step> = always(
        .event("submit") => weakNext(weakUntil(!.event("submit"), .event("completed"))))

    /// The feedback half: a tap that saw the button disabled is rejected
    /// in the next step. `G(✓tap(0) ⇒ X ✓rejected)`
    static let feedback: Pred<Step> = always(.event("tap", { $0 == 0 }) => weakNext(.event("rejected")))

    static func checkAll(_ trace: [String]) throws {
        try SchedulePropertyTests.check("G(✓tap(1) ⇒ X(¬✓tap(1) W ✓completed))", tellsTheTruth, over: trace)
        try SchedulePropertyTests.check("G(✓submit ⇒ X(¬✓submit W ✓completed))", oneAtATime, over: trace)
        try SchedulePropertyTests.check("G(✓tap(0) ⇒ X ✓rejected)", feedback, over: trace)
    }

    /// The bug is behind the schedule: the second tap must run while the
    /// first is suspended at the validation hop. Hegel finds it, and the
    /// shrunk schedule, one deviation, fails the affordance formula at the
    /// second tap: it saw the button enabled while a submission was in
    /// flight, and both taps submitted.
    @Test func theButtonLiesWhileSubmitting() throws {
        do {
            try forAll(DrawnSchedules.schedules, seed: 1, database: "") { schedule in
                let (outcome, _, trace) = twoTaps(schedule.policy)
                guard case .completed = outcome else { throw ScheduleError.didNotComplete(outcome, trace) }
                try Self.checkAll(trace)
            }
            Issue.record("the lying button was not found")
        } catch let failure as PropertyFailure {
            let minimal = try replay(DrawnSchedules.schedules, blob: try #require(failure.failures.first?.reproduceBlob))
            let (_, submissions, trace) = twoTaps(minimal.policy)
            #expect(submissions == 2)
            #expect(throws: TemporalViolation.self) {
                try check("affordance", Self.tellsTheTruth, over: trace)
            }
            let events = Step.parse(trace).filter { $0.kind == .event }.map(\.description)
            #expect(events.prefix(2) == ["event form tap 1", "event form tap 1"])
            do { try check("G(✓tap(1) ⇒ X(¬✓tap(1) W ✓completed))", Self.tellsTheTruth, over: trace) } catch {
                print("minimal schedule: \(minimal)\n\(error)")
            }
        }
    }

    /// Disabled at the tap, before any `await`: the button tells the truth
    /// at every step of every schedule, and a tap that saw it disabled is
    /// rejected with feedback. Two submissions are legal when the second
    /// tap comes after the first completed; the formulas say so, a count
    /// would not.
    @Test func theFixTellsTheTruthUnderEverySchedule() throws {
        try forAll(DrawnSchedules.schedules, database: "") { schedule in
            let (outcome, _, trace) = twoTaps(schedule.policy, safe: true)
            guard case .completed = outcome else { throw ScheduleError.didNotComplete(outcome, trace) }
            try Self.checkAll(trace)
        }
    }
}
