import Hegel

/// Search-as-you-type, above the code. A text field, one network request
/// per edit, a results list; responses arrive in any order and any request
/// can fail. Drawn first on "a", "ab", "abc", with the second response
/// failing and the first arriving late:
///
///     [query: "", shown: ⟨"", []⟩, pending: {}, error: no]
///      ─type "a"─▶      [query: "a",   shown: ⟨"", []⟩, pending: {0:"a"},         error: no]
///      ─type "ab"─▶     [query: "ab",  shown: ⟨"", []⟩, pending: {0:"a", 1:"ab"}, error: no]
///      ─1 fails─▶       [query: "ab",  shown: ⟨"", []⟩, pending: {0:"a"},         error: yes]
///      ─0 ok [a1, a2]─▶ [query: "ab",  shown: ⟨"", []⟩, pending: {},              error: yes]   stale
///      ─type "abc"─▶    [query: "abc", shown: ⟨"", []⟩, pending: {2:"abc"},       error: no]
///      ─2 ok [abc1]─▶   [query: "abc", shown: ⟨"abc", [abc1]⟩, pending: {},      error: no]
///
/// Two variables had to be written in for the rows to follow from the
/// arrows. `shown` carries the query its list answers: at "1 fails" the
/// next row needs to know whether the screen already answers "ab". And
/// `pending` maps request numbers to queries: at "0 ok" the next row
/// needs to know that request 0 asked something the user no longer asks.
/// `n`, the next request number, is the third: after request 0 is gone
/// the row no longer says that 2 is the next name.
///
/// A step is one edit of the text or one arrival. Sending is part of the
/// edit; the network is not a step.
///
///     Init:  query = "" ∧ shown = ⟨"", []⟩ ∧ pending = {} ∧ error = false ∧ n = 0
///     Next:  Type(q):  q ≠ query ∧ query′ = q ∧ error′ = false
///                    ∧ if q = "" then shown′ = ⟨"", []⟩ ∧ pending′ = pending ∧ n′ = n
///                      else shown′ = shown ∧ pending′ = pending ∪ {⟨n, q⟩} ∧ n′ = n + 1
///          ∨ Arrive(r, outcome):  r ∈ pending ∧ pending′ = pending \ {r} ∧ query′ = query ∧ n′ = n
///                    ∧ if r.query ≠ query then shown′ = shown ∧ error′ = error            (stale)
///                      else outcome = ok(rs): shown′ = ⟨query, rs⟩ ∧ error′ = false
///                           outcome = fail:   shown′ = shown ∧ error′ = (shown.query ≠ query)
///
///     Loading ≝ ∃ r ∈ pending: r.query = query
///     Inv:  (¬Loading ⇒ shown.query = query ∨ error) ∧ (error ⇒ shown.query ≠ query)
///
/// The "pick any"s: which pending request arrives, whether it failed,
/// what the user types. Which request arrives is the arrival order; every
/// order is a behaviour. Inv is what the screen promises: the list answers
/// what is typed, or a spinner is on, or an error is shown, and never an
/// error over a list that answers.
///
/// Two wrong designs are kept for refutation: `naive` shows whatever
/// arrives, `halfChecked` drops stale results but shows stale failures.
public struct Search: Equatable, Sendable, CustomStringConvertible {
    public struct Request: Hashable, Sendable, CustomStringConvertible {
        public let id: Int
        public let query: String
        public init(id: Int, query: String) {
            self.id = id
            self.query = query
        }
        public var description: String { "\(id):\"\(query)\"" }
    }

    /// The list and the query it answers.
    public struct Shown: Equatable, Sendable, CustomStringConvertible {
        public var query: String
        public var results: [String]
        public init(query: String, results: [String]) {
            self.query = query
            self.results = results
        }
        public var description: String { "⟨\"\(query)\", \(results)⟩" }
    }

    public enum Outcome: Hashable, Sendable {
        case ok([String])
        case failed
    }

    /// The arrow words.
    public enum Event: Hashable, Sendable, CustomStringConvertible {
        case type(String)
        case arrive(Int, Outcome)

        public var description: String {
            switch self {
            case .type(let q): return "type \"\(q)\""
            case .arrive(let id, .ok(let rs)): return "\(id) ok \(rs)"
            case .arrive(let id, .failed): return "\(id) fails"
            }
        }
    }

    /// Which Arrive clause. `checked` is the design; the other two are
    /// wrong and refuted on drawn behaviours.
    public enum Design: Sendable, CaseIterable {
        /// Every arrival is shown: `shown′ = ⟨r.query, rs⟩`, a failure is an error.
        case naive
        /// Stale results are dropped; every failure is an error.
        case halfChecked
        /// The relation above.
        case checked
    }

