import Schedules

/// Bugs to seed, each a textbook way to break two-phase commit.
public enum Bug: Sendable, Equatable {
    /// The coordinator, timing out with some votes missing, commits if
    /// every vote it did get was yes.
    case commitOnTimeout
    /// A prepared participant that has retried enough aborts on its own.
    case heuristicAbort
}

public actor Coordinator: Node {
    public nonisolated let name = "c"
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    let executor: ControlledSerialExecutor
    let scheduler: Scheduler
    let network: Network
    let bug: Bug?
    /// Stops after collecting every vote, before deciding: the blocking case.
    let crashAfterVotes: Bool
    let voteTimeout: Duration
    var participants: [Participant] = []
    public private(set) var votes: [Int: Bool] = [:]
    public private(set) var decision: Decision?
    var crashed = false

    public init(scheduler: Scheduler, network: Network, bug: Bug? = nil, crashAfterVotes: Bool = false, voteTimeout: Duration = .seconds(2)) {
        self.executor = scheduler.serialExecutor("c")
        self.scheduler = scheduler
        self.network = network
        self.bug = bug
        self.crashAfterVotes = crashAfterVotes
        self.voteTimeout = voteTimeout
    }

    public func start(_ participants: [Participant]) async {
        self.participants = participants
        for p in participants { await network.send(.prepare, from: name, to: p) }
        let clock = scheduler.clock
        await network.spawn { [self] in
            try? await clock.sleep(for: self.voteTimeout)
            await self.timeout()
        }
    }

    func timeout() async {
        guard decision == nil, !crashed, votes.count < participants.count else { return }
        scheduler.note("c timeout \(votes.count)")
        if bug == .commitOnTimeout, votes.values.allSatisfy({ $0 }) { await decide(.commit) } else { await decide(.abort) }
    }

    /// The decision is taken before any `await`. The first version
    /// checked `decision == nil` inside an `async` `decide` called with
    /// `await` from `receive`; that `await` is a suspension point even
    /// on the same actor, and hegel's PCT schedule ran the second vote
    /// there: a `no` was recorded, the commit was decided on the `yes`,
    /// and the abort found `decision` already set. Same shape as the
    /// withdrawal race: the check and the write on either side of an
    /// `await`.
    func decide(_ d: Decision) async {
        guard take(d) else { return }
        for p in participants { await network.send(.decision(d), from: name, to: p) }
    }

    func take(_ d: Decision) -> Bool {
        guard decision == nil else { return false }
        decision = d
        scheduler.note("c decide \(d.rawValue)")
        return true
    }

    public func receive(_ message: Message) async {
        guard !crashed else { return }
        switch message {
        case .vote(let p, let yes):
            guard decision == nil, votes[p] == nil else { return }
            votes[p] = yes
            if !yes { await decide(.abort); return }
            if votes.count == participants.count {
                if crashAfterVotes { crashed = true; scheduler.note("c crash"); return }
                await decide(.commit)
            }
        case .query(let p):
            if let decision { await network.send(.decision(decision), from: name, to: participants[p]) }
        case .prepare, .decision:
            break
        }
    }
}

public actor Participant: Node {
    public nonisolated let name: String
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    let executor: ControlledSerialExecutor
    let scheduler: Scheduler
    let network: Network
    let id: Int
    /// This participant's vote when prepared.
    let willVote: Bool
    let bug: Bug?
    let retries: Int
    let retryAfter: Duration
    var coordinator: Coordinator?
    public enum Phase: Sendable, Equatable { case working, prepared, committed, aborted, blocked }
    public private(set) var phase: Phase = .working

    public init(id: Int, vote: Bool, scheduler: Scheduler, network: Network, bug: Bug? = nil, retries: Int = 5, retryAfter: Duration = .seconds(1)) {
        self.id = id
        self.name = "p\(id)"
        self.willVote = vote
        self.executor = scheduler.serialExecutor("p\(id)")
        self.scheduler = scheduler
        self.network = network
        self.bug = bug
        self.retries = retries
        self.retryAfter = retryAfter
    }

    func attach(_ c: Coordinator) { coordinator = c }

    public func receive(_ message: Message) async {
        switch message {
        case .prepare:
            guard phase == .working, let coordinator else { return }
            scheduler.note("\(name) vote \(willVote ? "yes" : "no")")
            if willVote {
                phase = .prepared
                await network.send(.vote(from: id, yes: true), from: name, to: coordinator)
                let clock = scheduler.clock
                await network.spawn { [self] in
                    for _ in 0..<self.retries {
                        try? await clock.sleep(for: self.retryAfter)
                        if await self.phase != .prepared { return }
                        await self.query()
                    }
                    try? await clock.sleep(for: self.retryAfter)
                    await self.giveUp()
                }
            } else {
                phase = .aborted
                scheduler.note("\(name) decide abort")
                await network.send(.vote(from: id, yes: false), from: name, to: coordinator)
            }
        case .decision(let d):
            guard phase == .prepared || phase == .blocked || phase == .working else { return }
            phase = d == .commit ? .committed : .aborted
            scheduler.note("\(name) decide \(d.rawValue)")
        case .vote, .query:
            break
        }
    }

    func query() async {
        guard phase == .prepared, let coordinator else { return }
        scheduler.note("\(name) query")
        await network.send(.query(from: id), from: name, to: coordinator)
    }

    func giveUp() {
        guard phase == .prepared else { return }
        if bug == .heuristicAbort {
            phase = .aborted
            scheduler.note("\(name) decide abort")
        } else {
            phase = .blocked
            scheduler.note("\(name) blocked")
        }
    }
}

/// One run of the protocol: `votes[i]` is participant i's vote.
public struct Run: Sendable {
    public var outcome: Scheduler.Outcome
    public var trace: [String]
    public var events: [Event]
    public var coordinator: Decision?
    public var participants: [Participant.Phase]
    public var network: [String]
    public var choices: [Scheduler.Choice]
}

public func twoPhaseCommit(votes: [Bool], faults: Faults = Faults(), bug: Bug? = nil, crashAfterVotes: Bool = false, retries: Int = 5, policy: @escaping Scheduler.Policy, maxSteps: Int = 10_000) -> Run {
    let scheduler = Scheduler()
    let network = Network(scheduler: scheduler, faults: faults)
    let coordinator = Coordinator(scheduler: scheduler, network: network, bug: bug, crashAfterVotes: crashAfterVotes)
    let participants = votes.enumerated().map { Participant(id: $0, vote: $1, scheduler: scheduler, network: network, bug: bug, retries: retries) }
    let outcome = scheduler.run(policy: policy, maxSteps: maxSteps) {
        for p in participants { await p.attach(coordinator) }
        await coordinator.start(participants)
        await network.drain()
    }
    let trace = scheduler.trace, choices = scheduler.choices
    final class Box: @unchecked Sendable { var decision: Decision?; var phases: [Participant.Phase] = []; var log: [String] = [] }
    let box = Box()
    _ = scheduler.run(policy: Scheduler.fifo) {
        box.decision = await coordinator.decision
        for p in participants { box.phases.append(await p.phase) }
        box.log = await network.log
    }
    return Run(outcome: outcome, trace: trace, events: Event.parse(trace), coordinator: box.decision, participants: box.phases, network: box.log, choices: choices)
}
