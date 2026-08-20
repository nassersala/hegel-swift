/// Primitive generators: thin witnesses over libhegel's typed draws.

extension Gen where Value == Int64 {
    /// Integers in `range`, shrinking toward small magnitudes.
    public static func int(in range: ClosedRange<Int64>) -> Gen {
        Gen { tc in try tc.drawInteger(in: range) }
    }
}

extension Gen where Value == Int {
    public static func int(in range: ClosedRange<Int>) -> Gen {
        Gen { tc in
            Int(try tc.drawInteger(in: Int64(range.lowerBound)...Int64(range.upperBound)))
        }
    }
}

extension Gen where Value == Bool {
    /// Booleans, `true` with probability `p`.
    public static func bool(probability p: Double = 0.5) -> Gen {
        Gen { tc in try tc.drawBool(probability: p) }
    }

    public static let bool = Gen.bool()
}

extension Gen where Value == Double {
    public static func double(
        in range: ClosedRange<Double> = -.infinity ... .infinity,
        allowNaN: Bool = false,
        allowInfinity: Bool = false
    ) -> Gen {
        Gen { tc in
            try tc.drawDouble(
                min: range.lowerBound, max: range.upperBound,
                allowNaN: allowNaN, allowInfinity: allowInfinity)
        }
    }
}

extension Gen where Value == [UInt8] {
    public static func bytes(count: ClosedRange<UInt64>) -> Gen {
        Gen { tc in try tc.drawBytes(count: count) }
    }
}

/// Variable-length arrays: libhegel owns the length decision (so the
/// shrinker can delete elements), the element generator interprets each slot.
public func array<A>(of element: Gen<A>, count: ClosedRange<UInt64> = 0...UInt64.max) -> Gen<[A]> {
    Gen { tc in
        try tc.drawCollection(count: count) { try element.run(tc) }
    }
}

/// Picks one of the given generators, then runs it.
public func oneOf<A>(_ gens: [Gen<A>]) -> Gen<A> {
    precondition(!gens.isEmpty, "oneOf requires at least one generator")
    return Gen { tc in
        let index = Int(try tc.drawInteger(in: 0...Int64(gens.count - 1)))
        return try gens[index].run(tc)
    }
}

/// Picks one of the given constants.
public func element<A: Sendable>(of values: [A]) -> Gen<A> {
    precondition(!values.isEmpty, "element(of:) requires at least one value")
    return Gen { tc in
        values[Int(try tc.drawInteger(in: 0...Int64(values.count - 1)))]
    }
}

// TODO: string generators (hegel_string_generator_text/regex/email/url/domain
//       + hegel_generate_string — generator handles need an RAII wrapper),
//       dates/times/UUIDs/IPs, big integers, pools and state machines
//       (stateful testing), hegel_target (targeted PBT).
