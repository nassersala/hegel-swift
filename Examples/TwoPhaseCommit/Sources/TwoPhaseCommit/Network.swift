import Schedules

/// What the network does to one message, by send index. Reordering is
/// not a fault here: every delivery is its own job, so the scheduler
/// already orders deliveries any way it likes.
public struct Faults: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable { case drop, duplicate }
    public struct Fault: Sendable, Equatable {
        public var message: Int
        public var kind: Kind
        public init(message: Int, kind: Kind) { self.message = message; self.kind = kind }
    }
    public var faults: [Fault]
    public init(_ faults: [Fault] = []) { self.faults = faults }
    func kind(of index: Int) -> Kind? { faults.first { $0.message == index }?.kind }
    public var description: String {
        faults.isEmpty ? "reliable network" : faults.map { "\($0.kind) message \($0.message)" }.joined(separator: "; ")
    }
}

public enum Message: Sendable, Equatable, CustomStringConvertible {
    case prepare
    case vote(from: Int, yes: Bool)
    case decision(Decision)
    /// A prepared participant asking the coordinator for the decision.
    case query(from: Int)
    public var description: String {
        switch self {
        case .prepare: "prepare"
        case .vote(let p, let yes): "vote(p\(p), \(yes ? "yes" : "no"))"
        case .decision(let d): "\(d)"
        case .query(let p): "query(p\(p))"
        }
    }
}

public enum Decision: String, Sendable, Equatable { case commit, abort }

public protocol Node: Actor {
    nonisolated var name: String { get }
    func receive(_ message: Message) async
}

/// Delivers each send as its own task on the scheduler, applying `faults`
/// by send index, and keeps every task it spawned so `drain` can wait for
/// the protocol to go quiet.
public actor Network {
    public nonisolated let executor: ControlledSerialExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    let faults: Faults
    let scheduler: Scheduler
    private var sent = 0
    private var tasks: [Task<Void, Never>] = []
    public private(set) var log: [String] = []

    public init(scheduler: Scheduler, faults: Faults) {
        self.executor = scheduler.serialExecutor("net")
        self.scheduler = scheduler
        self.faults = faults
    }

    public func send(_ message: Message, from sender: String, to node: any Node) {
        let index = sent
        sent += 1
        let copies: Int
        switch faults.kind(of: index) {
        case .drop: copies = 0; scheduler.note("net drop \(index) \(message) \(sender)→\(node.name)")
        case .duplicate: copies = 2; scheduler.note("net duplicate \(index) \(message) \(sender)→\(node.name)")
        case nil: copies = 1
        }
        log.append("\(index): \(sender)→\(node.name) \(message)\(copies == 1 ? "" : " ×\(copies)")")
        for _ in 0..<copies {
            spawn { await node.receive(message) }
        }
    }

    /// Runs `body` as a task the scheduler controls and `drain` waits for.
    public func spawn(_ body: @escaping @Sendable () async -> Void) {
        tasks.append(Task(executorPreference: scheduler.taskExecutor) { await body() })
    }

    /// Waits until every spawned task, including the ones they spawn, is done.
    public func drain() async {
        while !tasks.isEmpty {
            let batch = tasks
            tasks.removeAll()
            for t in batch { await t.value }
        }
    }
}
