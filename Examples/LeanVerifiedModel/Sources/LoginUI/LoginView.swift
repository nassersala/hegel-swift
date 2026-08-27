#if canImport(SwiftUI)
import SwiftUI

/// The screen. Every transition it performs is `LoginViewModel.handle`,
/// which the property test checks against the Lean model.
public struct LoginView: View {
    @Bindable var model: LoginViewModel
    @State private var showExplainer = false

    public init(model: LoginViewModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 16) {
            Group {
                switch model.screen {
                case .phone: phone
                case .code: code
                case .locked: locked
                case .home: home
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            affordances
            trace
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .animation(.default, value: model.screen)
        .sheet(isPresented: $showExplainer) { explainer }
    }

    // MARK: Screens

    private var phone: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in").font(.largeTitle.bold())
            Text("Enter your phone number and we'll send a code.")
            TextField("Phone", text: $model.phone).textFieldStyle(.roundedBorder)
            Button("Send code") { model.sendCode() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isEnabled(.send) || model.phone.isEmpty)
        }
    }

    private var code: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter the code").font(.largeTitle.bold())
            Text("Sent to \(model.phone). The code is \(LoginViewModel.correctCode).")
                .foregroundStyle(.secondary)
            TextField("Code", text: $model.code).textFieldStyle(.roundedBorder)
            if model.lastResponse == .showError {
                Text("Wrong code. \(model.attemptsLeft) attempt\(model.attemptsLeft == 1 ? "" : "s") left.")
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Verify") { model.submitCode() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isEnabled(.goodCode) || model.code.isEmpty)
                Button("Resend") { model.resend() }.disabled(!model.isEnabled(.resend))
                Button("Back") { model.back() }.disabled(!model.isEnabled(.back))
            }
        }
    }

    private var locked: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Locked").font(.largeTitle.bold())
            Text("Three wrong codes. Go back and start again.")
            Button("Back") { model.back() }.buttonStyle(.bordered).disabled(!model.isEnabled(.back))
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome").font(.largeTitle.bold())
            Text("Signed in as \(model.phone).")
            Button("Start over") { model.reset() }.buttonStyle(.bordered)
        }
    }

    // MARK: Explainer panels

    /// The affordance row: what the screen presents as possible right now.
    /// The property checks this list against Lean's `enabled` after every step.
    private var affordances: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("possible here (checked against Lean `enabled`)").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(Stimulus.allCases, id: \.rawValue) { s in
                    Text(Explainer.label(s))
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(model.isEnabled(s) ? Color.green.opacity(0.2) : Color.gray.opacity(0.12))
                        .foregroundStyle(model.isEnabled(s) ? .primary : .secondary)
                        .clipShape(Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The bubbles: each handled stimulus, its response, the state change,
    /// and the theorem the test checks that step against.
    private var trace: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("trace (this implementation; each step is what the test replays against Lean `step`)")
                .font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.trace) { step in bubble(step).id(step.id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.trace.count) { _, _ in
                    if let last = model.trace.last { withAnimation { proxy.scrollTo(last.id) } }
                }
            }
            .frame(maxHeight: 220)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bubble(_ step: LoginViewModel.Step) -> some View {
        let suspicious = step.stimulus == .resend && step.toAttempts != step.fromAttempts
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(String(describing: step.from))/\(step.fromAttempts)  ▸ \(Explainer.label(step.stimulus))  → \(step.response)  → \(String(describing: step.to))/\(step.toAttempts)")
                .font(.caption.monospaced())
            Text(suspicious ? "violates resend_keeps_attempts" : "checked by \(Explainer.theorem(for: step.stimulus))")
                .font(.caption2)
                .foregroundStyle(suspicious ? .red : .secondary)
        }
        .padding(8)
        .background(suspicious ? Color.red.opacity(0.12) : Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            Toggle("bug: resend resets attempts", isOn: $model.resendResetsAttempts)
                .font(.caption)
            Spacer()
            Button("What is this?") { showExplainer = true }.font(.caption)
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A screen checked against a proved model").font(.title2.bold())
            Text(Explainer.summary)
            Text("Proved by Lean: the counter never exceeds 3 and stays below 3 while a code is being entered; resend never changes it; lockout is exactly the third bad code; a bad code adds exactly one.")
            Text("Checked by Hegel (the test, on the Mac): this view model refines that model on every random walk it tried, and shows as possible exactly what the model says is enabled. The SwiftUI layer is not verified.")
                .foregroundStyle(.secondary)
            Text("Toggle the bug and enter a wrong code, resend, and count: the trace turns red where the implementation stops agreeing with the theorem. The test finds that in three steps.")
            Spacer()
        }
        .padding(24)
        .presentationDetents([.large])
    }
}
#endif
