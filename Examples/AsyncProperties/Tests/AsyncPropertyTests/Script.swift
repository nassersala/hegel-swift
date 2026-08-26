import Hegel

/// One drawn scenario: what each source does, tick by tick, and when the
/// consumer asks for values. Renders to the validation runtime's marble
/// diagrams, which is also how a shrunk counterexample reads.
///
/// Diagram grammar (ASCII theme): every symbol is one tick. In an input,
/// a letter emits that value, `-` is silence, `|` finishes, `^` fails. In
/// the output, a letter is a demand point (`next()` is called by that
/// tick), `-` is a tick without a new demand, `;` cancels the consumer.
/// The consumer always demands once at tick 0 before the diagram starts.
struct Script: CustomStringConvertible, Sendable {
    enum Event: Sendable, Equatable {
        case value
        case delay(Int)
        case failure
        case finish
    }
    enum Demand: Sendable, Equatable {
        case next
        case wait(Int)
        case cancel
    }

    var sources: [[Event]]
    var consumer: [Demand]

    /// Distinct alphabets per source, so a value names its source and its
    /// ordinal (`c` is source 0's third value; `B` is source 1's second).
    static let alphabets = ["abcdefghijkl", "ABCDEFGHIJKL", "123456789"]

    // MARK: Rendering

    var inputDiagrams: [String] {
        sources.enumerated().map { index, events in
            let letters = Array(Self.alphabets[index])
            var out = ""
            var ordinal = 0
            for event in events {
                switch event {
                case .value:
                    out.append(letters[ordinal])
                    ordinal += 1
                case .delay(let n): out.append(String(repeating: "-", count: n))
                case .failure: out.append("^")
                case .finish: out.append("|")
                }
            }
            return out
        }
    }

    var outputDiagram: String {
        var out = ""
        for demand in consumer {
            switch demand {
            case .next: out.append("x")
            case .wait(let n): out.append(String(repeating: "-", count: n))
            case .cancel: out.append(";")
            }
        }
        return out
    }

    var description: String {
        (inputDiagrams.enumerated().map { "  in[\($0)]  \"\($1)\"" }
            + ["  out    \"\(outputDiagram)\""]).joined(separator: "\n")
    }

    // MARK: Timeline, as the model sees it

    struct Emission: Equatable {
        let value: String
        let source: Int
        let ordinal: Int
        let tick: Int
    }
    enum Terminal: Equatable {
        case finish
        case failure
    }

    /// Every value each source emits, with its tick.
    var emissions: [Emission] {
        var all: [Emission] = []
        for (index, events) in sources.enumerated() {
            let letters = Array(Self.alphabets[index])
            var tick = 0
            var ordinal = 0
            for event in events {
                switch event {
                case .value:
                    tick += 1
                    all.append(Emission(value: String(letters[ordinal]), source: index, ordinal: ordinal, tick: tick))
                    ordinal += 1
                case .delay(let n): tick += n
                case .failure, .finish: tick += 1
                }
            }
        }
        return all
    }

    /// How and when each source ends. A diagram without `|` or `^` ends
    /// implicitly: the pull after its last value returns nil at once, so
    /// it counts as a finish at the tick of that last value (trailing
    /// silence does not delay it).
    var terminals: [(Terminal, tick: Int)] {
        sources.map { events in
            var tick = 0
            var lastValue = 0
            for event in events {
                switch event {
                case .value:
                    tick += 1
                    lastValue = tick
                case .delay(let n): tick += n
                case .failure: return (.failure, tick + 1)
                case .finish: return (.finish, tick + 1)
                }
            }
            return (.finish, lastValue)
        }
    }

    /// Ticks at which the consumer issues `next()`: 0, then one per `x`,
    /// and one at the cancel tick (the runtime demands there too, so the
    /// cancellation has a suspension point to land on).
    var demandTicks: [Int] {
        var ticks = [0]
        var tick = 0
        for demand in consumer {
            switch demand {
            case .next:
                tick += 1
                ticks.append(tick)
            case .wait(let n): tick += n
            case .cancel:
                tick += 1
                ticks.append(tick)
            }
        }
        return ticks
    }

