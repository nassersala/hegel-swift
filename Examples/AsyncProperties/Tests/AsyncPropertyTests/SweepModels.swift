import AsyncSequenceValidation

/// Models for the second sweep: two-source operators whose children pull
/// on demand. Events from both sources are consumed in (tick, side) order,
/// which is how the runtime resolves simultaneous emissions.
extension Sim {
    enum Side: Int { case base = 0, signal = 1 }
    enum Merged: Equatable {
        case value(String, side: Int, tick: Int)
        case finish(side: Int, tick: Int)
        case failure(side: Int, tick: Int)
        var tick: Int {
            switch self {
            case .value(_, _, let t), .finish(_, let t), .failure(_, let t): return t
            }
        }
    }

    /// Both sources' events in tick order, each source ending with its
    /// terminal. Within a tick, `order` decides: the runtime resolves a
    /// tie by how many job hops each path needs, so an operator's tie
    /// rule is a measured fact, not a contract (see the self-checks).
    static func merged(_ script: Script, order: (Merged) -> (Int, Int)) -> [Merged] {
        var events: [Merged] = []
        for side in 0..<script.sources.count {
            for e in script.emissions where e.source == side {
                events.append(.value(e.value, side: side, tick: e.tick))
            }
            let (kind, t) = script.terminals[side]
            events.append(kind == .finish ? .finish(side: side, tick: t) : .failure(side: side, tick: t))
        }
        return events.enumerated().sorted {
            let a = order($0.element), b = order($1.element)
            return ($0.element.tick, a.0, a.1, $0.offset) < ($1.element.tick, b.0, b.1, $1.offset)
        }.map(\.element)
    }
    static func sideOf(_ m: Merged) -> Int {
        switch m {
        case .value(_, let s, _), .finish(let s, _), .failure(let s, _): return s
        }
    }
    static func kindOf(_ m: Merged) -> Int {
        switch m {
        case .value: return 0
        case .finish: return 1
        case .failure: return 2
        }
    }

    // MARK: combineLatest

    /// A tuple per upstream element once every source has emitted, in
    /// merged order, observed at max(its tick, demand); tuples buffer
    /// without limit while no demand is outstanding; failure ends the
    /// output at or after its tick, after earlier tuples; finish when
    /// both sources have finished, or at once when a source finishes
    /// before ever emitting (`emptyUpstreamFinished`). Tie rule within a
    /// tick: values, then finishes, then failures (errors take more hops).
    static func combineLatest(_ script: Script) -> [Observation] {
        var latest: [String?] = [nil, nil]
        var finished = [false, false]
        var available: [Observation] = []
        loop: for event in merged(script, order: { (kindOf($0), sideOf($0)) }) {
            switch event {
            case .value(let v, let side, let t):
                latest[side] = v
                if let a = latest[0], let b = latest[1] { available.append(.value(a + b, tick: t)) }
            case .finish(let side, let t):
                finished[side] = true
                if latest[side] == nil || (finished[0] && finished[1]) { available.append(.finish(tick: t)); break loop }
            case .failure(_, let t):
                available.append(.failure(tick: t))
                break loop
            }
        }
        return deliver(available, demands: script.demandTicks)
    }

    /// Observes each available event at max(availability, demand), in
    /// order, stopping at a terminal or when demand runs out.
    static func deliver(_ available: [Observation], demands: [Int]) -> [Observation] {
        var out: [Observation] = []
        var now = 0
        for (i, d) in demands.enumerated() {
            guard i < available.count else { break }
            now = max(now, d, available[i].tick)
            switch available[i] {
            case .value(let v, _): out.append(.value(v, tick: now))
            case .finish: out.append(.finish(tick: now)); return out
            case .failure: out.append(.failure(tick: now)); return out
            default: break
            }
        }
        exhausted(&out, demands: demands.count, now: now)
        return out
    }

    // MARK: chunks(ofCount:or:) / chunked(by:)

