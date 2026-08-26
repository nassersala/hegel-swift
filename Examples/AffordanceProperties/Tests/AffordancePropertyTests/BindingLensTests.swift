import Testing
import Hegel
import SwiftUI

// Every hand-written `Binding(get:set:)` is a lens, and the lens laws say
// whether it is a lawful one. A binding over a struct field (what
// `$model.volume` gives you) passes; the familiar "text field over an Int"
// binding fails put-get at the empty string — type a non-number, the field
// resets — and the shrinker names the minimal string.

@MainActor
@Suite struct BindingLensTests {
    static let ints = Gen<Int>.int(in: -1000...1000)
    static let strings = array(of: element(of: ["0", "1", "a"]), count: 0...3).map { $0.joined() }

    /// A binding derived from `Binding<S>`, modeled as a lens: `get` reads
    /// it over the state, `set` builds it over a copy of the state, assigns
    /// through it, and returns the copy.
    static func lens<S: Sendable, V: Sendable>(
        _ derive: @escaping @Sendable (Binding<S>) -> Binding<V>
    ) -> (get: @Sendable (S) -> V, set: @Sendable (S, V) -> S) {
        (
            get: { s in
                MainActor.assumeIsolated { derive(.constant(s)).wrappedValue }
            },
            set: { s, v in
                MainActor.assumeIsolated {
                    var copy = s
                    let root = Binding<S>(get: { copy }, set: { copy = $0 })
                    derive(root).wrappedValue = v
                    return copy
                }
            }
        )
    }

    struct Volume: Equatable, Sendable { var level: Int; var muted: Bool }

    /// `$model.level` — a binding over a stored property — is a lawful lens.
    @Test func bindingOverAStoredPropertyIsALens() throws {
        let states = zip(Self.ints, .bool).map { Volume(level: $0, muted: $1) }
        let (get, set) = Self.lens { (root: Binding<Volume>) in root.level }
        try forAll(Laws.lens(states, Self.ints, get: get, set: set), database: "")
    }

    /// The text-field binding: `Binding<String>` over an `Int`, with
    /// `set: { value = Int($0) ?? 0 }`. get-put and put-put hold; put-get
    /// fails at `""` — `get(set(s, ""))` is `"0"`.
    @Test func textFieldBindingOverAnIntIsNotALens() throws {
        let (get, set) = Self.lens { (root: Binding<Int>) in
            Binding<String>(get: { String(root.wrappedValue) }, set: { root.wrappedValue = Int($0) ?? 0 })
        }
        do {
            try forAll(Laws.lens(Self.ints, Self.strings, get: get, set: set), testCases: 300, database: "")
            Issue.record("expected put-get to fail")
        } catch let failure as PropertyFailure {
            #expect(failure.failures.count == 1)
            let c = try #require(failure.failures.first?.counterexample)
            #expect(c.hasPrefix("suite: lens Int → String\n  law: put-get\n  (s: 0, v: \"\")\n"))
            #expect(c.hasSuffix("violated: get(set(s, v)) = 0, v = "))
        }
    }
}
