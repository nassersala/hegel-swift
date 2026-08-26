import Testing
import HegelTesting
import AsyncAlgorithms
import AsyncSequenceValidation

extension AsyncProperties {
/// The model earns the right to be an oracle before it judges the
/// operators: upstream's hand-written diagrams must be accepted, and
/// deliberately corrupted traces must be rejected.
@Suite struct ModelSelfChecks {
    static let upstreamMerge2 = Script(
        sources: [[.value, .delay(1), .value, .delay(1), .value, .delay(1), .value, .delay(1), .finish],
                  [.delay(1), .value, .delay(1), .value, .delay(1), .value, .delay(1), .value]],
        consumer: Array(repeating: .next, count: 8))

    @Test func upstreamMergeDiagramReproduces() throws {
        let script = Self.upstreamMerge2
        #expect(script.inputDiagrams == ["a-b-c-d-|", "-A-B-C-D"])
        let trace = try Harness.merge(script)
        #expect(trace.description == "a@1 A@2 b@3 B@4 c@5 C@6 d@7 D@8 |@9")
        try Model.merge(script, trace)
    }

    @Test func upstreamMerge3DiagramReproduces() throws {
        // "a---e---|" / "-b-d-f-h|" / "--c---g-|" → "abcdefgh|"
        let script = Script(
            sources: [[.value, .delay(3), .value, .delay(3), .finish],
                      [.delay(1), .value, .delay(1), .value, .delay(1), .value, .delay(1), .value, .finish],
                      [.delay(2), .value, .delay(3), .value, .delay(1), .finish]],
            consumer: Array(repeating: .next, count: 8))
        let trace = try Harness.merge(script)
        #expect(trace.description == "a@1 A@2 1@3 B@4 b@5 C@6 2@7 D@8 |@9")
        try Model.merge(script, trace)
    }

    @Test func corruptedTracesAreRejected() throws {
        let script = Self.upstreamMerge2
        let good = try Harness.merge(script)
        var swapped = good
        swapped.events.swapAt(0, 1)  // A before a: legal, cross-source order is free
        #expect(throws: Never.self) { try Model.merge(script, swapped) }
        var premature = good
        premature.events[1] = .value("A", tick: 1)  // A emitted at 2
        #expect(throws: Illegal.self) { try Model.merge(script, premature) }
        var early = good
        early.events[2] = .value("c", tick: 2)
        #expect(throws: Illegal.self) { try Model.merge(script, early) }
        var dropped = good
        dropped.events.remove(at: 3)
        dropped.demandTicks.removeLast()
        #expect(throws: Illegal.self) { try Model.merge(script, dropped) }
        var skipped = good
        skipped.events[2] = .value("e", tick: 3)
        #expect(throws: Illegal.self) { try Model.merge(script, skipped) }
    }

    /// Pinned semantics, found by the failure law and triaged as
    /// implementation-as-designed: merge pulls each source only on
    /// downstream demand, so source 1's failure at tick 3 is observed
    /// after source 0's `c`, emitted at tick 4.
    @Test func failureIsPullDriven() throws {
        let script = Script(
            sources: [[.value, .delay(1), .value, .value, .finish], [.value, .value, .failure]],
            consumer: Array(repeating: .next, count: 5))
        #expect(script.inputDiagrams == ["a-bc|", "AB^"])
        #expect(try Harness.merge(script).description == "a@1 A@1 B@2 b@3 c@4 ^@5")
        let sparse = Script(sources: script.sources, consumer: [.next, .wait(1), .next, .wait(1), .next, .wait(1), .next, .wait(1), .next, .wait(1), .next])
        #expect(try Harness.merge(sparse).description == "a@1 A@1 b@3 B@5 c@7 ^@9")
    }

    @Test func zipHandDerivedTrace() throws {
        // "a-b|" zip "A--B|" → aA@2? a@1,A@1 → pair at max(1,1)=1... observed when both arrived.
        let script = Script(
            sources: [[.value, .delay(1), .value, .finish], [.value, .delay(2), .value, .finish]],
            consumer: Array(repeating: .next, count: 4))
        let trace = try Harness.zip(script)
        let values = trace.events.compactMap { if case .value(let v, _) = $0 { v } else { nil } }
        #expect(values == ["aA", "bB"])
        try Model.zip(script, trace)
        var wrong = trace
        wrong.events[0] = .value("aB", tick: 1)
        #expect(throws: Illegal.self) { try Model.zip(script, wrong) }
    }

    /// The generator never produces a script the runtime cannot parse, and
    /// the model never rejects the runtime on an empty-ish script.
    @Test(.propertyTesting) func generatedScriptsRender() {
        expectAll(Script.gen(sources: 1...3, endings: .any, allowCancel: true, enoughDemand: false), database: "") { script in
            #expect(script.inputDiagrams.count == script.sources.count)
            let demands = script.consumer.filter { $0 == .next || $0 == .cancel }.count
            #expect(script.demandTicks.count == 1 + demands)
        }
    }
}
}
