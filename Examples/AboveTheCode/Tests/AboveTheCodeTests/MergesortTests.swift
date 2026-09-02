import Testing
import HegelTesting
import AboveTheCode

/// Measure 5 of the pilot: Hegel run on the relation and code the
/// treatment agent produced for problem A, unchanged except for spelling.
@Suite struct PilotMergesort {
    static let inputs = array(of: Gen<Int>.int(in: -5...5), count: 0...8)

    /// The agent's own property: every drawn step enabled, Inv through
    /// every choice, every behaviour ends with one run in exactly N−1 steps.
    @Test(.propertyTesting) func everyBehaviourSorts() {
        expectAll(Self.inputs.flatMap { a in MergeModel.behaviour(a).map { (a, $0) } }, database: "") { a, run in
            var m = MergeModel(a)
            #expect(m.invariant)
            for s in run.steps {
                #expect(m.enabled(s))
                m.apply(s)
                #expect(m.invariant)
            }
            #expect(run.final.done)
            #expect(run.final.a == a.sorted())
            #expect(run.steps.count == max(a.count - 1, 0))
        }
    }

    @Test(.propertyTesting) func bothMergesortsRefineTheRelation() {
        expectAll(Self.inputs, database: "") { a in
            var differed = false
            var traces: [[MergeModel.MergeStep]] = []
            for sort in [{ (x: inout [Int], r: (MergeModel.MergeStep, [Int]) -> Void) in mergeSort(&x, record: r) },
                         { (x: inout [Int], r: (MergeModel.MergeStep, [Int]) -> Void) in mergeSortRecursive(&x, record: r) }] {
                var sorted = a
                var recorded: [(step: MergeModel.MergeStep, state: [Int])] = []
                sort(&sorted) { recorded.append(($0, $1)) }
                let (violation, final) = MergeModel.refines(recorded, from: a)
                #expect(violation == nil, "\(String(describing: violation))")
                #expect(final.done)
                #expect(final.a == sorted)
                #expect(sorted == a.sorted())
                traces.append(recorded.map(\.step))
            }
            if traces[0] != traces[1] { differed = true }
            _ = differed
        }
    }

    /// The agent's predicted bug: `t` one too far merges a run that is
    /// not in R. The output is right on `[3, 1, 2, 0]`; the refinement
    /// fails at step 0 with the reason.
    @Test func offByOneIsNotAStep() throws {
        var a = [3, 1, 2, 0]
        var recorded: [(step: MergeModel.MergeStep, state: [Int])] = []
        mergeSort(&a, bug: .rightEndOffByOne) { recorded.append(($0, $1)) }
        #expect(a == [0, 1, 2, 3])
        let v = try #require(MergeModel.refines(recorded, from: [3, 1, 2, 0]).violation)
        print("rightEndOffByOne: \(v)")
        #expect(v.index == 0)
        #expect(v.reason == "a named run is not in R")
        do {
            try forAll(Self.inputs, seed: 1, database: "") { a in
                var s = a
                var rec: [(step: MergeModel.MergeStep, state: [Int])] = []
                mergeSort(&s, bug: .rightEndOffByOne) { rec.append(($0, $1)) }
                if let v = MergeModel.refines(rec, from: a).violation { throw NotAStep(v.description) }
            }
            Issue.record("the bug refined the relation")
        } catch let failure as PropertyFailure {
            let a = try replay(Self.inputs, blob: try #require(failure.failures.first?.reproduceBlob))
            print("rightEndOffByOne shrinks to \(a)")
            #expect(a.count == 3)
        }
    }

    struct NotAStep: Error, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = "not a Next step: \(s)" }
    }
}
