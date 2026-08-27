/// A generator of `Value`s — the library's one abstraction.
///
/// `Gen` is a protocol witness, not a protocol: there is deliberately no
/// `Arbitrary` conformance to write. A generator is a value you construct,
/// name, compose, and pass explicitly. A type can have as many generators
/// as it has meanings (`.anyUser`, `.adultUser`, …) with no conformance
/// clashes. See the README's "Why" section.
///
/// Shrinking needs no code here at all: libhegel shrinks the underlying
/// choice sequence and `run` re-interprets it, so every generator built
/// from these combinators — however deeply composed — shrinks correctly
/// by construction and can never produce a value the generator itself
/// couldn't.
public struct Gen<Value>: Sendable {
    public let run: @Sendable (TestCase) throws -> Value

    public init(run: @escaping @Sendable (TestCase) throws -> Value) {
        self.run = run
    }
}

// MARK: - Combinators

extension Gen {
    /// Transforms every generated value. Shrinking passes through untouched.
    public func map<B>(_ f: @escaping @Sendable (Value) -> B) -> Gen<B> {
        Gen<B> { tc in f(try self.run(tc)) }
    }

    /// Generates a value, then uses it to pick the next generator.
    /// (Unlike rose-tree PBT libraries, monadic bind costs nothing in
    /// shrink quality here — shrinking happens below the value level.)
    public func flatMap<B>(_ f: @escaping @Sendable (Value) -> Gen<B>) -> Gen<B> {
        Gen<B> { tc in try f(self.run(tc)).run(tc) }
    }

    /// Rejects values failing `predicate`. Rejection is reported to
    /// libhegel as an assumption failure (the case is INVALID, redrawn,
    /// and does not count against the test budget). Prefer constructive
    /// generation over heavy filtering — the engine's health checks will
    /// abort a run that filters too much.
    public func filter(_ predicate: @escaping @Sendable (Value) -> Bool) -> Gen<Value> {
        Gen { tc in
            let value = try self.run(tc)
            guard predicate(value) else { throw HegelError.assume }
            return value
        }
    }
}

/// A tuple of generators becomes a generator of tuples — how tuples (and,
/// via `.map(Struct.init)`, your domain types) get generation without any
/// conformance machinery.
///
/// Fixed arities 2–4 exist alongside the parameter-pack form below because
/// they let the compiler infer element types backwards from `.map(T.init)`
/// (`.int(in: 0...120)` becomes `Int` because `User.age` is); through a
/// pack that inference does not happen. Five or more generators use the
/// pack; spell the element types when the compiler asks.
public func zip<A, B>(_ a: Gen<A>, _ b: Gen<B>) -> Gen<(A, B)> {
    Gen { tc in (try a.run(tc), try b.run(tc)) }
}

public func zip<A, B, C>(_ a: Gen<A>, _ b: Gen<B>, _ c: Gen<C>) -> Gen<(A, B, C)> {
    Gen { tc in (try a.run(tc), try b.run(tc), try c.run(tc)) }
}

public func zip<A, B, C, D>(
    _ a: Gen<A>, _ b: Gen<B>, _ c: Gen<C>, _ d: Gen<D>
) -> Gen<(A, B, C, D)> {
    Gen { tc in (try a.run(tc), try b.run(tc), try c.run(tc), try d.run(tc)) }
}

/// Any arity.
public func zip<each G>(_ gen: repeat Gen<each G>) -> Gen<(repeat each G)> {
    Gen { tc in (repeat try (each gen).run(tc)) }
}
