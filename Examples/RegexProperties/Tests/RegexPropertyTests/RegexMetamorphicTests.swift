import Testing
import Hegel
import Foundation

// Metamorphic relations for the Swift regex engine.
//
// A regex engine is a compiler (pattern → program) plus an interpreter, and
// it has no oracle: nobody can say by hand where `(?:a|bc)*b{1,2}` matches
// in "abcbbab". The compiler-testing literature answers that the way EMI
// (Le, Afshari, Su, PLDI 2014) and GraphicsFuzz (Donaldson et al., OOPSLA
// 2017) do: rewrite the program in a way that cannot change its meaning,
// and require the same output. Here the program is a small regex AST the
// engine generates, the rewrites are classic identities — `(?:R)`, `[ab]`
// ⇔ `(?:a|b)`, `R+` ⇔ `RR*`, `R?` ⇔ `R{0,1}`, `R{n}` unrolled — applied
// at an engine-chosen node, and the output is the list of match ranges in a
// text that is itself drawn to match the pattern half the time. One
// relation is EMI proper: add an alternative that cannot match *this* text
// (`(?:R|z+)` over an a–c text) and nothing may change.

// MARK: - A tiny regex AST

indirect enum Re: Sendable, CustomStringConvertible {
    case char(Character)            // a, b, c
    case cls([Character])           // [abc]
    case cat([Re])                  // RS
    case alt([Re])                  // R|S
    case star(Re)                   // R*
    case plus(Re)                   // R+
    case opt(Re)                    // R?
    case rep(Re, Int, Int?)         // R{m,n} / R{m,} (n == nil)
    case group(Re)                  // (?:R)

    /// The pattern text. Every operator's operand is rendered as an atom
    /// (grouped unless it already is one), so precedence never depends on
    /// the rewrite that produced the tree.
    var pattern: String {
        switch self {
        case .char(let c): return String(c)
        case .cls(let cs): return "[" + String(cs) + "]"
        case .cat(let rs): return rs.map(\.atomOrSequence).joined()
        case .alt(let rs): return rs.map(\.pattern).joined(separator: "|")
        case .star(let r): return r.atom + "*"
        case .plus(let r): return r.atom + "+"
        case .opt(let r): return r.atom + "?"
        case .rep(let r, let m, let n): return r.atom + "{\(m),\(n.map(String.init) ?? "")}"
        case .group(let r): return "(?:" + r.pattern + ")"
        }
    }

    /// Rendering safe as a quantifier operand.
    var atom: String {
        switch self {
        case .char, .cls, .group: return pattern
        default: return "(?:" + pattern + ")"
        }
    }

    /// Rendering safe inside a concatenation (alternation needs a group).
    var atomOrSequence: String {
        if case .alt = self { return "(?:" + pattern + ")" }
        return pattern
    }

    var description: String { pattern }

    /// Immediate children, for node addressing.
    var children: [Re] {
        switch self {
        case .char, .cls: return []
        case .cat(let rs), .alt(let rs): return rs
        case .star(let r), .plus(let r), .opt(let r), .group(let r), .rep(let r, _, _): return [r]
        }
    }

    func withChildren(_ new: [Re]) -> Re {
        switch self {
        case .char, .cls: return self
        case .cat: return .cat(new)
        case .alt: return .alt(new)
        case .star: return .star(new[0])
        case .plus: return .plus(new[0])
        case .opt: return .opt(new[0])
        case .group: return .group(new[0])
        case .rep(_, let m, let n): return .rep(new[0], m, n)
        }
    }

    /// All nodes in preorder.
    var nodes: [Re] { [self] + children.flatMap(\.nodes) }

    /// The tree with the preorder node `index` replaced by `f(node)`.
    func replacing(nodeAt index: Int, with f: (Re) -> Re) -> Re {
        var counter = 0
        func go(_ r: Re) -> Re {
            let mine = counter
            counter += 1
            if mine == index { return f(r) }
            return r.withChildren(r.children.map(go))
        }
        return go(self)
    }
}

// MARK: - Generators

let alphabet: [Character] = ["a", "b", "c"]

