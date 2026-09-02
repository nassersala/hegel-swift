import Hegel
import Testing

/// Each operator on a hand-written trace, including the end-of-trace
/// conventions: weak until with a right side that never arrives, `prev`
/// at position 0, `weakNext` at the last position.
@Suite struct TemporalLogic {
    let positive: Pred<Int> = now { $0 > 0 }
    let even: Pred<Int> = now { $0 % 2 == 0 }

    @Test func atomsAndConnectives() {
        #expect(evaluate(positive, over: [1, -1]))
        #expect(!evaluate(positive, over: [-1, 1]))
        #expect(evaluate(positive && even, over: [2]))
        #expect(!evaluate(positive && even, over: [1]))
        #expect(evaluate(positive || even, over: [-2]))
        #expect(evaluate(!positive, over: [-1]))
        #expect(evaluate(even => positive, over: [1]))   // vacuous
        #expect(!evaluate(even => positive, over: [-2]))
    }

    @Test func alwaysChecksEveryPosition() {
        #expect(evaluate(always(positive), over: [1, 2, 3]))
        #expect(!evaluate(always(positive), over: [1, 2, 0]))
        #expect(firstFailure(of: always(positive), over: [1, 2, 0]) == 2)
        #expect(firstFailure(of: always(positive), over: [1, 2, 3]) == nil)
        #expect(evaluate(always(positive), over: []))
    }

    @Test func weakNextLooksOneAhead() {
        #expect(evaluate(weakNext(positive), over: [-1, 1]))
        #expect(!evaluate(weakNext(positive), over: [1, -1]))
        #expect(evaluate(weakNext(positive), over: [-1]))  // last position: true
        #expect(evaluate(always(even => weakNext(positive)), over: [2, 1, 4]))
    }

    /// `weakNext` is weak, so its negation is strong: `!weakNext(p)` needs
    /// a next position and fails on a trace that ends here. The safety
    /// spelling puts the negation inside; `strongNext` is the explicit dual.
    @Test func negatedNextIsStrong() {
        let one: Pred<Int> = now { $0 == 1 }
        let two: Pred<Int> = now { $0 == 2 }
        #expect(evaluate(always(one => !weakNext(two)), over: [1, 3]))
        #expect(!evaluate(always(one => !weakNext(two)), over: [1]))      // ends in a 1: no next step
        #expect(evaluate(always(one => weakNext(!two)), over: [1]))       // the safety spelling
        #expect(!evaluate(strongNext(positive), over: [1]))
        #expect(evaluate(strongNext(positive), over: [1, 2]))
    }

    @Test func weakUntilHoldsWhenTheRightSideNeverHappens() {
        // p until q, q never: p to the end of the trace is enough.
        #expect(evaluate(weakUntil(positive, even), over: [1, 3, 5]))
        // p breaks before q.
        #expect(!evaluate(weakUntil(positive, even), over: [1, -3, 2]))
        // q arrives; p need not hold at or after it.
        #expect(evaluate(weakUntil(positive, even), over: [1, 2, -3]))
        // q at the first position.
        #expect(evaluate(weakUntil(.ff, even), over: [2, 1]))
    }

    @Test func prevIsFalseAtPositionZero() {
        #expect(!evaluate(prev(positive), over: [1, 1]))
        #expect(evaluate(always(prev(positive) => positive), over: [1, 2, 3]))
        #expect(!evaluate(always(prev(positive) => positive), over: [1, -1]))
    }

    @Test func changedComparesWithThePreviousState() {
        let grew: Pred<Int> = changed { $0 < $1 }
        #expect(!evaluate(grew, over: [1, 2]))  // position 0: no previous
        #expect(evaluate(weakNext(grew), over: [1, 2]))
        #expect(evaluate(always(weakNext(grew)), over: [1, 2, 3]))
        #expect(!evaluate(always(weakNext(grew)), over: [1, 3, 2]))
        #expect(firstFailure(of: always(weakNext(grew)), over: [1, 3, 2]) == 1)
    }
}
