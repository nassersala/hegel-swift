import COtp
import Hegel
import Schedules
import Testing
import os

// The account race from Examples/ScheduleProperties, checked against a
// Lean relation. The schedule is the drawn input; the run yields a trace of
// semantic events; every event must be enabled in the Lean model where it
// fires, and Lean's `step` must reproduce the final balance. Lean proved
// that every safe path keeps the balance non-negative.

enum BankTask: UInt8, Sendable { case a, b }

enum BankEvent: Equatable, Sendable, CustomStringConvertible {
    case checkPass(BankTask), checkFail(BankTask), commit(BankTask)
    var tag: UInt8 {
        switch self {
        case .checkPass(let t): 0 * 2 + t.rawValue
        case .checkFail(let t): 1 * 2 + t.rawValue
        case .commit(let t): 2 * 2 + t.rawValue
        }
    }
    var description: String {
        switch self {
        case .checkPass(let t): "checkPass(\(t))"
        case .checkFail(let t): "checkFail(\(t))"
        case .commit(let t): "commit(\(t))"
        }
    }
}

/// The Lean relation, one variant at a time.
struct BankModel: Sendable, CustomStringConvertible {
    enum Variant: UInt8 { case unsafe, safe }
    let variant: Variant
    var state: UInt64

    init(_ variant: Variant) {
        otp_init()
        self.variant = variant
        state = bank_initial_state()
    }
    var balance: Int32 { Int32(bitPattern: UInt32(truncatingIfNeeded: state)) }
    var phaseA: UInt8 { UInt8((state >> 32) & 0xff) }
    var phaseB: UInt8 { UInt8((state >> 40) & 0xff) }
    func enabled(_ e: BankEvent) -> Bool { bank_enabled(variant.rawValue, state, e.tag) == 1 }
    mutating func step(_ e: BankEvent) { state = bank_step(variant.rawValue, state, e.tag) }
    var description: String {
        let p = ["idle", "checked", "done"]
        return "balance \(balance), a \(p[Int(phaseA)]), b \(p[Int(phaseB)])"
    }
}

/// Test-only event recording at the semantic boundary. Appending is
/// synchronous and happens inside the actor, so it adds no suspension.
final class EventLog: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [BankEvent]())
    func record(_ e: BankEvent) { lock.withLock { $0.append(e) } }
    var events: [BankEvent] { lock.withLock { $0 } }
}

actor InstrumentedAccount {
    let executor: ControlledSerialExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private(set) var balance: Int
    let log: EventLog

    init(balance: Int, executor: ControlledSerialExecutor, log: EventLog) {
        self.balance = balance
        self.executor = executor
        self.log = log
    }

    /// Buggy: check, suspend, commit.
    func withdraw(_ amount: Int, as task: BankTask, auditedBy auditor: Auditor) async -> Bool {
        guard balance >= amount else { log.record(.checkFail(task)); return false }
        log.record(.checkPass(task))
        await auditor.record("withdraw \(amount)")
        balance -= amount
        log.record(.commit(task))
        return true
    }

    /// Fixed: check and commit before suspending. One semantic event.
    func withdrawSafely(_ amount: Int, as task: BankTask, auditedBy auditor: Auditor) async -> Bool {
        guard balance >= amount else { log.record(.checkFail(task)); return false }
        balance -= amount
        log.record(.checkPass(task))
        await auditor.record("withdraw \(amount)")
        return true
    }
}

