import Testing
import Hegel
import CryptoKit
import Foundation

// "Any mutation must be rejected." The security property of an
// authenticated cipher, a signature, or a MAC is not what the output is —
// it is that the verification decision flips from accept to reject under
// every attacker-side change of the input, however small. That is a
// metamorphic relation with the simplest possible check: the source is
// accepted, the follow-up is rejected. The engine draws which byte and
// which bit (or which byte to delete or duplicate), and a violation would
// shrink to the one-bit change that still verifies.

// MARK: - Mutations

/// One attacker-side change to a byte string, drawn by the engine.
enum Mutation: Sendable, CustomStringConvertible {
    case flipBit(byte: Int, bit: Int)
    case deleteByte(Int)
    case duplicateByte(Int)
    case appendByte(UInt8)

    static func any(for count: Int, _ tc: TestCase) throws -> Mutation {
        switch try tc.drawInteger(in: Int64(0)...(count > 0 ? 3 : 0)) {
        case 0: return .appendByte(UInt8(try tc.drawInteger(in: Int64(0)...255)))
        case 1: return .flipBit(
            byte: Int(try tc.drawInteger(in: Int64(0)...Int64(count - 1))),
            bit: Int(try tc.drawInteger(in: Int64(0)...7)))
        case 2: return .deleteByte(Int(try tc.drawInteger(in: Int64(0)...Int64(count - 1))))
        default: return .duplicateByte(Int(try tc.drawInteger(in: Int64(0)...Int64(count - 1))))
        }
    }

    func apply(to bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        switch self {
        case .flipBit(let i, let b): out[i] ^= 1 << b
        case .deleteByte(let i): out.remove(at: i)
        case .duplicateByte(let i): out.insert(out[i], at: i)
        case .appendByte(let v): out.append(v)
        }
        return out
    }

    var description: String {
        switch self {
        case .flipBit(let i, let b): return "flip bit \(b) of byte \(i)"
        case .deleteByte(let i): return "delete byte \(i)"
        case .duplicateByte(let i): return "duplicate byte \(i)"
        case .appendByte(let v): return "append byte \(v)"
        }
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

let bytes32 = Gen<[UInt8]>.bytes(count: 32...32)
let bytes12 = Gen<[UInt8]>.bytes(count: 12...12)
let message = Gen<[UInt8]>.bytes(count: 0...64)

enum Verdict: Equatable, CustomStringConvertible {
    case accepted
    case rejected
    var description: String { self == .accepted ? "accepted" : "rejected" }
}

/// The one relation shape of this file: the source verifies, the follow-up
/// — one drawn mutation of the attacker-visible part — does not.
func mutationIsRejected<Input>(
    _ name: String,
    followUp: @escaping @Sendable (Input, TestCase) throws -> Input
) -> Relation<Input, Verdict> {
    Relation(name, followUp: followUp) { a, b in
        guard a == .accepted else { throw RelationViolated("the untampered source did not verify") }
        guard b == .rejected else { throw RelationViolated("the mutated follow-up still verifies") }
    }
}

// MARK: - AEAD: AES-GCM and ChaCha20-Poly1305

struct Sealed: Sendable, CustomStringConvertible {
    var key: [UInt8]
    var combined: [UInt8]   // nonce ‖ ciphertext ‖ tag
    var note = ""
    var description: String { "key \(hex(key).prefix(8))… box \(hex(combined))\(note)" }
}

let aesSealed: Gen<Sealed> = zip(bytes32, bytes12, message).map { key, nonce, m in
    let box = try! AES.GCM.seal(m, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce))
    return Sealed(key: key, combined: Array(box.combined!))
}

let chachaSealed: Gen<Sealed> = zip(bytes32, bytes12, message).map { key, nonce, m in
    let box = try! ChaChaPoly.seal(m, using: SymmetricKey(data: key), nonce: ChaChaPoly.Nonce(data: nonce))
    return Sealed(key: key, combined: Array(box.combined))
}

let aesOpen: @Sendable (Sealed) -> Verdict = { s in
    guard let box = try? AES.GCM.SealedBox(combined: s.combined),
          (try? AES.GCM.open(box, using: SymmetricKey(data: s.key))) != nil
    else { return .rejected }
    return .accepted
}

let chachaOpen: @Sendable (Sealed) -> Verdict = { s in
    guard let box = try? ChaChaPoly.SealedBox(combined: s.combined),
          (try? ChaChaPoly.open(box, using: SymmetricKey(data: s.key))) != nil
    else { return .rejected }
    return .accepted
}

let aeadRelations: [Relation<Sealed, Verdict>] = [
    mutationIsRejected("one mutation of nonce‖ciphertext‖tag ⇒ rejected") { s, tc in
        var s = s
        let m = try Mutation.any(for: s.combined.count, tc)
        s.combined = m.apply(to: s.combined)
        s.note = "  (\(m))"
        return s
    },
    mutationIsRejected("one flipped key bit ⇒ rejected") { s, tc in
        var s = s
        let m = Mutation.flipBit(
            byte: Int(try tc.drawInteger(in: Int64(0)...31)), bit: Int(try tc.drawInteger(in: Int64(0)...7)))
        s.key = m.apply(to: s.key)
        s.note = "  (key: \(m))"
        return s
    },
]

// MARK: - Signatures: Ed25519 and P-256 ECDSA

struct Signed: Sendable, CustomStringConvertible {
    var publicKey: [UInt8]
    var message: [UInt8]
    var signature: [UInt8]
    var note = ""
    var description: String {
        "pk \(hex(publicKey).prefix(8))… msg \(hex(message)) sig \(hex(signature).prefix(16))…\(note)"
    }
}

let ed25519Signed: Gen<Signed> = zip(bytes32, message).map { seed, m in
    let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    return Signed(
        publicKey: Array(key.publicKey.rawRepresentation), message: m,
        signature: Array(try! key.signature(for: m)))
}

let p256Signed: Gen<Signed> = zip(bytes32, message)
    .map { seed, m in (try? P256.Signing.PrivateKey(rawRepresentation: seed)).map { ($0, m) } }
    .filter { $0 != nil }  // a seed at or above the curve order is not a key
    .map { pair in
        let (key, m) = pair!
        return Signed(
            publicKey: Array(key.publicKey.rawRepresentation), message: m,
            signature: Array(try! key.signature(for: m).rawRepresentation))
    }

let ed25519Verify: @Sendable (Signed) -> Verdict = { s in
    guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: s.publicKey),
          pk.isValidSignature(s.signature, for: s.message) else { return .rejected }
    return .accepted
}

