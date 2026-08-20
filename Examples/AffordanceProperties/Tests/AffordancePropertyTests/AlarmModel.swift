// A home alarm panel, modeled two ways:
//
//   Alarm       — the state machine; the truth about what is legal.
//   AlarmPanel  — a view model exposing the booleans a SwiftUI view would
//                 bind with .disabled(!panel.isEnabled(.trigger)); the
//                 user's picture of what is legal.
//
// Affordance correctness is the property that the two agree at every
// reachable state: isEnabled(action) == isLegal(action). The model follows
// an earlier Python/Hypothesis study of the same idea: cleanroom sequence
// specification + Norman's affordance theory + property-based testing.

enum AlarmState: String, Sendable {
    case disarmed, armed, triggered
}

enum AlarmAction: String, CaseIterable, Sendable {
    case arm, disarm, trigger, reset
}

struct Alarm: Sendable, CustomStringConvertible {
    private(set) var state: AlarmState = .disarmed

    /// The sequence grammar: which stimuli are legal from this state.
    func isLegal(_ action: AlarmAction) -> Bool {
        switch (state, action) {
        case (.disarmed, .arm),
             (.armed, .disarm), (.armed, .trigger),
             (.triggered, .disarm), (.triggered, .reset):
            return true
        default:
            return false
        }
    }

    mutating func apply(_ action: AlarmAction) {
        precondition(isLegal(action), "illegal action \(action) in \(state)")
        switch action {
        case .arm: state = .armed
        case .disarm: state = .disarmed
        case .trigger: state = .triggered
        case .reset: state = .armed
        }
    }

    var description: String { state.rawValue }
}

/// The view-model surface under test. `update` is event-driven on purpose:
/// that is how real UI code gets written, and where the bug class lives.
protocol AlarmPanel: Sendable {
    mutating func update(_ alarm: Alarm, after action: AlarmAction?)
    func isEnabled(_ action: AlarmAction) -> Bool
    /// Called when the user attempts an illegal action. Returns whether the
    /// panel gave visible feedback (the system teaches its grammar).
    mutating func noteRejected(_ action: AlarmAction) -> Bool
}

/// The button booleans a view binds to, plus the last feedback message.
struct PanelState: Equatable, Sendable {
    var armEnabled = false
    var disarmEnabled = false
    var triggerEnabled = false
    var resetEnabled = false
    var statusText = ""
    var feedback: String?

    /// The one honest way to render: derive everything from the state.
    static func derived(from alarm: Alarm) -> PanelState {
        var panel = PanelState(statusText: alarm.state.rawValue.uppercased())
        for action in AlarmAction.allCases where alarm.isLegal(action) {
            switch action {
            case .arm: panel.armEnabled = true
            case .disarm: panel.disarmEnabled = true
            case .trigger: panel.triggerEnabled = true
            case .reset: panel.resetEnabled = true
            }
        }
        return panel
    }

    func isEnabled(_ action: AlarmAction) -> Bool {
        switch action {
        case .arm: return armEnabled
        case .disarm: return disarmEnabled
        case .trigger: return triggerEnabled
        case .reset: return resetEnabled
        }
    }
}

/// Renders purely from the state machine. Affordance-correct by construction.
struct CorrectPanel: AlarmPanel {
    private var visual = PanelState.derived(from: Alarm())

    mutating func update(_ alarm: Alarm, after action: AlarmAction?) {
        visual = .derived(from: alarm)
    }

    func isEnabled(_ action: AlarmAction) -> Bool { visual.isEnabled(action) }

    mutating func noteRejected(_ action: AlarmAction) -> Bool {
        visual.feedback = "\(action.rawValue) is not available"
        return true
    }
}

/// The planted bug, ported from the Python study's BuggyPanel: on `reset`
/// the developer "knew" the machine goes back to armed and hand-copied the
/// armed visuals — leaving trigger disabled. Updating from the event
/// instead of the state is the classic way view caches drift from truth.
struct BuggyPanel: AlarmPanel {
    private var visual = PanelState.derived(from: Alarm())

    mutating func update(_ alarm: Alarm, after action: AlarmAction?) {
        if action == .reset {
            visual = PanelState(
                armEnabled: false,
                disarmEnabled: true,
                triggerEnabled: false,  // BUG: trigger is legal when armed
                resetEnabled: false,
                statusText: "ARMED")
        } else {
            visual = .derived(from: alarm)
        }
    }

    func isEnabled(_ action: AlarmAction) -> Bool { visual.isEnabled(action) }

    mutating func noteRejected(_ action: AlarmAction) -> Bool {
        visual.feedback = "\(action.rawValue) is not available"
        return true
    }
}
