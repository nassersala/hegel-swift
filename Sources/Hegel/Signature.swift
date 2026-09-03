/// Signature laws: the generators read off the closure's parameter types.
///
///     try forAll { (e: Edit, d: String, h: [Entry]) in
///         if meaning(undo(record(e, d, h)))(meaning(e)(d)) != d { throw LawViolated("undo") }
///     }
///
/// This is sugar. The call lowers onto the ordinary `forAll` over
/// `zip(Edit.gen, String.gen, [Entry].gen)`: same run, same shrinking,
/// same reproduce blob, and the same counterexample under the same seed.
///
/// `Gen.swift` says there is no `Arbitrary` conformance to write, and this
/// file is the one place a type-to-generator conformance exists, so the
/// terms are stated here. `DefaultGen` is a default, not a meaning: it is
/// consulted only when the call site names no generator at all, and any
/// explicit `Gen` argument wins. A type keeps every generator it has
/// (`.anyUser`, `.adultUser`, …); conforming names one of them as the one
/// a bare signature draws from. The conformances shipped are the standard
/// types with an obvious small default, chosen the way the `GenConvertible`
/// conversions are: conservative, and none where a default would be a
/// decision (no floating point, no dictionaries).
public protocol DefaultGen {
    /// The generator a bare signature draws from.
    static var gen: Gen<Self> { get }
}

// MARK: - Standard conformances

extension Int: DefaultGen {
    /// Small magnitudes: arithmetic laws stay readable and never overflow.
    public static var gen: Gen<Int> { .int(in: -100...100) }
}

extension Bool: DefaultGen {
    public static var gen: Gen<Bool> { .bool }
}

extension String: DefaultGen {
    /// Short ASCII: counterexamples print as typed. Shrinks toward `"0"`.
    public static var gen: Gen<String> { .asciiString(count: 0...8) }
}

extension Array: DefaultGen where Element: DefaultGen {
    /// Up to eight elements; shrinks by deleting them.
    public static var gen: Gen<[Element]> { array(of: Element.gen, count: 0...8) }
}

extension Optional: DefaultGen where Wrapped: DefaultGen {
    /// `nil` first, so a counterexample shrinks toward it.
    public static var gen: Gen<Wrapped?> {
        oneOf([Gen<Wrapped?> { _ in nil }, Wrapped.gen.map { Optional.some($0) }])
    }
}

// MARK: - forAll from the signature, arity 1 to 4

/// `forAll { (n: Int) in ... }`: the generator is `Int.gen`.
public func forAll<A: DefaultGen>(
    testCases: UInt64? = nil,
    seed: UInt64? = nil,
    database: String? = nil,
    settings: Settings = Settings(),
    file: StaticString = #fileID,
    line: UInt = #line,
    _ property: (A) throws -> Void
) throws {
    try forAll(A.gen, testCases: testCases, seed: seed, database: database,
               settings: settings, file: file, line: line, property)
}

public func forAll<A: DefaultGen, B: DefaultGen>(
    testCases: UInt64? = nil,
    seed: UInt64? = nil,
    database: String? = nil,
    settings: Settings = Settings(),
    file: StaticString = #fileID,
    line: UInt = #line,
    _ property: (A, B) throws -> Void
) throws {
    try forAll(zip(A.gen, B.gen), testCases: testCases, seed: seed, database: database,
               settings: settings, file: file, line: line) { drawn in try property(drawn.0, drawn.1) }
}

public func forAll<A: DefaultGen, B: DefaultGen, C: DefaultGen>(
    testCases: UInt64? = nil,
    seed: UInt64? = nil,
    database: String? = nil,
    settings: Settings = Settings(),
    file: StaticString = #fileID,
    line: UInt = #line,
    _ property: (A, B, C) throws -> Void
) throws {
    try forAll(zip(A.gen, B.gen, C.gen), testCases: testCases, seed: seed, database: database,
               settings: settings, file: file, line: line) { drawn in try property(drawn.0, drawn.1, drawn.2) }
}

public func forAll<A: DefaultGen, B: DefaultGen, C: DefaultGen, D: DefaultGen>(
    testCases: UInt64? = nil,
    seed: UInt64? = nil,
    database: String? = nil,
    settings: Settings = Settings(),
    file: StaticString = #fileID,
    line: UInt = #line,
    _ property: (A, B, C, D) throws -> Void
) throws {
    try forAll(zip(A.gen, B.gen, C.gen, D.gen), testCases: testCases, seed: seed, database: database,
               settings: settings, file: file, line: line) { drawn in
        try property(drawn.0, drawn.1, drawn.2, drawn.3)
    }
}
