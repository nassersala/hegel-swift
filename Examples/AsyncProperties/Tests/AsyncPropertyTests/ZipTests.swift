import Testing
import HegelTesting
import AsyncAlgorithms
import AsyncSequenceValidation

extension AsyncProperties {
@Suite struct ZipLaws {
    /// Normal completion: min-length pairing, pair i = (aᵢ, bᵢ).
    @Test(.propertyTesting) func normalCompletionPairsToTheShorterLength() {
        expectAll(Script.gen(sources: 2...2, endings: .finish, allowCancel: false, enoughDemand: true), database: "") { script in
            let trace = try Harness.zip(script)
            let values = trace.events.compactMap { if case .value(let v, _) = $0 { v } else { nil } }
            let a = script.emissions.filter { $0.source == 0 }, b = script.emissions.filter { $0.source == 1 }
            let expected = Swift.zip(a, b).map { $0.value + $1.value }
            #expect(values == expected, "\(script)\n  got \(trace)")
            #expect(trace.events.last.map { if case .finish = $0 { true } else { false } } == true, "\(script)\n  got \(trace)")
            try Model.zip(script, trace)
        }
    }

    @Test(.propertyTesting) func everyTraceIsLegal() {
        expectAll(Script.gen(sources: 2...2, endings: .any, allowCancel: true, enoughDemand: false), database: "") { script in
            try Model.zip(script, try Harness.zip(script))
        }
    }

    @Test(.propertyTesting) func exactTiming() {
        expectAll(Script.gen(sources: 2...2, endings: .any, allowCancel: false, enoughDemand: false), testCases: budget, database: "") { script in
            try Model.zipExact(script, try Harness.zip(script))
        }
    }

    @Test(.propertyTesting) func aFailingSourceEndsTheOutputWithFailure() {
        let scripts = Script.gen(sources: 2...2, endings: .any, allowCancel: false, enoughDemand: true)
            .filter { $0.terminals.contains { $0.0 == .failure } }
        expectAll(scripts, database: "") { script in
            let trace = try Harness.zip(script)
            let ended = trace.events.last.map { e -> Bool in
                switch e { case .failure, .finish: return true; default: return false }
            }
            #expect(ended == true, "\(script)\n  got \(trace)")
            try Model.zip(script, trace)
        }
    }

    @Test(.propertyTesting) func translationInTimeTranslatesTheTrace() {
        let scripts = Hegel.zip(
            Script.gen(sources: 2...2, endings: .explicit, allowCancel: true, enoughDemand: false),
            Gen<Int64>.int(in: 1...3))
        expectAll(scripts, database: "") { script, k in
            let shifted = Script(
                sources: script.sources.map { [.delay(Int(k))] + $0 },
                consumer: [.wait(Int(k))] + script.consumer)
            let base = try Harness.zip(script)
            let moved = try Harness.zip(shifted)
            let expected = base.events.map { e -> Observation in
                switch e {
                case .value(let v, let t): return .value(v, tick: t + Int(k))
                case .finish(let t): return .finish(tick: t + Int(k))
                case .failure(let t): return .failure(tick: t + Int(k))
                case .cancelled(let t): return .cancelled(tick: t + Int(k))
                case .error(let s, let t): return .error(s, tick: t + Int(k))
                case .demandExhausted(let t): return .demandExhausted(tick: t + Int(k))
                }
            }
            #expect(moved.events == expected, "\(script)\n  base  \(base)\n  moved \(moved)")
        }
    }
}
}
