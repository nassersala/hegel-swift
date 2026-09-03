import Testing
import HegelTesting
import AboveTheCode

/// Zero-downtime deployment: the relation checked on drawn behaviours,
/// the talk's two designs refuted before any code, the batch and the
/// capacity bound read off the relation, then two rollouts checked to
/// refine it and three seeded bugs reported as the first step that is
/// not a step.
@Suite struct AboveDeploy {
    static let behaviours: Gen<(n: Int, k: Int, run: Deploy.Run)> = Deploy.fleets.flatMap { fleet in
        Deploy.behaviour(servers: fleet.n, atLeast: fleet.k).map { (n: fleet.n, k: fleet.k, run: $0) }
    }

    /// The relation's own property, what TLC checks for small N: every
    /// state of every behaviour keeps both invariants, and with `n ≥ 2k`
    /// every behaviour ends done.
    @Test(.propertyTesting) func everyBehaviourKeepsBothInvariantsAndEndsDone() {
        expectAll(Self.behaviours, testCases: 1000, database: "") { n, k, run in
            for s in run.states {
                #expect(s.zeroDowntime, "\(s)")
                #expect(s.sameVersion, "\(s)")
            }
            #expect(run.final.done, "\(run.final)")
        }
    }

    /// The bounded form of "eventually done": with idles allowed at every
    /// state, the trace cannot say the upgrade completes, and the TLA
    /// twin says it under weak fairness. What the trace can say is that
    /// every behaviour that completes takes exactly 2n + 1 steps that are
    /// not idle: one start and one finish per server and one switch.
    @Test(.propertyTesting) func everyBehaviourHasExactlyTwoNPlusOneSteps() {
        expectAll(Self.behaviours, testCases: 1000, database: "") { n, _, run in
            #expect(run.events.filter { $0 != .idle }.count == 2 * n + 1, "\(run.events)")
        }
    }

