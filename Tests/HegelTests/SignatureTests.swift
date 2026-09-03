import Hegel
import Testing

@Suite struct SignatureTests {
    /// The undo law as a signature law: no generator argument, the
    /// parameter types name the generators.
    @Test func theUndoLawFromItsSignature() throws {
        try forAll(seed: 1, database: "") { (e: Edit, d: Doc, h: [Entry]) in
            let got = meaning(undo(record(e, d, h)))(meaning(e)(d))
            if got != d { throw LawViolated("undo(e)(e(d)) = \(got.debugDescription), d = \(d.debugDescription)") }
        }
    }

    /// The signature form and the explicit form are the same run: under
    /// the same seed the wrong undo shrinks to the same counterexample,
    /// with the same reproduce blob.
    @Test func shrinksToTheSameCounterexampleAsTheExplicitForm() throws {
        func fromSignature() -> PropertyFailure? {
            do {
                try forAll(seed: 1, database: "") { (e: Edit, d: Doc, h: [Entry]) in
                    let got = meaning(wrongUndo(record(e, d, h)))(meaning(e)(d))
                    if got != d { throw LawViolated("undo(e)(e(d)) = \(got.debugDescription), d = \(d.debugDescription)") }
                }
            } catch let failure as PropertyFailure { return failure } catch { return nil }
            return nil
        }
        func explicit() -> PropertyFailure? {
            do {
                try forAll(zip(Edit.gen, Doc.gen, [Entry].gen), seed: 1, database: "") { e, d, h in
                    let got = meaning(wrongUndo(record(e, d, h)))(meaning(e)(d))
                    if got != d { throw LawViolated("undo(e)(e(d)) = \(got.debugDescription), d = \(d.debugDescription)") }
                }
            } catch let failure as PropertyFailure { return failure } catch { return nil }
            return nil
        }
        let signature = try #require(fromSignature()?.failures.first)
        let named = try #require(explicit()?.failures.first)
        print("signature form:\n\(signature.counterexample ?? "-")\nexplicit form:\n\(named.counterexample ?? "-")")
        #expect(signature.counterexample == "(insert(at: 0, \"0\"), \"\", [])")
        #expect(signature.counterexample == named.counterexample)
        #expect(signature.reproduceBlob == named.reproduceBlob)
    }

    /// The experiment's own generators (letters a to c) find the same
    /// shape; only the letter differs, because the string generator does.
    @Test func theExperimentsGeneratorsFindTheSameShape() throws {
        do {
            try forAll(ABC.inputs, seed: 1, database: "") { e, d, h in
                let got = meaning(wrongUndo(record(e, d, h)))(meaning(e)(d))
                if got != d { throw LawViolated("unequal") }
            }
            Issue.record("wrongUndo must fail")
        } catch let failure as PropertyFailure {
            #expect(failure.failures.first?.counterexample == "(insert(at: 0, \"a\"), \"\", [])")
        }
    }

    /// Arity 1, 2 and 4, and the standard conformances' ranges.
    @Test func standardConformancesAndArities() throws {
        try forAll(testCases: 50, database: "") { (n: Int) in #expect((-100...100).contains(n)) }
        try forAll(testCases: 50, database: "") { (s: String, b: Bool) in
            #expect(s.count <= 8 && s.allSatisfy(\.isASCII))
            _ = b
        }
        try forAll(testCases: 50, database: "") { (xs: [Int], o: Int?, s: String, flags: [Bool]) in
            #expect(xs.count <= 8 && flags.count <= 8)
            if let o { #expect((-100...100).contains(o)) }
            _ = s
        }
    }

    /// An explicit generator still wins: the signature form is only what a
    /// bare closure gets.
    @Test func anExplicitGeneratorWins() throws {
        try forAll(.int(in: 1000...1000), testCases: 10, database: "") { (n: Int) in #expect(n == 1000) }
    }

    /// A signature law shrinks like any other: the standard `Int` default
    /// shrinks toward zero and `Optional` toward nil.
    @Test func shrinksThroughTheDefaults() throws {
        do {
            try forAll(seed: 1, database: "") { (n: Int, o: Int?) in
                if n > 3 { throw LawViolated("n > 3") }
            }
            Issue.record("must fail")
        } catch let failure as PropertyFailure {
            #expect(failure.failures.first?.counterexample == "(4, nil)")
        }
    }
}
