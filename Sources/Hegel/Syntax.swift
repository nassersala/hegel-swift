/// Spellings. Nothing here adds meaning; every form lowers onto `Gen`,
/// `Laws`, `Relation`, or `forAll` as they already exist. The point is
/// discovery: the named forms are the questions the library asks on the
/// user's behalf, and autocomplete is where a user meets them.

// MARK: - Drawing from a generator inside a property or another generator

extension TestCase {
    /// Draws a value from `gen`: the context-first way to build a
    /// generator that depends on earlier draws, without nested `flatMap`.
    ///
    ///     let order = Gen<Order> { tc in
    ///         let customer = try tc.draw(.customer)
    ///         let lines = try tc.draw(.array(of: .lineItem, count: 1...10))
    ///         return Order(customer: customer, lines: lines)
    ///     }
    public func draw<A>(_ gen: Gen<A>) throws -> A {
        try gen.run(self)
    }
}

// MARK: - Leading-dot spellings for the combinators

extension Gen {
    /// A generator of one value.
    public static func constant(_ value: Value) -> Gen where Value: Sendable {
        Gen { _ in value }
    }

    /// `array(of:count:)`, reachable with a leading dot in argument position.
    public static func array<A>(of element: Gen<A>, count: ClosedRange<UInt64> = 0...UInt64.max) -> Gen
    where Value == [A] {
        Hegel.array(of: element, count: count)
    }

    /// `oneOf`, reachable with a leading dot.
    public static func oneOf(_ gens: [Gen<Value>]) -> Gen {
        Hegel.oneOf(gens)
    }

    /// `element(of:)`, reachable with a leading dot.
    public static func element(of values: [Value]) -> Gen where Value: Sendable {
        Hegel.element(of: values)
    }

    /// `frequency`, reachable with a leading dot.
    public static func frequency(_ weighted: [(weight: Int, gen: Gen<Value>)]) -> Gen {
        Hegel.frequency(weighted)
    }
}

// MARK: - Ranges and arrays where a generator is expected

/// Things with an obvious generator: an integer range draws from it.
/// Conversion is conservative on purpose: no literals, no floating-point
/// ranges (their bounds need decisions about NaN and infinity), no arrays
/// (a conformance cannot depend on `Element: Sendable`; use
/// `.element(of:)`), no dictionaries.
public protocol GenConvertible {
    associatedtype Value
    var gen: Gen<Value> { get }
}

extension ClosedRange: GenConvertible where Bound == Int {
    public var gen: Gen<Int> { .int(in: self) }
}

/// `forAll(1...100) { n in ... }`
public func forAll<G: GenConvertible>(
    _ domain: G,
    testCases: UInt64? = nil,
    seed: UInt64? = nil,
    database: String? = nil,
    settings: Settings = Settings(),
    file: StaticString = #fileID,
    line: UInt = #line,
    _ property: (G.Value) throws -> Void
) throws {
    try forAll(
        domain.gen, testCases: testCases, seed: seed, database: database,
        settings: settings, file: file, line: line, property)
}

// MARK: - Subject-first laws

/// A law of one function `T -> T`. Autocomplete after `is:` lists them.
public struct UnaryLaw<T>: Sendable {
    let suite: @Sendable (Gen<T>, String, @escaping @Sendable (T) -> T, @escaping @Sendable (T, T) -> Bool) -> LawSuite

    /// `f(f(a)) == f(a)`: `sorted`, `normalized`, `trimmed`.
    public static var idempotent: UnaryLaw { UnaryLaw { Laws.idempotent($0, $1, $2, equal: $3) } }
    /// `f(f(a)) == a`: `reversed`, negation, conjugation.
    public static var involution: UnaryLaw { UnaryLaw { Laws.involution($0, $1, $2, equal: $3) } }
}

/// A law of one binary operation `(T, T) -> T`.
public struct BinaryLaw<T>: Sendable {
    let suite: @Sendable (Gen<T>, String, @escaping @Sendable (T, T) -> T, @escaping @Sendable (T, T) -> Bool) -> LawSuite

