import Foundation
import os
import Testing
@testable import Hegel
import HegelTesting

/// E0 of specs/async-experiments.md: the async `forAll` is the synchronous
/// one with suspension allowed. Every check here compares against the
/// synchronous twin by reproduce blob, not by seed — blob equality is the
/// acceptance test.
@Suite struct AsyncForAllTests {
    struct Violation: Error {}

    /// Suspends and resumes on a libdispatch thread, so the draws after it
    /// happen on a different thread than the draws before it. The engine
    /// handle survives this: its contract is one driver at a time, not
    /// thread affinity.
    static func hop() async {
        await withCheckedContinuation { c in
            DispatchQueue.global().asyncAfter(deadline: .now() + .microseconds(200)) {
                c.resume()
            }
        }
    }

    static func syncBlob(seed: UInt64) throws -> Failure {
        do {
            try forAll(.int(in: 0...1000), seed: seed, database: "") { n in
                if n >= 10 { throw Violation() }
            }
        } catch let failure as PropertyFailure {
            return try #require(failure.failures.first)
        }
        Issue.record("sync property should have failed")
        throw Violation()
    }

    @Test func asyncTwinShrinksToTheSameBlob() async throws {
        let sync = try Self.syncBlob(seed: 7)
        do {
            try await forAll(.int(in: 0...1000), seed: 7, database: "") { n in
                await Self.hop()
                if n >= 10 { throw Violation() }
            }
            Issue.record("async property should have failed")
        } catch let failure as PropertyFailure {
            #expect(failure.failures.count == 1)
            #expect(failure.failures.first?.reproduceBlob == sync.reproduceBlob)
            #expect(failure.failures.first?.counterexample == "10")
        }
    }

    /// Draw, suspend on another thread, draw again: the second draw must
    /// land in the same choice sequence as if nothing had happened, so the
    /// shrunk blob equals the synchronous twin's.
    @Test func suspensionBetweenDrawsReplaysLikeTheSyncTwin() async throws {
        let gen = Gen<Int64>.int(in: 0...100)
        func check(_ a: Int64, _ b: Int64) throws {
            if a + b >= 30 { throw Violation() }
        }
        var syncBlob: String?
        do {
            try forAll(gen, seed: 3, database: "") { a, tc in
                let b = try tc.drawInteger(in: 0...Int64(100))
                try check(a, b)
            }
        } catch let failure as PropertyFailure {
            syncBlob = failure.failures.first?.reproduceBlob
        }
        let expected = try #require(syncBlob)

        var asyncBlob: String?
        do {
            try await forAll(gen, seed: 3, database: "") { a, tc in
                await Self.hop()
                let b = try tc.drawInteger(in: 0...Int64(100))
                await Self.hop()
                try check(a, b)
            }
        } catch let failure as PropertyFailure {
            asyncBlob = failure.failures.first?.reproduceBlob
        }
        #expect(asyncBlob == expected)
        // And the blob really encodes both draws: the shrunk pair is minimal.
        let pair = try replay(Gen { tc in
            (try gen.run(tc), try tc.drawInteger(in: 0...Int64(100)))
        }, blob: expected)
        #expect(pair.0 + pair.1 == 30)
    }

    @Test func derandomizeMatchesTheSyncTwin() async throws {
        let settings = Settings(derandomize: true, database: "")
        var blobs: [String?] = []
        do {
            try forAll(.int(in: 0...1000), settings: settings) { n in
                if n >= 10 { throw Violation() }
            }
        } catch let failure as PropertyFailure {
            blobs.append(failure.failures.first?.reproduceBlob)
        }
        for _ in 0..<2 {
            do {
                try await forAll(.int(in: 0...1000), settings: settings) { n in
                    await Task.yield()
                    if n >= 10 { throw Violation() }
                }
            } catch let failure as PropertyFailure {
                blobs.append(failure.failures.first?.reproduceBlob)
            }
        }
        #expect(blobs.count == 3)
        #expect(blobs[0] != nil)
        #expect(Set(blobs.map { $0 ?? "" }).count == 1)
    }

    @Test func passingAsyncPropertyPasses() async throws {
        try await forAll(array(of: .int(in: 0...9), count: 0...8), database: "") { xs in
            await Task.yield()
            #expect(xs.reversed().reversed() == xs)
        }
    }

    @Test func assumeIsNotACounterexampleAsync() async throws {
        try await forAll(.int(in: 0...100), database: "") { n in
            await Task.yield()
            guard n.isMultiple(of: 2) else { throw HegelError.assume }
            #expect(n.isMultiple(of: 2))
        }
    }

    /// Cancelling the caller stops the run with `CancellationError`, never
    /// with a counterexample; the property that observed cancellation is
    /// not reported as a bug.
    @Test func callerCancellationPropagates() async throws {
        let started = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            try await forAll(.int(in: 0...100), database: "") { _ in
                started.continuation.yield()
                try await Task.sleep(for: .seconds(10))
            }
        }
        var iterator = started.stream.makeAsyncIterator()
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

    @Test func hungPropertyTimesOut() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await forAll(.int(in: 0...100), database: "", timeout: .milliseconds(50)) { _ in
                try await Task.sleep(for: .seconds(30))
            }
            Issue.record("expected PropertyTimeout")
        } catch let timeout as PropertyTimeout {
            #expect(timeout.timeout == .milliseconds(50))
            #expect(timeout.description.contains("did not complete"))
        }
        #expect(clock.now - start < .seconds(5))
    }

    /// A timeout large enough never fires and leaves the verdict untouched.
    @Test func generousTimeoutDoesNotChangeTheVerdict() async throws {
        let sync = try Self.syncBlob(seed: 11)
        do {
            try await forAll(.int(in: 0...1000), seed: 11, database: "", timeout: .seconds(5)) { n in
                await Task.yield()
                if n >= 10 { throw Violation() }
            }
            Issue.record("async property should have failed")
        } catch let failure as PropertyFailure {
            #expect(failure.failures.first?.reproduceBlob == sync.reproduceBlob)
        }
    }
}

@Suite struct AsyncExpectAllTests {
    @Test(.propertyTesting) func passingAsyncBody() async {
        await expectAll(.int(in: 0...100), database: "") { n in
            await Task.yield()
            #expect(n >= 0)
        }
    }

    /// The failing path reports exactly two issues, as the sync form does:
    /// the minimal counterexample summary and the body's own `#expect`
    /// replayed at that input.
    @Test(.propertyTesting) func failingAsyncBodyShrinksAndReplays() async {
        let recorded = OSAllocatedUnfairLock(initialState: [String]())
        await withKnownIssue {
            await expectAll(.int(in: 0...1000), seed: 1, database: "") { n in
                await Task.yield()
                #expect(n < 10)
            }
        } matching: { issue in
            recorded.withLock { $0.append(String(describing: issue)) }
            return true
        }
        let issues = recorded.withLock { $0 }
        #expect(issues.count == 2)
        #expect(issues.first?.contains("minimal counterexample: 10") == true)
    }
}

@Suite struct AsyncContextOverloadTests {
    /// SE-0296 prefers async overloads in async contexts; a synchronous
    /// body must still resolve to the synchronous `forAll` without `await`.
    @Test func syncBodyInAsyncContextStaysSync() async throws {
        try forAll(.int(in: 0...10), database: "") { n in
            #expect(n <= 10)
        }
    }
}
