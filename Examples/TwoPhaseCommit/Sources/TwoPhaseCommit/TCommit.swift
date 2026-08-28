/// Lamport's `TCommit` (TLA+ video course, lecture 5): the specification
/// two-phase commit implements. Resource managers only, no coordinator,
/// no messages. Each RM is `working`, `prepared`, `committed` or
/// `aborted`; `Prepare(rm)` moves a working RM to prepared; `Decide(rm)`
/// commits a prepared RM if every RM is prepared or committed
/// (`canCommit`), or aborts a working or prepared RM if none has
/// committed (`notCommitted`). Consistency, no two RMs deciding
/// differently, is a theorem of it.
public enum TCommit {
    public enum RMState: String, Sendable, Equatable { case working, prepared, committed, aborted }

    public struct State: Sendable, Equatable, CustomStringConvertible {
        public var rmState: [String: RMState]
        public init(rms: [String]) { rmState = Dictionary(uniqueKeysWithValues: rms.map { ($0, .working) }) }
        public var canCommit: Bool { rmState.values.allSatisfy { $0 == .prepared || $0 == .committed } }
        public var notCommitted: Bool { rmState.values.allSatisfy { $0 != .committed } }
        public var consistent: Bool { !(rmState.values.contains(.aborted) && rmState.values.contains(.committed)) }
        public var description: String {
            rmState.keys.sorted().map { "\($0): \(rmState[$0]!.rawValue)" }.joined(separator: ", ")
        }
    }

    /// `TCNext`'s disjuncts, one RM each.
    public enum Step: Sendable, Equatable, CustomStringConvertible {
        case prepare(String)
        case decide(String, Decision)
        public var description: String {
            switch self {
            case .prepare(let rm): "Prepare(\(rm))"
            case .decide(let rm, let d): "Decide(\(rm), \(d.rawValue))"
            }
        }
    }

    /// The next-state relation: the state after `step`, or nil if the
    /// step is not enabled.
    public static func next(_ s: State, _ step: Step) -> State? {
        var t = s
        switch step {
        case .prepare(let rm):
            guard s.rmState[rm] == .working else { return nil }
            t.rmState[rm] = .prepared
        case .decide(let rm, .commit):
            guard s.rmState[rm] == .prepared, s.canCommit else { return nil }
            t.rmState[rm] = .committed
        case .decide(let rm, .abort):
            guard let r = s.rmState[rm], r == .working || r == .prepared, s.notCommitted else { return nil }
            t.rmState[rm] = .aborted
        }
        return t
    }

    public struct Violation: Error, Equatable, CustomStringConvertible {
        public var index: Int
        public var step: Step
        public var state: State
        public var description: String { "step \(index) \(step) is not enabled in [\(state)]" }
    }

    /// Every step must be a `TCNext` step from the state so far. Returns
    /// the first step that is not, and the final state.
    public static func refines(_ steps: [Step], rms: [String]) -> (violation: Violation?, final: State) {
        var s = State(rms: rms)
        for (i, step) in steps.enumerated() {
            guard let t = next(s, step) else { return (Violation(index: i, step: step, state: s), s) }
            s = t
        }
        return (nil, s)
    }

    /// The refinement mapping from the implementation's event trace:
    /// what a participant does is a `TCommit` step of that RM; what the
    /// coordinator and the network do is forgotten, as `TwoPhase.tla`'s
    /// `tmState`, `tmPrepared` and `msgs` are.
    public static func project(_ events: [Event]) -> [Step] {
        events.compactMap { e in
            guard e.node.hasPrefix("p") else { return nil }
            switch e.words.first {
            case "vote": return e.words[1] == "yes" ? .prepare(e.node) : nil  // a no is followed by its own `decide abort`
            case "decide": return Decision(rawValue: e.words[1]).map { .decide(e.node, $0) }
            default: return nil
            }
        }
    }
}
