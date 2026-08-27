import Testing
import Quicksort
import Schedules

extension Scheduled { @Suite struct Regression {
    /// The lost wakeup in `ThresholdCell.read`: a waiting read is two jobs
    /// on the cell, the check and the registration, and a `join` may run
    /// between them. Under this schedule the `[1]|[2]` merge joined
    /// between the check and the registration of `[0]|[1, 2]`'s read, and
    /// the run stuck at 25 steps. Deterministic: same schedule, same trace.
    @Test func lostWakeup() {
        let schedule = Schedule(deviations: [.init(choice: 4, index: 1), .init(choice: 6, index: 1), .init(choice: 7, index: 1)])
        let values = [0, 0, 0, 0, 0, 0]
        for _ in 0..<3 {
            let (outcome, order, _) = thresholdMergesort(values, grace: .milliseconds(200), policy: schedule.policy)
            if case .completed = outcome {} else { Issue.record("\(outcome)") }
            #expect(order.isTotal)
        }
    }
} }
