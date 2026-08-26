import Testing
import Hegel
import Foundation

// Path and URL handling, in the shape of Mai, Pastore, Goknil and Briand's
// web-security relations: an access decision must not depend on how the
// attacker spells the input, and different parsers of the same string must
// not disagree about who the host is.

// MARK: - File paths under a root

/// A path an app would resolve under its own root (a document store, an
/// attachment directory, a local web view's file root).
struct PathQuery: Sendable, CustomStringConvertible {
    var segments: [String]
    var note = ""
    var requested: String { segments.joined(separator: "/") }
    var description: String { "\"\(requested)\"\(note)" }
}

let root = URL(filePath: "/srv/app/store", directoryHint: .isDirectory)

struct Resolution: Equatable, CustomStringConvertible {
    let path: String
    let inside: Bool
    var description: String { "\(path) (\(inside ? "inside" : "OUTSIDE") root)" }
}

/// What every such app does: resolve the requested path against the root
/// and check the result is still under it. The API matters, and the
/// relations below are what settled it: `.standardized` on the relative
/// URL escapes the base (see `standardizedOnARelativeURLEscapesTheBase`),
/// `.absoluteURL.standardized` keeps `a//a` as two segments (correct for a
/// URL, wrong for a file), `.standardizedFileURL` is the file-path one.
let resolve: @Sendable (PathQuery) -> Resolution = { q in
    let target = URL(filePath: q.requested, relativeTo: root).standardizedFileURL
    // Modulo the trailing slash: "a/." resolves to the directory "a/", the
    // same file as "a" (the first run shrank to exactly that pair).
    func strip(_ p: String) -> String { p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p }
    let path = strip(target.path(percentEncoded: false))
    let rootPath = strip(root.path(percentEncoded: false))
    return Resolution(path: path, inside: path == rootPath || path.hasPrefix(rootPath + "/"))
}

let segment = element(of: ["a", "b", "c", "docs", "x.txt"])
let pathQuery: Gen<PathQuery> = array(of: segment, count: 1...4).map { PathQuery(segments: $0) }

@Suite struct PathResolutionProperties {
    static let relations: [Relation<PathQuery, Resolution>] = [
        .invariant("inserting a \".\" segment") { q, tc in
            var q = q
            let at = Int(try tc.drawInteger(in: Int64(0)...Int64(q.segments.count)))
            q.segments.insert(".", at: at)
            q.note = "  (\".\" at \(at))"
            return q
        },
        .invariant("inserting \"x/..\"") { q, tc in
            var q = q
            let at = Int(try tc.drawInteger(in: Int64(0)...Int64(q.segments.count)))
            q.segments.insert(contentsOf: ["x", ".."], at: at)
            q.note = "  (\"x/..\" at \(at))"
            return q
        },
        .invariant("doubling a slash") { q, tc in
            var q = q
            let at = Int(try tc.drawInteger(in: Int64(1)...Int64(q.segments.count)))
            q.segments.insert("", at: at)
            q.note = "  (\"//\" at \(at))"
            return q
        },
        .invariant("a \"./\" prefix") { q, _ in
            var q = q
            q.segments.insert(".", at: 0)
            return q
        },
        // The web-security shape: more ".." than depth must flip the decision.
        Relation("\"..\" past the root ⇒ OUTSIDE",
            followUp: { q, tc in
                var q = q
                let extra = Int(try tc.drawInteger(in: Int64(1)...3))
                q.segments.insert(contentsOf: Array(repeating: "..", count: q.segments.count + extra), at: 0)
                q.note = "  (\(q.segments.count + extra)× \"..\")"
                return q
            },
            holds: { a, b in
                guard a.inside else { throw RelationViolated("the plain path resolved outside the root") }
                guard !b.inside else { throw RelationViolated("traversal past the root still resolves inside") }
            }),
    ]

    @Test func spellingDoesNotChangeTheResolution() throws {
        try forAll(source: pathQuery, relations: Self.relations, testCases: 1000, database: "", subject: resolve)
    }

