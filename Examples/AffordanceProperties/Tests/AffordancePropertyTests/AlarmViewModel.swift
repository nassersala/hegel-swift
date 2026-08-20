import Observation
#if canImport(SwiftUI)
import SwiftUI
#endif

// The real-UI escalation: the panel is no longer a plain struct but an
// @Observable view model — the object a SwiftUI view actually binds to —
// and the property tests IT, on macOS and on the iOS simulator.
//
// The view model owns the machine and exposes intents (`tap`), the way
// SwiftUI code is written. Rendering is injected as a function so the
// correct and buggy variants share everything except the render policy.

@Observable
final class AlarmViewModel {
    private(set) var alarm = Alarm()
    private(set) var visual: PanelState

    private let render: (Alarm, AlarmAction?) -> PanelState

    init(render: @escaping (Alarm, AlarmAction?) -> PanelState) {
        self.render = render
        self.visual = render(Alarm(), nil)
    }

    /// The intent a button calls. Illegal taps leave the machine alone and
    /// surface feedback (the system teaches its grammar).
    func tap(_ action: AlarmAction) {
        guard alarm.isLegal(action) else {
            visual.feedback = "\(action.rawValue) is not available"
            return
        }
        alarm.apply(action)
        visual = render(alarm, action)
    }

    /// Renders purely from the state machine. Correct by construction.
    static func correct() -> AlarmViewModel {
        AlarmViewModel { alarm, _ in .derived(from: alarm) }
    }

    /// The same planted bug as BuggyPanel: the reset event hand-copies the
    /// armed visuals and leaves trigger disabled.
    static func buggy() -> AlarmViewModel {
        AlarmViewModel { alarm, event in
            if event == .reset {
                return PanelState(
                    armEnabled: false,
                    disarmEnabled: true,
                    triggerEnabled: false,  // BUG: trigger is legal when armed
                    resetEnabled: false,
                    statusText: "ARMED")
            }
            return .derived(from: alarm)
        }
    }
}

#if canImport(SwiftUI)
/// The actual binding surface: buttons disabled by the view model's
/// booleans. The property tests the view model those bindings read, which
/// is the affordance encoding; rendering pixels is SwiftUI's job.
struct AlarmPanelView: View {
    var model: AlarmViewModel

    var body: some View {
        VStack(spacing: 12) {
            Text(model.visual.statusText).font(.headline)
            Button("Arm") { model.tap(.arm) }
                .disabled(!model.visual.armEnabled)
            Button("Disarm") { model.tap(.disarm) }
                .disabled(!model.visual.disarmEnabled)
            Button("Trigger") { model.tap(.trigger) }
                .disabled(!model.visual.triggerEnabled)
            Button("Reset") { model.tap(.reset) }
                .disabled(!model.visual.resetEnabled)
            if let feedback = model.visual.feedback {
                Text(feedback).font(.footnote)
            }
        }
        .padding()
    }
}
#endif
