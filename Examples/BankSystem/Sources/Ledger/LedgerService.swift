import os

/// The service: a synchronous core, and an actor around it that journals
/// each arrival. Both are refinements of `LedgerModel`; the actor is the
/// one whose steps can fail to be whole (skill 6a).
///
/// `LedgerCore` is the first refinement: one arrival is one call, no
/// suspension possible.
public struct LedgerCore: Sendable {
    public private(set) var model: LedgerModel
    public init(accounts: [Acct], initial b0: Int) { model = LedgerModel(accounts: accounts, initial: b0) }

    /// Check and commit in one call. `nil` for a message the relation does
    /// not cover (unknown account, amount outside ℕ⁺): nothing changes.
    public mutating func handle(_ m: Request) -> Rep? {
        guard model.enabled(m) else { return nil }
        model.apply(m)
        return model.out
    }

    /// The check alone (`i ∈ dom seen`), for the planted bug; when the
    /// identity is seen this is the whole Again step (out′ = seen[i]).
    public mutating func stored(_ m: Request) -> Rep? {
        guard let rep = model.seen[m.id] else { return nil }
        model.out = rep
        return rep
    }

    /// The commit alone, applying without re-checking, for the planted bug.
    public mutating func commitApply(_ m: Request) -> Rep {
        let (b, rep) = meaning(m.req, model.bal[m.acct]!)
        model.bal[m.acct] = b
        model.seen[m.id] = rep
        model.out = rep
        return rep
    }
}

/// Test-side recording of the service's states at the granularity of one
/// arrival: the message and the state right after its commit, appended
/// synchronously inside the actor so recording adds no suspension.
public final class ArrivalLog: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [(arrival: Request, state: LedgerModel)]())
    /// Phase C: a composed system records every component's steps in one
    /// ordered log; the observer is called synchronously inside `record`,
    /// so the ledger's step lands in that log before any suspension.
    private let observer: (@Sendable (Request, LedgerModel) -> Void)?
    public init(observer: (@Sendable (Request, LedgerModel) -> Void)? = nil) { self.observer = observer }
    public func record(_ m: Request, _ s: LedgerModel) {
        lock.withLock { $0.append((m, s)) }
        observer?(m, s)
    }
    public var entries: [(arrival: Request, state: LedgerModel)] { lock.withLock { $0 } }
}

/// Where the arrival is written before or after it is applied. On its own
/// executor so a call into it is a suspension of the ledger.
public actor Journal {
    public let executor: any SerialExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    public private(set) var lines: [String] = []
    public init(executor: any SerialExecutor) { self.executor = executor }
    public func append(_ line: String) { lines.append(line) }
}

/// The ledger as an actor. `journalBeforeCommit` is the planted bug: the
/// check `i ∉ dom seen` is made, the journal is awaited, then the commit
/// is made on whatever the state is by then. Off, the check and the commit
/// are one synchronous call and the journal is written behind it.
public actor LedgerService {
    public let executor: any SerialExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private var core: LedgerCore
    private let journal: Journal
    private let log: ArrivalLog
    private let journalBeforeCommit: Bool

    public init(executor: any SerialExecutor, accounts: [Acct], initial b0: Int,
                journal: Journal, log: ArrivalLog, journalBeforeCommit: Bool = false) {
        self.executor = executor
        core = LedgerCore(accounts: accounts, initial: b0)
        self.journal = journal
        self.log = log
        self.journalBeforeCommit = journalBeforeCommit
    }

    public var state: LedgerModel { core.model }

    public func handle(_ m: Request) async -> Rep? {
        guard core.model.enabled(m) else { return nil }
        if journalBeforeCommit {
            if let stored = core.stored(m) {            // the check
                log.record(m, core.model)
                return stored
            }
            await journal.append("arrive \(m)")        // the suspension between check and commit
            let rep = core.commitApply(m)               // the commit
            log.record(m, core.model)
            return rep
        }
        let rep = core.handle(m)                        // check and commit, one synchronous step
        log.record(m, core.model)
        await journal.append("applied \(m) → \(rep.map(\.description) ?? "–")")
        return rep
    }
}