    public var query: String
    public var shown: Shown
    /// Kept sorted by id; a set.
    public var pending: [Request]
    public var error: Bool
    public var next: Int

    public init() {
        query = ""
        shown = Shown(query: "", results: [])
        pending = []
        error = false
        next = 0
    }
    public init(query: String, shown: Shown, pending: [Request], error: Bool, next: Int) {
        self.query = query
        self.shown = shown
        self.pending = pending.sorted { $0.id < $1.id }
        self.error = error
        self.next = next
    }

    /// `Loading`: a request for what is typed is in flight.
    public var loading: Bool { pending.contains { $0.query == query } }
    /// Quiescent: nothing in flight.
    public var done: Bool { pending.isEmpty }
    /// `Inv`.
    public var truthful: Bool {
        (loading || shown.query == query || error) && (!error || shown.query != query)
    }

    public var description: String {
        "query = \"\(query)\", shown = \(shown), pending = \(pending), error = \(error)"
    }

    /// The fake server: what an `ok` response to `q` carries. The relation
    /// does not care; the behaviours use one fixed answer so that
    /// "the list answers its query" is checkable.
    public static func answer(_ q: String) -> [String] { ["\(q)1", "\(q)2"] }

    /// The queries a behaviour draws from. Small, and including "" so that
    /// clearing the field is a step.
    public static let queries = ["", "a", "b", "ab"]

    // MARK: Next

    /// `Next(self, event)` is enabled.
    public func enabled(_ e: Event) -> Bool {
        switch e {
        case .type(let q): return q != query
        case .arrive(let id, _): return pending.contains { $0.id == id }
        }
    }

    /// Precondition: `enabled(e)`.
    public mutating func apply(_ e: Event, design: Design = .checked) {
        precondition(enabled(e), "\(e) is not enabled at \(self)")
        switch e {
        case .type(let q):
            query = q
            error = false
            if q.isEmpty {
                shown = Shown(query: "", results: [])
            } else {
                pending.append(Request(id: next, query: q))
                next += 1
            }
        case .arrive(let id, let outcome):
            let i = pending.firstIndex { $0.id == id }!
            let r = pending.remove(at: i)
            let stale = r.query != query
            switch (design, outcome) {
            case (.naive, .ok(let rs)):
                shown = Shown(query: r.query, results: rs)
                error = false
            case (.naive, .failed), (.halfChecked, .failed):
                error = true
            case (.halfChecked, .ok(let rs)), (.checked, .ok(let rs)):
                if !stale {
                    shown = Shown(query: query, results: rs)
                    error = false
                }
            case (.checked, .failed):
                if !stale { error = shown.query != query }
            }
        }
    }

    /// The "pick any"s as draws: an arrival of any pending request with
    /// either outcome, or an edit to any other query.
    public func draw(_ tc: TestCase) throws -> Event {
        if !pending.isEmpty, try tc.drawBool() {
            return try drawArrival(tc)
        }
        let others = Search.queries.filter { $0 != query }
        return .type(others[Int(try tc.drawInteger(in: 0...Int64(others.count - 1)))])
    }

    /// The pick of a pending arrival only, used to drain. A failure is
    /// the `true` draw, so an outcome shrinks toward `ok`.
    func drawArrival(_ tc: TestCase) throws -> Event {
        let r = pending[Int(try tc.drawInteger(in: 0...Int64(pending.count - 1)))]
        return .arrive(r.id, try tc.drawBool(probability: 0.3) ? .failed : .ok(Search.answer(r.query)))
    }

    public struct Run: Sendable {
        /// The environment's moves, edits and arrivals, in order.
        public let events: [Event]
        /// The state after each event, under `design`.
        public let states: [Search]
        public let final: Search
    }

    /// A complete behaviour: drawn edits and arrivals, then every request
    /// still in flight arrives in a drawn order, so the run ends
    /// quiescent. The events are the same under every design; only the
    /// states differ.
    public static func behaviour(design: Design = .checked) -> Gen<Run> {
        Gen { tc in
            var s = Search()
            var states: [Search] = []
            var events = try tc.drawCollection(count: 0...10) {
                let e = try s.draw(tc)
                s.apply(e, design: design)
                states.append(s)
                return e
            }
            while !s.done {
                let e = try s.drawArrival(tc)
                s.apply(e, design: design)
                states.append(s)
                events.append(e)
            }
            return Run(events: events, states: states, final: s)
        }
    }
}
