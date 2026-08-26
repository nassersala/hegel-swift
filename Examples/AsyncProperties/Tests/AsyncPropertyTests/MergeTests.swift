import Testing
import HegelTesting
import AsyncAlgorithms
import AsyncSequenceValidation

extension AsyncProperties {
/// Laws for `merge`, grouped by termination mode. The validation runtime
/// installs a process-global hook, so the suite is serialized.
@Suite struct MergeLaws {
    /// Normal completion with enough demand: the output is the bag union
    /// of the inputs, each source in order, then finish.
    @Test(.propertyTesting) func normalCompletionIsTheBagUnionInSourceOrder() {
        expectAll(Script.gen(sources: 1...3, endings: .finish, allowCancel: false, enoughDemand: true), database: "") { script in
            let trace = try Harness.merge(script)
            let values = trace.events.compactMap { if case .value(let v, _) = $0 { v } else { nil } }
            #expect(Set(values) == Set(script.emissions.map(\.value)), "\(script)\n  got \(trace)")
            #expect(values.count == script.emissions.count, "\(script)\n  got \(trace)")
            for (s, _) in script.sources.enumerated() {
                let mine = values.filter { v in script.emissions.first { $0.value == v }?.source == s }
                #expect(mine == script.emissions.filter { $0.source == s }.map(\.value), "\(script)\n  got \(trace)")
            }
            #expect(trace.events.last.map { if case .finish = $0 { true } else { false } } == true, "\(script)\n  got \(trace)")
            try Model.merge(script, trace)
        }
    }

    /// Any script at all: the trace is one the model accepts.
    @Test(.propertyTesting) func everyTraceIsLegal() {
        expectAll(Script.gen(sources: 1...3, endings: .any, allowCancel: true, enoughDemand: false), database: "") { script in
            try Model.merge(script, try Harness.merge(script))
        }
    }

    /// Exact timing, 10k scripts: values at max(emission, demand), finish
    /// at max(last terminal, demand). No cancel (cancellation timing is
    /// its own law).
    @Test(.propertyTesting) func exactTiming() {
        expectAll(Script.gen(sources: 1...3, endings: .any, allowCancel: false, enoughDemand: false), testCases: budget, database: "") { script in
            try Model.mergeExact(script, try Harness.merge(script))
        }
    }

    /// Failure: with a failing source and enough demand, the output ends
    /// in that failure, and everything before it is legal.
    @Test(.propertyTesting) func aFailingSourceEndsTheOutputWithFailure() {
        let scripts = Script.gen(sources: 1...3, endings: .any, allowCancel: false, enoughDemand: true)
            .filter { $0.terminals.contains { $0.0 == .failure } }
        expectAll(scripts, database: "") { script in
            let trace = try Harness.merge(script)
            #expect(trace.events.last.map { if case .failure = $0 { true } else { false } } == true, "\(script)\n  got \(trace)")
            try Model.merge(script, trace)
        }
    }

    /// Cancellation at a drawn tick: terminates, with at most one value in
    /// flight after the cancel.
    @Test(.propertyTesting) func cancelTerminatesWithAtMostOneValueInFlight() {
        let scripts = Script.gen(sources: 1...3, endings: .any, allowCancel: true, enoughDemand: true)
            .filter { $0.cancelTick != nil }
        expectAll(scripts, database: "") { script in
            let trace = try Harness.merge(script)
            let c = script.cancelTick!
            let after = trace.events.filter { if case .value(_, let t) = $0 { t >= c } else { false } }
            #expect(after.count <= 1, "\(script)\n  got \(trace)")
            let terminated = trace.events.last.map { e -> Bool in
                switch e { case .finish, .failure, .cancelled: return true; default: return false }
            }
            #expect(terminated == true, "\(script)\n  got \(trace)")
            try Model.merge(script, trace)
        }
    }

    /// Metamorphic: translating every input and the consumer by k ticks
    /// translates every observed tick by k and changes nothing else.
    /// Endings are explicit because an empty source finishes at tick 0
    /// however far its diagram is shifted.
    @Test(.propertyTesting) func translationInTimeTranslatesTheTrace() {
        let scripts = Hegel.zip(
            Script.gen(sources: 1...3, endings: .explicit, allowCancel: true, enoughDemand: false),
            Gen<Int64>.int(in: 1...3))
        expectAll(scripts, database: "") { script, k in
            let shifted = Script(
                sources: script.sources.map { [.delay(Int(k))] + $0 },
                consumer: [.wait(Int(k))] + script.consumer)
            let base = try Harness.merge(script)
            let moved = try Harness.merge(shifted)
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

    /// Metamorphic: swapping the sources permutes nothing but the value
    /// tags under normal completion; the bag is schedule-insensitive.
    @Test(.propertyTesting) func swappingSourcesPreservesTheBag() {
        expectAll(Script.gen(sources: 2...2, endings: .finish, allowCancel: false, enoughDemand: true), database: "") { script in
            let swapped = Script(sources: [script.sources[1], script.sources[0]], consumer: script.consumer)
            let a = try Harness.merge(script).events.compactMap { if case .value(let v, _) = $0 { v } else { nil } }
            let b = try Harness.merge(swapped).events.compactMap { if case .value(let v, _) = $0 { v } else { nil } }
            // Rename swapped's tags back: source 0 letters ↔ source 1 letters.
            let rename = Dictionary(uniqueKeysWithValues:
                Swift.zip(Script.alphabets[0], Script.alphabets[1]).flatMap { [($0, $1), ($1, $0)] })
            let renamed = b.map { String($0.map { rename[$0] ?? $0 }) }
            #expect(Set(a) == Set(renamed), "\(script)\n  a \(a)\n  b \(b)")
        }
    }
}
}
