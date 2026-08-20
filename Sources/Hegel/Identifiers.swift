import CHegel
import Darwin  // inet_ntop for canonical IP formatting
import Foundation

extension TestCase {
    /// Draws a UUID. With `version` set, the RFC 4122 version nibble is
    /// forced to it (conventionally 1...5) and the variant nibble to the
    /// RFC 4122 variant; without it the 128 bits are uniform, except that
    /// the nil UUID is never produced.
    public func drawUUID(version: UInt8? = nil) throws(HegelError) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        try call(hegel_generate_uuid(ctx.raw, raw, version ?? 0, version != nil, &bytes))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Draws an IPv4 address as its 4 network-order bytes.
    public func drawIPv4() throws(HegelError) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        try call(hegel_generate_ipv4(ctx.raw, raw, &bytes))
        return bytes
    }

    /// Draws an IPv6 address as its 16 network-order bytes.
    public func drawIPv6() throws(HegelError) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        try call(hegel_generate_ipv6(ctx.raw, raw, &bytes))
        return bytes
    }
}

extension Gen where Value == UUID {
    /// UUIDs: uniform 128 bits (never nil) or, with `version:`, RFC 4122
    /// version/variant-stamped.
    public static func uuid(version: UInt8? = nil) -> Gen {
        Gen { tc in try tc.drawUUID(version: version) }
    }

    public static let uuid = Gen.uuid()
}

extension Gen where Value == [UInt8] {
    /// IPv4 addresses as 4 network-order bytes.
    public static let ipv4Bytes = Gen { tc in try tc.drawIPv4() }

    /// IPv6 addresses as 16 network-order bytes.
    public static let ipv6Bytes = Gen { tc in try tc.drawIPv6() }
}

extension Gen where Value == String {
    /// IPv4 addresses in dotted-decimal form.
    public static let ipv4 = Gen { tc in formatIP(try tc.drawIPv4(), family: AF_INET) }

    /// IPv6 addresses in canonical (RFC 5952, inet_ntop) form.
    public static let ipv6 = Gen { tc in formatIP(try tc.drawIPv6(), family: AF_INET6) }
}

private func formatIP(_ bytes: [UInt8], family: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let formatted = bytes.withUnsafeBufferPointer { raw in
        inet_ntop(family, raw.baseAddress, &buffer, socklen_t(buffer.count)) != nil
    }
    precondition(formatted, "inet_ntop failed for a \(bytes.count)-byte address")
    return String(cString: buffer)
}
