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
    /// exactly 10. Shrinking ends on the minimal counterexample, so the
    /// last INTERESTING case the engine hands us is the shrunk one. Also
    /// guards against vacuous self-bootstrap passes — this test cannot
    /// succeed unless generation, failure reporting, shrinking, and blob
    /// production all actually ran.
    @Test func knownCounterexampleShrinksToMinimum() throws {
        nonisolated(unsafe) var lastFailing: Int64 = -1
        do {
            try forAll(.int(in: 0...1000), database: "") { n in
                if n >= 10 {
                    lastFailing = n
                    throw HegelError.internalError("n >= 10")
                }
            }
            Issue.record("property should have failed")
        } catch let failure as PropertyFailure {
            #expect(lastFailing == 10)
            #expect(failure.failures.count == 1)
            #expect(failure.failures.first?.reproduceBlob != nil)
        }
    }
}
