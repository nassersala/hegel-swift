import COtp
import Hegel
import LoginUI
import Testing

/// The implementation under test. `resendResetsAttempts` is the planted
/// bug: it violates the Lean theorem `resend_keeps_attempts`.
private struct LoginScreen: Sendable, CustomStringConvertible {
    enum Screen: Sendable { case phone, code, locked, home }
    var screen = Screen.phone
    var attempts = 0
    let resendResetsAttempts: Bool
    var description: String { "\(screen)/\(attempts)" }

    mutating func handle(_ s: Stimulus) -> Response {
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
}

/// One command per stimulus. Applicability and the expected response both
/// come from Lean; nothing about the login is written twice.
private let commands: [Command<LoginScreen, LeanModel>] = Stimulus.allCases.map { s in
    Command(
        "\(s)",
        precondition: { $0.enabled(s) },
        run: { screen in screen.handle(s) },
        model: { m in m.step(s) })
}

private let consistent: @Sendable (LoginScreen, LeanModel) throws -> Void = { sut, m in
    let screenTag: UInt8 = switch sut.screen { case .phone: 0; case .code: 1; case .locked: 2; case .home: 3 }
    guard screenTag == m.screen, sut.attempts == Int(m.attempts) else { throw Drift(sut: "\(sut)", model: m) }
}

@Suite struct LeanVerifiedModelTests {
    @Test func evaluatorAnswersFromLean() {
        var m = LeanModel.initial
        #expect(m.description == "phone/0")
        #expect(m.enabled(.send) && !m.enabled(.goodCode))
        #expect(m.step(.send) == .showCodeField)
        #expect(m.step(.badCode) == .showError && m.attempts == 1)
        #expect(m.step(.resend) == .showCodeField && m.attempts == 1)
        #expect(m.step(.badCode) == .showError && m.step(.badCode) == .lockOut)
        #expect(m.description == "locked/3")
    }

    @Test func correctScreenRefinesTheLeanModel() throws {
        try forAll(
            sut: Gen { _ in LoginScreen(resendResetsAttempts: false) }, model: LeanModel.initial,
            commands: commands, consistent: consistent,
            testCases: 300, database: "")
    }

    /// The resend bug against the Lean oracle, observations only (no α):
    /// five steps. Two bad codes, a resend that (wrongly) clears them, and
    /// a third bad code that should have locked.
    @Test func resendBugShrinksToFiveStepsByObservation() throws {
        do {
            try forAll(
                sut: Gen { _ in LoginScreen(resendResetsAttempts: true) }, model: LeanModel.initial,
                commands: commands,
                testCases: 300, seed: 1, database: "")
            Issue.record("the planted bug was not found")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            #expect(trace == """
                initial: sut phone/0, model phone/0
                  send -> showCodeField
                  badCode -> showError
                  badCode -> showError
                  resend -> showCodeField
                  badCode -> showError failed
                violated: badCode: observed showError, model expected lockOut
                """, "\(trace)")
        }
    }

    /// With α comparing the counter, the same bug is caught at the resend
    /// itself: three steps, and the violation names the theorem's content.
    @Test func resendBugIsCaughtAtTheResendByAlpha() throws {
        do {
            try forAll(
                sut: Gen { _ in LoginScreen(resendResetsAttempts: true) }, model: LeanModel.initial,
                commands: commands, consistent: consistent,
                testCases: 300, seed: 1, database: "")
            Issue.record("the planted bug was not found")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            #expect(trace == """
                initial: sut phone/0, model phone/0
                  send -> showCodeField
                  badCode -> showError
                  resend -> showCodeField
                  invariant consistent failed
                violated: screen code/0 vs model code/1
                """, "\(trace)")
        }
    }
}
