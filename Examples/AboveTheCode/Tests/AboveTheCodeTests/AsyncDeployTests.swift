import Testing
import HegelTesting
import Schedules
import AboveTheCode

/// "Steps are whole", the claim the deployment relation makes without
/// saying so. A real rollout upgrades servers concurrently: one task per
/// server, each asking the fleet whether it may go offline. The guard
/// `|Online \ {s}| ≥ k` is one step in the relation; in code it is a
/// check and a commit, and an `await` between them is the producer-
/// consumer bug of the talk. Under the depth-first default schedule the
/// split is hidden, because each task runs to completion before its
/// sibling starts. One drawn deviation finds it.
@Suite struct AboveDeployAsync {
    /// The fleet as an actor under the controlled scheduler. `tryStart`
    /// decides and commits in one synchronous call, which is the correct
    /// version. `mayStart` then `commitStart` is the planted split.
    actor ControlledFleet {
        let executor: ControlledSerialExecutor
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        private var fleet: Fleet
        let k: Int

        init(executor: ControlledSerialExecutor, servers n: Int, atLeast k: Int) {
            self.executor = executor
            fleet = Fleet(servers: n)
            self.k = k
        }

        var atV1: [Int] { fleet.atV1 }
        var allAtV2: Bool { fleet.allAtV2 }
        var events: [Deploy.Event] { fleet.events }

        private func roomWithout(_ s: Int) -> Bool {
            fleet.servers[s] == .v1 && Set(fleet.online).subtracting([s]).count >= k
        }
        func tryStart(_ s: Int) -> Bool {
            guard roomWithout(s) else { return false }
            fleet.start(s)
            return true
        }
        func mayStart(_ s: Int) -> Bool { roomWithout(s) }
        func commitStart(_ s: Int) { fleet.start(s) }
        func finish(_ s: Int) { fleet.finish(s) }
        func switchIfAllowed() -> Bool {
            guard fleet.balancer == .v1, fleet.atV2.count >= k else { return false }
            fleet.switchBalancer()
            return true
        }
    }

    /// Rounds: every v1 server tries to go offline, the ones the fleet
    /// lets through upgrade and come back, then the balancer switches if
    /// it may. A server refused this round tries again next round.
    static func concurrentRollout(_ fleet: ControlledFleet, split: Bool) async {
        while await !fleet.allAtV2 {
            let candidates = await fleet.atV1
            var started = 0
            await withTaskGroup(of: Bool.self) { group in
                for s in candidates {
                    group.addTask {
                        let started: Bool
                        if split {
                            started = await fleet.mayStart(s)
                            if started { await fleet.commitStart(s) }  // the await between check and commit
                        } else {
                            started = await fleet.tryStart(s)
                        }
                        if started { await fleet.finish(s) }
                        return started
                    }
                }
                for await ok in group where ok { started += 1 }
            }
            let switched = await fleet.switchIfAllowed()
            if started == 0 && !switched { break }
        }
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    struct Run {
        let outcome: Scheduler.Outcome
        let events: [Deploy.Event]
        let choicePoints: Int
    }

    static func run(servers n: Int, atLeast k: Int, split: Bool, policy: @escaping Scheduler.Policy) -> Run {
        let scheduler = Scheduler()
        let fleet = ControlledFleet(executor: scheduler.serialExecutor("fleet"), servers: n, atLeast: k)
        let events = Box<[Deploy.Event]>([])
        let outcome = scheduler.run(policy: policy) {
            await concurrentRollout(fleet, split: split)
            events.value = await fleet.events
        }
        return Run(outcome: outcome, events: events.value, choicePoints: scheduler.choicePoints)
    }

    static let schedules: Gen<Schedule> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...60), Gen<Int64>.int(in: 0...12))
            .map { Schedule.Deviation(choice: Int($0), index: Int($1)) },
        count: 0...6
    ).map(Schedule.init)

    static let fleetsAndSchedules: Gen<(n: Int, k: Int, schedule: Schedule)> =
        Hegel.zip(Deploy.fleets, schedules).map { (n: $0.n, k: $0.k, schedule: $1) }

    struct DidNotComplete: Error { let outcome: Scheduler.Outcome }
    struct NotAStep: Error, CustomStringConvertible {
        let violation: Deploy.Violation
        var description: String { "not a Next step: \(violation)" }
    }

    static func checkRefines(_ run: Run, servers n: Int, atLeast k: Int) throws -> Deploy {
        guard case .completed = run.outcome else { throw DidNotComplete(outcome: run.outcome) }
        let (violation, final) = Deploy.refines(run.events, servers: n, atLeast: k)
        if let violation { throw NotAStep(violation: violation) }
        return final
    }

    /// Deciding and committing in one actor call refines under every
    /// drawn schedule and ends done.
    @Test func decidingSynchronouslyRefinesUnderEverySchedule() throws {
        var maxChoices = 0
        try forAll(Self.fleetsAndSchedules, testCases: 300, database: "") { n, k, schedule in
            let run = Self.run(servers: n, atLeast: k, split: false, policy: schedule.policy)
            let final = try Self.checkRefines(run, servers: n, atLeast: k)
            #expect(final.done, "\(final)")
            maxChoices = max(maxChoices, run.choicePoints)
        }
        print("synchronous decision: refines under 300 drawn schedules, up to \(maxChoices) choice points")
    }

    /// Under the default schedule the split passes: each server's task
    /// checks, commits and finishes before the next task checks.
    @Test(.propertyTesting) func theDefaultScheduleHidesTheSplit() {
        expectAll(Deploy.fleets, database: "") { n, k in
            let run = Self.run(servers: n, atLeast: k, split: true, policy: Schedule().policy)
            let final = try Self.checkRefines(run, servers: n, atLeast: k)
            #expect(final.done)
        }
    }

    /// Drawn schedules find it on two servers with one deviation: both
    /// tasks pass the check while both servers are online; one commits,
    /// upgrades and comes back at v2, where the balancer does not point;
    /// then the other commits its start with itself the only server
    /// online. Three events, and the third is not a step.
    @Test func theSplitIsFoundAtOneDeviation() throws {
        do {
            try forAll(Self.fleetsAndSchedules, seed: 1, database: "") { n, k, schedule in
                _ = try Self.checkRefines(Self.run(servers: n, atLeast: k, split: true, policy: schedule.policy), servers: n, atLeast: k)
            }
            Issue.record("the split was never exploited")
        } catch let failure as PropertyFailure {
            let (n, k, minimal) = try replay(Self.fleetsAndSchedules, blob: try #require(failure.failures.first?.reproduceBlob))
            let run = Self.run(servers: n, atLeast: k, split: true, policy: minimal.policy)
            let (violation, _) = Deploy.refines(run.events, servers: n, atLeast: k)
            print("split, n = \(n), k = \(k), schedule \(minimal): \(run.events.map(\.description).joined(separator: ", ")); \(violation.map(\.description) ?? "refines")")
            let v = try #require(violation)
            #expect(minimal.deviations.count == 1)
            #expect((n, k) == (2, 1))
            #expect(v.step == 2)
            if case .start(let s) = v.event {
                #expect(v.state.online == [s])
            } else {
                Issue.record("expected a start, got \(v.event)")
            }
        }
    }
}
