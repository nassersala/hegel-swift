import Testing
import Hegel

// The core property: what the user SEES as possible IS possible.
//
//     panel.isEnabled(action) == alarm.isLegal(action)   for every action,
//                                                        at every reachable state
//
// The engine drives the machine (rules = the four user actions, gated by
// their own legality) and the invariant checks the whole affordance matrix
// after every step. A violation shrinks to the shortest user session after
// which the UI lies.

private struct AffordanceViolation: Error, CustomStringConvertible {
    let action: AlarmAction
    let state: AlarmState
    let looksEnabled: Bool

    var description: String {
        "\(action.rawValue) looks \(looksEnabled ? "enabled" : "disabled") "
            + "but is \(looksEnabled ? "illegal" : "legal") (state: \(state.rawValue))"
    }
}

private struct FeedbackMissing: Error {}

/// One session: the machine (truth) and a panel (projection) side by side.
private struct Session<Panel: AlarmPanel>: CustomStringConvertible {
    var alarm = Alarm()
    var panel: Panel

    var description: String { alarm.description }
}

/// Runs the affordance property against any panel implementation.
private func checkAffordances<Panel: AlarmPanel>(
    _ makePanel: @escaping @Sendable () -> Panel,
    testCases: UInt64 = 300,
    seed: UInt64? = nil,
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    var rules: [Rule<Session<Panel>>] = AlarmAction.allCases.map { action in
        Rule(action.rawValue, precondition: { $0.alarm.isLegal(action) }) { session, _ in
            session.alarm.apply(action)
            session.panel.update(session.alarm, after: action)
        }
    }
    // The feedback property rides along: an illegal attempt must not change
    // the machine and must produce visible feedback.
    rules.append(Rule("attempt illegal") { session, tc in
        let index = try tc.drawInteger(in: Int64(0)...3)
        let action = AlarmAction.allCases[Int(index)]
        guard !session.alarm.isLegal(action) else { throw HegelError.assume }
        guard session.panel.noteRejected(action) else { throw FeedbackMissing() }
    })

    try forAll(
        initial: Gen { _ in Session(panel: makePanel()) },
        rules: rules,
        invariants: [
            Invariant("affordance correctness") { session in
                for action in AlarmAction.allCases
                where session.panel.isEnabled(action) != session.alarm.isLegal(action) {
                    throw AffordanceViolation(
                        action: action,
                        state: session.alarm.state,
                        looksEnabled: session.panel.isEnabled(action))
                }
            }
        ],
        testCases: testCases,
        seed: seed,
        database: "",
        file: file,
        line: line)
}

@Suite struct AffordanceProperties {
    /// A panel that renders purely from the state machine tells the truth
    /// at every reachable state.
    @Test func correctPanelTellsTheTruth() throws {
        try checkAffordances({ CorrectPanel() })
    }

    /// The buggy panel (event-driven reset shortcut) must be caught, and
    /// the counterexample must shrink to the shortest session after which
    /// the UI lies: arm, trigger, reset — three steps, then trigger looks
    /// disabled while the machine is armed. Seeded for determinism.
    @Test func buggyPanelShrinksToMinimalLyingTrace() throws {
        do {
            try checkAffordances({ BuggyPanel() }, seed: 1)
            Issue.record("the affordance property should have caught BuggyPanel")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            print("shrunk counterexample:\n\(trace)")
            let steps = trace.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("initial:") && !$0.hasPrefix("invariant") && !$0.hasPrefix("violated:") }
            #expect(steps == ["arm", "trigger", "reset"])
            #expect(trace.contains("initial: disarmed"))
            #expect(trace.contains("trigger looks disabled but is legal (state: armed)"))
        }
    }
}
