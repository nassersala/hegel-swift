import Schedules

/// A submit button's affordance in time. The view model disables the
/// button while a submission is in flight, so what the user sees as
/// possible is possible: one submission at a time.
///
/// Buggy: the button is disabled after the validation hop, so a second
/// tap arriving while the first is suspended there sees it enabled, is
/// accepted, and submits again. Fixed: disabled synchronously at the tap,
/// before any `await`.
///
/// Every event carries a number, as `Step.event` requires: `tap` carries
/// what the user saw (1 enabled, 0 disabled), `submit` and `completed`
/// the submission count, `rejected` 0.
actor SubmitForm {
    let executor: ControlledSerialExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    let validator: Validator
    let server: Server
    let safe: Bool
    /// The flag the button binds to.
    private(set) var submitEnabled = true
    private(set) var submissions = 0

    init(safe: Bool, executor: ControlledSerialExecutor, validator: Validator, server: Server) {
        self.safe = safe
        self.executor = executor
        self.validator = validator
        self.server = server
    }

    private func note(_ event: String) { executor.scheduler.note("form \(event)") }

    func tap() async {
        note("tap \(submitEnabled ? 1 : 0)")
        guard submitEnabled else { note("rejected 0"); return }
        if safe { submitEnabled = false }
        await validator.validate()
        if !safe { submitEnabled = false }
        submissions += 1
        note("submit \(submissions)")
        await server.send()
        note("completed \(submissions)")
        submitEnabled = true
    }
}

actor Validator {
    let executor: ControlledSerialExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    init(executor: ControlledSerialExecutor) { self.executor = executor }
    func validate() {}
}

actor Server {
    let executor: ControlledSerialExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    init(executor: ControlledSerialExecutor) { self.executor = executor }
    func send() {}
}

/// Two taps on the submit button, concurrently, under `policy`.
func twoTaps(_ policy: @escaping Scheduler.Policy, safe: Bool = false) -> (Scheduler.Outcome, submissions: Int, trace: [String]) {
    let scheduler = Scheduler()
    let form = SubmitForm(
        safe: safe,
        executor: scheduler.serialExecutor("form"),
        validator: Validator(executor: scheduler.serialExecutor("validator")),
        server: Server(executor: scheduler.serialExecutor("server")))
    let count = SendableBox<Int>(0)
    let outcome = scheduler.run(policy: policy) {
        async let a: Void = form.tap()
        async let b: Void = form.tap()
        _ = await (a, b)
        count.value = await form.submissions
    }
    return (outcome, count.value, scheduler.trace)
}
