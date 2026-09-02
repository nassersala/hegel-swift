import Testing
import Hegel
import HegelTesting
@testable import Teller

/// Step 5: the relation's own properties on drawn behaviours of submits,
/// timeouts, give-ups and arriving replies in any order (late copies,
/// wrong identities, replies after a give-up).
@Suite struct TellerSessionRelation {
    /// The invariant holds after every step, every reply taken is for the
    /// pending identity and lands in `out`, every emitted copy carries
    /// `t·seq` and the pending request, and the copies of one request
    /// number at most K.
    @Test func drawnBehavioursKeepTheInvariant() {
        expectAll(Session.behaviour(), testCases: 500) { run in
            var s = Session(teller: "t")
            var copies = 0
            for ((step, kind), (emitted, state)) in zip(zip(run.steps, run.kinds), zip(run.emitted, run.states)) {
                #expect(state.inv, "\(state) after \(step)")
                switch kind {
                case .submit:
                    copies = 1
                    #expect(emitted == Request(id: state.pendingId, req: state.pend!))
                case .timeout:
                    copies += 1
                    #expect(emitted == Request(id: state.pendingId, req: state.pend!))
                    #expect(copies <= Session.K)
                case .take:
                    guard case .reply(let r) = step else { Issue.record("take of \(step)"); break }
                    #expect(r.id == s.pendingId && s.pend != nil)
                    #expect(state.out == .taken(r.rep))
                case .giveUp:
                    #expect(copies == Session.K)
                    #expect(state.out == .unknown)
                case .ignore:
                    #expect(state == s)
                }
                s = state
            }
            #expect(run.final.pend == nil)
        }
    }

    /// The bound as a formula over the clauses of the trace.
    @Test func boundHoldsOnDrawnBehaviours() {
        expectAll(Session.behaviour(), testCases: 500) { run in
            let trace = Session.moments(run)
            #expect(evaluate(Session.bound, over: trace),
                    "\(firstFailure(of: Session.bound, over: trace).map { "at \($0): \(trace[$0].state)" } ?? "")")
        }
    }

    /// P4(a), no bound: the invariant sees it (`tries` passes K) and so
    /// does the formula, on the shortest trace, a submit and K timeouts.
    @Test func unboundedIsRefutedByTheFormula() throws {
        try Self.refute(.unbounded, expectedSteps: Session.K + 1)
    }

    /// The counter restarted by a stray reply: every state keeps the
    /// invariant, and the formula fails at the K-th timeout of one
    /// submit. A submit, K − 1 timeouts, one ignored reply, one more
    /// timeout: K + 2 steps.
    @Test func restartingTheCountOnAStrayKeepsTheInvariantAndFailsTheFormula() throws {
        try Self.refute(.restartsOnStray, expectedSteps: Session.K + 2, invariantHolds: true)
    }

    static func refute(_ design: Session.Design, expectedSteps: Int, invariantHolds: Bool = false) throws {
        do {
            try forAll(Session.behaviour(design: design), testCases: 500, seed: 1, database: "") { run in
                if invariantHolds { #expect(run.states.allSatisfy { $0.inv }) }
                if !evaluate(Session.bound, over: Session.moments(run)) { throw Refuted() }
            }
            Issue.record("\(design) was not refuted")
        } catch let failure as PropertyFailure {
            let minimal = try replay(Session.behaviour(design: design), blob: try #require(failure.failures.first?.reproduceBlob))
            let trace = Session.moments(minimal)
            print("\(design): \(zip(minimal.steps, minimal.kinds).map { "\($0)\($1 == .ignore ? " (ignored)" : "")" }.joined(separator: ", ")) → \(minimal.final); bound fails at \(firstFailure(of: Session.bound, over: trace) ?? -1)")
            #expect(minimal.steps.count == expectedSteps + 1)  // plus the closing reply
            #expect(minimal.kinds.filter { $0 == .timeout }.count == Session.K)
            if invariantHolds { #expect(minimal.states.allSatisfy { $0.inv }) }
        }
    }

    struct Refuted: Error {}

    /// The drawing at the top of Session.swift, step by step.
    @Test func theDrawnBehaviourIsABehaviour() {
        var s = Session(teller: "t")
        let steps: [(Session.Step, Session.Kind, Session)] = [
            (.submit(.wd(4)), .submit, Session(teller: "t", pend: .wd(4), seq: 1, tries: 1, out: .none)),
            (.timeout, .timeout, Session(teller: "t", pend: .wd(4), seq: 1, tries: 2, out: .none)),
            (.timeout, .timeout, Session(teller: "t", pend: .wd(4), seq: 1, tries: 3, out: .none)),
            (.giveUp, .giveUp, Session(teller: "t", pend: nil, seq: 1, tries: 0, out: .unknown)),
            (.reply(Reply(id: Id(teller: "t", n: 1), rep: .ok(6))), .ignore, Session(teller: "t", pend: nil, seq: 1, tries: 0, out: .unknown)),
            (.submit(.wd(7)), .submit, Session(teller: "t", pend: .wd(7), seq: 2, tries: 1, out: .none)),
            (.reply(Reply(id: Id(teller: "t", n: 1), rep: .ok(6))), .ignore, Session(teller: "t", pend: .wd(7), seq: 2, tries: 1, out: .none)),
            (.reply(Reply(id: Id(teller: "t", n: 2), rep: .refused(6))), .take, Session(teller: "t", pend: nil, seq: 2, tries: 0, out: .taken(.refused(6)))),
        ]
        for (step, kind, expected) in steps {
            #expect(s.enabled(step))
            #expect(s.kind(of: step) == kind)
            s.apply(step)
            #expect(s == expected)
        }
        #expect(!s.enabled(.timeout))
        #expect(!s.enabled(.giveUp))
        var full = Session(teller: "t", pend: .wd(4), seq: 1, tries: Session.K, out: .none)
        #expect(!full.enabled(.timeout))
        #expect(full.enabled(.giveUp))
        #expect(full.enabled(.reply(Reply(id: Id(teller: "t", n: 1), rep: .ok(6)))))
        full.apply(.giveUp)
        #expect(full == Session(teller: "t", pend: nil, seq: 1, tries: 0, out: .unknown))
    }
}