    /// Pull loop over the merged (base, signal) stream: base elements
    /// accumulate; a full chunk (`count`) or a signal with a non-empty
    /// accumulator emits at that event's tick; base finish emits the
    /// remainder (then finish on the next demand); base failure fails,
    /// dropping the accumulator; signal finish is ignored; signal failure
    /// fails. Tie rule within a tick: the signal's event reaches merge
    /// before the base's (the base path has one more hop); within a
    /// source, values before terminals.
    static func chunks(_ script: Script, count: Int?) -> [Observation] {
        let events = merged(script, order: { (kindOf($0), -sideOf($0)) })
        var i = 0
        var out: [Observation] = []
        var now = 0
        var acc: [String] = []
        var terminated = false
        let demands = script.demandTicks
        for d in demands {
            now = max(now, d)
            if terminated { out.append(.finish(tick: now)); return out }
            var delivered = false
            while !delivered {
                guard i < events.count else {
                    // Both sources done without a base terminal: cannot happen, sources always end.
                    out.append(.finish(tick: now)); return out
                }
                let event = events[i]
                i += 1
                now = max(now, event.tick)
                switch event {
                case .value(let v, 0, _):
                    acc.append(v)
                    if let count, acc.count == count {
                        out.append(.value(acc.joined(), tick: now)); acc = []; delivered = true
                    }
                case .value(_, _, _):  // signal
                    if !acc.isEmpty { out.append(.value(acc.joined(), tick: now)); acc = []; delivered = true }
                case .finish(0, _):
                    terminated = true
                    if acc.isEmpty { out.append(.finish(tick: now)); return out }
                    out.append(.value(acc.joined(), tick: now)); acc = []; delivered = true
                case .finish(_, _):
                    break  // signal finished; keep chunking by count / base end
                case .failure(_, _):
                    out.append(.failure(tick: now)); return out
                }
            }
        }
        exhausted(&out, demands: demands.count, now: now)
        return out
    }
}

// MARK: - combineLatest, acceptance form

extension Model {
    /// `combineLatest` under arbitrary demand. Children pull on demand, so
    /// when the consumer is late several elements become available in one
    /// pull and their order is scheduling. The law is therefore a set:
    /// each tuple is (latest of side 0, latest of side 1) after consuming
    /// one more element of either side (any number while a side is still
    /// empty), every consumed element's tick ≤ the observation tick;
    /// finish when both sides finished and every element was consumed,
    /// or when a side with no values finished; failure only once some
    /// side has failed (its earlier values may have been consumed
    /// silently while the other side was still empty).
    static func combineLatest(_ script: Script, _ trace: Trace) throws {
        try structure(script, trace)
        let values = (0..<2).map { s in script.emissions.filter { $0.source == s } }
        let terminals = script.terminals
        var states: Set<[Int]> = [[0, 0]]  // consumed per side
        for (k, event) in trace.events.enumerated() {
            switch event {
            case .value(let v, let t):
                var next: Set<[Int]> = []
                for st in states {
                    let (i0, i1) = (st[0], st[1])
                    func avail(_ s: Int, _ j: Int) -> Bool { j <= values[s].count && (j == 0 || values[s][j - 1].tick <= t) }
                    let (j0s, j1s): ([Int], [Int])
                    if i0 == 0 || i1 == 0 {
                        // still warming up: any prefix of either side may be consumed
                        j0s = Array(max(i0, 1)...values[0].count).filter { avail(0, $0) }
                        j1s = Array(max(i1, 1)...values[1].count).filter { avail(1, $0) }
                        guard !values[0].isEmpty, !values[1].isEmpty else { continue }
                    } else {
                        j0s = [i0, i0 + 1].filter { avail(0, $0) }
                        j1s = [i1, i1 + 1].filter { avail(1, $0) }
                    }
                    for j0 in j0s where j0 >= 1 {
                        for j1 in j1s where j1 >= 1 {
                            if (i0 == 0 || i1 == 0) || (j0 + j1 == i0 + i1 + 1) {
                                if values[0][j0 - 1].value + values[1][j1 - 1].value == v { next.insert([j0, j1]) }
                            }
                        }
                    }
                }
                guard !next.isEmpty else { throw Illegal(reason: "\(v)@\(t) is not a legal tuple from \(states)", at: k) }
                states = next
            case .finish(let t):
                let ok = states.contains { st in
                    let empty = (0..<2).contains { values[$0].isEmpty && terminals[$0].0 == .finish && terminals[$0].tick <= t }
                    let both = (0..<2).allSatisfy { terminals[$0].0 == .finish && terminals[$0].tick <= t && st[$0] == values[$0].count }
                    return empty || both
                }
                guard ok else { throw Illegal(reason: "finish@\(t) not legal from \(states)", at: k) }
            case .failure(let t):
                let ok = (0..<2).contains { terminals[$0].0 == .failure && terminals[$0].tick <= t }
                guard ok else { throw Illegal(reason: "failure@\(t) not legal: no side failed by then", at: k) }
            case .cancelled, .demandExhausted, .error:
                break
            }
        }
    }
}