actor Auditor {
    let executor: ControlledSerialExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private(set) var log: [String] = []
    init(executor: ControlledSerialExecutor) { self.executor = executor }
    func record(_ entry: String) { log.append(entry) }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

struct Run {
    let outcome: Scheduler.Outcome
    let balance: Int
    let events: [BankEvent]
    let jobs: [String]
}

func twoWithdrawals(_ policy: @escaping Scheduler.Policy, safe: Bool) -> Run {
    let scheduler = Scheduler()
    let log = EventLog()
    let account = InstrumentedAccount(balance: 100, executor: scheduler.serialExecutor("account"), log: log)
    let auditor = Auditor(executor: scheduler.serialExecutor("auditor"))
    let result = Box(0)
    let outcome = scheduler.run(policy: policy) {
        async let a = safe
            ? account.withdrawSafely(100, as: .a, auditedBy: auditor)
            : account.withdraw(100, as: .a, auditedBy: auditor)
        async let b = safe
            ? account.withdrawSafely(100, as: .b, auditedBy: auditor)
            : account.withdraw(100, as: .b, auditedBy: auditor)
        _ = await (a, b)
        result.value = await account.balance
    }
    return Run(outcome: outcome, balance: result.value, events: log.events, jobs: scheduler.trace)
}

struct NotAPath: Error, CustomStringConvertible {
    let event: BankEvent
    let index: Int
    let model: BankModel
    let events: [BankEvent]
    var description: String {
        "event \(index) \(event) is not enabled in Lean state (\(model)); trace \(events)"
    }
}

struct BalanceDisagrees: Error, CustomStringConvertible {
    let swift: Int
    let lean: Int32
    var description: String { "Swift balance \(swift), Lean says \(lean)" }
}

struct InvariantBroken: Error, CustomStringConvertible {
    let balance: Int
    let events: [BankEvent]
    var description: String { "balance \(balance) after \(events.map(\.description).joined(separator: ", "))" }
}

struct DidNotComplete: Error { let outcome: Scheduler.Outcome }

/// Refinement: the observed event trace is a valid path of the relation
/// and Lean's final balance is Swift's.
func checkRefines(_ run: Run, _ variant: BankModel.Variant) throws -> BankModel {
    var model = BankModel(variant)
    for (i, e) in run.events.enumerated() {
        guard model.enabled(e) else { throw NotAPath(event: e, index: i, model: model, events: run.events) }
        model.step(e)
    }
    guard Int(model.balance) == run.balance else { throw BalanceDisagrees(swift: run.balance, lean: model.balance) }
    return model
}

@Suite struct ConcurrencyTests {
    static let schedules: Gen<Schedule> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...40), Gen<Int64>.int(in: 0...7))
            .map { Schedule.Deviation(choice: Int($0), index: Int($1)) },
        count: 0...8
    ).map(Schedule.init)

    @Test func leanAnswersFromTheRelation() {
        var m = BankModel(.unsafe)
        #expect(m.description == "balance 100, a idle, b idle")
        #expect(m.enabled(.checkPass(.a)) && !m.enabled(.commit(.a)))
        m.step(.checkPass(.a)); m.step(.checkPass(.b)); m.step(.commit(.a)); m.step(.commit(.b))
        #expect(m.balance == -100)
        var s = BankModel(.safe)
        s.step(.checkPass(.a))
        #expect(s.balance == 0 && !s.enabled(.checkPass(.b)) && s.enabled(.checkFail(.b)))
    }

    /// The safe implementation refines the safe relation under every drawn
    /// schedule; Lean's `safe_paths_nonneg` then covers its balance.
    @Test func safeWithdrawalRefinesTheSafeRelation() throws {
        try forAll(Self.schedules, testCases: 300, database: "") { schedule in
            let run = twoWithdrawals(schedule.policy, safe: true)
            guard case .completed = run.outcome else { throw DidNotComplete(outcome: run.outcome) }
            let model = try checkRefines(run, .safe)
            #expect(model.balance >= 0)
        }
    }

    /// The unsafe implementation also refines its relation: the race is not
    /// a refinement failure, it is a behaviour the unsafe model admits
    /// (`unsafe_race`). The model is what is wrong.
    @Test func unsafeWithdrawalRefinesTheUnsafeRelation() throws {
        try forAll(Self.schedules, testCases: 300, database: "") { schedule in
            let run = twoWithdrawals(schedule.policy, safe: false)
            guard case .completed = run.outcome else { throw DidNotComplete(outcome: run.outcome) }
            _ = try checkRefines(run, .unsafe)
        }
    }

    /// Under the unsafe relation the invariant is not a theorem, and Hegel
    /// finds the schedule that breaks it: one deviation, and the event trace
    /// is Lean's witness.
    @Test func theRaceShrinksToOneDeviationWithItsEventTrace() throws {
        do {
            try forAll(Self.schedules, seed: 1, database: "") { schedule in
                let run = twoWithdrawals(schedule.policy, safe: false)
                guard case .completed = run.outcome else { throw DidNotComplete(outcome: run.outcome) }
                _ = try checkRefines(run, .unsafe)
                if run.balance < 0 { throw InvariantBroken(balance: run.balance, events: run.events) }
            }
            Issue.record("the race was not found")
        } catch let failure as PropertyFailure {
            let f = try #require(failure.failures.first)
            let minimal = try replay(Self.schedules, blob: try #require(f.reproduceBlob))
            #expect(minimal.deviations == [Schedule.Deviation(choice: 2, index: 0)])
            let run = twoWithdrawals(minimal.policy, safe: false)
            #expect(run.balance == -100)
            #expect(run.events == [.checkPass(.b), .checkPass(.a), .commit(.a), .commit(.b)])
        }
    }

    /// Instrumentation does not change the race: the same fixed policies
    /// give the same balances as the uninstrumented fixture in
    /// Examples/ScheduleProperties (FIFO races, LIFO runs each withdrawal
    /// to completion, the one-deviation schedule races).
    @Test func instrumentationPreservesTheRace() {
        let expected: [(String, Scheduler.Policy, Int)] = [
            ("fifo", Scheduler.fifo, -100),
            ("lifo", Scheduler.lifo, 0),
            ("deviation", Schedule(deviations: [.init(choice: 2, index: 0)]).policy, -100),
        ]
        for (name, policy, balance) in expected {
            let run = twoWithdrawals(policy, safe: false)
            #expect(run.balance == balance, "\(name): \(run.events)")
        }
    }
}