    /// `(a op b) op c == a op (b op c)`: a semigroup.
    public static var associative: BinaryLaw { BinaryLaw { Laws.semigroup($0, $1, $2, equal: $3) } }
    /// `a op b == b op a`.
    public static var commutative: BinaryLaw { BinaryLaw { Laws.commutative($0, $1, $2, equal: $3) } }
    /// `a op a == a`: `max`, union.
    public static var idempotent: BinaryLaw { BinaryLaw { Laws.idempotent($0, $1, $2, equal: $3) } }
}

/// A law of a binary operation with an identity.
public struct MonoidLaw<T: Sendable>: Sendable {
    let suite: @Sendable (Gen<T>, String, @escaping @Sendable (T, T) -> T, T, @escaping @Sendable (T, T) -> Bool) -> LawSuite

    /// Associativity and two-sided identity.
    public static var monoid: MonoidLaw { MonoidLaw { Laws.monoid($0, $1, $2, identity: $3, equal: $4) } }
    /// A commutative, idempotent monoid: the CRDT merge contract.
    public static var semilattice: MonoidLaw { MonoidLaw { Laws.semilattice($0, $1, $2, identity: $3, equal: $4) } }
}

/// A law of a pair of functions `A -> B`, `B -> A`.
public struct PairLaw<A, B>: Sendable {
    let suite: @Sendable (Gen<A>, String, @escaping @Sendable (A) -> B, String, @escaping @Sendable (B) -> A, @escaping @Sendable (A, A) -> Bool) -> LawSuite

    /// `from(to(a)) == a`: decode ∘ encode, parse ∘ print.
    public static var retraction: PairLaw { PairLaw { Laws.retraction($0, to: $1, $2, from: $3, $4, equal: $5) } }
}

/// `try forAll(sort, is: .idempotent, on: .array(of: .int(in: 0...9)))`
public func forAll<T>(
    _ f: @escaping @Sendable (T) -> T, is law: UnaryLaw<T>, on gen: Gen<T>,
    label: String = "f", equal: @escaping @Sendable (T, T) -> Bool,
    testCases: UInt64? = nil, seed: UInt64? = nil, database: String? = nil,
    settings: Settings = Settings(), file: StaticString = #fileID, line: UInt = #line
) throws {
    try forAll(law.suite(gen, label, f, equal), testCases: testCases, seed: seed,
               database: database, settings: settings, file: file, line: line)
}

public func forAll<T: Equatable>(
    _ f: @escaping @Sendable (T) -> T, is law: UnaryLaw<T>, on gen: Gen<T>, label: String = "f",
    testCases: UInt64? = nil, seed: UInt64? = nil, database: String? = nil,
    settings: Settings = Settings(), file: StaticString = #fileID, line: UInt = #line
) throws {
    try forAll(f, is: law, on: gen, label: label, equal: ==, testCases: testCases, seed: seed,
               database: database, settings: settings, file: file, line: line)
}

/// `try forAll(+, is: .associative, on: .int(in: -100...100))`
public func forAll<T>(
    _ op: @escaping @Sendable (T, T) -> T, is law: BinaryLaw<T>, on gen: Gen<T>,
    label: String = "op", equal: @escaping @Sendable (T, T) -> Bool,
    testCases: UInt64? = nil, seed: UInt64? = nil, database: String? = nil,
    settings: Settings = Settings(), file: StaticString = #fileID, line: UInt = #line
) throws {
    try forAll(law.suite(gen, label, op, equal), testCases: testCases, seed: seed,
               database: database, settings: settings, file: file, line: line)
}

public func forAll<T: Equatable>(
    _ op: @escaping @Sendable (T, T) -> T, is law: BinaryLaw<T>, on gen: Gen<T>, label: String = "op",
    testCases: UInt64? = nil, seed: UInt64? = nil, database: String? = nil,
    settings: Settings = Settings(), file: StaticString = #fileID, line: UInt = #line
) throws {
    try forAll(op, is: law, on: gen, label: label, equal: ==, testCases: testCases, seed: seed,
               database: database, settings: settings, file: file, line: line)
}

