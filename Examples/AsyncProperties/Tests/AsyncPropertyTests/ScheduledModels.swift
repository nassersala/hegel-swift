import AsyncSequenceValidation

/// Acceptance models for operators with internal tasks, used under drawn
/// schedules where a tie can be resolved either way. They say what no
/// order may do: lose a value that should reach the consumer, emit out of
/// order, invent a value, or end wrongly.
extension Model {
    /// `debounce` with finishing sources and enough demand: the output is
    /// a subsequence of the source in order; a value may appear only if
    /// no later value arrived strictly before its fire tick; it is seen
    /// no earlier than its fire tick unless flushed by the finish; the
    /// last source value is always delivered; then finish.
    static func debounceAccepts(_ script: Script, steps k: Int, _ trace: Trace) throws {
        try structure(script, trace)
        let values = script.emissions.map { ($0.value, $0.tick) }
        let (kind, f) = script.terminals[0]
        precondition(kind == .finish)
        var next = 0
        for (i, event) in trace.events.enumerated() {
            switch event {
            case .value(let v, let t):
                guard let j = values[next...].firstIndex(where: { $0.0 == v }) else {
                    throw Illegal(reason: "\(v) is not a later source value", at: i)
                }
                let fire = values[j].1 + k
                if j + 1 < values.count, values[j + 1].1 < fire {
                    throw Illegal(reason: "\(v) was superseded by \(values[j + 1].0) at \(values[j + 1].1) before firing at \(fire)", at: i)
                }
                guard t >= min(fire, f) else { throw Illegal(reason: "\(v) seen at \(t), fires at \(fire), finish at \(f)", at: i) }
                next = j + 1
            case .finish:
                guard values.isEmpty || next == values.count else {
                    throw Illegal(reason: "finished without delivering \(values.last!.0)", at: i)
                }
            case .failure, .cancelled, .error:
                throw Illegal(reason: "\(event) from a finishing source", at: i)
            case .demandExhausted:
                break
            }
        }
    }

    /// `buffer` (unbounded or bounded): nothing is lost or reordered. With
    /// enough demand every source value arrives, then the terminal.
    static func bufferNoLoss(_ script: Script, _ trace: Trace) throws {
        try structure(script, trace)
        let values = script.emissions.map(\.value)
        let (kind, _) = script.terminals[0]
        var next = 0
        for (i, event) in trace.events.enumerated() {
            switch event {
            case .value(let v, _):
                guard next < values.count, values[next] == v else {
                    throw Illegal(reason: "expected \(next < values.count ? values[next] : "terminal"), got \(v)", at: i)
                }
                next += 1
            case .finish:
                guard kind == .finish, next == values.count else { throw Illegal(reason: "finish with \(values.count - next) undelivered / kind \(kind)", at: i) }
            case .failure:
                guard kind == .failure, next == values.count else { throw Illegal(reason: "failure with \(values.count - next) undelivered / kind \(kind)", at: i) }
            case .cancelled, .error:
                throw Illegal(reason: "\(event)", at: i)
            case .demandExhausted:
                break
            }
        }
    }

    /// `chunks(ofCount:or:)`: chunks are non-empty, at most `count` long,
    /// and concatenate to a prefix of the base in order; a full-length
    /// chunk needs no signal; after a normal base finish with enough
    /// demand, everything was delivered.
    static func chunksAccept(_ script: Script, count: Int?, _ trace: Trace) throws {
        try structure(script, trace)
        let base = script.emissions.filter { $0.source == 0 }.map(\.value)
        let (kind0, _) = script.terminals[0]
        let (kind1, _) = script.terminals[1]
        var delivered = ""
        for (i, event) in trace.events.enumerated() {
            switch event {
            case .value(let chunk, _):
                guard !chunk.isEmpty, count.map({ chunk.count <= $0 }) ?? true else {
                    throw Illegal(reason: "chunk \(chunk) violates the count bound \(count.map(String.init) ?? "∞")", at: i)
                }
                delivered += chunk
                guard base.joined().hasPrefix(delivered) else {
                    throw Illegal(reason: "chunks so far \(delivered) are not a prefix of the base \(base.joined())", at: i)
                }
            case .finish:
                guard kind0 == .finish else { throw Illegal(reason: "finished but the base fails", at: i) }
                guard delivered == base.joined() else { throw Illegal(reason: "finished with \(base.joined().dropFirst(delivered.count)) undelivered", at: i) }
            case .failure:
                guard kind0 == .failure || kind1 == .failure else { throw Illegal(reason: "failed although nothing fails", at: i) }
            case .cancelled, .error:
                throw Illegal(reason: "\(event)", at: i)
            case .demandExhausted:
                break
            }
        }
    }
}
