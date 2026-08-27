import Hegel
import LoginUI
import Testing

// The same property against the @Observable view model the SwiftUI screen
// binds to: what the simulator shows is what Hegel drove against Lean.

private struct Session: CustomStringConvertible {
    let model: LoginViewModel
    var description: String { "\(model.screen)/\(model.attempts)" }
}

private let commands: [Command<Session, LeanModel>] = Stimulus.allCases.map { s in
    Command(
        "\(s)",
        precondition: { $0.enabled(s) },
        run: { session in session.model.handle(s) },
        model: { m in m.step(s) })
}

private let consistent: @Sendable (Session, LeanModel) throws -> Void = { session, m in
    guard session.model.screen.rawValue == m.screen, session.model.attempts == Int(m.attempts) else {
        throw Drift(sut: "\(session)", model: m)
    }
}

private struct AffordanceViolation: Error, CustomStringConvertible {
    let stimulus: Stimulus
    let looksEnabled: Bool
    let model: LeanModel
    var description: String {
        "\(stimulus) looks \(looksEnabled ? "enabled" : "disabled") but Lean says \(looksEnabled ? "illegal" : "legal") in \(model)"
    }
}

/// Affordance correctness against Lean's `enabled`: what the screen shows as
/// possible is exactly what the proved model allows.
private let affordances = Invariant<Modelled<Session, LeanModel>>("affordances match Lean enabled") { s in
    for x in Stimulus.allCases where s.sut.model.isEnabled(x) != s.model.enabled(x) {
        throw AffordanceViolation(stimulus: x, looksEnabled: s.sut.model.isEnabled(x), model: s.model)
    }
}

@Suite struct ViewModelTests {
    @Test func affordancesMatchLeanEnabled() throws {
        try forAll(
            sut: Gen { _ in Session(model: LoginViewModel()) }, model: LeanModel.initial,
            commands: commands, consistent: consistent, invariants: [affordances],
            testCases: 300, database: "")
    }

    @Test func viewModelRefinesTheLeanModel() throws {
        try forAll(
            sut: Gen { _ in Session(model: LoginViewModel()) }, model: LeanModel.initial,
            commands: commands, consistent: consistent,
            testCases: 300, database: "")
    }

    @Test func buggyViewModelIsCaughtAtTheResend() throws {
        do {
            try forAll(
                sut: Gen { _ in Session(model: LoginViewModel(resendResetsAttempts: true)) },
                model: LeanModel.initial,
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

    /// A screen that hides Back when locked: the machine still allows it,
    /// Lean says it is enabled, the screen says it is not. Caught the moment
    /// the lock is reached.
    @Test func hiddenBackWhenLockedIsAnAffordanceViolation() throws {
        do {
            try forAll(
                sut: Gen { _ in
                    let vm = LoginViewModel(); vm.hidesBackWhenLocked = true; return Session(model: vm)
                },
                model: LeanModel.initial,
                commands: commands, consistent: consistent, invariants: [affordances],
                testCases: 300, seed: 1, database: "")
            Issue.record("the planted UI bug was not found")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            #expect(trace == """
                initial: sut phone/0, model phone/0
                  send -> showCodeField
                  badCode -> showError
                  badCode -> showError
                  badCode -> lockOut
                  invariant affordances match Lean enabled failed
                violated: back looks disabled but Lean says legal in locked/3
                """, "\(trace)")
        }
    }

    /// The intents a button calls go through the same `handle`.
    @Test func intentsAreTheStateMachine() {
        let vm = LoginViewModel()
        vm.phone = "555"
        vm.sendCode()
        #expect(vm.screen == .code)
        vm.code = "0000"; vm.submitCode()
        #expect(vm.lastResponse == .showError && vm.attempts == 1)
        vm.code = LoginViewModel.correctCode; vm.submitCode()
        #expect(vm.screen == .home && vm.lastResponse == .signIn)
    }
}
