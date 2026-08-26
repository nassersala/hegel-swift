import AsyncSequenceValidation

typealias Trace = AsyncSequenceValidationDiagram.Trace
typealias Observation = AsyncSequenceValidationDiagram.Observation

/// Why a trace is not a legal output of an operator for a script.
struct Illegal: Error, CustomStringConvertible {
    let reason: String
    let at: Int
    var description: String { "event #\(at): \(reason)" }
}

/// Reference models: each accepts or rejects an observed trace for a
/// script. They describe the set of legal traces, not one privileged
/// trace, because simultaneous emissions may legally arrive in more than
/// one order. Every clause is a documented claim about the operator; a
/// rejection is triaged as model, implementation, or harness before it is
/// called a bug.
enum Model {
    /// Checks shared by every operator: one event per demand, each demand
    /// issued no earlier than the script says (the consumer demands at
    /// `max(script tick, now)`), a terminal event is last, an unknown
    /// error is never legal, and no event is observed before its demand.
    static func structure(_ script: Script, _ trace: Trace) throws {
        let demands = script.demandTicks
        guard trace.events.count == trace.demandTicks.count else {
            throw Illegal(reason: "harness: \(trace.events.count) events for \(trace.demandTicks.count) demands", at: 0)
        }
        for (i, event) in trace.events.enumerated() {
            let isLast = i == trace.events.count - 1
            switch event {
            case .demandExhausted:
                guard isLast else { throw Illegal(reason: "demand exhausted mid-trace", at: i) }
                guard trace.demandTicks.count - 1 == demands.count else {
                    throw Illegal(reason: "harness: exhausted after \(i) of \(demands.count) demands", at: i)
                }
            case .finish, .failure, .cancelled:
                guard isLast else { throw Illegal(reason: "\(event) followed by more events", at: i) }
                fallthrough
            case .value:
                guard i < demands.count else { throw Illegal(reason: "harness: more events than demands", at: i) }
                guard trace.demandTicks[i] >= demands[i] else {
                    throw Illegal(reason: "harness: demand \(i) issued at \(trace.demandTicks[i]), script says \(demands[i])", at: i)
                }
                guard event.tick >= trace.demandTicks[i] else {
                    throw Illegal(reason: "\(event) observed before its demand at \(trace.demandTicks[i])", at: i)
                }
            case .error(let e, _):
                throw Illegal(reason: "unexpected error \(e)", at: i)
            }
        }
    }

    /// `merge`: every value comes from exactly one source, each source's
    /// values arrive in source order without gaps, no value arrives before
    /// its emission tick; finish only after every source finished and
    /// every value was delivered; failure only if some source fails and
    /// only at or after its tick; after a cancel, at most one value at or
    /// after the cancel tick.
    ///
    /// Not a law, checked and rejected: "no value emitted after the
    /// earliest failure tick precedes the failure". Merge's children pull
    /// only on downstream demand, so a failure is not known until merge
    /// pulls it, and a value from another source emitted later can legally
    /// arrive first (`ModelSelfChecks.failureIsPullDriven`).
    static func merge(_ script: Script, _ trace: Trace) throws {
        try structure(script, trace)
        let emissions = script.emissions
        let terminals = script.terminals
        let earliestFailure = terminals.compactMap { $0.0 == .failure ? $0.tick : nil }.min()
        var nextOrdinal = Array(repeating: 0, count: script.sources.count)
        var valuesAtOrAfterCancel = 0

        for (i, event) in trace.events.enumerated() {
            switch event {
            case .value(let v, let t):
                guard let e = emissions.first(where: { $0.value == v }) else {
                    throw Illegal(reason: "\(v) is not a source value", at: i)
                }
                guard e.ordinal == nextOrdinal[e.source] else {
                    throw Illegal(reason: "\(v) out of source order (expected ordinal \(nextOrdinal[e.source]) of source \(e.source))", at: i)
                }
                nextOrdinal[e.source] += 1
                guard t >= e.tick else { throw Illegal(reason: "\(v) observed at \(t), emitted at \(e.tick)", at: i) }
                if let c = script.cancelTick, t >= c {
                    valuesAtOrAfterCancel += 1
                    guard valuesAtOrAfterCancel <= 1 else {
                        throw Illegal(reason: "second value (\(v)) after cancel at \(c)", at: i)
                    }
                }
            case .finish(let t):
                if let c = script.cancelTick, t >= c { continue }  // cancellation may surface as a finish
                guard terminals.allSatisfy({ $0.0 == .finish }) else {
                    throw Illegal(reason: "finished although a source fails", at: i)
                }
                guard nextOrdinal == script.sources.map({ $0.filter { $0 == .value }.count }) else {
                    throw Illegal(reason: "finished with values undelivered (\(nextOrdinal) of \(script.sources.map { $0.filter { $0 == .value }.count }))", at: i)
                }
                let latest = terminals.map(\.tick).max() ?? 0
                guard t >= latest else { throw Illegal(reason: "finished at \(t) before the last source at \(latest)", at: i) }
            case .failure(let t):
                guard let f = earliestFailure else { throw Illegal(reason: "failed although no source fails", at: i) }
                guard t >= f else { throw Illegal(reason: "failed at \(t) before the source at \(f)", at: i) }
            case .cancelled(let t):
                guard let c = script.cancelTick, t >= c else {
                    throw Illegal(reason: "cancelled without a cancel (or before it)", at: i)
                }
            case .demandExhausted, .error:
                break
            }
        }
    }

