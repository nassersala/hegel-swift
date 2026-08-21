# hegel-swift

Property-based testing for Swift, built on [Hegel](https://hegel.dev) 

```swift
import Hegel

struct User { var id: Int64; var age: Int; var active: Bool }

let adult = zip(
    .int(in: 0...Int64.max),
    .int(in: 18...65),
    .bool(probability: 0.9)
).map(User.init)

try forAll(adult) { user in
    let restored = try decode(encode(user))
    #expect(restored == user)
}
```

When that property fails, you don't get a random 47-field counterexample — you get the *minimal* one, shrunk by the same engine that shrinks for Hypothesis, plus a reproduce blob that replays it exactly.

> **Status: pre-alpha, but alive.** The core loop — run lifecycle, integer/bool/double/bytes draws, collections, spans, filtering, shrinking, failure reporting with reproduce blobs — compiles and passes its suite against the real engine (libhegel v0.32.5, vendored as a binary target). The shrinker test asserts that `n >= 10` shrinks to exactly `10`. See [Roadmap](#roadmap) for what's missing.

## Installation

Add the package to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/nassersala/hegel-swift", from: "0.1.0"),
]
```

and the products to your test target:

```swift
.testTarget(
    name: "MyTests",
    dependencies: [
        .product(name: "Hegel", package: "hegel-swift"),
        .product(name: "HegelTesting", package: "hegel-swift"), // Swift Testing sugar
    ]
)
```

libhegel ships inside the package as a binary target, so there is nothing else to install, link, or configure.

Requirements: Swift 6.2+ (Xcode 26), macOS 14+ / iOS 17+, Apple Silicon (the vendored slices are macOS arm64, iOS device, and iOS simulator).

## Why

### Why property-based testing

Example tests check the cases you thought of. Properties — `decode(encode(x)) == x`, idempotency, monotonicity, "the parser never crashes" — are checked against hundreds of generated inputs, including the adversarial ones you didn't think of: empty strings, `Int64.min`, NaN, the 3-element list with a duplicate. And when a property fails, the engine *shrinks* the counterexample until it's minimal, doing the first half of your debugging for you. PBT has a decades-long track record of catching the silly errors humans write — and it does the same for the code LLM agents write, which is exactly the argument the Hegel authors make for why this matters more now, not less.

### Why Hegel underneath, instead of a pure-Swift library

Hypothesis is the most widely used PBT library in the world, and its authors are blunt about why: not the model alone, but "an unreasonable amount of work" invested in the engine — the generators, the shrinker, the example database, ten years of tuning. Most Hypothesis-inspired ports copied the API, skipped the core model, and lost the benefits.

Hegel is those same authors extracting the engine into `libhegel`: a Rust core behind a C ABI that owns generation, shrinking, the failure database, and run scheduling, with thin per-language frontends on top (Rust, Go, C++, TypeScript, Java, OCaml officially — and Swift, here). The unreasonable amount of work is done **once**, and this library inherits it wholesale: a binding author writes marshalling and ergonomics, never a shrinker.

Concretely, the engine provides three things no from-scratch Swift library has:

1. **Internal shrinking.** Every value is produced by a sequence of primitive draws (the *choice sequence*). Shrinking edits that sequence and re-runs *your generator* to reinterpret it — so shrunk values can never violate your generator's invariants, and you never write `shrink(_:)` for any type, ever.
2. **A test database.** A discovered failure is saved (`.hegel/examples/` by default) and replayed *first* on the next run. Flaky discovery becomes stable regression test, automatically.
3. **Engine-grade generation.** Bounded floats with subnormal control, Unicode strings by category, regex-shaped strings, emails, stateful rule machines, targeted (hill-climbing) generation — primitives it would take years to match.

### Why Swift needs this

Swift has no Hypothesis-quality PBT library. SwiftCheck follows the QuickCheck model: an `Arbitrary` protocol conformance per type, hand-written `shrink` arrays, and type-directed generation — which brings us to the design question.

### Why there is no `Arbitrary` protocol here

This library uses **protocol witnesses, not protocols**: the one abstraction is a plain struct,

```swift
struct Gen<Value> {
    let run: (TestCase) throws -> Value
}
```

and everything else is function composition — `map`, `flatMap`, `filter`, `zip`.

The protocol-witness style and the choice-sequence engine are the same idea at two levels — **behavior as data passed explicitly, with policy owned by the substrate**.

What the witness style buys, concretely:

- **Multiple generators per type, zero clashes.** `User` can have `.anyUser`, `.adult`, `.adversarialUnicodeUser` — a protocol allows exactly one canonical conformance, and "the one true generator for `User`" is not a real thing.
- **Tuples and functions compose freely.** `zip` turns a tuple of `Gen`s into a `Gen` of tuples; `.map(User.init)` lifts it to your domain type. No conditional-conformance gymnastics, no associated-type walls.
- **Shrinking composes for free.** Combinators never touch the choice sequence, so every composed generator shrinks correctly with zero shrinker code — the exact property that `Arbitrary.shrink` designs lose the moment two shrinkers must agree about an invariant.
- **No ceremony at the edges.** Generators are values: store them in arrays, pick them with `oneOf`, parameterize them with functions, namespace them as statics on `Gen`.

The cost is tiny: you pass generators explicitly instead of having the compiler infer them. 

## Getting libhegel

`Vendor/CHegel.xcframework` vendors libhegel v0.32.5 as a binary target: one dynamic `CHegel.framework` per slice (macOS arm64, iOS device, iOS simulator), each carrying the dylib, the canonical `hegel.h`, and a module map. `swift build` and `swift test` work out of the box; SPM and Xcode link and embed the framework wherever the package is consumed. The full suite passes on the iOS simulator (`xcodebuild test -scheme hegel-swift-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`).

The slices are built from the pinned tag of [hegeldev/hegel-rust](https://github.com/hegeldev/hegel-rust) (upstream releases ship prebuilt dylibs for desktop platforms only, so iOS requires building from source anyway). To upgrade, bump `TAG` in `Scripts/build-xcframework.sh` and rebuild against a checkout of that tag:

```sh
git clone --branch vX.Y.Z --depth 1 https://github.com/hegeldev/hegel-rust
Scripts/build-xcframework.sh --hegel-rust ./hegel-rust --slices macos,ios,ios-sim
```

The script refuses to build from a checkout that isn't exactly at the pinned tag. The canonical ABI is `hegel-c/include/hegel.h` in hegel-rust; this binding tracks it. Reproduce blobs are version-pinned — a stored counterexample replays only on the libhegel version that produced it.

## Die Hard, solved by the shrinker

The classic TLA+ example (via [Hypothesis](https://hypothesis.works/articles/how-not-to-die-hard-with-hypothesis/)): a 3-gallon jug, a 5-gallon jug, and the false invariant that the big jug never holds exactly 4 gallons. The shrunk counterexample is the puzzle's solution:

```swift
try forAll(
    initial: Gen { _ in Jugs() },
    rules: [
        Rule("fill small")  { jugs, _ in jugs.small = 3 },
        Rule("fill big")    { jugs, _ in jugs.big = 5 },
        Rule("empty small") { jugs, _ in jugs.small = 0 },
        Rule("empty big")   { jugs, _ in jugs.big = 0 },
        Rule("pour small into big") { jugs, _ in /* … */ },
        Rule("pour big into small") { jugs, _ in /* … */ },
    ],
    invariants: [
        Invariant("big is never 4") { jugs in
            if jugs.big == 4 { throw DieHardSolved() }
        }
    ])
```

```
initial: (small: 0, big: 0)
  fill big
  pour big into small
  empty small
  pour big into small
  fill big
  pour big into small
invariant big is never 4 failed
```

Six steps, the minimal solution. Random rule scheduling finds a solution; choice-sequence shrinking minimizes it. `DieHardTests.swift` pins the trace exactly. Across seeds 1–10, nine shrink to this trace and one lands in the valid 8-step alternative; shrinking guarantees a local minimum, not a global one.

## Targeted properties

`tc.target(score)` records a finite observation (higher = more interesting) and the engine hill-climbs, biasing later cases toward inputs that scored higher. The property closure can take the `TestCase` as a second parameter to record it:

```swift
try forAll(array(of: .int(in: 0...10), count: 0...200)) { xs, tc in
    let sum = xs.reduce(0, +)
    try tc.target(Double(sum))
    #expect(sum < 800)
}
```

Generation biases toward short lists, so at 200 cases random search finds `sum >= 800` in 0 of 20 runs; with targeting, 18 of 20. The shrinker then minimizes the hit to a list summing to exactly 800. Stateful runs take a `maximize:` closure, scored after every step, with the run's best reported once.

Measured caveat: targeting is only as good as the gradient. On Die Hard, `maximize: -|big − 4|` made discovery worse than random search, because `big = 3` and `big = 5` both score −1 while being structurally far from the solution. The score must measure real progress toward the bug.

## Metamorphic relations: testing without an oracle

Prayer times have no oracle — nothing says what fajr at (51.5, −0.1) on 2024-03-09 *should* be. What can be said is how the times must respond to a *change* of input. Chen's metamorphic testing names that: a **source** input and its output, a **follow-up** input derived from it, and a relation over the two executions (the *metamorphic group*). Here a relation is a value, like `Gen` and `Rule`:

```swift
let fajrAngleUp = Relation<Query, Times>(
    "fajr angle up ⇒ fajr earlier or equal, nothing else moves",
    followUp: { q, tc in
        var q = q
        q.params.fajrAngle += Double(try tc.drawInteger(in: Int64(1)...6))
        return q
    },
    holds: { a, b in
        guard b.fajr <= a.fajr else { throw RelationViolated("fajr moved later") }
        try expectEqual(a, b, except: [.fajr])
    })

try forAll(
    source: temperateQuery,
    relations: [fajrAngleUp, ishaAngleUp, adjustmentShifts, longitudeShift, fourYearsLater],
    subject: prayerTimes)
```

Per case the engine draws a source and one relation, runs the subject on source and follow-up, and checks. Whatever the follow-up drew (the angle increment, the longitude delta) is in the choice sequence, so a violation shrinks to the minimal group and is displayed as one:

```
relation: Δ° east ⇒ every time 4Δ min earlier (±1 min rounding)
  source:       (0.0, -180.0) 2000-1-1 muslimWorldLeague fajr 18.0° isha 17.0°
  follow-up:    (0.0, -179.0) 2000-1-1 muslimWorldLeague fajr 18.0° isha 17.0°
  f(source):    fajr 31T16:44  sunrise 31T17:59  dhuhr 01T00:04  asr 01T03:29  maghrib 01T06:07  isha 01T07:17
  f(follow-up): fajr 01T16:41  sunrise 01T17:56  dhuhr 02T00:01  asr 02T03:25  maghrib 02T06:03  isha 02T07:14
violated: fajr shifted 1437.0 min, expected -4.0
```

That is the longitude relation's first run against adhan: at longitude −180 (and within a few ulps of it) the library computes the previous local day — it treats −180 as +180 — so one degree east moves every prayer a day later. An edge case, not a practical bug, but a discontinuity in a function that should be continuous in longitude, and the shrinker walked straight to it (the generator's bound). `AdhanMetamorphicTests.swift` pins it and keeps the relation's domain a hair off the boundary.

Two patterns ship as constructors, named after Zhou, Sun, Chen and Towey's MR patterns: `.invariant(_:under:)` (symmetry — `sort(reversed(xs)) == sort(xs)`) and `.monotone(_:followUp:_:_:)` (change direction). `HegelError.assume` in a follow-up rejects a source the relation doesn't apply to. Chains of relations — several follow-ups checked against the original — are the stateful machine with transforms as rules; nothing more is needed. Chen's "beyond necessary properties" point shows up in the adhan set: the four-years-later relation is a hypothesis with a tolerance, not a theorem — its first version, one year later, shrank to the leap-year drift at grazing twilight, fajr 24 min off at (−55, 0), 2000-02-02 → 2001.

## Example: properties for a real library

`Examples/AdhanProperties` property-tests [adhan-swift](https://github.com/batoulapps/adhan-swift) (Islamic prayer times): ordering of the five prayers, madhab moving only asr, qibla always a bearing, times belonging to their day. **The first run found a real bug** ([batoulapps/adhan-swift#102](https://github.com/batoulapps/adhan-swift/issues/102)): in the high-latitude band the library can return non-nil, out-of-order times — asr before dhuhr on the same day, or landing days after the requested date. Hegel shrank it to the minimal reproduction `(lat -72, lon 0), 2000-08-01, muslimWorldLeague`. ~1,700 generated cases run in ~13 ms.

The example also includes a stateful machine: rules move a probe clock around a generated day while an invariant pins the `currentPrayer`/`nextPrayer` contract (before fajr it's `(nil, fajr)`, from isha on `(isha, nil)`, otherwise `next` is `current`'s successor and the clock sits in `[time(current), time(next))`) — and the metamorphic relations above.

Dogfood lesson, worth knowing: **properties passed to `forAll` must `throw` on violation.** A bare `#expect` inside `forAll` records a Swift Testing issue but returns normally, so the engine counts the case as valid and never shrinks it. `expectAll` (below) exists because of this.

## Swift Testing integration

`HegelTesting` (a separate product, so `Hegel` itself never links the Testing framework) provides `expectAll`: same shape as `forAll`, but `#expect` failures inside the body are bridged into engine signals, so they shrink.

```swift
import Testing
import HegelTesting  // re-exports Hegel

@Test(.propertyTesting) func roundTrip() {
    expectAll(adult) { user in
        #expect(try decode(encode(user)) == user)
    }
}
```

On failure the test reports exactly two issues: the minimal counterexample (with its reproduce blob), and the body's own `#expect` failure replayed at that minimal input — pointing at the exact expectation that broke. The `.propertyTesting` trait keeps the search phase's intermediate failures out of the test results entirely; without it `expectAll` still works, but every failing probe shows up as a non-failing "known issue" line. Thrown errors keep their `forAll` meaning (`HegelError.assume` rejects the case; anything else is a violation).

## Example: affordance correctness

`Examples/AffordanceProperties` property-tests a user interface claim: what the user sees as possible is possible.

```
panel.isEnabled(action) == alarm.isLegal(action)    for every action, at every reachable state
```

A home alarm panel is modeled twice: the state machine (the truth about which actions are legal) and a view model exposing the enabled/disabled booleans a SwiftUI view would bind to. The engine drives the machine through its rules; an invariant checks the full affordance matrix after every step. A second rule attempts illegal actions and requires visible feedback.

The buggy panel under test updates its visuals from the *event* instead of the *state*: on `reset` it hand-copies the armed visuals and leaves the trigger button disabled. The property catches it and shrinks the failure to the shortest user session after which the UI lies:

```
initial: disarmed
  arm
  trigger
  reset
invariant affordance correctness failed
violated: trigger looks disabled but is legal (state: armed)
```

The example runs the property twice: against a plain struct panel, and against an `@Observable` view model — the object a SwiftUI view actually binds with `.disabled(!model.visual.triggerEnabled)`, with a real `View` in the file to prove the binding surface. Rules call the view model's intents the way a user taps buttons. All of it passes on the iOS simulator:

```sh
cd Examples/AffordanceProperties
xcodebuild test -scheme AffordanceProperties-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

When this property fails in a real product, the user is in Norman's "gulf of execution": the interface misrepresents what the system will do. The Therac-25 accidents were this property violated with a beam button. The model here follows earlier work connecting cleanroom sequence specification (Prowell), affordance theory (Norman), and property-based testing; the state machine and the planted bug are ported from a Python/Hypothesis study of the same idea.

## Example: the Swift regex engine, compiler-style

`Examples/RegexProperties` does to `Regex` what EMI (Le, Afshari, Su, PLDI 2014) does to GCC and GraphicsFuzz (Donaldson et al., OOPSLA 2017) does to shader compilers: rewrite the program without changing its meaning and require the same output. The program is a small regex AST the engine generates (`a–c`, classes, `|`, `*+?`, `{m,n}`, groups); the rewrites are identities applied at an engine-chosen node; the output is every match range plus whole-match, in a text drawn to match the pattern half the time:

```swift
rewrite("R+ ⇒ RR*") {
    if case .plus(let r) = $0 { return .cat([r, .star(r)]) }
    return nil
}
rewrite("R{m,n} ⇒ R{m}R{0,n−m}") { … }
rewrite("R ⇒ (?:R|z+)  (dead alternative, equivalence modulo this text)") { … }
```

Eight rewrite relations × 2000 cases, an alternation-reorder relation on whole-match only (order changes *which* match leftmost-first picks, not whether one exists), and a cross-program relation — Swift's engine and ICU's `NSRegularExpression` on the same query must agree. All of it runs in 0.3 s, and the Swift engine passes.

What the shrinker found instead was two false premises of mine, each reduced to one line. The dead-alternative relation's first run: `/a/ on "az"` — the regex-shaped text generator pads with arbitrary characters, so `z` was not dead; the texts now come from the `a–c` alphabet with `a–c` padding. The ICU comparison's first run: `/(?:b*|a)/ on "a"` — I had computed ICU's whole-match as an anchored *first* match, which is the leftmost-first match at 0 (`b*` = empty) and not "some path reaches the end"; `\A(?:R)\z` is. That is what a violated relation means in Chen's framing: a bug in the subject or a wrong conjecture in the relation, and shrinking makes it obvious which.

One engineering note the example documents: Swift's engine backtracks without memoization, so `(?:(?:a|ab)*)*`-shaped patterns on a 20-character text do not terminate in useful time — true of every backtracking engine, not a finding. The generator bounds quantifier nesting to two and texts to ten characters.

## Example: security properties

`Examples/SecurityProperties` takes the shape Chen et al. ("Metamorphic Testing for Cybersecurity", *IEEE Computer* 2016) and Mai, Pastore, Goknil and Briand ("Metamorphic Security Testing for Web Systems", ICST 2020) give security testing: a secure decision must not change when the attacker-controlled part of the input changes. Subjects are Apple's own.

**CryptoKit — any mutation must be rejected.** The source verifies; the follow-up, one engine-drawn mutation (flip a bit, delete, duplicate or append a byte) of the attacker-visible part, must not:

```swift
mutationIsRejected("one mutation of nonce‖ciphertext‖tag ⇒ rejected") { s, tc in
    var s = s
    s.combined = try Mutation.any(for: s.combined.count, tc).apply(to: s.combined)
    return s
}
```

AES-GCM and ChaCha20-Poly1305 (box and key), Ed25519 and P-256 ECDSA (message and signature), HMAC-SHA256 (message and MAC): 4000 mutations, all rejected.

**Path resolution — spelling must not change the decision.** An app resolves a requested path under its root and checks the result is still inside. Relations: inserting `.`, inserting `x/..`, doubling a slash, a `./` prefix ⇒ same resolved file; more `..` than depth ⇒ OUTSIDE. The relations settled which Foundation API that code should call, and found one thing:

```
relation: inserting "x/.."
  source:       "a"
  follow-up:    "x/../a"  ("x/.." at 0)
  f(source):    /srv/app/store/a (inside root)
  f(follow-up): /a (OUTSIDE root)
```

`URL.standardized` on a *relative* file URL applies RFC 3986's `remove_dot_segments` to the relative path alone; that algorithm is defined for the merged absolute path, and on `x/../a` it yields `/a` — the result is `file:///a`, the base is gone. `a/x/..` and `./a` are fine; only a `..` that consumes the first segment trips it. Same family as swift-corelibs-foundation #3234 ("URL.standardized turns a path into a hostname"). `absoluteURL.standardized` is right but keeps `a//a` as two segments (correct for a URL, not for a file); `standardizedFileURL` is the one. The example pins the `.standardized` behavior so a fix shows up, and uses `standardizedFileURL`.

**URL parsers — one string, one authority.** `URL`, `URLComponents` and `NSURL` on strings shaped like authority-confusion attacks (`u:pa@b@host`, `\`, `%40`, `#`/`?` in the path, IPv6, IDN, odd ports) must agree on scheme, user, host and port, or all reject. They do — after two representation choices the first run surfaced in every one of its ~60 disagreement classes, worth knowing if a check compares hosts across APIs: `URLComponents.host` keeps IPv6 brackets (`[::1]`, where `URL.host` and `NSURL.host` give `::1`) and decodes IDNA (`☃.com`, where the others keep `xn--n3h.com`; `encodedHost` matches).

## Testing the binding itself

Same strategy as the official bindings (hegel-go is the template), self-bootstrapped with the circularity broken deliberately:

1. **Hermetic FFI smoke tests** (`SmokeTests.swift`) — drive the raw C protocol with a pinned seed, derandomization, and the database disabled; assert the loop actually yields test cases. Tests *our marshalling*; the engine is trusted upstream.
2. **Self-bootstrap** (`HegelTests.swift`) — `forAll` testing the binding's own generators (bounds, filter semantics, collection sizes). Two test kinds cannot pass vacuously: *deliberate-failure* tests (a false property must fail, and must shrink to its **known** minimal counterexample) and *blob* assertions (a failure must carry a reproduce blob).
3. **Differential conformance** (`Conformance/` + `Scripts/conformance.sh`) — the same draw program under the same seed produces byte-identical draw transcripts here and in hegel-go, both loading the *same* vendored libhegel binary (hegel-go accepts it via `HEGEL_LIBHEGEL_PATH`; it pins 0.32.5 too). The choice-sequence model makes cross-language determinism directly checkable; the transcripts match.

The Antithesis platform is deliberately *not* part of this layer, even though Hegel is an Antithesis project: their integration points the other way (libhegel's `urandom` backend lets the Antithesis fuzzer steer Hegel tests running inside their deterministic hypervisor). Where it may earn a place later: fuzzing the threading contracts (`hegel_test_case_clone` from multiple threads) under a deterministic scheduler.

## Design

| Layer | What it is | What it knows |
|---|---|---|
| `CHegel` | binary target: `CHegel.framework` (libhegel + `hegel.h` + module map) per slice | nothing — raw ABI |
| `Context` / `TestCase` | RAII handle wrappers; status codes → thrown Swift errors (`HEGEL_E_STOP_TEST` → overrun, `HEGEL_E_ASSUME` → rejection) | ownership + calling convention |
| `Gen<Value>` | the witness: `(TestCase) throws -> Value` + combinators | nothing about shrinking — by design |
| `forAll` | the run loop: next-test-case / interpret / mark-complete; failures → shrunk blobs | the engine protocol |

## Roadmap

- [x] Compile against real `libhegel` (v0.32.5, built from the pinned hegel-rust tag); suite green incl. shrink-to-known-minimum
- [x] String generators (text/regex/email/URL/domain, Unicode categories & codepoint ranges incl. Arabic) with RAII generator handles
- [x] `replay(blob:)` + drawn-value display: `PropertyFailure` shows the shrunk counterexample, recovered by replaying the blob through the generator
- [x] Dates/times/datetimes (`CalendarDate`/`TimeOfDay`/`CalendarDateTime` + `DateComponents` bridging), UUIDs, IPv4/IPv6, big integers (`UInt64`, `Int128`, `UInt128`)
- [x] `Settings` on `forAll`/`expectAll`: seed, derandomize, database path/key, phases, multiple-failure reporting (distinct thrown error types = distinct bugs), verbosity, single-test-case mode
- [x] Stateful testing: `forAll(initial:rules:invariants:)` over engine state machines (rule selection, step budget, whole-step shrinking) + `Pool` for reuse of previously generated values; failing runs display as minimal rule traces
- [x] Targeted PBT: `tc.target(score)` in property bodies (`forAll` passes the `TestCase` to two-parameter closures) + `maximize:` on stateful runs
- [x] Metamorphic relations: `forAll(source:relations:subject:)` + `Relation`, the `.invariant`/`.monotone` patterns, failures displayed as the metamorphic group
- [x] Swift Testing integration sugar: `expectAll` + `.propertyTesting` trait (motivated by the adhan dogfood: bare `#expect` inside a `forAll` property doesn't shrink)
- [x] Binary target: `CHegel.xcframework` vendored, built from the pinned hegel-rust tag (`Scripts/build-xcframework.sh`) — no linker flags or rpaths anywhere
- [x] Differential conformance vs hegel-go: identical seed → identical draw transcript, same engine binary (`Scripts/conformance.sh`)
- [ ] Validate against `hegeldev/hegel-core` (the cross-language protocol suite)

## References

- [Why Hegel?](https://hegel.dev/explanation/why-hegel) · [How Hegel works](https://hegel.dev/explanation/how-hegel-works) · [libhegel reference](https://hegel.dev/reference/libhegel)
- [hegeldev/hegel-rust](https://github.com/hegeldev/hegel-rust) — reference implementation + canonical `hegel.h`
- Brandon Williams, *Protocol Witnesses* — the design stance behind `Gen`
- [Hypothesis](https://hypothesis.readthedocs.io) — the model this all descends from
- Chen, Cheung, Yiu, [*Metamorphic Testing: A New Approach for Generating Next Test Cases*](https://arxiv.org/abs/2002.12543) (1998) · Chen & Tse, [*New Visions on Metamorphic Testing after a Quarter of a Century of Inception*](https://dl.acm.org/doi/10.1145/3468264.3473136) (ESEC/FSE 2021) — the source/follow-up/group vocabulary behind `Relation`
- Chen, Kuo, Ma, Susilo, Towey, Voas, Zhou, [*Metamorphic Testing for Cybersecurity*](https://csrc.nist.gov/pubs/journal/2016/06/metamorphic-testing-for-cybersecurity/final) (IEEE Computer 2016) · Mai, Pastore, Goknil, Briand, [*Metamorphic Security Testing for Web Systems*](https://arxiv.org/abs/1912.05278) (ICST 2020) — the shape of `Examples/SecurityProperties`
- Le, Afshari, Su, *Compiler Validation via Equivalence Modulo Inputs* (PLDI 2014) · Donaldson, Evrard, Lascu, Thomson, *Automated Testing of Graphics Shader Compilers* (OOPSLA 2017) — the shape of `Examples/RegexProperties`
- Alzahrani, Spichkova, Harland, [*Application of property-based testing tools for metamorphic testing*](https://arxiv.org/abs/2211.12003) (2022) — metamorphic testing as a kind of PBT, the stance `forAll(source:relations:subject:)` takes

## Crafted By:
Nasser Ali Alzahrani [@nassersala](http://twitter.com/nassersala)

## License
MIT — see [LICENSE](LICENSE). `Vendor/CHegel.xcframework` contains libhegel binaries built unmodified from [hegeldev/hegel-rust](https://github.com/hegeldev/hegel-rust) v0.32.5 (MIT, Antithesis, LLC); the upstream notice is included in LICENSE. This binding is unofficial and not affiliated with Antithesis.
