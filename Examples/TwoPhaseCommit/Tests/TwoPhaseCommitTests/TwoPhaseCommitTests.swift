import Testing
import Hegel
import HegelTesting
import Schedules
import TwoPhaseCommit

@Suite(.serialized) enum Scheduled {}

extension Scheduled { @Suite struct TwoPhase {
    static let votes = array(of: Gen<Bool>.bool, count: 1...4)
    static let schedules: Gen<Schedule> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...40), Gen<Int64>.int(in: 0...7))
            .map { Schedule.Deviation(choice: Int($0), index: Int($1)) },
        count: 0...8
    ).map(Schedule.init)
    static let faults: Gen<Faults> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...15), Gen<Bool>.bool)
            .map { Faults.Fault(message: Int($0), kind: $1 ? .drop : .duplicate) },
        count: 0...3
    ).map(Faults.init)
    static let pct: Gen<PCT> = Hegel.zip(
        array(of: Gen<Int64>.int(in: 0...7).map(Int.init), count: 0...8),
        array(of: Gen<Int64>.int(in: 0...30).map(Int.init), count: 0...2)
    ).map { PCT(priorities: $0, changePoints: $1) }

    // Lamport's TCommit invariants over the event trace.
    /// No two nodes decide differently.
    static let agreement: Pred<Event> = always(now { Set($0.decisions.values).count <= 1 })
    /// A commit needs every participant's yes; a no never precedes a commit.
    static func validity(_ n: Int) -> Pred<Event> {
        always(now { e in
            !e.decisions.values.contains(.commit) || (e.votes.count == n && e.votes.values.allSatisfy { $0 })
        })
    }
    /// Everyone decides, nobody is left blocked: the liveness surrogate.
    static let everyoneDecides: Pred<Event> = now { $0.blocked.isEmpty }

    static func check(_ name: String, _ formula: Pred<Event>, over run: Run) throws {
        if let i = firstFailure(of: formula, over: run.events) {
            throw Violation(name: name, step: i, events: run.events, trace: run.trace, network: run.network)
        }
    }

    /// Reliable network, every schedule: agreement, validity, everyone
    /// decides, and commit exactly when every vote is yes.
    @Test(.propertyTesting) func reliableNetworkEverySchedule() {
        expectAll(Hegel.zip(Self.votes, Self.schedules), database: "") { votes, schedule in
            let run = twoPhaseCommit(votes: votes, policy: schedule.policy)
            guard case .completed = run.outcome else { Issue.record("\(run.outcome)"); return }
            #expect(run.coordinator == (votes.allSatisfy { $0 } ? .commit : .abort))
            #expect(run.participants.allSatisfy { $0 == (votes.allSatisfy { $0 } ? .committed : .aborted) })
            #expect(throws: Never.self) { try Self.check("agreement", Self.agreement, over: run) }
            #expect(throws: Never.self) { try Self.check("validity", Self.validity(votes.count), over: run) }
            #expect(throws: Never.self) { try Self.check("everyone decides", Self.everyoneDecides, over: run.lastState) }
        }
    }

    /// Faults and schedules together: safety on all of them, and with
    /// fewer faults than retries every prepared participant decides. A
    /// participant whose `prepare` was dropped never joins and stays
    /// `.working`: presumed abort, not a blocked node.
    @Test(.propertyTesting) func faultyNetworkEverySchedule() {
        expectAll(Hegel.zip(Self.votes, Self.faults, Self.schedules), testCases: 300, database: "") { votes, faults, schedule in
            let run = twoPhaseCommit(votes: votes, faults: faults, policy: schedule.policy)
            guard case .completed = run.outcome else { Issue.record("\(run.outcome) under \(faults)"); return }
            #expect(throws: Never.self) { try Self.check("agreement", Self.agreement, over: run) }
            #expect(throws: Never.self) { try Self.check("validity", Self.validity(votes.count), over: run) }
            #expect(throws: Never.self) { try Self.check("everyone decides", Self.everyoneDecides, over: run.lastState) }
            #expect(run.participants.allSatisfy { $0 != .prepared && $0 != .blocked })
        }
    }

    /// PCT as the schedule generator, and each run restated as deviations.
    @Test(.propertyTesting) func underPCT() {
        expectAll(Hegel.zip(Self.votes, Self.faults, Self.pct), testCases: 200, database: "") { votes, faults, pct in
            let run = twoPhaseCommit(votes: votes, faults: faults, policy: pct.policy)
            guard case .completed = run.outcome else { Issue.record("\(run.outcome)"); return }
            #expect(throws: Never.self) { try Self.check("agreement", Self.agreement, over: run) }
            let replay = twoPhaseCommit(votes: votes, faults: faults, policy: Schedule(explaining: run.choices).policy)
            #expect(replay.trace == run.trace)
        }
    }

    /// The protocol's known liveness failure: the coordinator crashes
    /// after collecting the votes and every prepared participant blocks.
    /// Safety holds even then. hegel finds it and shrinks to the bare
    /// story: one participant, voting yes, reliable network, default
    /// schedule.
    @Test func coordinatorCrashBlocksAndShrinksToTheStory() throws {
        do {
            try forAll(Hegel.zip(Self.votes, Self.faults, Self.schedules), seed: 3, database: "") { votes, faults, schedule in
                let run = twoPhaseCommit(votes: votes, faults: faults, crashAfterVotes: true, policy: schedule.policy)
                try Self.check("agreement", Self.agreement, over: run)
                try Self.check("everyone decides", Self.everyoneDecides, over: run.lastState)
            }
            Issue.record("the blocking case was not found")
        } catch let failure as PropertyFailure {
            let f = try #require(failure.failures.first)
            let (votes, faults, schedule) = try replay(Hegel.zip(Self.votes, Self.faults, Self.schedules), blob: try #require(f.reproduceBlob))
            #expect(votes == [true])
            #expect(faults == Faults())
            #expect(schedule == Schedule())
            let run = twoPhaseCommit(votes: votes, faults: faults, crashAfterVotes: true, policy: schedule.policy)
            #expect(run.participants == [.blocked])
            #expect(run.coordinator == nil)
            print("blocking case: votes \(votes), \(faults), \(schedule)\n" + run.events.map(\.description).joined(separator: "\n"))
        }
    }

    /// Seeded bug: commit on timeout. The shrunk counterexample is one
    /// participant voting no whose vote is dropped: the coordinator times
    /// out with no votes, all of which are yes, and commits.
    @Test func commitOnTimeoutShrinksToOneDroppedNo() throws {
        do {
            try forAll(Hegel.zip(Self.votes, Self.faults, Self.schedules), seed: 5, database: "") { votes, faults, schedule in
                let run = twoPhaseCommit(votes: votes, faults: faults, bug: .commitOnTimeout, policy: schedule.policy)
                try Self.check("agreement", Self.agreement, over: run)
                try Self.check("validity", Self.validity(votes.count), over: run)
            }
            Issue.record("the bug was not found")
        } catch let failure as PropertyFailure {
            let f = try #require(failure.failures.first)
            let (votes, faults, schedule) = try replay(Hegel.zip(Self.votes, Self.faults, Self.schedules), blob: try #require(f.reproduceBlob))
            #expect(votes.count == 1)
            #expect(faults.faults.count == 1 && faults.faults.first?.kind == .drop)
            #expect(schedule == Schedule())
            let run = twoPhaseCommit(votes: votes, faults: faults, bug: .commitOnTimeout, policy: schedule.policy)
            print("commit on timeout: votes \(votes), \(faults), \(schedule)\n" + run.network.joined(separator: "\n") + "\n" + run.events.map(\.description).joined(separator: "\n"))
            #expect(throws: Violation.self) { try Self.check("validity", Self.validity(votes.count), over: run) }
        }
    }

    /// Seeded bug: heuristic abort. With one retry, dropping a
    /// participant's decision and then its query leaves it aborting on
    /// its own while the coordinator and the others committed. Two drops
    /// are what it takes; the shrinker keeps the participant count it
    /// found, since removing a participant renumbers the messages.
    @Test func heuristicAbortDisagrees() throws {
        do {
            try forAll(Hegel.zip(Self.votes, Self.faults, Self.schedules), testCases: 500, seed: 2, database: "") { votes, faults, schedule in
                let run = twoPhaseCommit(votes: votes, faults: faults, bug: .heuristicAbort, retries: 1, policy: schedule.policy)
                try Self.check("agreement", Self.agreement, over: run)
            }
            Issue.record("the bug was not found")
        } catch let failure as PropertyFailure {
            let f = try #require(failure.failures.first)
            let (votes, faults, schedule) = try replay(Hegel.zip(Self.votes, Self.faults, Self.schedules), blob: try #require(f.reproduceBlob))
            #expect(votes.allSatisfy { $0 })
            #expect(faults.faults.count == 2 && faults.faults.allSatisfy { $0.kind == .drop })
            let run = twoPhaseCommit(votes: votes, faults: faults, bug: .heuristicAbort, retries: 1, policy: schedule.policy)
            print("heuristic abort: votes \(votes), \(faults), \(schedule)\n" + run.network.joined(separator: "\n") + "\n" + run.events.map(\.description).joined(separator: "\n"))
            #expect(run.coordinator == .commit && run.participants.contains(.aborted))
        }
    }
} }

extension Run {
    /// A one-state trace for end-of-run predicates.
    var lastState: Run { var r = self; r.events = events.suffix(1); return r }
}

struct Violation: Error, CustomStringConvertible {
    let name: String, step: Int, events: [Event], trace: [String], network: [String]
    var description: String {
        "\(name) fails at event \(step): \(events[step])\n" + events.enumerated().map { "\($0 == step ? "→" : " ") \($1)" }.joined(separator: "\n")
            + "\nnetwork:\n" + network.joined(separator: "\n")
    }
}
