import AsyncSequenceValidation

/// Executable reference models for the timed operators and for `buffer`.
/// Each produces the one trace it predicts for a script, so the law is
/// trace equality, not acceptance. Simulations are over discrete ticks
/// with the runtime's resolution rules: a value emitted at tick t is
/// visible to a pull at t; a pull issued at d against a value emitted at
/// e resolves at max(d, e); the consumer demands at max(script tick,
/// time of the previous delivery); an input without an explicit ending
/// finishes on the pull after its last value.
enum Sim {
    enum Pulled: Equatable {
        case value(String, Int)
        case finish(Int)
        case failure(Int)
    }

    /// A pull-driven view of source `index`.
    struct Upstream {
        let values: [(String, Int)]
        let terminal: (Script.Terminal, Int)
        var i = 0

        init(_ script: Script, source index: Int = 0) {
            values = script.emissions.filter { $0.source == index }.map { ($0.value, $0.tick) }
            terminal = script.terminals[index]
        }

        mutating func pull(at now: Int) -> Pulled {
            if i < values.count {
                let (v, e) = values[i]
                i += 1
                return .value(v, max(now, e))
            }
            let t = max(now, terminal.1)
            return terminal.0 == .finish ? .finish(t) : .failure(t)
        }
    }

    /// Tail of a trace once the consumer's demands are used up.
    static func exhausted(_ out: inout [Observation], demands: Int, now: Int) {
        if out.count == demands { out.append(.demandExhausted(tick: now)) }
    }

    // MARK: throttle

    /// Arrival-driven: the first value is emitted at once; afterwards a
    /// value arriving at or after `lastEmit + k` triggers an emission of
    /// the latest (or first) value seen since; a pending value is flushed
    /// on finish, no earlier than `lastEmit + k` (the implementation
    /// sleeps to keep the rate bound), and dropped on failure.
    static func throttle(_ script: Script, steps k: Int, latest: Bool) -> [Observation] {
        var up = Upstream(script)
        var out: [Observation] = []
        var now = 0
        var lastEmit: Int?
        var pending: [String] = []
        var finished = false
        let demands = script.demandTicks
        for d in demands {
            now = max(now, d)
            if finished { out.append(.finish(tick: now)); return out }
            var delivered = false
            while !delivered {
                switch up.pull(at: now) {
                case .value(let v, let t):
                    now = t
                    pending.append(v)
                    if lastEmit.map({ t - $0 >= k }) ?? true {
                        out.append(.value(latest ? pending.last! : pending.first!, tick: t))
                        lastEmit = t
                        pending = []
                        delivered = true
                    }
                case .finish(let t):
                    now = t
                    if pending.isEmpty { out.append(.finish(tick: t)); return out }
                    now = max(t, lastEmit! + k)
                    out.append(.value(latest ? pending.last! : pending.first!, tick: now))
                    pending = []
                    finished = true
                    delivered = true
                case .failure(let t):
                    now = t
                    out.append(.failure(tick: t))
                    return out
                }
            }
        }
        exhausted(&out, demands: demands.count, now: now)
        return out
    }

    // MARK: debounce

    /// Timer-driven: value i fires at `e_i + k` unless value i+1 arrives
    /// strictly before then (arriving exactly at the fire tick loses to
    /// the timer); on finish the pending value is flushed with the
    /// finish; on failure it is dropped. Fired values queue for the consumer and
    /// are observed at max(fire tick, demand tick).
    static func debounce(_ script: Script, steps k: Int) -> [Observation] {
        let values = script.emissions.map { ($0.value, $0.tick) }
        let (kind, f) = script.terminals[0]
        var available: [Observation] = []
        for (i, (v, e)) in values.enumerated() {
            let fire = e + k
            if i + 1 < values.count && values[i + 1].1 < fire { continue }  // superseded
            if fire <= f {
                available.append(.value(v, tick: fire))  // fires first even when the terminal lands on the same tick
            } else if kind == .finish {
                available.append(.value(v, tick: f))  // flushed by finish
            }  // else dropped by failure
        }
        available.append(kind == .finish ? .finish(tick: f) : .failure(tick: f))

        var out: [Observation] = []
        var now = 0
        let demands = script.demandTicks
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

    // MARK: buffer

    /// An eager producer fills the buffer as the source emits; the
    /// consumer drains it. Within a tick, emissions land before demands
    /// are served. `bounded(n)` blocks the producer when full;
    /// `bufferingOldest(n)` drops the arrival; `bufferingLatest(n)` evicts
    /// the oldest. Limit 0 applies no policy at all for any of the three
    /// (the sequence is a passthrough: values are pulled on demand). The
    /// terminal is delivered only once the buffer is drained; buffered
    /// values precede a failure.
    static func buffer(_ script: Script, policy: BufferPolicy) -> [Observation] {
        enum Ev { case value(String), terminal(Script.Terminal) }
        var events: [(Int, Ev)] = script.emissions.map { ($0.tick, .value($0.value)) }
        let (kind, f) = script.terminals[0]
        events.append((f, .terminal(kind)))
        events.sort { $0.0 < $1.0 }  // stable: values before the terminal at the same tick
        let demands = script.demandTicks
        var out: [Observation] = []
        var buf: [String] = []
        var blocked: String?
        var terminal: Script.Terminal?
        var src = 0, di = 0
        var lastTick = 0
        let horizon = (events.map(\.0) + demands).max()! + 1

        for t in 0...horizon {
            var changed = true
            while changed {
                changed = false
                // producer
                if blocked == nil, terminal == nil, src < events.count, events[src].0 <= t {
                    changed = true
                    switch events[src].1 {
                    case .terminal(let k): terminal = k
                    case .value(let v):
                        switch policy {
                        case .unbounded: buf.append(v)
                        case .bounded(0), .bufferingOldest(0), .bufferingLatest(0):
                            blocked = v  // passthrough: handed over on demand
                        case .bounded(let n):
                            if buf.count < n { buf.append(v) } else { blocked = v }
                        case .bufferingOldest(let n):
                            if buf.count < n { buf.append(v) }
                        case .bufferingLatest(let n):
                            if buf.count < n { buf.append(v) } else { buf.removeFirst(); buf.append(v) }
                        }
                    }
                    src += 1
                }
                // consumer
                if di < demands.count, demands[di] <= t {
                    if !buf.isEmpty {
                        out.append(.value(buf.removeFirst(), tick: t))
                        lastTick = t
                        di += 1
                        changed = true
                        if let b = blocked { buf.append(b); blocked = nil }
                    } else if let b = blocked {
                        out.append(.value(b, tick: t))
                        lastTick = t
                        di += 1
                        blocked = nil
                        changed = true
                    } else if let k = terminal {
                        out.append(k == .finish ? .finish(tick: t) : .failure(tick: t))
                        return out
                    }
                }
            }
        }
        exhausted(&out, demands: demands.count, now: lastTick)
        return out
    }
}

/// Trace equality with a readable diff.
struct Mismatch: Error, CustomStringConvertible {
    let expected: [Observation]
    let got: [Observation]
    var description: String {
        "expected \(expected.map(\.description).joined(separator: " "))\n  got      \(got.map(\.description).joined(separator: " "))"
    }
}

func expectTrace(_ expected: [Observation], _ trace: Trace) throws {
    if trace.events != expected { throw Mismatch(expected: expected, got: trace.events) }
}
