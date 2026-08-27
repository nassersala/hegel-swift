import Hegel
import Schedules

/// One line of `Scheduler.trace` as a state: the step is the state, so
/// PropRatt's tick atoms are atoms over the step's kind and lane. The
/// fixture's own state (the balance) is not in the trace; formulas here
/// speak about the scheduler, not the account.
struct Step: Equatable, Sendable, CustomStringConvertible {
    enum Kind: Equatable, Sendable { case enqueue, run, timer, advance, event }
    var kind: Kind
    var id: Int?
    var lane: String?
    /// Lanes of the jobs still ready after a `run` step.
    var ready: [String]
    /// The fake clock after this step.
    var now: Duration
    /// For `event` steps: the words after `event`, e.g. `["commit", "-100"]`.
    var event: [String] = []
    var description: String {
        kind == .event ? "event \(event.joined(separator: " "))" : "\(kind) #\(id.map(String.init) ?? "-")@\(lane ?? "-") ready \(ready) at \(now)"
    }

    /// Parses the scheduler's trace lines. Unknown lines are dropped.
    static func parse(_ trace: [String]) -> [Step] {
        var now: Duration = .zero
        var steps: [Step] = []
        for line in trace {
            let words = line.split(separator: " ")
            guard let head = words.first else { continue }
            func job(_ w: Substring) -> (Int?, String?) {
                let parts = w.dropFirst().split(separator: "@")
                return (parts.first.flatMap { Int($0) }, parts.dropFirst().first.map(String.init))
            }
            switch head {
            case "enqueue":
                let (id, lane) = job(words[1])
                steps.append(Step(kind: .enqueue, id: id, lane: lane, ready: [], now: now))
            case "run":
                let (id, lane) = job(words[1])
                let ready = line.split(separator: "(ready: ").dropFirst().first.map {
                    $0.dropLast(2).split(separator: ", ").map { String($0.split(separator: "@").last ?? "") }
                } ?? []
                steps.append(Step(kind: .run, id: id, lane: lane, ready: ready, now: now))
            case "timer":
                steps.append(Step(kind: .timer, id: Int(words[1].dropFirst()), lane: nil, ready: [], now: now))
            case "advance":
                // "advance to 3.0 seconds, firing #1"
                let text = line.split(separator: " to ").dropFirst().first.map { $0.split(separator: ",").first.map(String.init) ?? "" } ?? ""
                now = Duration.parse(text) ?? now
                steps.append(Step(kind: .advance, id: nil, lane: nil, ready: [], now: now))
            case "event":
                steps.append(Step(kind: .event, id: nil, lane: nil, ready: [], now: now, event: words.dropFirst().map(String.init)))
            default:
                continue
            }
        }
        return steps
    }
}

extension Duration {
    /// Parses `Duration`'s description, "3.0 seconds".
    static func parse(_ text: String) -> Duration? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]), parts[1] == "seconds" else { return nil }
        return .seconds(value)
    }
}

/// Tick atoms: what happened at this step.
extension Pred where State == Step {
    /// A job ran on `lane` at this step.
    static func ticked(_ lane: String) -> Pred { now { $0.kind == .run && $0.lane == lane } }
    /// A step of this kind.
    static func ticked(_ kind: Step.Kind) -> Pred { now { $0.kind == kind } }
    /// A semantic event with this name; `value` sees its argument.
    static func event(_ name: String, _ value: @escaping @Sendable (Int) -> Bool = { _ in true }) -> Pred {
        now { $0.kind == .event && $0.event.first == name && $0.event.dropFirst().first.flatMap { Int($0) }.map(value) ?? false }
    }
}

/// A formula failed over a trace: the report is the offending step in
/// its context, PropRatt's counterexample table as text.
struct TemporalViolation: Error, CustomStringConvertible {
    let formula: String
    let step: Int
    let steps: [Step]
    var description: String {
        let lines = steps.indices.map { "\($0 == step ? ">" : " ") \(steps[$0])" }
        return "\(formula) fails at step \(step)\n" + lines.joined(separator: "\n")
    }
}

/// Checks `formula` at position 0; throws with the first failing step.
func check(_ name: String, _ formula: Pred<Step>, over trace: [String]) throws {
    let steps = Step.parse(trace)
    if let step = firstFailure(of: formula, over: steps) {
        throw TemporalViolation(formula: name, step: step, steps: steps)
    }
}
