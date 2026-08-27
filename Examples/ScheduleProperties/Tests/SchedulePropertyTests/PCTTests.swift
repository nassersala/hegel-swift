import Testing
import Hegel
import HegelTesting
import Schedules

/// PCT (Burckhardt et al. 2010) as a second schedule generator: hegel
/// draws priorities and change points instead of ready-set indices, and
/// the run is reported as the deviations it made (`Schedule(explaining:)`).
@Suite struct PCTSchedules {
    /// PCT at depth `d` with change points drawn from `0..<k`, the
    /// paper's parameters; `k` is the fixture's choice-point count under
    /// the default schedule (8 here).
    static func pct(depth: Int, steps k: Int) -> Gen<PCT> {
        Hegel.zip(
            array(of: Gen<Int64>.int(in: 0...7).map(Int.init), count: 0...8),
            array(of: Gen<Int64>.int(in: 0...Int64(k - 1)).map(Int.init), count: UInt64(depth - 1)...UInt64(depth - 1))
        ).map { PCT(priorities: $0, changePoints: $1) }
    }
    static let k = twoWithdrawalsRun(Schedule().policy).0.choicePoints
    /// Depth 2: one change point. The race needs exactly one preemption.
    static let pct2 = pct(depth: 2, steps: k)

    /// Task identity on public API: every job belongs to a task, three
    /// tasks run (root and two `async let` children), and a task's
    /// resumptions keep its id while their job ids differ.
    @Test func jobsCarryTheirTask() {
        let (scheduler, _, _) = twoWithdrawalsRun(Scheduler.fifo)
        let jobs = scheduler.jobs
        #expect(jobs.allSatisfy { $0.task != 0 })
        #expect(Set(jobs.map(\.task)).count == 3)
        let byTask = Dictionary(grouping: jobs, by: \.task)
        #expect(byTask.values.contains { $0.count >= 2 })
        #expect(Set(jobs.map(\.id)).count == jobs.count)
    }

    /// A PCT run restated as deviations replays to the same trace.
    @Test(.propertyTesting) func aPCTRunIsExplainedByItsDeviations() {
        expectAll(Self.pct2, database: "") { pct in
            let (scheduler, _, _) = twoWithdrawalsRun(pct.policy)
            let explained = Schedule(explaining: scheduler.choices)
            #expect(twoWithdrawals(explained.policy).trace == scheduler.trace)
        }
    }

    /// `PCT()` is the depth-first default.
    @Test func emptyPCTIsDepthFirst() {
        #expect(twoWithdrawals(PCT().policy).trace == twoWithdrawals(Schedule().policy).trace)
    }

    /// The instrumentation E2b asked for, over the PCT generator.
    @Test func generatorInstrumentation() throws {
        var withChoice = 0, widths: [Int] = [], choices: [Int] = [], hashes = Set<Int>(), tasks = Set<Int>()
        try forAll(Self.pct2, testCases: 200, database: "") { pct in
            let (scheduler, _, _) = twoWithdrawalsRun(pct.policy)
            if scheduler.choicePoints > 0 { withChoice += 1 }
            widths.append(scheduler.maxReadyWidth)
            choices.append(scheduler.choicePoints)
            hashes.insert(scheduler.trace.hashValue)
            tasks.insert(Set(scheduler.jobs.map(\.task)).count)
        }
        print("""
            PCT instrumentation over 200 schedules: runs with ≥1 choice point \(withChoice)/200, \
            max ready width \(widths.max() ?? 0), choice points per run \(choices.min() ?? 0)...\(choices.max() ?? 0), \
            tasks per run \(tasks.sorted()), unique traces \(hashes.count)
            """)
        #expect(withChoice == 200)
        #expect(hashes.count >= 2)
    }

    /// Runs to first failure, uniform deviations against PCT at depth 2,
    /// over 20 seeds each. The paper's bound for PCT is
    /// `1 / (n · k)` per run with `n = 3` tasks and `k` the choice points,
    /// so the expected runs to a failure are at most `3k`.
    @Test func runsToFirstFailure() throws {
        let uniform = measureRunsToFirstFailure(DrawnSchedules.schedules, \.policy)
        let pct = measureRunsToFirstFailure(Self.pct2, \.policy)
        let k = Self.k
        print("runs to first failure on twoWithdrawals, 20 seeds: uniform \(uniform), PCT(d=2, k=\(k)) \(pct); n = 3, bound n·k = \(3 * k)")
        #expect(pct.median <= 3 * k)
    }
}

struct RunsToFailure: CustomStringConvertible {
    var runs: [Int]
    var median: Int { runs.sorted()[runs.count / 2] }
    var description: String { "median \(median), min \(runs.min() ?? 0), max \(runs.max() ?? 0)" }
}

/// For seeds 1...20: how many test cases hegel drew before the buggy
/// `twoWithdrawals` first broke the invariant.
func measureRunsToFirstFailure<S>(_ gen: Gen<S>, _ policy: KeyPath<S, Scheduler.Policy>, cap: UInt64 = 5000) -> RunsToFailure {
    var runs: [Int] = []
    for seed in 1...20 as ClosedRange<UInt64> {
        var count = 0, failed = false
        do {
            try forAll(gen, testCases: cap, seed: seed, database: "") { s in
                if failed { return }
                count += 1
                if twoWithdrawals(s[keyPath: policy]).balance < 0 { failed = true; throw ScheduleError.invariantBroken(0, []) }
            }
        } catch {}
        runs.append(failed ? count : Int(cap) + 1)
    }
    return RunsToFailure(runs: runs)
}
