import Testing
import HegelTesting
import Quicksort

@Suite struct LamportQuicksort {
    static let arrays = array(of: Gen<Int>.int(in: 0...9), count: 0...8)

    /// The relation's own correctness, as TLC checks it on `Quicksort.tla`
    /// for N ≤ 4: every behaviour ends sorted, a permutation of the input.
    /// Here for drawn arrays and drawn choices.
    @Test(.propertyTesting) func everyBehaviourSorts() {
        expectAll(Self.arrays.flatMap { a in Lamport.behaviour(a).map { (a, $0) } }, database: "") { a, run in
            #expect(run.final.done)
            #expect(run.final.a == a.sorted())
        }
    }

    /// Refinement: the concrete quicksort's steps are a behaviour of the
    /// relation. Every recorded step is a `Next` step, and the run ends
    /// with U empty.
    @Test(.propertyTesting) func hoareQuicksortRefinesTheRelation() {
        expectAll(Self.arrays, database: "") { a in
            let (sorted, steps) = quicksort(a)
            let (violation, final) = Lamport.refines(steps, from: a)
            #expect(violation == nil, "\(String(describing: violation))")
            #expect(final.done)
            #expect(sorted == a.sorted())
        }
    }

    /// The worklist quicksort, its range chosen by a draw, refines the
    /// same relation; and its behaviours are not the recursion's: over
    /// drawn arrays of length ≥ 4 some drawn pick order differs from the
    /// recursive step sequence.
    @Test func worklistQuicksortRefinesTheRelationInAnyOrder() throws {
        var differed = false
        try forAll(Self.arrays, testCases: 300, database: "") { a, tc in
            let (sorted, steps) = try worklistQuicksort(a) { ranges in
                Int(try tc.drawInteger(in: 0...Int64(ranges.count - 1)))
            }
            let (violation, final) = Lamport.refines(steps, from: a)
            if let violation { throw NotAStep(violation) }
            #expect(final.done)
            #expect(sorted == a.sorted())
            if steps != quicksort(a).steps { differed = true }
        }
        #expect(differed)
        // Depth-first pick: the recursion's behaviour exactly.
        let sample = [3, 1, 4, 1, 5, 9, 2, 6]
        let depthFirst = try worklistQuicksort(sample).steps
        #expect(depthFirst == quicksort(sample).steps)
    }

    /// The Lomuto split on a Hoare partition: the first bad step is a
    /// `drop` of an empty or reversed range, or a partition of a range the
    /// relation never produced. It shrinks to two elements.
    @Test func excludingThePivotIsNotAStep() throws {
        do {
            try forAll(Self.arrays, seed: 1, database: "") { a in
                let (_, steps) = quicksort(a, bug: .excludePivot)
                if let bad = Lamport.refines(steps, from: a).violation { throw NotAStep(bad) }
            }
            Issue.record("the bug was not found")
        } catch let failure as PropertyFailure {
            let c = try #require(failure.failures.first?.counterexample)
            let a = try replay(Self.arrays, blob: try #require(failure.failures.first?.reproduceBlob))
            print("excludePivot: \(c) → \(Lamport.refines(quicksort(a, bug: .excludePivot).steps, from: a).violation!)")
            #expect(a.count == 2)
        }
    }

    struct NotAStep: Error, CustomStringConvertible {
        let step: Lamport.Step
        init(_ step: Lamport.Step) { self.step = step }
        var description: String { "not a Next step: \(step)" }
    }
}
