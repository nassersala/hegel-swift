import Testing
import AsyncAlgorithms
import AsyncSequenceValidation

/// Found by `TimedLaws.debounce` at 10k scripts (swift-async-algorithms
/// 1.1.5, identical on main): an upstream error that arrives while the
/// consumer is not suspended in `next()` is reported as a normal finish.
/// `DebounceStateMachine.upstreamThrew`, case
/// `.waitingForDemand(task, .none, clockContinuation, .none)`, transitions
/// to `.finished` and discards the error instead of entering
/// `.upstreamFailure`, the state that exists to hold it. Values arriving
/// in the same state are buffered; errors vanish.
///
/// Both tests assert the correct behaviour under `withKnownIssue`, so
/// they stay green until upstream fixes it and then flag the fix.
extension AsyncProperties {
    @Suite struct DebounceSwallowsUpstreamError {
        /// Shrunk counterexample: "a^" with k = 1. `a` fires at tick 2, the
        /// upstream fails at tick 2 right after, the consumer's next
        /// demand sees a finish.
        @Test func shrunkScript() throws {
            let script = Script(sources: [[.value, .failure]], consumer: [.next])
            #expect(script.inputDiagrams == ["a^"])
            let trace = try Harness.debounce(script, steps: 1)
            #expect(trace.events.first == .value("a", tick: 2))
            withKnownIssue("apple/swift-async-algorithms: debounce drops an upstream error when no demand is outstanding") {
                #expect(trace.events.last == .failure(tick: 2), "got \(trace)")
            }
        }

        /// The same with the consumer simply away: value at 1 (k = 0),
        /// failure at 2, next demand at 5 sees a finish.
        @Test func consumerAway() throws {
            let script = Script(sources: [[.value, .failure]], consumer: [.wait(4), .next, .next])
            let trace = try Harness.debounce(script, steps: 0)
            #expect(trace.events.first == .value("a", tick: 1))
            withKnownIssue("apple/swift-async-algorithms: debounce drops an upstream error when no demand is outstanding") {
                #expect(trace.events.last == .failure(tick: 5), "got \(trace)")
            }
        }

        /// Standalone, real clock, no test runtime.
        struct Boom: Error {}
        static func stream() -> AsyncThrowingStream<Int, any Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(1)
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    continuation.finish(throwing: Boom())
                }
            }
        }

        @Test func realClock() async throws {
            var iterator = Self.stream().debounce(for: .milliseconds(10)).makeAsyncIterator()
            #expect(try await iterator.next() == 1)
            try await Task.sleep(for: .milliseconds(300))  // consumer busy while the upstream throws
            await withKnownIssue("apple/swift-async-algorithms: debounce drops an upstream error when no demand is outstanding") {
                await #expect(throws: Boom.self) { try await iterator.next() }
            }
            // Control: the consumer is waiting in next() when the error arrives.
            var control = Self.stream().debounce(for: .milliseconds(10)).makeAsyncIterator()
            #expect(try await control.next() == 1)
            await #expect(throws: Boom.self) { try await control.next() }
        }
    }
}