    /// `zip` of two sources: the i-th value is the concatenation of the
    /// i-th values of each source, observed no earlier than either; finish
    /// only once some finished source has had all its values paired;
    /// failure only if some source fails and only at or after its tick
    /// (pull-driven, as for merge: a failure after a source's last paired
    /// value is not seen until the next pair is requested).
    static func zip(_ script: Script, _ trace: Trace) throws {
        try structure(script, trace)
        precondition(script.sources.count == 2)
        let bySource = (0..<2).map { s in script.emissions.filter { $0.source == s } }
        let terminals = script.terminals
        let earliestFailure = terminals.compactMap { $0.0 == .failure ? $0.tick : nil }.min()
        var pairs = 0
        var valuesAtOrAfterCancel = 0

        for (i, event) in trace.events.enumerated() {
            switch event {
            case .value(let v, let t):
                guard pairs < bySource[0].count, pairs < bySource[1].count else {
                    throw Illegal(reason: "pair \(pairs) (\(v)) beyond the shorter source", at: i)
                }
                let (a, b) = (bySource[0][pairs], bySource[1][pairs])
                guard v == a.value + b.value else {
                    throw Illegal(reason: "pair \(pairs) is \(v), expected \(a.value + b.value)", at: i)
                }
                guard t >= max(a.tick, b.tick) else {
                    throw Illegal(reason: "\(v) observed at \(t), components emitted at \(a.tick) and \(b.tick)", at: i)
                }
                pairs += 1
                if let c = script.cancelTick, t >= c {
                    valuesAtOrAfterCancel += 1
                    guard valuesAtOrAfterCancel <= 1 else {
                        throw Illegal(reason: "second value (\(v)) after cancel at \(c)", at: i)
                    }
                }
            case .finish(let t):
                if let c = script.cancelTick, t >= c { continue }
                let exhausted = (0..<2).filter { terminals[$0].0 == .finish && bySource[$0].count == pairs }
                guard let s = exhausted.min(by: { terminals[$0].tick < terminals[$1].tick }) else {
                    throw Illegal(reason: "finished after \(pairs) pairs with no source exhausted", at: i)
                }
                guard t >= terminals[s].tick else {
                    throw Illegal(reason: "finished at \(t) before source \(s) at \(terminals[s].tick)", at: i)
                }
            case .failure(let t):
                guard let f = earliestFailure else { throw Illegal(reason: "failed although no source fails", at: i) }
                guard t >= f else { throw Illegal(reason: "failed at \(t) before the source at \(f)", at: i) }
            case .cancelled(let t):
                guard let c = script.cancelTick, t >= c else {
                    throw Illegal(reason: "cancelled without a cancel (or before it)", at: i)
                }
            case .demandExhausted, .error:
                break
            }
        }
    }
}

