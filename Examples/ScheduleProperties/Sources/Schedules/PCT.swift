import os

/// A probabilistic concurrency testing policy, after Burckhardt, Kothari,
/// Musuvathi and Nagarakatte (ASPLOS 2010): every task gets a priority,
/// the highest-priority ready task always runs, and at each of a few
/// change points the running task's priority drops below every other.
/// A bug that needs `d − 1` preemptions at the right places is found with
/// probability at least `1 / (n · k^(d−1))` for `n` tasks and `k` steps.
///
/// Here a task is a Swift task (`JobInfo.task`, the same across its
/// resumptions) and a step is a choice point: the scheduler only chooses
/// when two or more jobs are ready, so a change point anywhere else is a
/// no-op, and `k` is `Scheduler.choicePoints`, not the job count.
///
/// Tasks are ranked in order of first appearance; `priorities[rank]` is
/// the task's priority, 0 for tasks past the end. Ties run depth-first,
/// so `PCT()` is the depth-first default and shrinks toward it.
public struct PCT: Sendable, Equatable, CustomStringConvertible {
    public var priorities: [Int]
    /// Choice points at which the task about to run is demoted, in order;
    /// the `i`th demotion lands at priority `i`, below every initial one.
    public var changePoints: [Int]

    public init(priorities: [Int] = [], changePoints: [Int] = []) {
        self.priorities = priorities
        self.changePoints = changePoints
    }

    /// The bug depth this schedule can reach: `changePoints.count + 1`.
    public var depth: Int { changePoints.count + 1 }

    public var policy: Scheduler.Policy {
        struct Run { var ranks: [Int: Int] = [:]; var demoted: [Int: Int] = [:] }
        let run = OSAllocatedUnfairLock(initialState: Run())
        let priorities = priorities, changePoints = changePoints
        let base = changePoints.count
        return { ready, choice in
            run.withLock { r in
                for job in ready where r.ranks[job.task] == nil { r.ranks[job.task] = r.ranks.count }
                func priority(_ job: Scheduler.JobInfo) -> Int {
                    if let d = r.demoted[job.task] { return d }
                    let rank = r.ranks[job.task]!
                    return base + (rank < priorities.count ? priorities[rank] : 0)
                }
                func top() -> Int { ready.indices.max { a, b in
                    let pa = priority(ready[a]), pb = priority(ready[b])
                    return pa != pb ? pa < pb : a < b
                }! }
                if let i = changePoints.firstIndex(of: choice) {
                    r.demoted[ready[top()].task] = i
                }
                return top()
            }
        }
    }

    public var description: String {
        (priorities.isEmpty && changePoints.isEmpty) ? "PCT: depth-first"
            : "PCT: priorities \(priorities), change points \(changePoints)"
    }
}