    /// True when two different sources have an event (value or terminal)
    /// on the same tick. The runtime resolves such ties by job-hop order,
    /// which differs per operator and is not a contract.
    var hasSimultaneousCrossSourceEvents: Bool {
        var seen: [Int: Int] = [:]  // tick → source
        for e in emissions {
            if let s = seen[e.tick], s != e.source { return true }
            seen[e.tick] = e.source
        }
        for (source, events) in sources.enumerated() {
            guard events.contains(where: { $0 == .finish || $0 == .failure }) else { continue }
            let t = terminals[source].tick
            if let s = seen[t], s != source { return true }
            seen[t] = source
        }
        return false
    }

    var cancelTick: Int? {
        var tick = 0
        for demand in consumer {
            switch demand {
            case .next: tick += 1
            case .wait(let n): tick += n
            case .cancel: return tick + 1
            }
        }
        return nil
    }

}

// MARK: - Generators

extension Script {
    /// Which endings a source may have.
    enum Endings: Sendable {
        /// Every source ends with `|`.
        case finish
        /// `|` or `^`.
        case explicit
        /// `|`, `^`, or nothing (implicit finish).
        case any
    }

    static func source(endings: Endings, maxValues: Int = 6) -> Gen<[Event]> {
        let body: Gen<Event> = Gen<Int64>.int(in: 0...4).flatMap { k in
            k < 3 ? Gen { _ in .value } : Gen<Int64>.int(in: 1...3).map { .delay(Int($0)) }
        }
        let ending: Gen<[Event]>
        switch endings {
        case .finish:
            ending = Gen { _ in [.finish] }
        case .explicit:
            ending = Gen<Int64>.int(in: 0...2).map { $0 < 2 ? [.finish] : [.failure] }
        case .any:
            ending = Gen<Int64>.int(in: 0...3).map { k in
                switch k {
                case 0, 1: return [.finish]
                case 2: return [.failure]
                default: return []
                }
            }
        }
        return Hegel.zip(array(of: body, count: 0...UInt64(maxValues)), ending).map { $0 + $1 }
    }

    static func demand(allowCancel: Bool, count: ClosedRange<UInt64> = 0...8) -> Gen<[Demand]> {
        let step: Gen<Demand> = Gen<Int64>.int(in: 0...4).flatMap { k in
            k < 3 ? Gen { _ in .next } : Gen<Int64>.int(in: 1...3).map { .wait(Int($0)) }
        }
        let steps = array(of: step, count: count)
        guard allowCancel else { return steps }
        return Hegel.zip(steps, .bool(probability: 0.3)).map { $0 + ($1 ? [.cancel] : []) }
    }

    /// Scripts with a cancel, followed by two more demands: what a
    /// `for await` loop does after its task is cancelled.
    static func cancelling(sources count: ClosedRange<UInt64>) -> Gen<Script> {
        gen(sources: count, endings: .any, allowCancel: true, enoughDemand: false)
            .filter { $0.cancelTick != nil }
            .map { s in Script(sources: s.sources, consumer: s.consumer + [.next, .next]) }
    }

    /// `sources` sources, each with `endings`; a consumer that may cancel
    /// when `allowCancel`. With `enoughDemand`, the consumer is padded so it
    /// can observe every value plus the terminal event.
    static func gen(
        sources count: ClosedRange<UInt64>,
        endings: Endings,
        allowCancel: Bool,
        enoughDemand: Bool
    ) -> Gen<Script> {
        Hegel.zip(array(of: source(endings: endings), count: count), demand(allowCancel: allowCancel))
            .map { sources, consumer in
                var script = Script(sources: sources, consumer: consumer)
                if enoughDemand {
                    let needed = script.emissions.count + 1
                    while script.demandTicks.count < needed { script.consumer.append(.next) }
                }
                return script
            }
    }
}
