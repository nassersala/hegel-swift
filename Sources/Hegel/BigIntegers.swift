import CHegel

/// Integer draws beyond `int64_t`, over `hegel_generate_integer_big`: the
/// ABI takes bounds (and returns the value) as two's-complement
/// little-endian signed byte buffers.

extension TestCase {
    /// Draws from any fixed-width integer range via the big-integer ABI.
    /// Unsigned types get one extra zero (sign) byte so values with the top
    /// bit set stay non-negative on the wire.
    func drawIntegerBig<T: FixedWidthInteger>(in range: ClosedRange<T>) throws(HegelError) -> T {
        let width = T.bitWidth / 8
        let bufferWidth = width + (T.isSigned ? 0 : 1)

        func encode(_ value: T) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: bufferWidth)
            withUnsafeBytes(of: value.littleEndian) { raw in
                bytes.replaceSubrange(0..<width, with: raw)
            }
            return bytes
        }

        var out = [UInt8](repeating: 0, count: bufferWidth)
        var outLen = 0
        let minBytes = encode(range.lowerBound)
        let maxBytes = encode(range.upperBound)
        try call(hegel_generate_integer_big(
            ctx.raw, raw,
            minBytes, minBytes.count,
            maxBytes, maxBytes.count,
            &out, out.count, &outLen))

        // libhegel sign-fills up to the requested capacity, so the first
        // T.bitWidth bits are the drawn value (an unsigned draw's extra
        // sign byte is necessarily zero within the given bounds).
        var value = T.zero
        withUnsafeMutableBytes(of: &value) { raw in
            raw.copyBytes(from: out[0..<width])
        }
        return T(littleEndian: value)
    }

    /// Draws an unsigned 64-bit integer in `range` (inclusive).
    public func drawInteger(in range: ClosedRange<UInt64>) throws(HegelError) -> UInt64 {
        try drawIntegerBig(in: range)
    }

    /// Draws a signed 128-bit integer in `range` (inclusive).
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public func drawInteger(in range: ClosedRange<Int128>) throws(HegelError) -> Int128 {
        try drawIntegerBig(in: range)
    }

    /// Draws an unsigned 128-bit integer in `range` (inclusive).
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public func drawInteger(in range: ClosedRange<UInt128>) throws(HegelError) -> UInt128 {
        try drawIntegerBig(in: range)
    }
}

extension Gen where Value == UInt64 {
    /// Unsigned 64-bit integers, shrinking toward small magnitudes.
    public static func int(in range: ClosedRange<UInt64> = 0...UInt64.max) -> Gen {
        Gen { tc in try tc.drawInteger(in: range) }
    }
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Gen where Value == Int128 {
    /// Signed 128-bit integers, shrinking toward small magnitudes.
    public static func int(in range: ClosedRange<Int128> = Int128.min...Int128.max) -> Gen {
        Gen { tc in try tc.drawInteger(in: range) }
    }
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Gen where Value == UInt128 {
    /// Unsigned 128-bit integers, shrinking toward small magnitudes.
    public static func int(in range: ClosedRange<UInt128> = 0...UInt128.max) -> Gen {
        Gen { tc in try tc.drawInteger(in: range) }
    }
}
