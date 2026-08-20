import Testing
import Hegel

// The same affordance property, run against the @Observable view model a
// SwiftUI view binds to. Rules call the view model's intents (tap), like a
// user; the invariant compares its published enabled-flags against the
// machine's legality after every step.

private struct ViewModelAffordanceViolation: Error, CustomStringConvertible {
    let action: AlarmAction
    let state: AlarmState
    let looksEnabled: Bool

    var description: String {
        "\(action.rawValue) looks \(looksEnabled ? "enabled" : "disabled") "
            + "but is \(looksEnabled ? "illegal" : "legal") (state: \(state.rawValue))"
    }
}

private struct FeedbackMissing: Error {}
private struct IllegalTapMutatedMachine: Error {}

private struct ViewModelSession: CustomStringConvertible {
    let model: AlarmViewModel
    var description: String { model.alarm.description }
}

private func checkViewModelAffordances(
    _ makeModel: @escaping @Sendable () -> AlarmViewModel,
    testCases: UInt64 = 300,
    seed: UInt64? = nil,
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    var rules: [Rule<ViewModelSession>] = AlarmAction.allCases.map { action in
        Rule(action.rawValue, precondition: { $0.model.alarm.isLegal(action) }) { session, _ in
            session.model.tap(action)
        }
    }
    rules.append(Rule("tap illegal") { session, tc in
        let index = try tc.drawInteger(in: Int64(0)...3)
        let action = AlarmAction.allCases[Int(index)]
        guard !session.model.alarm.isLegal(action) else { throw HegelError.assume }
        let before = session.model.alarm.state
        session.model.tap(action)
        guard session.model.alarm.state == before else { throw IllegalTapMutatedMachine() }
        guard session.model.visual.feedback != nil else { throw FeedbackMissing() }
    })

    try forAll(
        initial: Gen { _ in ViewModelSession(model: makeModel()) },
        rules: rules,
        invariants: [
            Invariant("affordance correctness") { session in
                for action in AlarmAction.allCases
                where session.model.visual.isEnabled(action) != session.model.alarm.isLegal(action) {
                    throw ViewModelAffordanceViolation(
                        action: action,
                        state: session.model.alarm.state,
                        looksEnabled: session.model.visual.isEnabled(action))
                }
            }
        ],
        testCases: testCases,
        seed: seed,
        database: "",
        file: file,
        line: line)
}

@Suite struct ViewModelAffordanceProperties {
    @Test func correctViewModelTellsTheTruth() throws {
        try checkViewModelAffordances { AlarmViewModel.correct() }
    }

    /// Same minimal lying session as the struct panel: arm, trigger,
    /// reset — then the trigger button the view binds to renders disabled
    /// while the machine is armed. Seeded for determinism.
    @Test func buggyViewModelShrinksToMinimalLyingTrace() throws {
        do {
            try checkViewModelAffordances({ AlarmViewModel.buggy() }, seed: 1)
            Issue.record("the affordance property should have caught the buggy view model")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            let steps = trace.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("initial:") && !$0.hasPrefix("invariant") && !$0.hasPrefix("violated:") }
            #expect(steps == ["arm", "trigger", "reset"])
            #expect(trace.contains("trigger looks disabled but is legal (state: armed)"))
        }
    }
}