/// `try forAll(+, 0, are: .monoid, on: .int(in: -100...100))`
public func forAll<T: Sendable>(
    _ op: @escaping @Sendable (T, T) -> T, _ identity: T, are law: MonoidLaw<T>, on gen: Gen<T>,
    label: String = "op", equal: @escaping @Sendable (T, T) -> Bool,
    testCases: UInt64? = nil, seed: UInt64? = nil, database: String? = nil,
    settings: Settings = Settings(), file: StaticString = #fileID, line: UInt = #line
) throws {
    try forAll(law.suite(gen, label, op, identity, equal), testCases: testCases, seed: seed,
               database: database, settings: settings, file: file, line: line)
}

public func forAll<T: Sendable & Equatable>(
    _ op: @escaping @Sendable (T, T) -> T, _ identity: T, are law: MonoidLaw<T>, on gen: Gen<T>, label: String = "op",
    testCases: UInt64? = nil, seed: UInt64? = nil, database: String? = nil,
    settings: Settings = Settings(), file: StaticString = #fileID, line: UInt = #line
) throws {
    try forAll(op, identity, are: law, on: gen, label: label, equal: ==, testCases: testCases, seed: seed,
               database: database, settings: settings, file: file, line: line)
}

/// `try forAll(encode, decode, are: .retraction, on: .users)`
public func forAll<A, B>(
    _ to: @escaping @Sendable (A) -> B, _ from: @escaping @Sendable (B) -> A, are law: PairLaw<A, B>, on gen: Gen<A>,
    labels: (String, String) = ("to", "from"), equal: @escaping @Sendable (A, A) -> Bool,
    testCases: UInt64? = nil, seed: UInt64? = nil, database: String? = nil,
    settings: Settings = Settings(), file: StaticString = #fileID, line: UInt = #line
) throws {
    try forAll(law.suite(gen, labels.0, to, labels.1, from, equal), testCases: testCases, seed: seed,
               database: database, settings: settings, file: file, line: line)
}

public func forAll<A: Equatable, B>(
    _ to: @escaping @Sendable (A) -> B, _ from: @escaping @Sendable (B) -> A, are law: PairLaw<A, B>, on gen: Gen<A>,
    labels: (String, String) = ("to", "from"),
    testCases: UInt64? = nil, seed: UInt64? = nil, database: String? = nil,
    settings: Settings = Settings(), file: StaticString = #fileID, line: UInt = #line
) throws {
    try forAll(to, from, are: law, on: gen, labels: labels, equal: ==, testCases: testCases, seed: seed,
               database: database, settings: settings, file: file, line: line)
}

// MARK: - Key-path relations

extension Relation {
    /// The change-direction pattern with the follow-up written as a key
    /// path: bump one field by a drawn amount, observe one aspect of the
    /// output, state the direction. "A larger fajr angle gives an earlier
    /// or equal fajr" is
    ///
    ///     .monotone("fajr angle up", bumping: \.params.fajrAngle, by: .int(in: 1...6),
    ///               observing: \.fajr, .nonIncreasing)
    ///
    /// The drawn amount is part of the choice sequence and shrinks. General
    /// closures remain for follow-ups that are not a bump of one field.
    public static func monotone<P: AdditiveArithmetic & Sendable, V: Comparable & SendableMetatype>(
        _ name: String,
        bumping field: WritableKeyPath<Input, P> & Sendable, by delta: Gen<P>,
        observing value: KeyPath<Output, V> & Sendable, _ direction: Monotonicity
    ) -> Relation {
        monotone(name, followUp: { input, tc in
            var followUp = input
            followUp[keyPath: field] += try delta.run(tc)
            return followUp
        }, { $0[keyPath: value] }, direction)
    }
}

extension Relation where Output: Equatable & SendableMetatype {
    /// The symmetry pattern with the follow-up as a key path: shifting one
    /// field by a drawn amount leaves the output unchanged.
    ///
    ///     .invariant("longitude period", shifting: \.longitude, by: .constant(360))
    public static func invariant<P: AdditiveArithmetic & Sendable>(
        _ name: String,
        shifting field: WritableKeyPath<Input, P> & Sendable, by delta: Gen<P>
    ) -> Relation {
        invariant(name) { input, tc in
            var followUp = input
            followUp[keyPath: field] += try delta.run(tc)
            return followUp
        }
    }
}