/// Patterns of bounded depth, with at most `quantifiers` nested quantifiers
/// on any path. Swift's engine backtracks without memoization, so
/// `(?:(?:a|ab)*)*`-shaped patterns on a 20-character text take longer than
/// the age of the universe — a property of every backtracking engine, not a
/// finding, and not what these relations are about. Texts are kept to ten
/// characters for the same reason.
func re(depth: Int, quantifiers: Int = 2) -> Gen<Re> {
    let leaf: Gen<Re> = oneOf([
        element(of: alphabet).map(Re.char),
        array(of: element(of: alphabet), count: 1...3).map { Re.cls(Array(Set($0)).sorted()) },
    ])
    guard depth > 0 else { return leaf }
    let sub = re(depth: depth - 1, quantifiers: quantifiers)
    var options: [Gen<Re>] = [
        leaf,
        array(of: sub, count: 2...3).map(Re.cat),
        array(of: sub, count: 2...3).map(Re.alt),
        sub.map(Re.group),
    ]
    if quantifiers > 0 {
        let operand = re(depth: depth - 1, quantifiers: quantifiers - 1)
        options += [
            operand.map(Re.star),
            operand.map(Re.plus),
            operand.map(Re.opt),
            zip(operand, .int(in: 0...3), .int(in: 0...3)).map { r, m, extra in
                extra == 3 ? Re.rep(r, m, nil) : Re.rep(r, m, m + extra)
            },
        ]
    }
    return oneOf(options)
}

struct Query: Sendable, CustomStringConvertible {
    var re: Re
    var text: String
    var description: String { "/\(re.pattern)/ on \"\(text)\"" }
}

let abc = Gen<String>.string(count: 0...8, codepoints: 0x61...0x63)
let pad = Gen<String>.string(count: 0...2, codepoints: 0x61...0x63)

/// A pattern and a text over a–c: half the time a text the engine drew to
/// match the pattern, padded on both sides (so matches are common and not
/// only at the ends), half the time any short a–c string. The alphabet
/// matters: the dead-alternative relation below relies on `z` never
/// occurring. (The first run had the engine pad with arbitrary characters
/// and shrank straight to `/a/` on "az" — a false premise, not a bug.)
let query: Gen<Query> = re(depth: 3).flatMap { r in
    oneOf([
        zip(pad, Gen<String>.regex(r.pattern).filter { $0.count <= 6 }, pad).map { $0 + $1 + $2 },
        abc,
    ]).map { Query(re: r, text: $0) }
}

// MARK: - Subject

struct Matches: Equatable, CustomStringConvertible {
    let whole: Bool
    let ranges: [Range<Int>]

    var description: String {
        let spans = ranges.map { "\($0.lowerBound)..<\($0.upperBound)" }.joined(separator: " ")
        return "whole: \(whole)  matches: [\(spans)]"
    }
}

/// The Swift regex engine: every match range (character offsets), and
/// whether the whole text matches. A pattern the grammar produced must
/// compile, so a compile error is a violation, not a rejection.
let swiftRegex: @Sendable (Query) throws -> Matches = { q in
    let regex = try Regex(q.re.pattern)
    let ranges = q.text.matches(of: regex).map { m in
        q.text.distance(from: q.text.startIndex, to: m.range.lowerBound)
            ..< q.text.distance(from: q.text.startIndex, to: m.range.upperBound)
    }
    return Matches(whole: q.text.wholeMatch(of: regex) != nil, ranges: ranges)
}

/// ICU, via NSRegularExpression, on the same query. The grammar here is in
/// the dialect both engines share, so this is the second program of a
/// cross-program relation: same pattern, same text, same matches. (Offsets
/// are UTF-16 in NSRange; the texts are ASCII, so they coincide with
/// character offsets.)
let icuRegex: @Sendable (Query) throws -> Matches = { q in
    let regex = try NSRegularExpression(pattern: q.re.pattern)
    let ns = q.text as NSString
    let whole = NSRange(location: 0, length: ns.length)
    let ranges = regex.matches(in: q.text, range: whole).map { m in
        m.range.location ..< m.range.location + m.range.length
    }
    // "Some path matches the whole text" is the anchored pattern, not an
    // anchored first match (which is the leftmost-first match at 0 and may
    // stop short where another alternative would have reached the end).
    let anchored = try NSRegularExpression(pattern: "\\A(?:" + q.re.pattern + ")\\z")
    let isWhole = anchored.firstMatch(in: q.text, range: whole) != nil
    return Matches(whole: isWhole, ranges: ranges)
}