    /// Both wrong designs are refuted by the shortest story that shows
    /// them, on the smallest fleet, each against the invariant the talk
    /// had at that round. `anyServer` against zero downtime needs two
    /// starts: nobody is online. `oneOffline` keeps zero downtime and
    /// fails same version at one start and its finish: a v2 server and a
    /// v1 server, both online, clients seeing both. (`anyServer` fails
    /// same version too, by the same two steps; the shrinker prefers the
    /// finish, so the round is checked against the invariant it had.)
    @Test(arguments: [Deploy.Design.anyServer, .oneOffline])
    func wrongDesignRefutedOnDrawnBehaviours(design: Deploy.Design) throws {
        let behaviours = Deploy.fleets.flatMap { fleet in
            Deploy.behaviour(servers: fleet.n, atLeast: fleet.k, design: design).map { (n: fleet.n, k: fleet.k, run: $0) }
        }
        let broken: (Deploy) -> Bool = design == .anyServer ? { !$0.zeroDowntime } : { !$0.sameVersion }
        do {
            try forAll(behaviours, testCases: 2000, seed: 1, database: "") { _, _, run in
                if let s = run.states.first(where: broken) { throw Untruthful("\(s)") }
            }
            Issue.record("\(design) kept the invariant")
        } catch let failure as PropertyFailure {
            let (n, k, run) = try replay(behaviours, blob: try #require(failure.failures.first?.reproduceBlob))
            let i = try #require(run.states.firstIndex(where: broken))
            print("\(design), n = \(n), k = \(k), refuted after \(run.events[...i].map(\.description).joined(separator: ", ")): \(run.states[i])")
            #expect((n, k) == (2, 1))
            #expect(i == 1)
            switch design {
            case .anyServer:
                #expect(run.events[...1] == [.start(0), .start(1)])
                #expect(run.states[1].online.isEmpty)
            case .oneOffline:
                #expect(run.events[...1] == [.start(0), .finish(0)])
                let neverDown = run.states.allSatisfy { $0.zeroDowntime }
                #expect(neverDown)
                #expect(run.states[1].online == [0, 1])
            case .balanced: break
            }
        }
    }

    /// The batch, read off the guard: with five servers and k = 2, drawn
    /// behaviours take three offline at once and never four.
    @Test(.propertyTesting) func theBatchIsReadOffTheRelation() {
        var widest = 0
        expectAll(Deploy.behaviour(servers: 5, atLeast: 2), testCases: 500, database: "") { run in
            #expect(run.maxOffline <= 3, "\(run.events)")
            widest = max(widest, run.maxOffline)
        }
        print("n = 5, k = 2: at most \(widest) offline at once over 500 drawn behaviours")
        #expect(widest == 3)
    }

    /// The capacity bound, found by the relation: three servers cannot
    /// keep two online. After the first upgrade, no start is allowed and
    /// the switch is not yet, and the only step is idle. TLC reports the
    /// same state as a deadlock.
    @Test func threeServersCannotKeepTwoOnline() {
        var s = Deploy(servers: 3, atLeast: 2)
        s.apply(.start(0))
        s.apply(.finish(0))
        print("n = 3, k = 2, stuck at \(s)")
        #expect(s.enabledSteps.isEmpty)
        #expect(!s.done)
        #expect(s.zeroDowntime && s.sameVersion)
    }

    /// The claim: on every fleet the relation admits, both rollouts record
    /// only Next steps and end done.
    @Test(arguments: Rollout.allCases)
    func theRolloutRefinesTheRelation(rollout: Rollout) {
        var widest = 0
        expectAll(Deploy.fleets, testCases: 200, database: "") { n, k in
            let events = rollout.run(servers: n, atLeast: k)
            let (violation, final) = Deploy.refines(events, servers: n, atLeast: k)
            #expect(violation == nil, "\(String(describing: violation))")
            #expect(final.done, "\(final)")
            #expect(events.count == 2 * n + 1)
            if n == 5 && k == 2 {
                var s = Deploy(servers: 5, atLeast: 2)
                for e in events { s.apply(e); widest = max(widest, s.offline.count) }
            }
        }
        print("\(rollout): refines; n = 5, k = 2 takes at most \(widest) offline at once")
        #expect(widest == (rollout == .batched ? 3 : 1))
    }

    /// Each seeded bug is found on the smallest fleet that shows it and
    /// reported as the first event that is not a step. Switching on the
    /// first v2 server is a step when k = 1, so the story needs k = 2 and
    /// four servers. One too many in the batch needs two servers.
    @Test(arguments: [(Rollout.oneAtATime, Rollout.Bug.switchesOnFirst), (.batched, .batchTooLarge)])
    func seededBugIsTheFirstStepThatIsNotAStep(rollout: Rollout, bug: Rollout.Bug) throws {
        do {
            try forAll(Deploy.fleets, testCases: 500, seed: 1, database: "") { n, k in
                if let v = Deploy.refines(rollout.run(servers: n, atLeast: k, bug: bug), servers: n, atLeast: k).violation {
                    throw NotAStep("\(v)")
                }
            }
            Issue.record("\(rollout) with \(bug) refined the relation")
        } catch let failure as PropertyFailure {
            let (n, k) = try replay(Deploy.fleets, blob: try #require(failure.failures.first?.reproduceBlob))
            let events = rollout.run(servers: n, atLeast: k, bug: bug)
            let v = try #require(Deploy.refines(events, servers: n, atLeast: k).violation)
            print("\(rollout) with \(bug), n = \(n), k = \(k): \(events[...v.step].map(\.description).joined(separator: ", "))\n\(v)")
            switch bug {
            case .switchesOnFirst:
                #expect((n, k) == (4, 2))
                #expect(v.step == 2 && v.event == .switchBalancer)
            case .batchTooLarge:
                #expect((n, k) == (2, 1))
                #expect(v.step == 1 && v.event == .start(1))
                #expect(v.state.offline == [0])
            case .neverSwitches: break
            }
        }
    }

    /// The talk's first fix as code, a balancer never switched: every
    /// recorded step is a step, and the rollout stops before done, with
    /// the last v1 server unable to start because it is the last one
    /// online. The refinement is silent; the final state is the report,
    /// and the relation names the one step the code refuses to take.
    @Test(arguments: Rollout.allCases)
    func neverSwitchingStopsShort(rollout: Rollout) {
        expectAll(Deploy.fleets, testCases: 200, database: "") { n, k in
            let events = rollout.run(servers: n, atLeast: k, bug: .neverSwitches)
            let (violation, final) = Deploy.refines(events, servers: n, atLeast: k)
            #expect(violation == nil)
            #expect(!final.done, "\(final)")
            #expect(final.atV1.count == k && final.balancer == .v1, "\(final)")
            #expect(final.enabledSteps == [.switchBalancer], "\(final.enabledSteps)")
        }
    }

    struct Untruthful: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
    struct NotAStep: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}
