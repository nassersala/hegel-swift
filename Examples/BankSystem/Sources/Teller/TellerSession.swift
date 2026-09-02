import Hegel
import os

/// Where a request goes. A wire's send does not block: it hands the
/// message over and returns, as a socket write or a URLSession resume does.
public protocol Wire: Sendable {
    func send(_ request: Request)
}

/// The realistic suspension: the session writes a line to an audit store
/// on another lane. Where that `await` sits relative to the decision is
/// what the scheduler tests.
public protocol Audit: Sendable {
    func record(_ line: String) async
}

/// The recorded states, appended synchronously inside the actor.
public final class Trace: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [Session.Record]())
    /// Phase C: called synchronously inside `append`, so a composed
    /// system's one ordered log sees the teller's step before any suspension.
    private let observer: (@Sendable (Session.Record) -> Void)?
    public init(observer: (@Sendable (Session.Record) -> Void)? = nil) { self.observer = observer }
    func append(_ r: Session.Record) {
        lock.withLock { $0.append(r) }
        observer?(r)
    }
    public var records: [Session.Record] { lock.withLock { $0 } }
}

/// The teller session as code: an actor with a submit, a timer on a clock,
/// and a reply inbox. Each of the relation's steps is one synchronous
/// block of the actor that records itself at the step's granularity; the
/// audit write comes after the block. `Bug` moves it before: between the
/// timer's check and the resend, or between the identity check of a reply
/// and its commit.
public actor TellerSession {
    public enum Bug: Sendable, CaseIterable {
        case awaitBeforeResend
        case awaitBeforeTake
    }

    public let teller: String
    private let executor: any SerialExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let wire: any Wire
    private let audit: any Audit
    private let clock: any Clock<Duration>
    private let timeout: Duration
    /// Where the timer tasks run. `Task {}` inside an actor escapes a
    /// controlled scheduler (its body lands on the global pool); the
    /// session spawns its timers with an explicit preference.
    private let timers: (any TaskExecutor)?
    private let bug: Bug?
    public nonisolated let trace: Trace

    private var pending: Req?
    private var seq = 0
    private var tries = 0
    private var out: Out = .none
    private var timerGeneration = 0
    private var waiter: CheckedContinuation<Out, Never>?

    public init(teller: String, executor: any SerialExecutor, wire: any Wire, audit: any Audit,
                clock: any Clock<Duration>, timeout: Duration, timers: (any TaskExecutor)? = nil, bug: Bug? = nil,
                trace: Trace = Trace()) {
        self.teller = teller
        self.trace = trace
        self.executor = executor
        self.wire = wire
        self.audit = audit
        self.clock = clock
        self.timeout = timeout
        self.timers = timers
        self.bug = bug
    }

    public var state: Session { Session(teller: teller, pend: pending, seq: seq, tries: tries, out: out) }

    private var pendingId: Id { Id(teller: teller, n: seq) }

    private func record(_ step: Session.Step, _ kind: Session.Kind, emitted: Request?) {
        trace.append(Session.Record(step: step, kind: kind, emitted: emitted, state: state))
    }

    /// `Submit`. False when a request is outstanding (P5a).
    public func submit(_ r: Req) -> Bool {
        guard pending == nil else { return false }
        pending = r
        seq += 1
        tries = 1
        out = .none
        let q = Request(id: pendingId, req: r)
        record(.submit(r), .submit, emitted: q)
        armTimer()
        wire.send(q)
        return true
    }

    /// The outcome of the outstanding request, once it has one. Registers
    /// and checks inside the continuation, so a reply that lands between
    /// the check and the registration is not a lost wakeup.
    public func outcome() async -> Out {
        await withCheckedContinuation { c in
            if pending == nil { c.resume(returning: out) } else { waiter = c }
        }
    }

    /// The reply inbox: `Take` or `Ignore`.
    public func deliver(_ reply: Reply) async {
        if bug == .awaitBeforeTake {
            let matches = pending != nil && reply.id == pendingId
            await audit.record("reply \(reply)")
            if matches { take(reply) } else { record(.reply(reply), .ignore, emitted: nil) }
            return
        }
        if pending != nil && reply.id == pendingId {
            take(reply)
        } else {
            record(.reply(reply), .ignore, emitted: nil)
        }
        await audit.record("reply \(reply)")
    }

    private func take(_ reply: Reply) {
        pending = nil
        tries = 0
        out = .taken(reply.rep)
        timerGeneration += 1
        record(.reply(reply), .take, emitted: nil)
        settle()
    }

    private func settle() {
        if let w = waiter {
            waiter = nil
            w.resume(returning: out)
        }
    }

    /// One timer per copy; a stale generation fires into nothing.
    private func armTimer() {
        timerGeneration += 1
        let gen = timerGeneration
        Task(executorPreference: timers) { [timeout, clock] in
            try? await clock.sleep(for: timeout)
            await self.fired(gen)
        }
    }

    /// `Timeout` or `GiveUp`.
    private func fired(_ gen: Int) async {
        guard gen == timerGeneration, let r = pending else { return }
        let q = Request(id: pendingId, req: r)
        if bug == .awaitBeforeResend {
            await audit.record("timer \(q.id)")
            if tries < Session.K { resend(q) } else { giveUp() }
            return
        }
        if tries < Session.K { resend(q) } else { giveUp() }
        await audit.record("timer \(q.id)")
    }

    private func resend(_ q: Request) {
        tries += 1
        record(.timeout, .timeout, emitted: q)
        armTimer()
        wire.send(q)
    }

    private func giveUp() {
        pending = nil
        tries = 0
        out = .unknown
        timerGeneration += 1
        record(.giveUp, .giveUp, emitted: nil)
        settle()
    }
}
