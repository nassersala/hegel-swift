import Hegel
import Testing

// A one-time-code login, enumerated Cleanroom-style: canonical states named
// by the shortest sequence that reaches them, every stimulus in every state.

private enum Stimulus: CaseIterable, Sendable { case enterPhone, send, goodCode, badCode, resend, back }
private enum Response: Equatable, Sendable { case none, showCodeField, showError, lockOut, signIn }
private enum Login: CaseIterable, Sendable, CustomStringConvertible {
    case start, phoneEntered, codeSent, oneBad, twoBad, locked, done
    var description: String {
        switch self {
        case .start: "Δ"
        case .phoneEntered: "P"
        case .codeSent: "P.S"
        case .oneBad: "P.S.b"
        case .twoBad: "P.S.b.b"
        case .locked: "P.S.b.b.b"
        case .done: "P.S.g"
        }
    }
}

/// The switch is the table. Delete any case and it does not compile.
private let login = Enumeration<Login, Stimulus, Response>(initial: .start) { state, stimulus in
    switch (state, stimulus) {
    case (.start, .enterPhone): .respond(.none, then: .phoneEntered)
    case (.start, _): .illegal

    case (.phoneEntered, .send): .respond(.showCodeField, then: .codeSent)
    case (.phoneEntered, .enterPhone): .respond(.none, then: .phoneEntered)
    case (.phoneEntered, .back): .respond(.none, then: .start)
    case (.phoneEntered, .goodCode), (.phoneEntered, .badCode), (.phoneEntered, .resend): .illegal

    case (.codeSent, .goodCode): .respond(.signIn, then: .done)
    case (.codeSent, .badCode): .respond(.showError, then: .oneBad)
    case (.codeSent, .resend): .respond(.showCodeField, then: .codeSent)   // resend keeps the count
    case (.codeSent, .back): .respond(.none, then: .phoneEntered)
    case (.codeSent, .enterPhone), (.codeSent, .send): .illegal

    case (.oneBad, .goodCode): .respond(.signIn, then: .done)
    case (.oneBad, .badCode): .respond(.showError, then: .twoBad)
    case (.oneBad, .resend): .respond(.showCodeField, then: .oneBad)
    case (.oneBad, .back): .respond(.none, then: .phoneEntered)
    case (.oneBad, .enterPhone), (.oneBad, .send): .illegal

    case (.twoBad, .goodCode): .respond(.signIn, then: .done)
    case (.twoBad, .badCode): .respond(.lockOut, then: .locked)             // R7: three bad codes lock
    case (.twoBad, .resend): .respond(.showCodeField, then: .twoBad)
    case (.twoBad, .back): .respond(.none, then: .phoneEntered)
    case (.twoBad, .enterPhone), (.twoBad, .send): .illegal

    case (.locked, .back): .respond(.none, then: .start)
    case (.locked, _): .illegal

    case (.done, _): .illegal
    }
}

/// The implementation under test. `resendResetsAttempts` is the planted bug.
private struct LoginScreen: Sendable, CustomStringConvertible {
    enum Screen: Sendable { case phone, code, locked, home }
    var screen = Screen.phone
    var attempts = 0
    let resendResetsAttempts: Bool
    var description: String { "\(screen)/\(attempts)" }

    mutating func handle(_ s: Stimulus) -> Response {
        switch (screen, s) {
        case (.phone, .enterPhone): return .none
        case (.phone, .send): screen = .code; attempts = 0; return .showCodeField
        case (.code, .goodCode): screen = .home; return .signIn
        case (.code, .badCode):
            attempts += 1
            if attempts >= 3 { screen = .locked; return .lockOut }
            return .showError
        case (.code, .resend):
            if resendResetsAttempts { attempts = 0 }
            return .showCodeField
        case (.code, .back): screen = .phone; return .none
        case (.locked, .back): screen = .phone; return .none
        default: return .none
        }
    }
}

// The screen has no phone-entered state of its own, so `Δ ▸ enterPhone` and
// `P ▸ back` are observations of nothing; `.phone` covers both Δ and P.

@Suite struct EnumerationTests {
    @Test func switchFormIsCompleteByConstruction() {
        #expect(login.problems().isEmpty)
    }

    @Test func walkIsTheGate() {
        guard case .accepted(let end) = login.walk([.enterPhone, .send, .badCode, .goodCode]) else {
            Issue.record("should accept"); return
        }
        #expect(end == .done)
        guard case .rejected(let at, let x, let s) = login.walk([.enterPhone, .goodCode]) else {
            Issue.record("should reject"); return
        }
        #expect(at == 1 && x == .goodCode && s == .phoneEntered)
    }

    @Test func correctScreenRefinesTheTable() throws {
        try forAll(
            sut: Gen { _ in LoginScreen(resendResetsAttempts: false) }, model: login.initial,
            commands: login.commands(run: { screen, s in screen.handle(s) }),
            testCases: 300, database: "")
    }

    /// The resend bug shrinks to the six-step walk the experiment found:
    /// enterPhone, send, badCode, resend, badCode, badCode.
    @Test func resendBugShrinksToTheSixStepWalk() throws {
        do {
            try forAll(
                sut: Gen { _ in LoginScreen(resendResetsAttempts: true) }, model: login.initial,
                commands: login.commands(run: { screen, s in screen.handle(s) }),
                testCases: 300, seed: 1, database: "")
            Issue.record("the planted bug was not found")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            #expect(trace == """
                initial: sut phone/0, model Δ
                  Δ ▸ enterPhone -> none
                  P ▸ send -> showCodeField
                  P.S ▸ badCode -> showError
                  P.S.b ▸ resend -> showCodeField
                  P.S.b ▸ badCode -> showError
                  P.S.b.b ▸ badCode -> showError failed
                violated: P.S.b.b ▸ badCode: observed showError, model expected lockOut
                """, "\(trace)")
        }
    }

    @Test func blockFormReportsMissingCellsAndUnreachableStates() {
        enum S: CaseIterable, Sendable { case a, b, c }
        enum X: CaseIterable, Sendable { case go, stay }
        let table = Enumeration<S, X, Response>(initial: .a, table: [
            .a: [.go: .respond(.none, then: .b), .stay: .respond(.none, then: .a)],
            .b: [.go: .respond(.none, then: .a)],   // missing .stay
            // .c missing entirely, and unreachable
        ])
        #expect(table.problems() == ["missing state c", "b missing stay", "unreachable state c"])
        #expect(table[.b, .stay] == .illegal)
        #expect(table.commands(run: { (_: inout Int, _) in Response.none }).count == 3)
    }
}
