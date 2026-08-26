import Testing
import HegelTesting
import AsyncAlgorithms
import AsyncSequenceValidation

let budget: UInt64 = 10_000

extension AsyncProperties {
    /// `buffer`, `debounce`, `throttle` against their executable models,
    /// trace equality, 10k scripts each. Single source, no cancel.
    @Suite struct TimedLaws {
        static let single = Script.gen(sources: 1...1, endings: .any, allowCancel: false, enoughDemand: false)
        static let intervals = Gen<Int64>.int(in: 0...4).map { Int($0) }

        @Test(.propertyTesting) func throttleLatest() {
            expectAll(Hegel.zip(Self.single, Self.intervals), testCases: budget, database: "") { script, k in
                try expectTrace(Sim.throttle(script, steps: k, latest: true), try Harness.throttle(script, steps: k, latest: true))
            }
        }

        @Test(.propertyTesting) func throttleFirst() {
            expectAll(Hegel.zip(Self.single, Self.intervals), testCases: budget, database: "") { script, k in
                try expectTrace(Sim.throttle(script, steps: k, latest: false), try Harness.throttle(script, steps: k, latest: false))
            }
        }

        /// Finishing sources and a consumer that always has a demand
        /// outstanding. Both restrictions are findings: the failure path is
        /// broken upstream (`DebounceSwallowsUpstreamError`), and a slow
        /// consumer changes what debounce emits
        /// (`TimedModelSelfChecks.debounceSlowConsumerEmitsSupersededValue`).
        @Test(.propertyTesting) func debounce() {
            let continuous = Script.source(endings: .finish).map { events in
                Script(sources: [events], consumer: Array(repeating: .next, count: events.count + 2))
            }
            expectAll(Hegel.zip(continuous, Self.intervals), testCases: budget, database: "") { script, k in
                try expectTrace(Sim.debounce(script, steps: k), try Harness.debounce(script, steps: k))
            }
        }

        /// The failure path, kept running so the model stays honest about
        /// what it predicts; expected to fail until upstream is fixed.
        @Test(.propertyTesting) func debounceFailurePath() {
            let failing = Script.gen(sources: 1...1, endings: .any, allowCancel: false, enoughDemand: false)
                .filter { $0.terminals[0].0 == .failure }
            withKnownIssue("apple/swift-async-algorithms: debounce drops an upstream error when no demand is outstanding") {
                expectAll(Hegel.zip(failing, Self.intervals), testCases: 300, database: "") { script, k in
                    try expectTrace(Sim.debounce(script, steps: k), try Harness.debounce(script, steps: k))
                }
            }
        }

        static let policies: Gen<BufferPolicy> = Hegel.zip(Gen<Int64>.int(in: 0...3), Gen<Int64>.int(in: 0...3)).map { kind, n in
            switch kind {
            case 0: return .unbounded
            case 1: return .bounded(Int(n))
            case 2: return .bufferingOldest(Int(n))
            default: return .bufferingLatest(Int(n))
            }
        }

        @Test(.propertyTesting) func buffer() {
            expectAll(Hegel.zip(Self.single, Self.policies), testCases: budget, database: "") { script, policy in
                try expectTrace(Sim.buffer(script, policy: policy), try Harness.buffer(script, policy: policy))
            }
        }
    }

    /// The models against upstream's own diagrams before they judge anything.
    @Suite struct TimedModelSelfChecks {
        static func script(_ diagram: String, demands: Int) -> Script {
            // Only single-letter values, "-", "|", "^" appear in the diagrams we use.
            var events: [Script.Event] = []
            loop: for ch in diagram {
                switch ch {
                case "-": events.append(.delay(1))
                case "|": events.append(.finish); break loop
                case "^": events.append(.failure); break loop
                default: events.append(.value)
                }
            }
            return Script(sources: [events], consumer: Array(repeating: .next, count: demands))
        }

