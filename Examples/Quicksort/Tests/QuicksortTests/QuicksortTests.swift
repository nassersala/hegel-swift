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
