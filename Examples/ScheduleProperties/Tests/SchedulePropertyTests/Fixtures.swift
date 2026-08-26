import Schedules

/// The classic actor-reentrancy bug: check, `await`, then commit. Two
/// concurrent withdrawals of the whole balance both pass the check if the
/// second runs while the first is suspended at the audit hop.
actor Account {
    let executor: ControlledSerialExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private(set) var balance: Int

    init(balance: Int, executor: ControlledSerialExecutor) {
        self.balance = balance
        self.executor = executor
    }

    /// Buggy: the balance may change across the `await`.
    func withdraw(_ amount: Int, auditedBy auditor: Auditor) async -> Bool {
        guard balance >= amount else { return false }
        await auditor.record("withdraw \(amount)")
        balance -= amount  // may go negative
        return true
    }

    /// Fixed: commit before suspending.
    func withdrawSafely(_ amount: Int, auditedBy auditor: Auditor) async -> Bool {
        guard balance >= amount else { return false }
        balance -= amount
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

/// Two withdrawals of the full balance, concurrently, under `policy`.
/// Returns the outcome, the final balance (negative = invariant broken)
/// and the trace.
func twoWithdrawals(_ policy: @escaping Scheduler.Policy, safe: Bool = false) -> (Scheduler.Outcome, balance: Int, trace: [String]) {
    let scheduler = Scheduler()
    let account = Account(balance: 100, executor: scheduler.serialExecutor("account"))
    let auditor = Auditor(executor: scheduler.serialExecutor("auditor"))
    let result = SendableBox<Int>(0)
    let outcome = scheduler.run(policy: policy) {
        async let a = safe ? account.withdrawSafely(100, auditedBy: auditor) : account.withdraw(100, auditedBy: auditor)
        async let b = safe ? account.withdrawSafely(100, auditedBy: auditor) : account.withdraw(100, auditedBy: auditor)
        _ = await (a, b)
        result.value = await account.balance
    }
    return (outcome, result.value, scheduler.trace)
}

final class SendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
