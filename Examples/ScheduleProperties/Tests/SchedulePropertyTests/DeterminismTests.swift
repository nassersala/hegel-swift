import Testing
import Hegel
import Schedules

/// E2a: determinism without hegel. One policy reproduces the race on
/// every run; another never does; the trace is identical across runs.
@Suite struct Determinism {
    @Test func fifoReproducesTheRaceEveryTime() {
        var traces = Set<[String]>()
        for _ in 0..<50 {
            let (outcome, balance, trace) = twoWithdrawals(Scheduler.fifo)
            guard case .completed = outcome else { Issue.record("\(outcome)\n\(trace.joined(separator: "\n"))"); return }
            #expect(balance == -100)
            traces.insert(trace)
        }
        #expect(traces.count == 1)
    }

    @Test func lifoNeverReproducesTheRace() {
        var traces = Set<[String]>()
        for _ in 0..<50 {
            let (outcome, balance, trace) = twoWithdrawals(Scheduler.lifo)
            guard case .completed = outcome else { Issue.record("\(outcome)\n\(trace.joined(separator: "\n"))"); return }
            #expect(balance == 0)
            traces.insert(trace)
        }
        #expect(traces.count == 1)
    }

    @Test func theFixHoldsUnderBothPolicies() {
        #expect(twoWithdrawals(Scheduler.fifo, safe: true).balance == 0)
        #expect(twoWithdrawals(Scheduler.lifo, safe: true).balance == 0)
    }

    /// The clock law as a formula over the step trace,
    /// `G(✓advance ⇒ prev(ready = ∅) ∧ prev now < now)`: time moves only
    /// when the step before left nothing ready (the trace records the
    /// ready set on `run` lines), and strictly forward. The wake order is
    /// an observation of the fixture, not of the trace, and stays raw.
    @Test func fakeClockOrdersSleepers() {
        let scheduler = Scheduler()
        let order = SendableBox<[String]>([])
        let clock = scheduler.clock
        let outcome = scheduler.run(policy: Scheduler.fifo) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await clock.sleep(for: .seconds(3)); order.value.append("3s") }
                group.addTask { try? await clock.sleep(for: .seconds(1)); order.value.append("1s") }
                group.addTask { try? await clock.sleep(for: .seconds(2)); order.value.append("2s") }
            }
        }
        #expect(order.value == ["1s", "2s", "3s"])
        if case .completed(_, let advances) = outcome { #expect(advances == 3) } else { Issue.record("\(outcome)") }

        let steps = Step.parse(scheduler.trace)
        let clockLaw: Pred<Step> = always(
            .ticked(.advance) => (prev(now { $0.ready.isEmpty }) && changed { $0.now < $1.now })
        )
        #expect(evaluate(clockLaw, over: steps), "\(firstFailure(of: clockLaw, over: steps).map { "at step \($0): \(steps[$0])" } ?? "")")
        #expect(steps.filter { $0.kind == .advance }.count == 3)
        #expect(steps.last?.now == .seconds(3))
    }
}

/// Which suspension points stay under control, and which escape. Each
/// case is a documented fact about the runtime (macOS 26 / Swift 6.3),
/// not a test of our code. "Controlled" means the job ran from our queue
/// and appears in the trace; "escapes" means the body ran elsewhere and
/// only its resumption came back to us.
///
/// Serialized: each test blocks the cooperative-pool thread it runs on
/// while waiting for escaped work to come back through that same pool. Run
/// in parallel on a small runner they hold every pool thread and the
/// escaped bodies never get one (CI, 2026-08-27: `.stuck` after the full
/// grace on 3 cores).
@Suite(.serialized) struct Reach {
    func runs(_ scheduler: Scheduler) -> [String] { scheduler.trace.filter { $0.hasPrefix("run") } }

    /// `Task {}` does not inherit the task executor preference: its body
    /// escapes to the global pool and only the awaiting resumption comes
    /// back. Code under test must spawn with `Task(executorPreference:)`
    /// or structured children to stay under control.
    ///
    /// Two claims. Safety, as a formula over the trace: after the root
    /// step nothing runs until the resumption comes back on our lane,
    /// `X(¬✓run W ✓run@tasks)`, weak because the trace may end first.
    /// Liveness, "the resumption does come back", is not a formula: it
    /// is `.completed` within the 2 s grace, a bounded surrogate whose
    /// bound is wall time.
    @Test func unstructuredTaskBodyEscapes() {
        let scheduler = Scheduler()
        let outcome = scheduler.run(policy: Scheduler.fifo, grace: .seconds(2)) { await Task { }.value }
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        let runs = Step.parse(scheduler.trace).filter { $0.kind == .run }
        #expect(evaluate(next(weakUntil(!.ticked(.run), .ticked("tasks"))), over: runs))
        #expect(runs.count == 2)
    }

    /// `Task(executorPreference:)` and task-group children are controlled.
    @Test func explicitPreferenceAndChildrenAreControlled() {
        let scheduler = Scheduler()
        let executor = scheduler.taskExecutor
        let outcome = scheduler.run(policy: Scheduler.fifo) {
            await Task(executorPreference: executor) { }.value
            await withTaskGroup(of: Void.self) { $0.addTask { } }
        }
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        #expect(runs(scheduler).count == 5)  // root, task, resume, child, resume
    }

    /// An actor with the default executor runs its jobs on the preferred
    /// task executor (SE-0417): controlled, with no `unownedExecutor`
    /// override. Actors need our executor only to get their own lane
    /// name in the trace.
    @Test func defaultActorIsControlled() {
        actor Plain { func touch() {} }
        let scheduler = Scheduler()
        let outcome = scheduler.run(policy: Scheduler.fifo) { await Plain().touch() }
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        #expect(runs(scheduler).count == 3)
        // G(✓run ⇒ lane = tasks)
        #expect(evaluate(always(.ticked(.run) => now { $0.lane == "tasks" }), over: Step.parse(scheduler.trace)))
    }

    /// `Task.detached` drops the preference: its body escapes to the
    /// global pool; the awaiting resumption comes back.
    @Test func detachedTaskBodyEscapes() {
        let scheduler = Scheduler()
        let outcome = scheduler.run(policy: Scheduler.fifo, grace: .seconds(2)) {
            await Task.detached { }.value
        }
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        #expect(runs(scheduler).count == 2)  // the detached body is not in the trace
    }

    /// `MainActor` has its own executor (the main queue): the body
    /// escapes; the resumption comes back.
    @Test func mainActorBodyEscapes() {
        let scheduler = Scheduler()
        let outcome = scheduler.run(policy: Scheduler.fifo, grace: .seconds(2)) {
            await MainActor.run { }
        }
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        #expect(runs(scheduler).count == 2)
    }

    /// A real-clock sleep escapes in time only: wall time passes, then
    /// the resumption comes back to our queue. Deterministic order,
    /// nondeterministic duration.
    @Test func realClockSleepEscapesInTime() {
        let scheduler = Scheduler()
        let outcome = scheduler.run(policy: Scheduler.fifo, grace: .seconds(2)) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if case .completed = outcome {} else { Issue.record("\(outcome)") }
        #expect(runs(scheduler).count == 2)
    }

    /// A deadlock among controlled jobs is reported, not hung.
    @Test func deadlockIsReported() {
        let scheduler = Scheduler()
        let outcome = scheduler.run(policy: Scheduler.fifo, grace: .milliseconds(20)) {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
        #expect(outcome == .stuck(steps: 1))
    }
}
