import Testing
@testable import Hegel

// These tests require libhegel to be installed — see README "Getting libhegel".

struct User: Equatable {
    var id: Int64
    var age: Int
    var active: Bool
}

// Two witnesses for one type, no conformance clash — the point of the design.
let anyUser = zip(
    .int(in: 0...Int64.max),
    .int(in: 0...120),
    .bool
).map(User.init)

let adult = zip(
    .int(in: 0...Int64.max),
    .int(in: 18...65),
    .bool(probability: 0.9)
).map(User.init)

@Suite struct GenTests {
    @Test func integersRespectBounds() throws {
        try forAll(.int(in: -5...5)) { n in
            #expect((-5...5).contains(n))
        }
    }

    @Test func composedGeneratorsRespectInvariants() throws {
        try forAll(adult) { user in
            #expect(user.age >= 18 && user.age <= 65)
        }
    }

    @Test func collectionsRespectSizeBounds() throws {
        try forAll(array(of: .bool, count: 1...8)) { xs in
            #expect((1...8).contains(UInt64(xs.count)))
        }
    }

    @Test func filterRejectsWithoutFailing() throws {
        try forAll(Gen<Int64>.int(in: 0...100).filter { $0 % 2 == 0 }) { n in
            #expect(n % 2 == 0)
        }
    }

    /// Sanity-check the failure path: this property is false and must
    /// produce a shrunk counterexample, not a pass.
    @Test func failingPropertyIsReported() {
        #expect(throws: PropertyFailure.self) {
            try forAll(.int(in: 0...1000), database: "") { n in
                if n >= 10 { throw HegelError.internalError("n >= 10") }
            }
        }
    }

    /// Shrinker integration, end to end: "n >= 10 fails" must shrink to
    /// exactly 10, asserted by REPLAYING the reproduce blob (not by
    /// trusting the last observed case). Guards against vacuous
    /// self-bootstrap passes — this cannot succeed unless generation,
    /// failure reporting, shrinking, blob production, and replay all ran.
    @Test func knownCounterexampleShrinksToMinimum() throws {
        let gen = Gen<Int64>.int(in: 0...1000)
        do {
            try forAll(gen, database: "") { n in
                if n >= 10 { throw HegelError.internalError("n >= 10") }
            }
            Issue.record("property should have failed")
        } catch let failure as PropertyFailure {
            #expect(failure.failures.count == 1)
            let blob = try #require(failure.failures.first?.reproduceBlob)
            #expect(try replay(gen, blob: blob) == 10)
            // The runner already replayed it for display:
            #expect(failure.failures.first?.counterexample == "10")
        }
    }

    @Test func stringsRespectAlphabetAndLength() throws {
        try forAll(.asciiString(count: 1...16), database: "") { s in
            #expect(!s.isEmpty && s.count <= 16)
            #expect(s.allSatisfy { $0.isASCII })
        }
    }

    @Test func regexStringsMatch() throws {
        try forAll(.regex("[a-z]{2,5}-[0-9]{3}"), database: "") { s in
            #expect(s.wholeMatch(of: /[a-z]{2,5}-[0-9]{3}/) != nil)
        }
    }

    @Test func emailsHaveAnAtSign() throws {
        try forAll(.email, database: "") { s in
            #expect(s.contains("@"))
        }
    }

    @Test func arabicTextStaysInBlock() throws {
        try forAll(.arabicText(count: 1...12), database: "") { s in
            #expect(!s.isEmpty)
            #expect(s.unicodeScalars.allSatisfy { (0x0600...0x06FF).contains($0.value) })
        }
    }

    /// String shrinking must also arrive at the minimal counterexample:
    /// "contains no 'z'" fails minimally on a single "z" (ASCII 'z' is the
    /// lexicographically-largest lowercase letter, so the shrunk string is
    /// exactly one character long).
    @Test func failingStringShrinksSmall() throws {
        let gen = Gen<String>.string(count: 0...20, codec: "ascii")
        do {
            try forAll(gen, database: "") { s in
                if s.contains("z") { throw HegelError.internalError("has z") }
            }
            Issue.record("property should have failed")
        } catch let failure as PropertyFailure {
            let blob = try #require(failure.failures.first?.reproduceBlob)
            let shrunk = try replay(gen, blob: blob)
            #expect(shrunk.count == 1)
            #expect(shrunk == "z")
        }
    }
}