// MARK: - Relations

/// A relation that rewrites one engine-chosen node where `rule` applies
/// (`nil` = not applicable there; no applicable node rejects the case), then
/// requires identical matches.
func rewrite(_ name: String, _ rule: @escaping @Sendable (Re) -> Re?) -> Relation<Query, Matches> {
    .invariant(name) { q, tc in
        let candidates = q.re.nodes.indices.filter { rule(q.re.nodes[$0]) != nil }
        guard !candidates.isEmpty else { throw HegelError.assume }
        let target = candidates[Int(try tc.drawInteger(in: Int64(0)...Int64(candidates.count - 1)))]
        var q = q
        q.re = q.re.replacing(nodeAt: target) { rule($0)! }
        return q
    }
}

@Suite struct RegexMetamorphicProperties {
    static let relations: [Relation<Query, Matches>] = [
        rewrite("R ⇒ (?:R)") { .group($0) },
        rewrite("[ab] ⇒ (?:a|b)") {
            if case .cls(let cs) = $0 { return .group(.alt(cs.map(Re.char))) }
            return nil
        },
        rewrite("R+ ⇒ RR*") {
            if case .plus(let r) = $0 { return .cat([r, .star(r)]) }
            return nil
        },
        rewrite("R? ⇒ R{0,1}") {
            if case .opt(let r) = $0 { return .rep(r, 0, 1) }
            return nil
        },
        rewrite("R* ⇒ R{0,}") {
            if case .star(let r) = $0 { return .rep(r, 0, nil) }
            return nil
        },
        rewrite("R{n} ⇒ R…R (unrolled)") {
            if case .rep(let r, let m, let n) = $0, n == m, m >= 1 {
                return .group(.cat(Array(repeating: r, count: m)))
            }
            return nil
        },
        rewrite("R{m,n} ⇒ R{m}R{0,n−m}") {
            if case .rep(let r, let m, let n?) = $0, n > m {
                return .group(.cat([.rep(r, m, m), .rep(r, 0, n - m)]))
            }
            return nil
        },
        // EMI proper: an alternative that cannot match any a–c text.
        rewrite("R ⇒ (?:R|z+)  (dead alternative, equivalence modulo this text)") {
            .group(.alt([$0, .plus(.char("z"))]))
        },
    ]

    @Test func rewritesPreserveMatches() throws {
        try forAll(
            source: query,
            relations: Self.relations,
            testCases: 2000,
            database: "",
            subject: swiftRegex)
    }

    /// Two engines, one dialect: Swift's engine and ICU must agree on every
    /// match. Chen & Tse count this as a metamorphic relation across
    /// programs (identity transform, different subject); the rest of the
    /// world calls it differential testing.
    @Test func swiftAndICUAgree() throws {
        try forAll(query, testCases: 2000, database: "") { q in
            let (swift, icu) = (try swiftRegex(q), try icuRegex(q))
            guard swift == icu else {
                throw RelationViolated("swift \(swift) ≠ icu \(icu) for \(q)")
            }
        }
    }

    /// Reordering alternatives changes *which* match leftmost-first
    /// semantics picks, but not whether the whole text matches.
    @Test func alternativeOrderDoesNotAffectWholeMatch() throws {
        let reorder = Relation<Query, Bool>(
            "R|S ⇒ S|R preserves whole-match",
            followUp: { q, tc in
                let candidates = q.re.nodes.indices.filter {
                    if case .alt = q.re.nodes[$0] { return true }
                    return false
                }
                guard !candidates.isEmpty else { throw HegelError.assume }
                let target = candidates[Int(try tc.drawInteger(in: Int64(0)...Int64(candidates.count - 1)))]
                var q = q
                q.re = q.re.replacing(nodeAt: target) {
                    if case .alt(let rs) = $0 { return .alt(rs.reversed()) }
                    return $0
                }
                return q
            },
            holds: { a, b in
                guard a == b else { throw RelationViolated("whole-match verdict changed") }
            })
        try forAll(
            source: query,
            relations: [reorder],
            testCases: 1000,
            database: ""
        ) { q in try swiftRegex(q).whole }
    }
}
