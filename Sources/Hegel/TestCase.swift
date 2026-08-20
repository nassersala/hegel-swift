import CHegel

/// A libhegel error-reporting context. One per runner thread; libhegel
/// forbids sharing a context across threads.
final class Context {
    let raw: OpaquePointer

    init() {
        // hegel_context_new never returns NULL.
        self.raw = hegel_context_new()
    }

    /// The diagnostic recorded by the most recent failing call on this
    /// context. Borrowed pointer — copy immediately.
    var lastError: String {
        guard let p = hegel_context_last_error(raw) else { return "" }
        return String(cString: p)
    }

    deinit {
        _ = hegel_context_free(raw)
    }
}

/// A single test case: the handle a test body draws generated values from.
///
/// This is what `Gen.run` receives. It wraps the `(hegel_context_t*,
/// hegel_test_case_t*)` pair every draw call needs, and owns neither —
/// the `Runner` manages both lifetimes around the test body.
public struct TestCase {
    let ctx: Context
    let raw: OpaquePointer

    @inline(__always)
    func call(_ code: hegel_result_t) throws(HegelError) {
        try check(code, ctx.lastError)
    }

    // MARK: - Scalar draws

    /// Draws an integer in `range` (inclusive bounds, per the ABI).
    public func drawInteger(in range: ClosedRange<Int64>) throws(HegelError) -> Int64 {
        var out: Int64 = 0
        try call(hegel_generate_integer(ctx.raw, raw, range.lowerBound, range.upperBound, &out))
        return out
    }

    /// Draws a boolean that is `true` with probability `p`.
    public func drawBool(probability p: Double = 0.5) throws(HegelError) -> Bool {
        var out = false
        try call(hegel_generate_boolean(ctx.raw, raw, p, false, false, &out))
        return out
    }

    /// Draws a double in `[min, max]`. Mirrors `hegel_generate_float` with
    /// width 64; the remaining knobs are surfaced as parameters with the
    /// ABI's "no restriction" defaults.
    public func drawDouble(
        min: Double = -.infinity,
        max: Double = .infinity,
        allowNaN: Bool = false,
        allowInfinity: Bool = false,
        smallestNonzeroMagnitude: Double = 5e-324
    ) throws(HegelError) -> Double {
        var out: Double = 0
        try call(hegel_generate_float(
            ctx.raw, raw, 64, min, max,
            allowNaN, allowInfinity,
            false, false,
            smallestNonzeroMagnitude, &out))
        return out
    }

    /// Draws a byte buffer whose length libhegel picks in `sizes`.
    public func drawBytes(count sizes: ClosedRange<UInt64>) throws(HegelError) -> [UInt8] {
        var result = hegel_generate_bytes_result_t()
        try call(hegel_generate_bytes(ctx.raw, raw, sizes.lowerBound, sizes.upperBound, &result))
        defer { _ = hegel_generate_bytes_result_free(ctx.raw, &result) }
        return Array(UnsafeBufferPointer(start: result.data, count: result.len))
    }

    // MARK: - Structure

    /// Groups the draws made inside `body` into a span, so the shrinker
    /// treats them as one unit. Every compound generator should use this.
    /// `label` must be a stable value not reserved by libhegel (see the
    /// hegel_label_t constants in hegel.h).
    public func span<A>(label: UInt64, _ body: () throws -> A) throws -> A {
        try call(hegel_start_span(ctx.raw, raw, label))
        do {
            let value = try body()
            try call(hegel_stop_span(ctx.raw, raw, false))
            return value
        } catch {
            // A rejected/failed span is discarded so libhegel retries from
            // before it opened.
            _ = hegel_stop_span(ctx.raw, raw, true)
            throw error
        }
    }

    /// Draws a variable-length collection: libhegel decides the length
    /// (within `sizes`) so the shrinker can delete elements; `element` is
    /// invoked once per element.
    public func drawCollection<A>(
        count sizes: ClosedRange<UInt64>,
        element: () throws -> A
    ) throws -> [A] {
        var collection: OpaquePointer?
        try call(hegel_new_collection(ctx.raw, raw, sizes.lowerBound, sizes.upperBound, &collection))
        defer { _ = hegel_collection_free(ctx.raw, collection) }
        var out: [A] = []
        while true {
            var more = false
            try call(hegel_collection_more(ctx.raw, raw, collection, &more))
            guard more else { break }
            out.append(try element())
        }
        return out
    }
}
