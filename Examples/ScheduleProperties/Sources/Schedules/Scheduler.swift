import os

/// A controlled scheduler: one ready queue for every executor it hands
/// out, a fake clock, and a policy that picks which ready job runs next.
///
/// Everything runs on the thread that calls `run`; the concurrency
/// runtime's own pool is never involved for code that stays on our
/// executors. Jobs carry stable ids in enqueue order, so a trace names
/// them and the trace is a function of the policy alone.
public final class Scheduler: @unchecked Sendable {
    /// Which ready job runs next. Consulted only at choice points (two or
    /// more ready jobs); `choice` counts prior choice points in this run.
    public typealias Policy = @Sendable (_ ready: [JobInfo], _ choice: Int) -> Int

    public struct JobInfo: Sendable, Equatable, CustomStringConvertible {
        public let id: Int
        /// The executor the job was enqueued on.
        public let lane: String
        public var description: String { "#\(id)@\(lane)" }
    }

    public enum Outcome: Sendable, Equatable {
        /// The root task finished after `steps` jobs and `clockAdvances`.
        case completed(steps: Int, clockAdvances: Int)
        /// Nothing ready, no timer pending, root not finished: a deadlock
        /// among our jobs, or work that escaped to an executor we do not
        /// control and never came back within the grace period.
        case stuck(steps: Int)
        /// More than `maxSteps` jobs ran.
        case runaway
    }

    struct Pending {
        let info: JobInfo
        let job: UnownedJob
        let executor: any Lane
    }
    struct Timer {
        let id: Int
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Never>
    }
    struct State {
        var ready: [Pending] = []
        var timers: [Timer] = []
        var now: Duration = .zero
        var nextId = 0
        var trace: [String] = []
        var maxReadyWidth = 0
        var choicePoints = 0
    }

    let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// The trace of the last run: `enqueue`, `run`, and `advance` lines.
    public var trace: [String] { state.withLock { $0.trace } }
    /// Ready-set width high-water mark of the last run.
    public var maxReadyWidth: Int { state.withLock { $0.maxReadyWidth } }
    /// How many steps of the last run had two or more ready jobs.
    public var choicePoints: Int { state.withLock { $0.choicePoints } }
    /// The fake clock's current time.
    public var now: Duration { state.withLock { $0.now } }

    // MARK: Executors

    /// A serial executor for one actor. Give each actor its own so actor
    /// isolation stays exactly what the language guarantees.
    public func serialExecutor(_ name: String) -> ControlledSerialExecutor {
        ControlledSerialExecutor(name: name, scheduler: self)
    }

    /// The task executor tasks under test prefer. Non-actor async code,
    /// task starts, and continuations resumed from anywhere land here.
    public lazy var taskExecutor = ControlledTaskExecutor(name: "tasks", scheduler: self)

    public lazy var clock = FakeClock(scheduler: self)

    func enqueue(_ job: UnownedJob, on lane: any Lane) {
        state.withLock { s in
            let info = JobInfo(id: s.nextId, lane: lane.name)
            s.nextId += 1
            s.ready.append(Pending(info: info, job: job, executor: lane))
            s.trace.append("enqueue \(info)")
        }
    }

    func sleep(until deadline: Duration, _ continuation: CheckedContinuation<Void, Never>) {
        state.withLock { s in
            let id = s.nextId
            s.nextId += 1
            s.timers.append(Timer(id: id, deadline: deadline, continuation: continuation))
            s.trace.append("timer #\(id) until \(deadline)")
        }
    }

    // MARK: Running