let p256Verify: @Sendable (Signed) -> Verdict = { s in
    guard let pk = try? P256.Signing.PublicKey(rawRepresentation: s.publicKey),
          let sig = try? P256.Signing.ECDSASignature(rawRepresentation: s.signature),
          pk.isValidSignature(sig, for: s.message) else { return .rejected }
    return .accepted
}

let signatureRelations: [Relation<Signed, Verdict>] = [
    mutationIsRejected("one mutation of the message ⇒ signature rejected") { s, tc in
        var s = s
        let m = try Mutation.any(for: s.message.count, tc)
        s.message = m.apply(to: s.message)
        s.note = "  (message: \(m))"
        return s
    },
    mutationIsRejected("one mutation of the signature ⇒ rejected") { s, tc in
        var s = s
        let m = try Mutation.any(for: s.signature.count, tc)
        s.signature = m.apply(to: s.signature)
        s.note = "  (signature: \(m))"
        return s
    },
]

// MARK: - MAC: HMAC-SHA256

struct Authenticated: Sendable, CustomStringConvertible {
    var key: [UInt8]
    var message: [UInt8]
    var mac: [UInt8]
    var note = ""
    var description: String { "key \(hex(key).prefix(8))… msg \(hex(message)) mac \(hex(mac).prefix(16))…\(note)" }
}

let hmacAuthenticated: Gen<Authenticated> = zip(bytes32, message).map { key, m in
    Authenticated(
        key: key, message: m,
        mac: Array(HMAC<SHA256>.authenticationCode(for: m, using: SymmetricKey(data: key))))
}

let hmacVerify: @Sendable (Authenticated) -> Verdict = { a in
    HMAC<SHA256>.isValidAuthenticationCode(a.mac, authenticating: a.message, using: SymmetricKey(data: a.key))
        ? .accepted : .rejected
}

let macRelations: [Relation<Authenticated, Verdict>] = [
    mutationIsRejected("one mutation of the message ⇒ MAC rejected") { a, tc in
        var a = a
        let m = try Mutation.any(for: a.message.count, tc)
        a.message = m.apply(to: a.message)
        a.note = "  (message: \(m))"
        return a
    },
    mutationIsRejected("one mutation of the MAC ⇒ rejected") { a, tc in
        var a = a
        let m = try Mutation.any(for: a.mac.count, tc)
        a.mac = m.apply(to: a.mac)
        a.note = "  (mac: \(m))"
        return a
    },
]

// MARK: - Tests

@Suite struct CryptoTamperProperties {
    @Test func aesGCMRejectsEveryMutation() throws {
        try forAll(source: aesSealed, relations: aeadRelations, testCases: 1000, database: "", subject: aesOpen)
    }

    @Test func chaChaPolyRejectsEveryMutation() throws {
        try forAll(source: chachaSealed, relations: aeadRelations, testCases: 1000, database: "", subject: chachaOpen)
    }

    @Test func ed25519RejectsEveryMutation() throws {
        try forAll(source: ed25519Signed, relations: signatureRelations, testCases: 500, database: "", subject: ed25519Verify)
    }

    @Test func p256RejectsEveryMutation() throws {
        try forAll(source: p256Signed, relations: signatureRelations, testCases: 500, database: "", subject: p256Verify)
    }

    @Test func hmacRejectsEveryMutation() throws {
        try forAll(source: hmacAuthenticated, relations: macRelations, testCases: 1000, database: "", subject: hmacVerify)
    }
}
