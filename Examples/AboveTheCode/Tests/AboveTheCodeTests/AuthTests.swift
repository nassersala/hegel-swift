import Testing
import HegelTesting
import AboveTheCode

/// Token refresh: the relation checked on drawn behaviours, two wrong
/// designs refuted before any code, then the session checked to refine
/// the relation under every drawn order of 401s and refresh completions,
/// and six seeded bugs reported as the first pair that is not a step.
@Suite struct AboveAuth {
    /// The relation's own property, what TLC would check for small N:
    /// every state of every behaviour keeps `Inv`, and the run ends with
    /// every request settled.
    @Test(.propertyTesting) func everyBehaviourIsTruthful() {
        expectAll(Auth.behaviour(), testCases: 1000, database: "") { run in
            for s in run.states { #expect(s.truthful, "\(s)") }
            #expect(run.final.settled)
        }
    }

    /// Both wrong designs are refuted by the shortest story that shows
    /// them. `refreshesOnEvery401` needs two requests under a0, one 401,
    /// the refresh, then the other's 401: it trades f1 away for an a1 that
    /// nobody rejected. `staysSignedIn` needs one 401 and a failed
    /// refresh: it sits on a0 knowing a0 is bad.
    @Test(arguments: [Auth.Design.refreshesOnEvery401, .staysSignedIn])
    func wrongDesignRefutedOnDrawnBehaviours(design: Auth.Design) throws {
        do {
            try forAll(Auth.behaviour(design: design), testCases: 2000, seed: 1, database: "") { run in
                if let s = run.states.first(where: { !$0.truthful }) { throw Untruthful("\(s)") }
            }
            Issue.record("\(design) kept Inv")
        } catch let failure as PropertyFailure {
            let run = try replay(Auth.behaviour(design: design), blob: try #require(failure.failures.first?.reproduceBlob))
            let k = try #require(run.states.firstIndex { !$0.truthful })
            print("\(design) refuted after \(run.events[...k].map(\.description).joined(separator: ", ")): \(run.states[k])")
            switch design {
            case .refreshesOnEvery401:
                #expect(k == 4)
                #expect(run.events[...k] == [.send, .send, .unauthorized(0), .refreshed(Auth.credentials(1)), .unauthorized(1)])
                #expect(run.states[k].refreshing == "f1")
                #expect(!run.states[k].rejected.contains("a1"))
            case .staysSignedIn:
                #expect(k == 2)
                #expect(run.events[...k] == [.send, .unauthorized(0), .refreshRejected])
                #expect(run.states[k].creds == Auth.credentials(0))
                #expect(run.states[k].refreshing == nil)
            case .unbounded, .checked: break
            }
        }
    }

    /// The decision: one retry with the same token after an unreachable
    /// refresh, then sign out. Drawn behaviours reach both.
    @Test(.propertyTesting) func anUnreachableRefreshIsRetriedOnce() {
        expectAll(Auth.behaviour(), testCases: 1000, database: "") { run in
            var s = Auth()
            for e in run.events {
                let before = s
                s.apply(e)
                if e == .refreshUnreachable {
                    if before.retried {
                        #expect(s.creds == nil && s.refreshing == nil, "\(before) → \(s)")
                    } else {
                        #expect(s.retried && s.refreshing == before.refreshing && s.creds == before.creds, "\(before) → \(s)")
                    }
                }
            }
        }
    }

    /// The bound as a trace property: after a refresh starts, none starts
    /// again until the token it returned has been accepted. Inv cannot
    /// say this; the formula holds on every drawn behaviour of the
    /// relation.
    @Test(.propertyTesting) func noSecondRefreshWithoutASuccessBetween() {
        expectAll(Auth.behaviour(), testCases: 1000, database: "") { run in
            #expect(evaluate(Auth.oneRefreshPerProof, over: Auth.moments(run)), "\(run.events)")
        }
    }

    /// The unbounded design keeps Inv and fails the formula, in four
    /// events: one request, one 401, one refresh, and a 401 on the token
    /// it returned. That is the loop, caught at its second turn.
    @Test func theUnboundedDesignRefreshesForever() throws {
        do {
            try forAll(Auth.behaviour(design: .unbounded), testCases: 2000, seed: 1, database: "") { run in
                for s in run.states where !s.truthful { throw Untruthful("\(s)") }
                if let k = firstFailure(of: Auth.oneRefreshPerProof, over: Auth.moments(run)) {
                    throw NotAStep("formula fails at position \(k) of \(run.events)")
                }
            }
            Issue.record("the unbounded design kept the formula")
        } catch let failure as PropertyFailure {
            let run = try replay(Auth.behaviour(design: .unbounded), blob: try #require(failure.failures.first?.reproduceBlob))
            let k = try #require(firstFailure(of: Auth.oneRefreshPerProof, over: Auth.moments(run)))
            print("unbounded refuted at position \(k): \(run.events.map(\.description).joined(separator: ", "))")
            #expect(run.events.prefix(4) == [.send, .unauthorized(0), .refreshed(Auth.credentials(1)), .unauthorized(0)])
            #expect(run.states[3].refreshing == "f1")
        }
    }

    /// The claim: under every drawn order of sends, 401s, 200s and
    /// refresh completions, every state the session reaches is the
    /// relation's, and it ends settled.
    @Test(.propertyTesting) func theSessionRefinesTheRelationUnderEveryOrder() {
        expectAll(Auth.behaviour(), testCases: 1000, database: "") { run in
            let (violation, final) = Auth.refines(run.events)
            #expect(violation == nil, "\(String(describing: violation))")
            #expect(final == run.final)
            #expect(final.settled)
            #expect(final.truthful)
        }
    }

    /// Each seeded bug is found and shrunk to its shortest story, and the
    /// report is the first event after which the code's state is not the
    /// relation's. Four need one request and one refresh; the two that
    /// are about a second 401 need two requests.
    @Test(arguments: AuthSession.Bug.allCases)
    func seededBugIsTheFirstPairThatIsNotAStep(bug: AuthSession.Bug) throws {
        do {
            try forAll(Auth.behaviour(), testCases: 2000, seed: 1, database: "") { run in
                if let v = Auth.refines(run.events, bug: bug).violation { throw NotAStep("\(v)") }
            }
            Issue.record("\(bug) refined the relation")
        } catch let failure as PropertyFailure {
            let run = try replay(Auth.behaviour(), blob: try #require(failure.failures.first?.reproduceBlob))
            let v = try #require(Auth.refines(run.events, bug: bug).violation)
            print("\(bug), events \(run.events[...v.step].map(\.description).joined(separator: ", "))\n\(v)")
            switch bug {
            case .refreshesTwice:
                #expect(v.step == 3)
                #expect(run.events[...3] == [.send, .send, .unauthorized(0), .unauthorized(1)])
                #expect(v.reason == "the code has 2 refreshes in flight")
            case .ignoresStaleness:
                #expect(v.step == 4)
                #expect(run.events[...4] == [.send, .send, .unauthorized(0), .refreshed(Auth.credentials(1)), .unauthorized(1)])
                #expect(v.got?.refreshing == "f1")
            case .retriesUnderOldToken:
                #expect(v.step == 2)
                #expect(run.events[...2] == [.send, .unauthorized(0), .refreshed(Auth.credentials(1))])
                #expect(v.got?.requests[0] == .sent("a0"))
            case .dropsWaitersOnFailure:
                #expect(v.step == 2)
                #expect(run.events[...2] == [.send, .unauthorized(0), .refreshRejected])
                #expect(v.got?.done[0] == nil && v.got?.requests[0] == nil)
            case .forgetsRotatedRefreshToken:
                #expect(v.step == 2)
                #expect(run.events[...2] == [.send, .unauthorized(0), .refreshed(Auth.credentials(1))])
                #expect(v.got?.creds == Auth.Credentials(access: "a1", refresh: "f0"))
            case .keepsCredentialsOnRefreshFailure:
                #expect(v.step == 2)
                #expect(run.events[...2] == [.send, .unauthorized(0), .refreshRejected])
                #expect(v.got?.creds == Auth.credentials(0))
            case .refreshesForever:
                #expect(v.step == 3)
                #expect(run.events[...3] == [.send, .unauthorized(0), .refreshed(Auth.credentials(1)), .unauthorized(0)])
                #expect(v.got?.refreshing == "f1")
                #expect(v.expected.creds == nil)
            case .givesUpOnFirstNetworkError:
                #expect(v.step == 2)
                #expect(run.events[...2] == [.send, .unauthorized(0), .refreshUnreachable])
                #expect(v.got?.creds == nil && v.expected.retried)
            case .retriesForever:
                #expect(v.step == 3)
                #expect(run.events[...3] == [.send, .unauthorized(0), .refreshUnreachable, .refreshUnreachable])
                #expect(v.got?.refreshing == "f0" && v.expected.creds == nil)
            }
        }
    }

    /// Two of the bugs are not coding slips: each buggy session is a
    /// behaviour of the wrong design it came from. The bug is above the
    /// code, in the Unauthorized or RefreshRejected clause.
    @Test(.propertyTesting, arguments: [
        (AuthSession.Bug.ignoresStaleness, Auth.Design.refreshesOnEvery401),
        (.keepsCredentialsOnRefreshFailure, .staysSignedIn),
    ])
    func wrongSessionRefinesWrongDesign(bug: AuthSession.Bug, design: Auth.Design) {
        expectAll(Auth.behaviour(design: design), testCases: 1000, database: "") { run in
            let (violation, final) = Auth.refines(run.events, bug: bug, design: design)
            #expect(violation == nil, "\(String(describing: violation))")
            #expect(final == run.final)
        }
    }

    struct Untruthful: Error, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = "Inv fails at \(s)" }
    }
    struct NotAStep: Error, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = "not a Next step: \(s)" }
    }
}
