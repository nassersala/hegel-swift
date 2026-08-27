import Testing
import Hegel
import HegelTesting
import Schedules

/// The lost wakeup in `ThresholdCell.read` as the acceptance test for
/// PCT: under uniform deviations it took three exact deviations
/// (`Regression.lostWakeup`); it is a depth-2 bug, one preemption of the
/// reader between its check and its registration.
extension Scheduled { @Suite struct PCTSchedules {
    static let values = [0, 0, 0, 0, 0, 0]

    /// PCT at depth `d` with change points drawn from `0..<k`, the
    /// paper's parameters.
    static func pct(depth: Int, steps k: Int) -> Gen<PCT> {
        Hegel.zip(
            array(of: Gen<Int64>.int(in: 0...7).map(Int.init), count: 0...8),
            array(of: Gen<Int64>.int(in: 0...Int64(k - 1)).map(Int.init), count: UInt64(depth - 1)...UInt64(depth - 1))
        ).map { PCT(priorities: $0, changePoints: $1) }
    }

    /// The sorting run's task and step counts, for the bound.
    static var shape: (n: Int, k: Int) {
        let run = thresholdMergesortRun(values, policy: Schedule().policy)
        return (run.tasks, run.choicePoints)
    }

    /// Runs to first `.stuck`, 20 seeds each, uniform against PCT(d=2)
    /// with change points in `0..<k`. PCT's bound is `1/(n·k)` per run.
    @Test func runsToFirstFailure() {
        let (n, k) = Self.shape
        let uniform = Self.measure(ParallelQuicksort.schedules, \.policy)
        let pct = Self.measure(Self.pct(depth: 2, steps: k), \.policy)
        print("runs to first failure on the lost wakeup, 20 seeds: uniform \(uniform), PCT(d=2, k=\(k)) \(pct); n = \(n), bound n·k = \(n * k)")
        #expect(pct.median <= n * k)
    }

    /// What PCT found, said as deviations: the run restated by
    /// `Schedule(explaining:)` replays to the same outcome.
    @Test(.propertyTesting) func aPCTRunIsExplainedByItsDeviations() {
        expectAll(Self.pct(depth: 2, steps: Self.shape.k), database: "") { pct in
            let run = thresholdMergesortRun(Self.values, recheck: false, policy: pct.policy)
            let replay = thresholdMergesortRun(Self.values, recheck: false, policy: Schedule(explaining: run.choices).policy)
            #expect(replay.outcome == run.outcome)
            #expect(replay.choices == run.choices)
        }
    }

    static func measure<S>(_ gen: Gen<S>, _ policy: KeyPath<S, Scheduler.Policy>, cap: UInt64 = 2000) -> RunsToFailure {
        var runs: [Int] = []
        for seed in 1...20 as ClosedRange<UInt64> {
            var count = 0, failed = false
            do {
                try forAll(gen, testCases: cap, seed: seed, database: "") { s in
                    if failed { return }
                    count += 1
                    let run = thresholdMergesortRun(values, recheck: false, policy: s[keyPath: policy])
                    if case .stuck = run.outcome { failed = true; throw StuckError() }
                }
            } catch {}
            runs.append(failed ? count : Int(cap) + 1)
        }
        return RunsToFailure(runs: runs)
    }
} }

struct StuckError: Error {}

struct RunsToFailure: CustomStringConvertible {
    var runs: [Int]
    var median: Int { runs.sorted()[runs.count / 2] }
    var description: String { "median \(median), min \(runs.min() ?? 0), max \(runs.max() ?? 0)" }
}
