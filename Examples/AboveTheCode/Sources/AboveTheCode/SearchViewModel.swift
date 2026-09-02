/// The code under the relation in `Search.swift`: a view model with no
/// SwiftUI in it. The app wraps it in `@Observable` on the main actor and
/// binds a text field to `setQuery`, a list to `results`, a spinner to
/// `isLoading`, a banner to `errorMessage`. The transport is a protocol,
/// so a test can hold every response and deliver them in a drawn order.
///
/// `isLoading` is derived, not stored: a request for the current text is
/// in flight. Storing it is where `spinsForStaleRequests` comes from.
public final class SearchViewModel {
    /// One-line deviations from the design, each a bug the refinement
    /// check reports as the first pair that is not a `Next` step.
    public enum Bug: Sendable, CaseIterable {
        /// No staleness check at all.
        case trustsEveryResponse
        /// Stale results are dropped, stale failures are shown.
        case trustsEveryFailure
        /// `isLoading` is "anything in flight".
        case spinsForStaleRequests
        /// A failure for the current text shows an error even when the
        /// list already answers it.
        case errorOverAnswer
    }

    public private(set) var query = ""
    public private(set) var results: [String] = []
    /// The query `results` answers. A header can show it; the refinement
    /// mapping needs it.
    public private(set) var resultsFor = ""
    public private(set) var errorMessage: String?
    public var isLoading: Bool {
        bug == .spinsForStaleRequests ? !inFlight.isEmpty : inFlight.contains(query)
    }

    /// The query of each request in flight, one entry per request.
    private var inFlight: [String] = []
    private let transport: any SearchTransport
    private let bug: Bug?

    public init(transport: any SearchTransport, bug: Bug? = nil) {
        self.transport = transport
        self.bug = bug
    }

    /// The text field changed. Clearing shows nothing and asks nothing;
    /// anything else asks the transport and keeps what is shown until an
    /// answer for the new text arrives.
    public func setQuery(_ q: String) {
        guard q != query else { return }
        query = q
        errorMessage = nil
        if q.isEmpty {
            results = []
            resultsFor = ""
            return
        }
        inFlight.append(q)
        transport.search(q) { [weak self] outcome in self?.received(outcome, for: q) }
    }

    private func received(_ outcome: Result<[String], any Error>, for q: String) {
        if let i = inFlight.firstIndex(of: q) { inFlight.remove(at: i) }
        let stale = q != query
        switch outcome {
        case .success(let rs):
            if stale && bug != .trustsEveryResponse { return }
            results = rs
            resultsFor = q
            errorMessage = nil
        case .failure(let e):
            switch bug {
            case .trustsEveryResponse, .trustsEveryFailure:
                errorMessage = "\(e)"
            case .errorOverAnswer:
                if !stale { errorMessage = "\(e)" }
            case .spinsForStaleRequests, nil:
                if !stale { errorMessage = resultsFor == query ? nil : "\(e)" }
            }
        }
    }
}

public protocol SearchTransport: AnyObject {
    /// Sends one request. `deliver` is called once, when the response
    /// arrives, on the view model's thread.
    func search(_ query: String, deliver: @escaping (Result<[String], any Error>) -> Void)
}

/// A transport that holds every response until told which to deliver.
/// Requests are numbered in the order they are sent, which is the order
/// the relation numbers them.
public final class FakeNetwork: SearchTransport {
    public struct Failure: Error, CustomStringConvertible {
        public var description: String { "request failed" }
    }

    public private(set) var issued = 0
    private var waiting: [Int: (query: String, deliver: (Result<[String], any Error>) -> Void)] = [:]

    public init() {}

    /// What is in flight, as the relation's `pending`.
    public var pending: [Search.Request] {
        waiting.keys.sorted().map { Search.Request(id: $0, query: waiting[$0]!.query) }
    }

    public func search(_ query: String, deliver: @escaping (Result<[String], any Error>) -> Void) {
        waiting[issued] = (query, deliver)
        issued += 1
    }

    /// Delivers request `id`, if it is in flight.
    @discardableResult
    public func deliver(_ id: Int, _ outcome: Search.Outcome) -> Bool {
        guard let w = waiting.removeValue(forKey: id) else { return false }
        switch outcome {
        case .ok(let rs): w.deliver(.success(rs))
        case .failed: w.deliver(.failure(Failure()))
        }
        return true
    }
}

extension Search {
    /// The refinement mapping: the view model's state and the transport's
    /// queue, read as a `Search` state.
    public static func project(_ vm: SearchViewModel, _ network: FakeNetwork) -> Search {
        Search(
            query: vm.query,
            shown: Shown(query: vm.resultsFor, results: vm.results),
            pending: network.pending,
            error: vm.errorMessage != nil,
            next: network.issued)
    }

    public struct Violation: CustomStringConvertible, Sendable {
        /// Index of the event in the run.
        public let step: Int
        public let from: Search
        public let event: Event
        public let expected: Search
        public let got: Search
        public let reason: String

        public var description: String {
            """
            step \(step): \(event) is not a Next step, \(reason)
              from:     \(from)
              expected: \(expected)
              got:      \(got)
            """
        }
    }

    /// Drives a fresh view model through `events`, one edit or one
    /// delivery per event, and checks after each that the projected
    /// state is the relation's, and that `isLoading` is `Loading`.
    /// Returns the first violation, if any, and the state reached.
    public static func refines(
        _ events: [Event], bug: SearchViewModel.Bug? = nil, design: Design = .checked
    ) -> (violation: Violation?, final: Search) {
        let network = FakeNetwork()
        let vm = SearchViewModel(transport: network, bug: bug)
        var s = Search()
        for (i, e) in events.enumerated() {
            var expected = s
            expected.apply(e, design: design)
            switch e {
            case .type(let q): vm.setQuery(q)
            case .arrive(let id, let outcome):
                if !network.deliver(id, outcome) {
                    return (Violation(step: i, from: s, event: e, expected: expected, got: project(vm, network),
                                      reason: "the code has no request \(id) in flight"), s)
                }
            }
            let got = project(vm, network)
            guard got == expected else {
                return (Violation(step: i, from: s, event: e, expected: expected, got: got, reason: "states differ"), s)
            }
            guard vm.isLoading == expected.loading else {
                return (Violation(step: i, from: s, event: e, expected: expected, got: got,
                                  reason: "isLoading is \(vm.isLoading), Loading is \(expected.loading)"), s)
            }
            s = expected
        }
        return (nil, s)
    }
}
