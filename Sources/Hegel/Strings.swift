import CHegel
import Darwin  // strdup/free for C-string-array marshalling

/// RAII wrapper over a `hegel_string_generator_t` handle.
///
/// Immutable after construction; draws pass it as `const`, so sharing one
/// across draws (and generators built from it) is safe. Freed exactly once,
/// on deinit.
public final class StringGenerator: @unchecked Sendable {
    let raw: OpaquePointer
    private let ctx: Context

    init(ctx: Context, raw: OpaquePointer) {
        self.ctx = ctx
        self.raw = raw
    }

    deinit {
        _ = hegel_string_generator_free(ctx.raw, raw)
    }

    /// Unicode text with an alphabet carved out of a codec range, Unicode
    /// general categories, and explicit include/exclude characters — the
    /// full `hegel_string_generator_text` surface.
    public static func text(
        count: ClosedRange<UInt64> = 0...64,
        codec: String? = nil,   // "ascii", "latin-1", nil = full Unicode
        codepoints: ClosedRange<UInt32> = 0...UInt32.max,
        categories: [String]? = nil,
        excludeCategories: [String]? = nil,
        includeCharacters: String? = nil,
        excludeCharacters: String? = nil
    ) throws -> StringGenerator {
        let ctx = Context()
        var out: OpaquePointer?
        let include = Array((includeCharacters ?? "").utf8)
        let exclude = Array((excludeCharacters ?? "").utf8)
        try withCStringArray(categories) { cats, catsLen in
            try withCStringArray(excludeCategories) { excats, excatsLen in
                try include.withUnsafeBufferPointer { inc in
                    try exclude.withUnsafeBufferPointer { exc in
                        try check(hegel_string_generator_text(
                            ctx.raw,
                            count.lowerBound, count.upperBound,
                            codec,
                            codepoints.lowerBound, codepoints.upperBound,
                            cats, catsLen,
                            excats, excatsLen,
                            includeCharacters == nil ? nil : inc.baseAddress, inc.count,
                            excludeCharacters == nil ? nil : exc.baseAddress, exc.count,
                            &out), ctx.lastError)
                    }
                }
            }
        }
        return StringGenerator(ctx: ctx, raw: out!)
    }

    /// Strings matching `pattern` (Python `re` syntax). With
    /// `fullMatch: false` the match may be padded on either side.
    public static func regex(
        _ pattern: String,
        fullMatch: Bool = true,
        alphabet: StringGenerator? = nil
    ) throws -> StringGenerator {
        let ctx = Context()
        var out: OpaquePointer?
        try check(
            hegel_string_generator_regex(ctx.raw, pattern, fullMatch, alphabet?.raw, &out),
            ctx.lastError)
        return StringGenerator(ctx: ctx, raw: out!)
    }

    /// RFC 5321/5322 email addresses.
    public static func email() throws -> StringGenerator {
        let ctx = Context()
        var out: OpaquePointer?
        try check(hegel_string_generator_email(ctx.raw, &out), ctx.lastError)
        return StringGenerator(ctx: ctx, raw: out!)
    }

    /// RFC 3986 http/https URLs.
    public static func url() throws -> StringGenerator {
        let ctx = Context()
        var out: OpaquePointer?
        try check(hegel_string_generator_url(ctx.raw, &out), ctx.lastError)
        return StringGenerator(ctx: ctx, raw: out!)
    }

    /// Fully-qualified domain names, at most `maxLength` (4...255) total.
    public static func domain(maxLength: UInt64 = 255) throws -> StringGenerator {
        let ctx = Context()
        var out: OpaquePointer?
        try check(hegel_string_generator_domain(ctx.raw, maxLength, &out), ctx.lastError)
        return StringGenerator(ctx: ctx, raw: out!)
    }
}

extension TestCase {
    /// Draws a string from a string-generator handle. The engine can reject
    /// its own draw (e.g. an email exceeding the RFC length cap) — that
    /// surfaces as `HegelError.assume` and the runner redraws.
    public func drawString(using generator: StringGenerator) throws(HegelError) -> String {
        var result = hegel_generate_string_result_t()
        try call(hegel_generate_string(ctx.raw, raw, generator.raw, &result))
        defer { _ = hegel_generate_string_result_free(ctx.raw, &result) }
        // Not NUL-terminated, may contain interior NULs — always use len.
        let bytes = UnsafeRawBufferPointer(start: result.data, count: result.len)
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension Gen where Value == String {
    /// General text. See `StringGenerator.text` for the alphabet knobs.
    public static func string(
        count: ClosedRange<UInt64> = 0...64,
        codec: String? = nil,
        codepoints: ClosedRange<UInt32> = 0...UInt32.max,
        categories: [String]? = nil,
        excludeCategories: [String]? = nil
    ) -> Gen {
        // Built once, here, and shared by every draw. libhegel 0.32.5 keeps
        // a process-global entry for every string generator ever created
        // (constants_in_alphabet in hegel-c, keyed by the alphabet's
        // address, never evicted), so building one per draw grew the
        // process by about 2.5 MB per 50,000 draws and leaks --atExit
        // reported 34,000 blocks after two runs of 1000 cases with 50
        // draws each. The handle is immutable and Sendable, so capturing
        // it keeps the closure Sendable; a construction error is thrown
        // at the first draw, where it was thrown before.
        let generator = Result { try StringGenerator.text(
            count: count, codec: codec, codepoints: codepoints,
            categories: categories, excludeCategories: excludeCategories) }
        return Gen { tc in try tc.drawString(using: generator.get()) }
    }

    /// ASCII-only text.
    public static func asciiString(count: ClosedRange<UInt64> = 0...64) -> Gen {
        .string(count: count, codec: "ascii")
    }

    /// Text drawn from the Arabic Unicode blocks (U+0600–U+06FF plus
    /// supplement U+0750–U+077F falls outside this range; extend the
    /// codepoints if you need it).
    public static func arabicText(count: ClosedRange<UInt64> = 1...32) -> Gen {
        .string(count: count, codepoints: 0x0600...0x06FF)
    }

    /// Strings matching a regular expression (Python `re` syntax).
    public static func regex(_ pattern: String, fullMatch: Bool = true) -> Gen {
        let generator = Result { try StringGenerator.regex(pattern, fullMatch: fullMatch) }
        return Gen { tc in try tc.drawString(using: generator.get()) }
    }

    /// RFC-shaped email addresses.
    public static let email: Gen = {
        let generator = Result { try StringGenerator.email() }
        return Gen { tc in try tc.drawString(using: generator.get()) }
    }()

    /// RFC 3986 http/https URLs.
    public static let url: Gen = {
        let generator = Result { try StringGenerator.url() }
        return Gen { tc in try tc.drawString(using: generator.get()) }
    }()
}

/// Marshals an optional Swift string array as `const char *const *` + len.
/// nil array → (nil, 0), which the ABI reads as "no restriction".
func withCStringArray<R>(
    _ strings: [String]?,
    _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) throws -> R
) throws -> R {
    guard let strings else { return try body(nil, 0) }
    let duplicated: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    defer { duplicated.forEach { free($0) } }
    let constPointers = duplicated.map { UnsafePointer($0) }
    return try constPointers.withUnsafeBufferPointer { buffer in
        try body(buffer.baseAddress, strings.count)
    }
}
