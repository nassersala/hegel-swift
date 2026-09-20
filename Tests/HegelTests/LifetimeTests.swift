import os
import Testing
@testable import Hegel
import HegelTesting

/// `TestCase` is a copyable value a property can store, and the runner
/// frees the engine handle when the case ends. A copy kept past that point
/// must throw, not reach freed memory.
@Suite struct RetainedTestCaseTests {
    @Test func drawOnACaseKeptPastForAllThrows() throws {
        var kept: TestCase?
        try forAll(.int(in: 0...10), testCases: 5, database: "") { _, tc in
            kept = tc
        }
        let tc = try #require(kept)
        // The message names the misuse, not just a NULL handle.
        var thrown: (any Error)?
        do { _ = try tc.drawInteger(in: 0...Int64(10)) } catch { thrown = error }
        if case .invalidArgument(let message)? = thrown as? HegelError {
            #expect(message.contains("has ended"))
        } else {
            Issue.record("expected HegelError.invalidArgument, got \(String(describing: thrown))")
        }
        #expect(throws: HegelError.self) { try tc.drawBool() }
        #expect(throws: HegelError.self) {
            try tc.drawCollection(count: 0...4) { try tc.drawInteger(in: 0...Int64(10)) }
        }
    }

    /// The previous case's handle is dead by the time the next case runs.
    @Test func drawOnThePreviousCaseThrows() throws {
        var previous: TestCase?
        var stale: [Bool] = []
        try forAll(.int(in: 0...10), testCases: 5, database: "") { _, tc in
            if let previous {
                do {
                    _ = try previous.drawInteger(in: 0...Int64(10))
                    stale.append(false)
                } catch {
                    stale.append(true)
                }
            }
            previous = tc
        }
        #expect(!stale.isEmpty)
        #expect(stale.allSatisfy { $0 })
    }

    @Test func drawOnACaseKeptPastReplayThrows() throws {
        struct Violation: Error {}
        var blob: String?
        do {
            try forAll(.int(in: 0...1000), seed: 7, database: "") { n in
                if n >= 10 { throw Violation() }
            }
        } catch let failure as PropertyFailure {
            blob = failure.failures.first?.reproduceBlob
        }
        nonisolated(unsafe) var kept: TestCase?
        let value = try replay(Gen<Int64> { tc in
            kept = tc
            return try tc.drawInteger(in: 0...Int64(1000))
        }, blob: try #require(blob))
        #expect(value == 10)
        let tc = try #require(kept)
        #expect(throws: HegelError.self) { try tc.drawInteger(in: 0...Int64(10)) }
    }

    @Test func poolOnADeadCaseThrows() throws {
        var kept: TestCase?
        try forAll(.int(in: 0...10), testCases: 3, database: "") { _, tc in
            kept = tc
        }
        let tc = try #require(kept)
        #expect(throws: HegelError.self) { _ = try Pool<Int>(tc) }
    }
}

/// The report phase re-runs the property at the shrunk counterexample.
/// That re-run is a property invocation like any other: cancelling the
/// caller propagates, and `timeout` bounds it.
@Suite struct ReRunTests {
    struct Violation: Error {}

    /// Every case of the run shares its context and the re-run is a
    /// replayed case with a fresh one, which is how the property below
    /// knows it is in the re-run.
    @Test func cancellationDuringTheReRunPropagates() async throws {
        let reached = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            defer { reached.continuation.finish() }
            nonisolated(unsafe) var runContext: Context?
            try await forAll(.int(in: 0...1000), seed: 7, database: "") { n, tc in
                if runContext == nil { runContext = tc.ctx }
                if tc.ctx !== runContext {
                    reached.continuation.yield()
                    try await Task.sleep(for: .seconds(10))
                }
                if n >= 10 { throw Violation() }
            }
        }
        var iterator = reached.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        do {
            try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    /// A caller cancelled during the engine's last case reaches the report
    /// phase already cancelled. It gets no re-run, even from a property
    /// that never looks at cancellation. The engine's invocation count is a
    /// function of the seed, so a first run counts them and a second
    /// cancels on the last one.
    @Test func aCancelledCallerIsNotReRun() async throws {
        func run(cancelAt: Int?) async -> (engineCalls: Int, reRuns: Int, error: (any Error)?) {
            let counts = OSAllocatedUnfairLock(initialState: (engineCalls: 0, reRuns: 0))
            let task = Task {
                nonisolated(unsafe) var runContext: Context?
                try await forAll(.int(in: 0...1000), seed: 7, database: "") { n, tc in
                    await Task.yield()
                    if runContext == nil { runContext = tc.ctx }
                    if tc.ctx === runContext {
                        let call = counts.withLock { $0.engineCalls += 1; return $0.engineCalls }
                        if call == cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
                    } else {
                        counts.withLock { $0.reRuns += 1 }
                    }
                    if n >= 10 { throw Violation() }
                }
            }
            var thrown: (any Error)?
            do { try await task.value } catch { thrown = error }
            let (engineCalls, reRuns) = counts.withLock { $0 }
            return (engineCalls, reRuns, thrown)
        }
        let counted = await run(cancelAt: nil)
        #expect(counted.reRuns == 1)
        #expect(counted.error is PropertyFailure)

        let cancelled = await run(cancelAt: counted.engineCalls)
        #expect(cancelled.engineCalls == counted.engineCalls)
        #expect(cancelled.reRuns == 0)
        #expect(cancelled.error is CancellationError)
    }

    /// `expectAll` replays the body once more at the minimal input with
    /// interception off. The invocation count is a function of the seed, so
    /// a first run counts them and a second hangs on the last one.
    @Test(.propertyTesting) func timeoutBoundsTheFinalReplayOfExpectAll() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        func run(hangAt: Int?) async -> [Bool] {
            calls.withLock { $0 = 0 }
            let timedOut = OSAllocatedUnfairLock(initialState: [Bool]())
            await withKnownIssue {
                await expectAll(.int(in: 0...1000), seed: 1, database: "", timeout: .milliseconds(500)) { n in
                    let call = calls.withLock { $0 += 1; return $0 }
                    if call == hangAt { try await Task.sleep(for: .seconds(30)) }
                    #expect(n < 10)
                }
            } matching: { issue in
                timedOut.withLock { $0.append(issue.error is PropertyTimeout) }
                return true
            }
            return timedOut.withLock { $0 }
        }
        #expect(await run(hangAt: nil) == [false, false])
        let total = calls.withLock { $0 }
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await run(hangAt: total) == [false, true])
        #expect(clock.now - start < .seconds(10))
    }
}