        @Test func throttleDiagrams() throws {
            let dense = Self.script("abcdefghijk|", demands: 14)
            #expect(try Harness.throttle(dense, steps: 2, latest: true).description == "a@1 c@3 e@5 g@7 i@9 k@11 |@12")
            #expect(try Harness.throttle(dense, steps: 2, latest: false).description == "a@1 b@3 d@5 f@7 h@9 j@11 |@12")
            #expect(try Harness.throttle(dense, steps: 3, latest: false).description == "a@1 b@4 e@7 h@10 k@13 |@13")
            for (k, latest) in [(0, true), (1, false), (2, true), (2, false), (3, true), (3, false)] {
                try expectTrace(Sim.throttle(dense, steps: k, latest: latest), try Harness.throttle(dense, steps: k, latest: latest))
            }
            let sparse = Self.script("-a-b-c-d-e-f-g-h-i-j-k-|", demands: 24)
            try expectTrace(Sim.throttle(sparse, steps: 3, latest: true), try Harness.throttle(sparse, steps: 3, latest: true))
            let failing = Self.script("abcdef^hijk|", demands: 14)
            try expectTrace(Sim.throttle(failing, steps: 2, latest: true), try Harness.throttle(failing, steps: 2, latest: true))
        }

        @Test func debounceDiagrams() throws {
            let long = Self.script("abcd----e---f-g----|", demands: 22)
            #expect(try Harness.debounce(long, steps: 3).description == "d@7 e@12 g@18 |@20")
            try expectTrace(Sim.debounce(long, steps: 3), try Harness.debounce(long, steps: 3))
            let flushed = Self.script("abcd----e---f-g-|", demands: 20)
            #expect(try Harness.debounce(flushed, steps: 3).description == "d@7 e@12 g@17 |@17")
            try expectTrace(Sim.debounce(flushed, steps: 3), try Harness.debounce(flushed, steps: 3))
            for d in ["a|", "a^", "----|"] {
                let s = Self.script(d, demands: 8)
                try expectTrace(Sim.debounce(s, steps: 3), try Harness.debounce(s, steps: 3))
            }
        }

        /// Found by the debounce law with arbitrary demand, triaged as the
        /// state machine's design: when a value arrives and no demand is
        /// outstanding, debounce buffers it and stops pulling the upstream,
        /// so a later value cannot supersede it. `"a-bc|"` with k = 2 and a
        /// consumer away until tick 5 emits `b` at 5, then `c` at 6; a
        /// continuously demanding consumer never sees `b` (`c` is flushed
        /// by the finish at 5). The documented contract, emit after
        /// quiescence, holds only for the latter.
        @Test func debounceSlowConsumerEmitsSupersededValue() throws {
            let away = Script(sources: [[.value, .delay(1), .value, .value, .finish]], consumer: [.wait(4), .next, .next, .next])
            #expect(away.inputDiagrams == ["a-bc|"])
            #expect(try Harness.debounce(away, steps: 2).description == "a@3 b@5 c@6 |@7")
            let continuous = Script(sources: away.sources, consumer: Array(repeating: .next, count: 6))
            #expect(try Harness.debounce(continuous, steps: 2).description == "a@3 c@5 |@5")
            try expectTrace(Sim.debounce(continuous, steps: 2), try Harness.debounce(continuous, steps: 2))
        }

        @Test func bufferDiagrams() throws {
            // Upstream's "X-12-34-5|" with the consumer away between its
            // first demand and tick 5, then again until 8.
            let s = Script(sources: [[.value, .delay(1), .value, .value, .delay(1), .value, .value, .delay(1), .value, .finish]],
                           consumer: [.wait(4), .next, .wait(2), .next, .next, .next, .next])
            #expect(s.inputDiagrams == ["a-bc-de-f|"])
            let oldest = try Harness.buffer(s, policy: .bufferingOldest(2))
            #expect(oldest.description == "a@1 b@5 c@8 d@9 f@10 |@11")
            try expectTrace(Sim.buffer(s, policy: .bufferingOldest(2)), oldest)
            let latest = try Harness.buffer(s, policy: .bufferingLatest(2))
            #expect(latest.description == "a@1 b@5 d@8 e@9 f@10 |@11")
            try expectTrace(Sim.buffer(s, policy: .bufferingLatest(2)), latest)
            let failing = Self.script("a-bcdef^", demands: 8)
            for p in [BufferPolicy.bufferingOldest(2), .bufferingLatest(2), .bounded(2), .unbounded, .bounded(0)] {
                try expectTrace(Sim.buffer(failing, policy: p), try Harness.buffer(failing, policy: p))
            }
        }
    }
}
