// swift-foundation#2198: URL.standardized on a relative file URL applied RFC
// 3986 remove_dot_segments to the relative path alone, so `x/../a` against a
// base became `file:///a`. Fixed by swift-foundation#1942 (Swift 6.4, macOS
// 27). Exits non-zero where the bug is present. Run against any toolchain:
//   swift Scripts/check-url-standardized.swift
import Foundation
let root = URL(filePath: "/srv/root/", directoryHint: .isDirectory)
var failed = false
for (p, want) in [("x/../a", "file:///srv/root/a"), ("a/x/..", "file:///srv/root/a/"), ("./a", "file:///srv/root/a"), ("a", "file:///srv/root/a")] {
    let got = URL(filePath: p, relativeTo: root).standardized.absoluteString
    let ok = got == want
    if !ok { failed = true }
    print("\(ok ? "ok  " : "FAIL") \(p.padding(toLength: 8, withPad: " ", startingAt: 0)) standardized=\(got)\(ok ? "" : "  want \(want)")")
}
exit(failed ? 1 : 0)
