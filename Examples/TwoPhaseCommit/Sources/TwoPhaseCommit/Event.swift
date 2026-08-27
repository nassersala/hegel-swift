/// The protocol's semantic events, projected from the scheduler's trace,
/// each carrying the state so far: the votes cast and the decisions
/// taken, so a formula over the trace is a formula over states.
public struct Event: Sendable, Equatable, CustomStringConvertible {
    public var node: String
    public var words: [String]
    /// Votes cast so far, by participant name.
    public var votes: [String: Bool]
    /// Decisions taken so far, by node name (the coordinator is `c`).
    public var decisions: [String: Decision]
    public var blocked: Set<String>

    public var description: String { "\(node) \(words.joined(separator: " "))" }
    public func named(_ name: String) -> Bool { words.first == name }
    public var decision: Decision? { named("decide") ? Decision(rawValue: words[1]) : nil }

    public static func parse(_ trace: [String]) -> [Event] {
        var votes: [String: Bool] = [:], decisions: [String: Decision] = [:], blocked: Set<String> = []
        var events: [Event] = []
        for line in trace where line.hasPrefix("event ") {
            let words = line.split(separator: " ").dropFirst().map(String.init)
            guard words.count >= 2 else { continue }
            let node = words[0], rest = Array(words.dropFirst())
            switch rest[0] {
            case "vote": votes[node] = rest[1] == "yes"
            case "decide": decisions[node] = Decision(rawValue: rest[1])
            case "blocked": blocked.insert(node)
            default: break
            }
            events.append(Event(node: node, words: rest, votes: votes, decisions: decisions, blocked: blocked))
        }
        return events
    }
}
