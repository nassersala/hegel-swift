import Testing
import HegelTesting
import AboveTheCode

/// Fung's algorithm explained by refuting wrong relations. Two are
/// refuted with a minimal trace; the tool is silent on the third, and
/// silence is not a proof.
@Suite struct AboveFung {
    static let arrays = array(of: Gen<Int>.int(in: 0...9), count: 0...8)

    @Test(.propertyTesting) func theThreeAlgorithmsSort() {
        expectAll(Self.arrays, database: "") { a in
            #expect(fung(a) == a.sorted())
            #expect(insertionSortPasses(a).last ?? a == a.sorted())
            #expect(exchangeSortSwaps(a).last ?? a == a.sorted())
        }
    }

    /// Relation 1 is what the code looks like, and exchange sort refines it.
    @Test(.propertyTesting) func exchangeSortRefinesRelation1() {
        expectAll(Self.arrays, database: "") { a in
            let (violation, final) = Exchange.refines(exchangeSortSwaps(a), from: a)
            #expect(violation == nil, "\(String(describing: violation))")
            #expect(final == a.sorted())
        }
    }

    /// Fung does not: the first swap of pass 0 on a sorted pair creates an
    /// inversion. Shrinks to two elements in order.
    @Test func fungIsNotAnExchangeSort() throws {
        do {
            try forAll(Self.arrays, seed: 1, database: "") { a in
                if let v = Exchange.refines(fungSwaps(a), from: a).violation { throw NotAStep("\(v.from) → \(v.to)") }
            }
            Issue.record("Fung refined relation 1")
        } catch let failure as PropertyFailure {
            let a = try replay(Self.arrays, blob: try #require(failure.failures.first?.reproduceBlob))
            print("relation 1 refuted on \(a): \(Exchange.refines(fungSwaps(a), from: a).violation!)")
            #expect(a.count == 2)
            #expect(a[0] < a[1])
        }
    }

    /// Relation 2, insertion with the remainder fixed: refuted by pass 0,
    /// which shuffles the rest. Two elements cannot show it; shrinks to
    /// three.
    @Test func passZeroPermutesTheRemainder() throws {
        do {
            try forAll(Self.arrays, seed: 1, database: "") { a in
                if let v = Insertion.refines(passes: fungPasses(a), from: a, remainder: .fixed).violation {
                    throw NotAStep("\(v.from) → \(v.to)")
                }
            }
            Issue.record("Fung refined relation 2")
        } catch let failure as PropertyFailure {
            let a = try replay(Self.arrays, blob: try #require(failure.failures.first?.reproduceBlob))
            let v = Insertion.refines(passes: fungPasses(a), from: a, remainder: .fixed).violation!
            print("relation 2 refuted on \(a): \(v.from) → \(v.to)")
            #expect(a.count == 3)
            #expect(v.from.prefix.isEmpty)
        }
    }

    /// Relation 3, the remainder free: Fung refines it, and so does
    /// insertion sort, which refines relation 2 as well. Two pieces of
    /// code, one relation above them.
    @Test(.propertyTesting) func fungRefinesRelation3() {
        expectAll(Self.arrays, database: "") { a in
            let (violation, final) = Insertion.refines(passes: fungPasses(a), from: a, remainder: .free)
            #expect(violation == nil, "\(String(describing: violation))")
            #expect(final.done)
            #expect(final.prefix == a.sorted())
        }
    }

    @Test(.propertyTesting) func insertionSortRefinesRelations2And3() {
        expectAll(Self.arrays, database: "") { a in
            for remainder in [Insertion.Remainder.fixed, .free] {
                let (violation, final) = Insertion.refines(passes: insertionSortPasses(a), from: a, remainder: remainder)
                #expect(violation == nil, "\(remainder): \(String(describing: violation))")
                #expect(final.done)
                #expect(final.prefix == a.sorted())
            }
        }
    }

    /// The relations' own correctness, on drawn behaviours: every run of
    /// either insertion relation ends sorted.
    @Test(.propertyTesting) func everyBehaviourSorts() {
        for remainder in [Insertion.Remainder.fixed, .free] {
            expectAll(Self.arrays.flatMap { a in Insertion.behaviour(a, remainder: remainder).map { (a, $0) } }, database: "") { a, run in
                #expect(run.final.done)
                #expect(run.final.prefix == a.sorted())
            }
        }
    }

    /// A claim from the pilot's treatment answer for problem B: the
    /// variant that skips pass 0 sorts, and is not a behaviour of relation
    /// 3, because without the maximum in front a later pass evicts an
    /// element from the prefix. Hegel confirms both halves; the shrunk
    /// input is three elements.
    @Test func skippingPassZeroSortsButDoesNotRefineRelation3() throws {
        do {
            try forAll(Self.arrays, seed: 1, database: "") { a in
                let passes = fungWithoutPassZeroPasses(a)
                #expect(passes.last ?? a == a.sorted())
                if let v = Insertion.refines(passes: passes, from: a, remainder: .free).violation {
                    throw NotAStep("\(v.from) → \(v.to)")
                }
            }
            Issue.record("the variant refined relation 3")
        } catch let failure as PropertyFailure {
            let a = try replay(Self.arrays, blob: try #require(failure.failures.first?.reproduceBlob))
            let v = Insertion.refines(passes: fungWithoutPassZeroPasses(a), from: a, remainder: .free).violation!
            print("pass 0 skipped, relation 3 refuted on \(a): \(v.from) → \(v.to)")
            #expect(a.count == 3)
            #expect(v.from.prefix.count == 1)
        }
    }

    struct NotAStep: Error, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = "not a Next step: \(s)" }
    }
}
