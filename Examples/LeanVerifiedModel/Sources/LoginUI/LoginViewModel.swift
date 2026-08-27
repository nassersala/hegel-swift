import Observation

/// Tags agreed with Lean/Otp/Export.lean.
public enum Stimulus: UInt8, CaseIterable, Sendable {
    case enterPhone, send, goodCode, badCode, resend, back
}

public enum Response: UInt8, Equatable, Sendable, CustomStringConvertible {
    case none, showCodeField, showError, lockOut, signIn
    public var description: String {
        ["none", "showCodeField", "showError", "lockOut", "signIn"][Int(rawValue)]
    }
}

public enum Screen: UInt8, Sendable { case phone, code, locked, home }

/// The one-time-code login a SwiftUI view binds to. The state machine is
/// `handle(_:)`; the intents below are what buttons call. A property test
/// drives `handle` against the Lean-verified model.
@Observable
public final class LoginViewModel {
    public private(set) var screen = Screen.phone
    public private(set) var attempts = 0
    public private(set) var lastResponse = Response.none
    public var phone = ""
    public var code = ""

    /// The code that signs in. Everything else is a bad code.
    public static let correctCode = "1234"

    /// The planted bug: resend clears the attempt counter.
    public var resendResetsAttempts: Bool

    /// One handled stimulus, for the explainer.
    public struct Step: Identifiable, Sendable {
        public let id: Int
        public let from: Screen
        public let fromAttempts: Int
        public let stimulus: Stimulus
        public let response: Response
        public let to: Screen
        public let toAttempts: Int
    }
    public private(set) var trace: [Step] = []

    public init(resendResetsAttempts: Bool = false) {
        self.resendResetsAttempts = resendResetsAttempts
    }

    /// Affordance: whether the screen presents `s` as possible. This is what
    /// the buttons bind to, and what the property compares with Lean's
    /// `enabled`. Text-field validation (empty phone, empty code) is not part
    /// of it: the text is the stimulus's argument, not the machine's state.
    public func isEnabled(_ s: Stimulus) -> Bool {
        switch (screen, s) {
        case (.phone, .enterPhone), (.phone, .send), (.phone, .back): true
        case (.code, .goodCode), (.code, .badCode), (.code, .resend), (.code, .back): true
        case (.locked, .back): true
        default: false
        }
    }

    public func reset() {
        screen = .phone; attempts = 0; lastResponse = .none; phone = ""; code = ""; trace = []
    }

    // MARK: The state machine

    @discardableResult
    public func handle(_ s: Stimulus) -> Response {
        let (from, fromAttempts) = (screen, attempts)
        let r = step(s)
        lastResponse = r
        trace.append(Step(id: trace.count, from: from, fromAttempts: fromAttempts, stimulus: s,
                          response: r, to: screen, toAttempts: attempts))
        return r
    }

    private func step(_ s: Stimulus) -> Response {
        switch (screen, s) {
        case (.phone, .enterPhone), (.phone, .back): return .none
        case (.phone, .send): screen = .code; attempts = 0; return .showCodeField
        case (.code, .goodCode): screen = .home; attempts = 0; return .signIn
        case (.code, .badCode):
            attempts += 1
            if attempts >= 3 { screen = .locked; return .lockOut }
            return .showError
        case (.code, .resend):
            if resendResetsAttempts { attempts = 0 }
            return .showCodeField
        case (.code, .back), (.locked, .back): screen = .phone; attempts = 0; return .none
        default: return .none
        }
    }

    // MARK: Intents

    public func sendCode() { handle(.send); code = "" }
    public func submitCode() { handle(code == Self.correctCode ? .goodCode : .badCode); code = "" }
    public func resend() { handle(.resend); code = "" }
    public func back() { handle(.back); code = "" }

    public var attemptsLeft: Int { max(0, 3 - attempts) }
}
