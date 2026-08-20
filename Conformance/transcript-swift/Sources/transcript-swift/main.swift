import Hegel

// The transcript program. Its exact draw sequence, knob for knob, is
// mirrored in ../transcript-go/main.go — both sides must pass identical
// arguments to the same libhegel calls, or the choice sequences diverge.
let draws = zip(
    zip(
        .int(in: 0...1000),
        .int(in: Int64.min...Int64.max)),
    zip(
        .bool(),
        .double(in: 0...1)),
    .bytes(count: 0...16)
)

try forAll(
    draws,
    settings: Settings(
        testCases: 32, seed: 42, derandomize: true, database: "",
        verbosity: .quiet)
) { ints, scalars, bytes in
    let (a, b) = ints
    let (c, d) = scalars
    let bits = String(format: "%016llx", d.bitPattern)
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    print("case a=\(a) b=\(b) c=\(c) d=\(bits) e=\(hex)")
}
