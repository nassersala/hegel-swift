import Testing
import HegelTesting
import AsyncAlgorithms
import AsyncSequenceValidation

extension AsyncProperties {
    @Suite struct SweepLaws {
        static let counts: Gen<Int?> = Gen<Int64>.int(in: 0...4).map { $0 == 0 ? nil : Int($0) }

        /// Two sources, no simultaneous cross-source events, and a consumer
        /// with a demand always outstanding: every event then resolves at
        /// its own tick and the exact models apply. Ties (same tick, or a
        /// late consumer making several events available in one pull) are
        /// resolved by job-hop order, which is scheduling, not contract;
        /// the observed outcomes are pinned in `SweepModelSelfChecks.tieFacts`.
        static let continuousPair = array(of: Script.source(endings: .any), count: 2...2)
            .map { sources in Script(sources: sources, consumer: Array(repeating: .next, count: sources.map(\.count).reduce(0, +) + 4)) }
            .filter { !$0.hasSimultaneousCrossSourceEvents }

        @Test(.propertyTesting) func combineLatestExact() {
            expectAll(Self.continuousPair, testCases: budget, database: "") { script in
                try expectTrace(Sim.combineLatest(script), try Harness.combineLatest(script))
            }
        }

        /// Arbitrary demand and simultaneous events allowed: the acceptance
        /// model admits every legal interleaving.
        @Test(.propertyTesting) func combineLatestAnyDemand() {
            expectAll(Script.gen(sources: 2...2, endings: .any, allowCancel: false, enoughDemand: false), testCases: budget, database: "") { script in
                try Model.combineLatest(script, try Harness.combineLatest(script))
            }
        }

        @Test(.propertyTesting) func chunksExact() {
            expectAll(Hegel.zip(Self.continuousPair, Self.counts), testCases: budget, database: "") { script, count in
                try expectTrace(Sim.chunks(script, count: count), try Harness.chunks(script, count: count))
            }
        }
    }

    @Suite struct SweepModelSelfChecks {
        static func script(_ base: String, _ signal: String, demands: Int) -> Script {
            func events(_ d: String) -> [Script.Event] {
                var out: [Script.Event] = []
                loop: for ch in d {
                    switch ch {
                    case "-": out.append(.delay(1))
                    case "|": out.append(.finish); break loop
                    case "^": out.append(.failure); break loop
                    default: out.append(.value)
                    }
                }
                return out
            }
            return Script(sources: [events(base), events(signal)], consumer: Array(repeating: .next, count: demands))
        }

        /// Upstream's chunk diagrams (spaces removed).
        @Test func chunkDiagrams() throws {
            let s1 = Self.script("ABC-DEF-GHI-|", "---X---X---X|", demands: 14)
            #expect(try Harness.chunks(s1, count: nil).description == "abc@4 def@8 ghi@12 |@13")
            try expectTrace(Sim.chunks(s1, count: nil), try Harness.chunks(s1, count: nil))
            let s2 = Self.script("AB^", "---X|", demands: 6)
            #expect(try Harness.chunks(s2, count: nil).description == "^@3")
            try expectTrace(Sim.chunks(s2, count: nil), try Harness.chunks(s2, count: nil))
            let s3 = Self.script("111-111|", "---X---|", demands: 10)
            #expect(try Harness.chunks(s3, count: nil).description == "abc@4 def@8 |@8")
            try expectTrace(Sim.chunks(s3, count: nil), try Harness.chunks(s3, count: nil))
            let s4 = Self.script("AB--A-B-|", "--X----X|", demands: 12)
            #expect(try Harness.chunks(s4, count: 2).description == "ab@2 cd@7 |@9")
            try expectTrace(Sim.chunks(s4, count: 2), try Harness.chunks(s4, count: 2))
        }

        /// Same-tick outcomes, as observed. Not laws: which side wins a
        /// tick depends on how many job hops each path takes.
        @Test func tieFacts() throws {
            func cl(_ a: String, _ b: String) throws -> String {
                try AsyncSequenceValidationDiagram.run(inputs: [a, b], output: "xxxxxxxx") { d in
                    combineLatest(d.inputs[0], d.inputs[1]).map { $0 + $1 }
                }.description
            }
            // An empty-upstream finish beats a simultaneous failure on either side.
            #expect(try cl("|", "^") == "|@1")
            #expect(try cl("^", "|") == "|@1")
            // Value vs failure on one tick: the value wins when the consumer
            // is waiting, the failure wins when the consumer arrives late and
            // both resolve in the same pull.
            #expect(try cl("a-^", "ABC|") == "aA@1 aB@2 aC@3 ^@3")
            #expect(try AsyncSequenceValidationDiagram.run(inputs: ["a-^", "ABC|"], output: "-xx") { d in
                combineLatest(d.inputs[0], d.inputs[1]).map { $0 + $1 }
            }.description == "aA@1 aB@2 ^@3")
            func ch(_ a: String, _ b: String, _ count: Int?) throws -> String {
                try AsyncSequenceValidationDiagram.run(inputs: [a, b], output: "xxxxxxxx") { d in
                    if let count { return AnyAsyncSequence(d.inputs[0].chunks(ofCount: count, or: d.inputs[1]).map { $0.joined() }) }
                    return AnyAsyncSequence(d.inputs[0].chunked(by: d.inputs[1]).map { $0.joined() })
                }.description
            }
            // The signal reaches merge before a simultaneous base value (one hop fewer).
            #expect(try ch("a|", "A|", nil) == "a@2 |@2")
            #expect(try ch("ab|", "-A|", nil) == "a@2 b@3 |@3")
            // A signal failure beats a simultaneous base value; the value is lost.
            #expect(try ch("a", "^", nil) == "^@1")
        }

        /// A source failure held by `combineLatest` (its children pull
        /// ahead) is delivered to a cancelled task's next demand instead of
        /// `nil`; merge never holds one, so it always answers `nil`.
        @Test func heldFailureSurvivesCancellation() throws {
            let s = Script(sources: [[.value, .failure], [.value, .value, .finish]], consumer: [.next, .wait(1), .cancel, .next, .next])
            #expect(s.inputDiagrams == ["a^", "AB|"] && s.outputDiagram == "x-;xx")
            #expect(try Harness.combineLatest(s, persistent: true).description == "aA@1 aB@2 ^@3")
        }

        @Test func combineLatestBasics() throws {
            let s = Self.script("a-b-|", "-A--|", demands: 8)
            let trace = try Harness.combineLatest(s)
            #expect(trace.description == "aA@2 bA@3 |@5")
            try expectTrace(Sim.combineLatest(s), trace)
        }
    }
}
