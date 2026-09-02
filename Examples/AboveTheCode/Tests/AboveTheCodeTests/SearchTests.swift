import Testing
import HegelTesting
import AboveTheCode

/// Search-as-you-type: the relation checked on drawn behaviours, two
/// wrong designs refuted before any code, then the view model checked to
/// refine the relation under every drawn arrival order, and four seeded
/// bugs reported as the first pair that is not a step.
@Suite struct AboveSearch {
    /// The relation's own property, what TLC would check for small N:
    /// every state of every behaviour keeps `Inv`, the run ends
    /// quiescent, and the list answers the query it is labelled with.
    @Test(.propertyTesting) func everyBehaviourIsTruthful() {
        expectAll(Search.behaviour(), database: "") { run in
            for s in run.states {
                #expect(s.truthful, "\(s)")
                #expect(s.shown.query.isEmpty || s.shown.results == Search.answer(s.shown.query), "\(s)")
            }
            #expect(run.final.done)
            #expect(!run.final.loading)
        }
    }

    /// Both wrong designs are refuted by a three-event story: the user
    /// clears the field and a late response lands. `naive` shows results
    /// for "a" under an empty field; `halfChecked` shows an error under an
    /// empty field that answers itself.
    @Test(arguments: [Search.Design.naive, .halfChecked])
    func wrongDesignRefutedOnDrawnBehaviours(design: Search.Design) throws {
        do {
            try forAll(Search.behaviour(design: design), seed: 1, database: "") { run in
                if let s = run.states.first(where: { !$0.truthful }) { throw Untruthful("\(s)") }
            }
            Issue.record("\(design) kept Inv")
        } catch let failure as PropertyFailure {
            let run = try replay(Search.behaviour(design: design), blob: try #require(failure.failures.first?.reproduceBlob))
            let k = try #require(run.states.firstIndex { !$0.truthful })
            print("\(design) refuted after \(run.events[...k].map(\.description).joined(separator: ", ")): \(run.states[k])")
            #expect(k == 2)
            #expect(run.events[0] == .type("a"))
            #expect(run.events[1] == .type(""))
            #expect(run.states[k].query.isEmpty)
            switch design {
            case .naive: #expect(run.states[k].shown.query == "a")
            case .halfChecked: #expect(run.states[k].error)
            case .checked: break
            }
        }
    }

    /// The claim: under every drawn arrival order and outcome, every
    /// state the view model reaches is the relation's, and its spinner is
    /// `Loading`.
    @Test(.propertyTesting) func theViewModelRefinesTheRelationUnderEveryArrivalOrder() {
        expectAll(Search.behaviour(), database: "") { run in
            let (violation, final) = Search.refines(run.events)
            #expect(violation == nil, "\(String(describing: violation))")
            #expect(final == run.final)
            #expect(final.done)
            #expect(final.truthful)
        }
    }

    /// Each seeded bug is found and shrunk to its shortest story, and the
    /// report is the first event after which the code's state is not the
    /// relation's. The spinner bug needs no arrival at all: clear the
    /// field, and it spins for a request that answers nothing shown.
    @Test(arguments: SearchViewModel.Bug.allCases)
    func seededBugIsTheFirstPairThatIsNotAStep(bug: SearchViewModel.Bug) throws {
        do {
            try forAll(Search.behaviour(), seed: 1, database: "") { run in
                if let v = Search.refines(run.events, bug: bug).violation { throw NotAStep("\(v)") }
            }
            Issue.record("\(bug) refined the relation")
        } catch let failure as PropertyFailure {
            let run = try replay(Search.behaviour(), blob: try #require(failure.failures.first?.reproduceBlob))
            let v = try #require(Search.refines(run.events, bug: bug).violation)
            print("\(bug), events \(run.events[...v.step].map(\.description).joined(separator: ", "))\n\(v)")
            switch bug {
            case .trustsEveryResponse:
                #expect(v.step == 2)
                #expect(v.got.shown.query == "a" && v.got.query.isEmpty)
            case .trustsEveryFailure:
                #expect(v.step == 2)
                #expect(v.got.error && v.got.query.isEmpty)
            case .spinsForStaleRequests:
                #expect(v.step == 1)
                #expect(run.events[1] == .type(""))
                #expect(v.reason.hasPrefix("isLoading is true"))
            case .errorOverAnswer:
                #expect(v.step == 4)
                #expect(v.got.error && v.got.shown.query == v.got.query)
            }
        }
    }

    /// The two staleness bugs are not coding slips: each buggy view model
    /// is a behaviour of the wrong design it came from. The bug is above
    /// the code, in the Arrive clause.
    @Test(.propertyTesting, arguments: [
        (SearchViewModel.Bug.trustsEveryResponse, Search.Design.naive),
        (.trustsEveryFailure, .halfChecked),
    ])
    func wrongViewModelRefinesWrongDesign(bug: SearchViewModel.Bug, design: Search.Design) {
        expectAll(Search.behaviour(design: design), database: "") { run in
            let (violation, final) = Search.refines(run.events, bug: bug, design: design)
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
