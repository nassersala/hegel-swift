import Foundation  // String(format:) — leaks through Hegel today, but only because
// non-resilient swiftmodules expose their imports; be explicit.
import Hegel

// The transcript programs. Each one's exact draw sequence, knob for knob,
// is mirrored in ../transcript-go, ../transcript-rust and
// ../transcript-dialectic — every column must pass identical arguments to
// identical libhegel calls, or the choice sequences diverge. One program
// per invocation: `transcript-swift <program>`; an unknown name exits 2.

func settings(cases: UInt64 = 32) -> Settings {
    Settings(
        testCases: cases, seed: 42, derandomize: true, database: "",
        verbosity: .quiet, statefulStepCount: 6)
}

func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func list<A>(_ xs: [A]) -> String {
    "[" + xs.map { "\($0)" }.joined(separator: ",") + "]"
}

// Primitive draws: integer, big integer through the int64 path, boolean,
// bounded float, bytes.
func primitives() throws {
    let draws = zip(
        zip(
            .int(in: 0...1000),
            .int(in: Int64.min...Int64.max)),
        zip(
            .bool(),
            .double(in: 0...1)),
        .bytes(count: 0...16)
    )
    try forAll(draws, settings: settings()) { ints, scalars, bytes in
        let (a, b) = ints
        let (c, d) = scalars
        let bits = String(format: "%016llx", d.bitPattern)
        print("case a=\(a) b=\(b) c=\(c) d=\(bits) e=\(hex(bytes))")
    }
}

// The big-integer ABI: an unsigned 64-bit range does not fit int64.
func bigints() throws {
    try forAll(Gen<UInt64>.int(in: 0...UInt64.max), settings: settings()) { f in
        print("case f=\(f)")
    }
}

// Unrestricted text.
func text() throws {
    try forAll(Gen<String>.string(count: 0...8), settings: settings()) { t in
        print("case t=\(hex(t.utf8))")
    }
}

// Text with a codec, a regex, an email.
func strings() throws {
    let draws = zip(
        Gen<String>.string(count: 0...8, codec: "ascii"),
        .regex("[a-z]{1,4}"),
        .email)
    try forAll(draws, settings: settings()) { a, r, e in
        print("case a=\(hex(a.utf8)) r=\(hex(r.utf8)) e=\(hex(e.utf8))")
    }
}

// Collections: the engine picks the length.
func lists() throws {
    let draws = zip(
        Gen<[Int64]>.array(of: Gen<Int64>.int(in: 0...9), count: 0...4),
        Gen<[Bool]>.array(of: .bool(), count: 1...3))
    try forAll(draws, settings: settings()) { l, m in
        print("case l=\(list(l)) m=\(list(m))")
    }
}

// A counter under the state-machine ABI. `reject` gives reset a
// precondition, so a selected rule can be reported rejected.
func stateful(reject: Bool) throws {
    let rules: [Rule<Int64>] = [
        Rule("RuleAdd") { state, tc in
            let k = try tc.drawInteger(in: Int64(1)...Int64(9))
            state += k
            print("step add \(k) -> \(state)")
        },
        Rule("RuleReset", precondition: { state in
            if reject && state == 0 { print("step reset rejected") }
            return !reject || state > 0
        }) { state, _ in
            state = 0
            print("step reset -> 0")
        },
    ]
    try forAll(
        initial: Gen { _ in print("case"); return Int64(0) },
        rules: rules,
        invariants: [Invariant("InvariantNonNeg") { state in
            if state < 0 { throw NSError(domain: "negative", code: 0) }
        }],
        settings: settings(cases: 8))
}

let program = CommandLine.arguments.dropFirst().first ?? ""
switch program {
case "primitives": try primitives()
case "bigints": try bigints()
case "text": try text()
case "strings": try strings()
case "lists": try lists()
case "stateful": try stateful(reject: false)
case "stateful-reject": try stateful(reject: true)
default:
    FileHandle.standardError.write("transcript-swift: no program named '\(program)'\n".data(using: .utf8)!)
    exit(2)
}
