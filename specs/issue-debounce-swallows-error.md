# Draft issue: `debounce` drops an upstream error when no demand is outstanding

Target: apple/swift-async-algorithms 1.1.5; identical on main (a5195af, 2026-08-09).
Status: filed 2026-08-26 as apple/swift-async-algorithms#450. Found by `Examples/AsyncProperties` in hegel-swift.

## Summary

If the base sequence throws while the consumer is not suspended in `next()`, the error is discarded and the next `next()` returns `nil`. The consumer sees a normal completion.

## Reproduction

```swift
struct Boom: Error {}
let stream = AsyncThrowingStream<Int, any Error> { continuation in
    continuation.yield(1)
    Task {
        try? await Task.sleep(for: .milliseconds(100))
        continuation.finish(throwing: Boom())
    }
}
var iterator = stream.debounce(for: .milliseconds(10)).makeAsyncIterator()
_ = try await iterator.next()                  // 1
try await Task.sleep(for: .milliseconds(300))  // consumer busy; upstream throws meanwhile
try await iterator.next()                      // nil; expected: throws Boom
```

Without the sleep, so the consumer is waiting in `next()` when the upstream throws, `Boom` is thrown.

Validation diagram form. Value at tick 1, failure at tick 2, consumer away until tick 5:

```swift
validate {
    "a^"
    $0.inputs[0].debounce(for: .steps(0), clock: $0.clock)
    "a,,,^"   // actual: "a,,,|"
}
```

The minimal form, `"a^"` with `.steps(1)` and a continuous consumer, gives `"-[a|]"` where `"-[a^]"` is expected; there the deadline and the failure share a tick, so the gap form above is the clearer one.

The package's Debounce guide states the operator "throws when the base type throws".

## Cause

`DebounceStateMachine.upstreamThrew(_:)`, case `.waitingForDemand(task, .none, clockContinuation, .none)`:

```swift
self.state = .finished
return .cancelTaskAndClockContinuation(task: task, clockContinuation: clockContinuation)
```

The error is not stored. `.upstreamFailure(error)` exists for this case and `next()` already handles it (`resumeDownstreamContinuationWithError`), but nothing in the file ever assigns that state; this branch copies the normal-finish transition instead. `elementProduced` in the same state buffers the element, so a value arriving here survives and an error does not.

## Fix

Transition to `.upstreamFailure(error)` in that branch and keep cancelling the clock continuation. The following `next()` then throws.

## Related

#269 had a different cause (a Swift 5.8 change in `group.waitForAll`, fixed by #254 before 1.0) and a different symptom (a stall).