    /// Runs `root` under `policy` until it finishes, deadlocks, or exceeds
    /// `maxSteps`. `root` starts on the task executor; actors it touches
    /// must use executors from this scheduler to stay under control.
    ///
    /// `grace` is real time to wait when nothing is ready before calling
    /// it stuck: work that escaped to the global pool (a detached task, a
    /// real-clock sleep) may still hop back onto our queue.
    public func run(
        policy: @escaping Policy,
        maxSteps: Int = 10_000,
        grace: Duration = .milliseconds(50),
        _ root: @escaping @Sendable () async -> Void
    ) -> Outcome {
        state.withLock { s in
            s = State()
        }
        let done = OSAllocatedUnfairLock(initialState: false)
        let task = Task(executorPreference: taskExecutor) {
            await root()
            done.withLock { $0 = true }
        }
        defer { task.cancel() }

        var steps = 0
        var advances = 0
        while !done.withLock({ $0 }) {
            if steps >= maxSteps { return .runaway }
            let next: Pending? = state.withLock { s in
                guard !s.ready.isEmpty else { return nil }
                s.maxReadyWidth = max(s.maxReadyWidth, s.ready.count)
                var index = 0
                if s.ready.count > 1 {
                    index = policy(s.ready.map(\.info), s.choicePoints)
                    precondition(s.ready.indices.contains(index), "policy chose \(index) of \(s.ready.count)")
                    s.choicePoints += 1
                }
                let chosen = s.ready.remove(at: index)
                s.trace.append(s.ready.isEmpty ? "run \(chosen.info)" : "run \(chosen.info) (ready: \(s.ready.map(\.info)))")
                return chosen
            }
            if let next {
                next.executor.run(next.job)
                steps += 1
                continue
            }
            // Nothing ready: advance the fake clock to the earliest timer.
            let fired: [Timer] = state.withLock { s in
                guard let earliest = s.timers.map(\.deadline).min() else { return [] }
                s.now = earliest
                let due = s.timers.filter { $0.deadline <= earliest }
                s.timers.removeAll { $0.deadline <= earliest }
                s.trace.append("advance to \(earliest), firing \(due.map { "#\($0.id)" }.joined(separator: " "))")
                return due
            }
            if !fired.isEmpty {
                advances += 1
                for timer in fired { timer.continuation.resume() }
                continue
            }
            // Nothing ready, no timers. Give escaped work a moment to come back.
            let deadline = ContinuousClock.now + grace
            var cameBack = false
            while ContinuousClock.now < deadline {
                if done.withLock({ $0 }) || state.withLock({ !$0.ready.isEmpty }) { cameBack = true; break }
                usleep(200)
            }
            if !cameBack { return .stuck(steps: steps) }
        }
        return .completed(steps: steps, clockAdvances: advances)
    }
}

/// An executor that forwards to the scheduler and knows how to run a job.
protocol Lane: AnyObject, Sendable {
    var name: String { get }
    func run(_ job: UnownedJob)
}

public final class ControlledSerialExecutor: SerialExecutor, Lane, @unchecked Sendable {
    public let name: String
    let scheduler: Scheduler
    init(name: String, scheduler: Scheduler) {
        self.name = name
        self.scheduler = scheduler
    }
    public func enqueue(_ job: consuming ExecutorJob) {
        scheduler.enqueue(UnownedJob(job), on: self)
    }
    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
    func run(_ job: UnownedJob) {
        job.runSynchronously(on: asUnownedSerialExecutor())
    }
}

public final class ControlledTaskExecutor: TaskExecutor, Lane, @unchecked Sendable {
    public let name: String
    let scheduler: Scheduler
    init(name: String, scheduler: Scheduler) {
        self.name = name
        self.scheduler = scheduler
    }
    public func enqueue(_ job: consuming ExecutorJob) {
        scheduler.enqueue(UnownedJob(job), on: self)
    }
    public func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
    func run(_ job: UnownedJob) {
        job.runSynchronously(on: asUnownedTaskExecutor())
    }
}

// MARK: - Fake clock

/// A `Clock` whose time only moves when the scheduler has nothing ready.
public struct FakeClock: Clock, Sendable {
    public struct Instant: InstantProtocol, Sendable, Hashable, Comparable {
        public var offset: Duration
        public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }
    let scheduler: Scheduler
    public var now: Instant { Instant(offset: scheduler.now) }
    public var minimumResolution: Duration { .nanoseconds(1) }

    /// Registers a timer with the scheduler. Cancellation is not honoured
    /// in E2a: a cancelled sleeper still wakes at its deadline.
    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        if deadline.offset <= scheduler.now { return }
        await withCheckedContinuation { scheduler.sleep(until: deadline.offset, $0) }
    }
}

// MARK: - Policies

extension Scheduler {
    /// Run jobs in enqueue order.
    public static let fifo: Policy = { _, _ in 0 }
    /// Run the most recently enqueued job first.
    public static let lifo: Policy = { ready, _ in ready.count - 1 }
}
