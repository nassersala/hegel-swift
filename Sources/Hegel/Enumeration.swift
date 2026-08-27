/// One cell of an enumeration table: what the system must respond to a
/// stimulus in a state, and which state it is then in; or that the cell is
/// illegal (the stimulus cannot occur there).
public enum Cell<State, Response> {
    case respond(Response, then: State)
    case illegal
}

extension Cell: Sendable where State: Sendable, Response: Sendable {}
extension Cell: Equatable where State: Equatable, Response: Equatable {}

/// A sequence-based enumeration (Mills, Prowell & Poore; the Cleanroom
/// "state box"): every canonical state crossed with every stimulus, each
/// cell a response and a next state. Two ways to write it:
///
/// - as a function with an exhaustive `switch` over `(State, Stimulus)`,
///   where the compiler is the completeness check: leave a cell out and it
///   does not compile (convention: no `default` in stimulus position);
/// - as a dictionary of blocks, one per state, where `problems()` is the
///   completeness check (Aaron Hsu's form: states named by sequence, every
///   stimulus listed, illegal cells inline).
///
/// One table, several consumers: `problems()`, `walk(_:from:)` (a gate),
/// `commands(run:)` (Hegel drives the real system through it and shrinks
/// a mismatch to the shortest walk that shows it).
public struct Enumeration<State: CaseIterable & Hashable & Sendable, Stimulus: CaseIterable & Hashable & Sendable, Response: Sendable>: Sendable {
    public let initial: State
    let table: [State: [Stimulus: Cell<State, Response>]]

    /// The switch form. Every cell is evaluated once, here.
    public init(initial: State, _ cell: (State, Stimulus) -> Cell<State, Response>) {
        self.initial = initial
        var table: [State: [Stimulus: Cell<State, Response>]] = [:]
        for s in State.allCases {
            var block: [Stimulus: Cell<State, Response>] = [:]
            for x in Stimulus.allCases { block[x] = cell(s, x) }
            table[s] = block
        }
        self.table = table
    }

    /// The block form. Missing blocks and cells are reported by
    /// `problems()` and treated as illegal.
    public init(initial: State, table: [State: [Stimulus: Cell<State, Response>]]) {
        self.initial = initial
        self.table = table
    }

    public subscript(_ state: State, _ stimulus: Stimulus) -> Cell<State, Response> {
        table[state]?[stimulus] ?? .illegal
    }

    /// Whether the table is well formed: every state has a block, every
    /// block has every stimulus, every next state has a block, and every
    /// state is reachable from `initial`. Empty means complete.
    public func problems() -> [String] {
        var out: [String] = []
        for s in State.allCases where table[s] == nil { out.append("missing state \(s)") }
        for s in State.allCases {
            guard let block = table[s] else { continue }
            for x in Stimulus.allCases where block[x] == nil { out.append("\(s) missing \(x)") }
            for x in Stimulus.allCases {
                if case .respond(_, let next) = block[x] ?? .illegal, table[next] == nil {
                    out.append("\(s) ▸ \(x) → \(next) undefined")
                }
            }
        }
        var seen: Set<State> = [initial]
        var frontier = [initial]
        while let s = frontier.popLast() {
            for x in Stimulus.allCases {
                if case .respond(_, let next) = self[s, x], seen.insert(next).inserted { frontier.append(next) }
            }
        }
        for s in State.allCases where !seen.contains(s) { out.append("unreachable state \(s)") }
        return out
    }

    /// The result of walking a plan through the table.
    public enum Walk: Sendable {
        case accepted(end: State)
        /// The first illegal step: its index, the stimulus, and the state
        /// it was attempted in.
        case rejected(at: Int, Stimulus, in: State)
    }

    /// Walks a whole plan before any of it runs: the gate.
    public func walk(_ plan: [Stimulus], from start: State? = nil) -> Walk {
        var s = start ?? initial
        for (i, x) in plan.enumerated() {
            guard case .respond(_, let next) = self[s, x] else { return .rejected(at: i, x, in: s) }
            s = next
        }
        return .accepted(end: s)
    }

    /// One command per legal cell, in `allCases` order (deterministic, so a
    /// pinned seed replays across processes), named `state ▸ stimulus`. The
    /// model is the table; `run` applies the stimulus to the real system and
    /// returns its response, compared with the cell's under `equal`.
    /// Illegal cells get no command: they are never generated.
    public func commands<SUT>(
        run: @escaping @Sendable (inout SUT, Stimulus) throws -> Response,
        equal: @escaping @Sendable (Response, Response) -> Bool
    ) -> [Command<SUT, State>] {
        var out: [Command<SUT, State>] = []
        for s in State.allCases {
            for x in Stimulus.allCases {
                guard case .respond(let expected, let next) = self[s, x] else { continue }
                out.append(Command(
                    "\(s) ▸ \(x)",
                    precondition: { $0 == s },
                    run: { sut in try run(&sut, x) },
                    model: { state in state = next; return expected },
                    equal: equal))
            }
        }
        return out
    }

    public func commands<SUT>(
        run: @escaping @Sendable (inout SUT, Stimulus) throws -> Response
    ) -> [Command<SUT, State>] where Response: Equatable {
        commands(run: run, equal: ==)
    }
}
