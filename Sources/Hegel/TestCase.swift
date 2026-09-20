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

/// One engine test-case handle, shared by every copy of the `TestCase`
/// that wraps it. `TestCase` is a copyable value, so a property or a
/// generator can keep one past the invocation it was handed to, and the
/// case is freed when that invocation ends. `end` frees the handle and
/// leaves NULL behind for the copies, which libhegel answers with
/// HEGEL_E_INVALID_HANDLE rather than reading freed memory.
///
/// Not synchronised: `TestCase` is not `Sendable`, so the copies are on the
/// task that drives the case, which is also the one that ends it.
final class CaseHandle {
    private(set) var raw: OpaquePointer?

    init(_ raw: OpaquePointer) { self.raw = raw }

    func end(_ ctx: Context) {
        _ = hegel_test_case_free(ctx.raw, raw)
        raw = nil
    }
}

/// A single test case: the handle a test body draws generated values from.
///
/// This is what `Gen.run` receives. It wraps the `(hegel_context_t*,
/// hegel_test_case_t*)` pair every draw call needs, and owns neither —
/// the `Runner` manages both lifetimes around the test body.
///
/// A `TestCase` is valid for the one invocation it is passed to. A copy
/// kept past it throws `HegelError.invalidArgument` from every draw.
public struct TestCase {
    let ctx: Context
    private let handle: CaseHandle

    init(ctx: Context, raw: OpaquePointer) {
        self.ctx = ctx
        self.handle = CaseHandle(raw)
    }

    /// NULL once the case has ended.
    var raw: OpaquePointer? { handle.raw }

    /// Frees the engine handle. Called once by whoever made the case, when
    /// the invocation it was made for is over.
    func end() { handle.end(ctx) }

    @inline(__always)
    func call(_ code: hegel_result_t) throws(HegelError) {
        try check(code, raw == nil ? "this TestCase's test case has ended; a TestCase is valid only for the invocation it was passed to" : ctx.lastError)
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

    /// A span label for the generator called `name`: the 64-bit FNV-1a
    /// hash of its UTF-8 bytes, which is what `hegel_label_from_name`
    /// computes (AbiMirrorTests holds the two equal). A label means nothing to
    /// the engine beyond identity: spans with the same label are taken to
    /// come from the same generator, and so to be candidates for swapping,
    /// duplicating and reordering with each other. Prefix the name with
    /// your library's; `hegel.<kind>` names are libhegel's own.
    public static func label(_ name: String) -> UInt64 {
        fnv1a(fnvOffsetBasis, name.utf8)
    }

    /// The label for a generator built from others: its own label first,
    /// its components' after, so a list of integers and a list of strings
    /// differ while every list of integers agrees. What
    /// `hegel_label_combine` computes: FNV-1a continued over each label's
    /// little-endian bytes. Order matters, and combining one label does
    /// not give it back.
    public static func label(combining labels: [UInt64]) -> UInt64 {
        labels.reduce(fnvOffsetBasis) { hash, label in
            withUnsafeBytes(of: label.littleEndian) { fnv1a(hash, $0) }
        }
    }

    private static let fnvOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static func fnv1a(_ hash: UInt64, _ bytes: some Sequence<UInt8>) -> UInt64 {
        bytes.reduce(hash) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
    }

    static let listLabel = label("hegel-swift.list")
    static let statefulRuleLabel = label("hegel-swift.stateful.rule")

    /// Groups the draws made inside `body` into a span, so the shrinker
    /// treats them as one unit. Every compound generator should use this.
    /// Derive `label` with `TestCase.label(_:)`.
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
    /// invoked once per element. The whole draw sits in a list-labelled
    /// span, as in the reference bindings: the engine's generation reads
    /// span structure, so leaving it out changes the choice sequence (the
    /// conformance harness diverged at case 11 of the lists program
    /// without it).
    public func drawCollection<A>(
        count sizes: ClosedRange<UInt64>,
        element: () throws -> A
    ) throws -> [A] {
        // The element type stands in for the element generator's label, as
        // the type name does in the reference frontend: `Gen` is a closure
        // with no label of its own. Without it every list shares a label,
        // the engine's mutation copies a list of integers over a list of
        // booleans, and the lists conformance program parts from the
        // reference at case 11, where mutation starts.
        let label = Self.label(combining: [Self.listLabel, Self.label(String(reflecting: A.self))])
        return try span(label: label) {
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
}