    /// FOUND by the "x/.." relation on its first run, shrunk to `"a"` vs
    /// `"x/../a"`: on macOS 26 (Swift 6.3 Foundation) `URL.standardized` on
    /// a *relative* file URL applies RFC 3986's remove_dot_segments to the
    /// relative path alone, and that algorithm — specified only for the
    /// merged absolute path — turns `x/../a` into `/a`: the result is an
    /// absolute URL `file:///a`, the base is gone, and an app that checked
    /// `path.hasPrefix(root)` would now deny a legitimate request. `a/x/..`
    /// and `./a` standardize correctly; only a `..` that consumes the first
    /// segment trips it. `absoluteURL.standardized` and `standardizedFileURL`
    /// are right. The CI runner's older Foundation does NOT do this — it is
    /// a regression, reported as swiftlang/swift-foundation#2198 (same
    /// family as swift-corelibs-foundation #3234). Maintainers confirmed
    /// the diagnosis; fixed by swift-foundation#1942 (release/6.4.x: Swift
    /// 6.4, macOS 27). Verified on the 6.4 and main nightlies and on the
    /// macOS 27 beta (26A5416b) via Scripts/check-url-standardized.swift.
    /// This test pins the behavior
    /// where present and requires the fix where Foundation is new enough.
    @Test func standardizedOnARelativeURLEscapesTheBase() throws {
        let relativeStandardized: @Sendable (PathQuery) -> Resolution = { q in
            let target = URL(filePath: q.requested, relativeTo: root).standardized
            let path = target.path(percentEncoded: false)
            let rootPath = root.path(percentEncoded: false)
            return Resolution(path: path, inside: path == rootPath || path.hasPrefix(rootPath))
        }
        do {
            try forAll(
                source: pathQuery,
                relations: [Self.relations[1]],  // inserting "x/.."
                testCases: 300, database: "",
                subject: relativeStandardized)
            print("this Foundation standardizes relative URLs correctly (swift-foundation#2198 absent or fixed)")
        } catch let failure as PropertyFailure {
            if #available(macOS 27, iOS 27, *) {
                Issue.record("swift-foundation#2198 should be fixed here (#1942): \(failure)")
            }
            let group = try #require(failure.failures.first?.counterexample)
            #expect(group.contains("follow-up:    \"x/../a\""))
            #expect(group.contains("f(follow-up): /a (OUTSIDE root)"))
        }
    }
}

// MARK: - URL parsers

/// The parts of a URL an authorization or SSRF check would look at.
struct Authority: Equatable, CustomStringConvertible {
    let scheme: String?
    let user: String?
    let host: String?
    let port: Int?
    var description: String {
        "scheme=\(scheme ?? "nil") user=\(user ?? "nil") host=\(host ?? "nil") port=\(port.map(String.init) ?? "nil")"
    }
}

/// Hosts modulo two representation choices the first run surfaced (every
/// one of its ~60 disagreement classes was one of these): `URLComponents.host`
/// keeps the brackets of an IPv6 literal (`[::1]`) where `URL.host` and
/// `NSURL.host` strip them, and `URLComponents.host` decodes IDNA
/// (`xn--n3h.com` → `☃.com`) where the other two return punycode. Worth
/// knowing if a check compares hosts across APIs; not a parsing
/// disagreement. `encodedHost` gives the punycode form, and brackets are
/// stripped here.
func canonicalHost(_ h: String?) -> String? {
    guard var h else { return nil }
    if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
    return h
}

let swiftURL: @Sendable (String) -> Authority? = { s in
    URL(string: s).map { Authority(scheme: $0.scheme, user: $0.user, host: canonicalHost($0.host), port: $0.port) }
}

let components: @Sendable (String) -> Authority? = { s in
    URLComponents(string: s).map {
        Authority(scheme: $0.scheme, user: $0.user, host: canonicalHost($0.encodedHost), port: $0.port)
    }
}

let nsURL: @Sendable (String) -> Authority? = { s in
    NSURL(string: s).map {
        Authority(scheme: $0.scheme, user: $0.user, host: canonicalHost($0.host), port: $0.port?.intValue)
    }
}

/// URL strings shaped like authority-confusion attacks: userinfo with `@`
/// and `\`, percent-encoded delimiters, odd hosts, `#`/`?` where the path
/// should be.
let schemes: Gen<String> = element(of: ["http", "https", "file", "ftp"])
let userinfoTokens: Gen<String> = element(of: ["user", "u:p", "a@b", "%40", "\\", "a:b:c", "%2F"])
let userinfo: Gen<String> = oneOf([
    Gen { _ in "" },
    array(of: userinfoTokens, count: 1...2).map { $0.joined() + "@" },
])
let hosts: Gen<String> = element(of: [
    "example.com", "a.b", "127.0.0.1", "[::1]", "0x7f.1", "a_b", "EXAMPLE.com", "xn--n3h.com",
])
let ports: Gen<String> = oneOf([Gen { _ in "" }, element(of: [":80", ":8080", ":", ":0", ":65536", ":1a"])])
let pathTokens: Gen<String> = element(of: [
    "a", "b", ".", "..", "%2e%2e", "%2F", "%40", "@", "\\", ":", "%25", "%00", " ", "é", "#", "?", "//",
])
let paths: Gen<String> = array(of: pathTokens, count: 0...4).map { $0.joined(separator: "/") }

let hostileURL: Gen<String> = zip(schemes, userinfo, hosts, zip(ports, paths)).map { scheme, userinfo, host, tail in
    scheme + "://" + userinfo + host + tail.0 + "/" + tail.1
}

@Suite struct URLParserProperties {
    /// Three parsers of one string must agree on scheme, user, host and
    /// port, or all reject it. Disagreement is how host-confusion and SSRF
    /// bugs happen: the check looks at one parser's host, the request goes
    /// to another's.
    @Test func parsersAgreeOnTheAuthority() throws {
        try forAll(hostileURL, testCases: 1500, database: "") { s in
            let (a, b, c) = (swiftURL(s), components(s), nsURL(s))
            guard a == b, b == c else {
                throw RelationViolated(
                    "URL: \(a.map(\.description) ?? "nil")  URLComponents: \(b.map(\.description) ?? "nil")  NSURL: \(c.map(\.description) ?? "nil")")
            }
        }
    }
}