extension Model {
    /// Tight timing claims on top of `merge`: a value is observed exactly
    /// at max(its emission tick, the tick its demand was issued), and the
    /// finish exactly at max(demand tick, last source terminal tick).
    static func mergeExact(_ script: Script, _ trace: Trace) throws {
        try merge(script, trace)
        let emissions = script.emissions
        let latest = script.terminals.map(\.tick).max() ?? 0
        for (i, event) in trace.events.enumerated() {
            switch event {
            case .value(let v, let t):
                let e = emissions.first { $0.value == v }!
                let expected = max(e.tick, trace.demandTicks[i])
                guard t == expected else {
                    throw Illegal(reason: "\(v) observed at \(t), expected exactly \(expected) = max(emitted \(e.tick), demanded \(trace.demandTicks[i]))", at: i)
                }
            case .finish(let t):
                let expected = max(latest, trace.demandTicks[i])
                guard t == expected else {
                    throw Illegal(reason: "finish observed at \(t), expected exactly \(expected)", at: i)
                }
            default: break
            }
        }
    }

    /// Tight timing claims on top of `zip`: pair i exactly at max(both
    /// components' ticks, demand tick); finish exactly at max(demand tick,
    /// the exhausted source's terminal tick).
    static func zipExact(_ script: Script, _ trace: Trace) throws {
        try zip(script, trace)
        let bySource = (0..<2).map { s in script.emissions.filter { $0.source == s } }
        let terminals = script.terminals
        var pairs = 0
        for (i, event) in trace.events.enumerated() {
            switch event {
            case .value(let v, let t):
                let expected = max(bySource[0][pairs].tick, bySource[1][pairs].tick, trace.demandTicks[i])
                pairs += 1
                guard t == expected else {
                    throw Illegal(reason: "\(v) observed at \(t), expected exactly \(expected)", at: i)
                }
            case .finish(let t):
                let exhausted = (0..<2).filter { terminals[$0].0 == .finish && bySource[$0].count == pairs }
                let earliest = exhausted.map { terminals[$0].tick }.min() ?? 0
                let expected = max(earliest, trace.demandTicks[i])
                guard t == expected else {
                    throw Illegal(reason: "finish observed at \(t), expected exactly \(expected)", at: i)
                }
            default: break
            }
        }
    }
}

extension Model {
    /// Cancellation, for any operator, with a consumer that keeps
    /// demanding after its task is cancelled: from the first demand at
    /// or after the cancel tick, the operator may deliver at most one
    /// value (a flush of what it already held), then finishes at the
    /// tick of the demand that asked; it never throws anything but a
    /// source failure that predates the cancel (which an operator that
    /// pulls ahead may hold — `combineLatest` does, merge cannot), and
    /// never hangs (a hang shows as a trace without a terminal). Events
    /// before the cancel are other laws' business.
    static func cancellation(_ script: Script, _ trace: Trace) throws {
        try structure(script, trace)
        let c = script.cancelTick!
        guard let k = trace.events.indices.first(where: { trace.demandTicks[$0] >= c }) else {
            // Every answered demand was issued before the cancel: fine if the
            // sequence had already ended, a hang otherwise.
            switch trace.events.last {
            case .finish, .failure: return
            default: throw Illegal(reason: "no demand at or after the cancel at \(c) was answered: \(trace)", at: trace.events.count)
            }
        }
        let after = Array(trace.events[k...])
        let demands = Array(trace.demandTicks[k...])
        let failedBefore = script.terminals.contains { $0.0 == .failure && $0.tick <= c }
        switch after.map({ e -> String in
            switch e {
            case .value: return "v"
            case .finish: return "|"
            case .failure: return failedBefore ? "|" : "^"
            default: return String(describing: e)
            }
        }).joined() {
        case "|":
            guard after[0].tick == demands[0] else {
                throw Illegal(reason: "finish at \(after[0].tick), demanded at \(demands[0]) after cancel at \(c)", at: k)
            }
        case "v|":
            guard after[1].tick == demands[1] else {
                throw Illegal(reason: "finish at \(after[1].tick), demanded at \(demands[1]) after cancel at \(c)", at: k + 1)
            }
        default:
            throw Illegal(reason: "after cancel at \(c): \(after) (expected finish, or one value then finish)", at: k)
        }
    }
}
