/// What each stimulus is checked against at test time. Static text: the app
/// does not link Lean; the property test does.
public enum Explainer {
    public static func theorem(for s: Stimulus) -> String {
        switch s {
        case .resend: "resend_keeps_attempts"
        case .badCode: "badCode_increments, lockout_iff"
        case .goodCode, .send, .back, .enterPhone: "inv_preserved"
        }
    }

    public static func label(_ s: Stimulus) -> String {
        switch s {
        case .enterPhone: "enter phone"
        case .send: "send"
        case .goodCode: "good code"
        case .badCode: "bad code"
        case .resend: "resend"
        case .back: "back"
        }
    }

    public static let summary = """
        The screen's state machine is LoginViewModel.handle. A property test \
        drives it through hundreds of random walks against a model written in \
        Lean 4, whose invariant and theorems Lean proved. After every step the \
        test checks the response and that screen and counter agree with the \
        model. What you see here is the implementation's own trace, tagged \
        with the theorem each step is checked against.
        """
}
