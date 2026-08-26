import AsyncAlgorithms
import AsyncSequenceValidation
import Testing
import Hegel

/// Every suite in this target nests here: the validation runtime installs
/// a process-global enqueue hook, so nothing may run two diagrams at once.
/// `.serialized` applies recursively to nested suites.
@Suite(.serialized) enum AsyncProperties {}

/// Runs a script through the vendored validation runtime. Synchronous:
/// the runtime drives the fake clock on its own thread and blocks the
/// caller, which is what lets a synchronous `forAll` sit around it.
enum Harness {
    static func merge(_ script: Script, persistent: Bool = false, schedule: TieSchedule = TieSchedule()) throws -> Trace {
        let inputs = script.inputDiagrams
        return try AsyncSequenceValidationDiagram.run(inputs: inputs, output: script.outputDiagram, persistentConsumer: persistent, schedule: schedule.pick) { d in
            let i = d.inputs
            switch inputs.count {
            case 1: return AnyAsyncSequence(i[0])
            case 2: return AnyAsyncSequence(AsyncAlgorithms.merge(i[0], i[1]))
            default: return AnyAsyncSequence(AsyncAlgorithms.merge(i[0], i[1], i[2]))
            }
        }
    }

    static func zip(_ script: Script, persistent: Bool = false, schedule: TieSchedule = TieSchedule()) throws -> Trace {
        try AsyncSequenceValidationDiagram.run(inputs: script.inputDiagrams, output: script.outputDiagram, persistentConsumer: persistent, schedule: schedule.pick) { d in
            AsyncAlgorithms.zip(d.inputs[0], d.inputs[1]).map { $0 + $1 }
        }
    }

    typealias Step = AsyncSequenceValidationDiagram.Clock.Step

    static func debounce(_ script: Script, steps k: Int, persistent: Bool = false, schedule: TieSchedule = TieSchedule()) throws -> Trace {
        try AsyncSequenceValidationDiagram.run(inputs: script.inputDiagrams, output: script.outputDiagram, persistentConsumer: persistent, schedule: schedule.pick) { d in
            d.inputs[0].debounce(for: .steps(k), clock: d.clock)
        }
    }

    static func throttle(_ script: Script, steps k: Int, latest: Bool, persistent: Bool = false, schedule: TieSchedule = TieSchedule()) throws -> Trace {
        try AsyncSequenceValidationDiagram.run(inputs: script.inputDiagrams, output: script.outputDiagram, persistentConsumer: persistent, schedule: schedule.pick) { d in
            d.inputs[0]._throttle(for: .steps(k), clock: d.clock, latest: latest)
        }
    }

    static func combineLatest(_ script: Script, persistent: Bool = false, schedule: TieSchedule = TieSchedule()) throws -> Trace {
        try AsyncSequenceValidationDiagram.run(inputs: script.inputDiagrams, output: script.outputDiagram, persistentConsumer: persistent, schedule: schedule.pick) { d in
            AsyncAlgorithms.combineLatest(d.inputs[0], d.inputs[1]).map { $0 + $1 }
        }
    }

    /// Source 0 is the base, source 1 the signal. `count == nil` is
    /// `chunked(by:)`; otherwise `chunks(ofCount:or:)`. Chunks render as
    /// their joined letters.
    static func chunks(_ script: Script, count: Int?, persistent: Bool = false, schedule: TieSchedule = TieSchedule()) throws -> Trace {
        try AsyncSequenceValidationDiagram.run(inputs: script.inputDiagrams, output: script.outputDiagram, persistentConsumer: persistent, schedule: schedule.pick) { d in
            if let count {
                return AnyAsyncSequence(d.inputs[0].chunks(ofCount: count, or: d.inputs[1]).map { $0.joined() })
            }
            return AnyAsyncSequence(d.inputs[0].chunked(by: d.inputs[1]).map { $0.joined() })
        }
    }

    static func buffer(_ script: Script, policy: BufferPolicy, persistent: Bool = false, schedule: TieSchedule = TieSchedule()) throws -> Trace {
        try AsyncSequenceValidationDiagram.run(inputs: script.inputDiagrams, output: script.outputDiagram, persistentConsumer: persistent, schedule: schedule.pick) { d in
            d.inputs[0].buffer(policy: policy.upstream)
        }
    }
}

enum BufferPolicy: Sendable, Equatable, CustomStringConvertible {
    case unbounded
    case bounded(Int)
    case bufferingOldest(Int)
    case bufferingLatest(Int)

    var upstream: AsyncBufferSequencePolicy {
        switch self {
        case .unbounded: return .unbounded
        case .bounded(let n): return .bounded(n)
        case .bufferingOldest(let n): return .bufferingOldest(n)
        case .bufferingLatest(let n): return .bufferingLatest(n)
        }
    }
    var description: String {
        switch self {
        case .unbounded: return ".unbounded"
        case .bounded(let n): return ".bounded(\(n))"
        case .bufferingOldest(let n): return ".bufferingOldest(\(n))"
        case .bufferingLatest(let n): return ".bufferingLatest(\(n))"
        }
    }
}

/// Type erasure so one closure can return merges of different arity.
struct AnyAsyncSequence: AsyncSequence, Sendable {
    typealias Element = String
    let make: @Sendable () -> AsyncIterator
    init<S: AsyncSequence & Sendable>(_ base: S) where S.Element == String {
        make = { AsyncIterator(next: { var it = base.makeAsyncIterator(); return { try await it.next() } }()) }
    }
    struct AsyncIterator: AsyncIteratorProtocol {
        let next: () async throws -> String?
        mutating func next() async throws -> String? { try await self.next() }
    }
    func makeAsyncIterator() -> AsyncIterator { make() }
}


/// An interleaving as data, for the validation runtime's ready batches:
/// deviations from the default order at numbered choice points. Empty is
/// the runtime's own deterministic order, so a shrunk schedule is the
/// fewest, earliest deviations that still produce the failure. (Mirror
/// of `Schedules.Schedule` in Examples/ScheduleProperties; kept local so
/// the two example packages stay independent.)
struct TieSchedule: Sendable, Equatable, CustomStringConvertible {
    struct Deviation: Sendable, Equatable {
        var choice: Int
        var index: Int
    }
    var deviations: [Deviation] = []

    var pick: ((_ ready: [String], _ choice: Int) -> Int)? {
        if deviations.isEmpty { return nil }
        let deviations = deviations
        return { ready, choice in
            deviations.first { $0.choice == choice }.map { $0.index % ready.count } ?? 0
        }
    }

    var description: String {
        deviations.isEmpty ? "default order" : deviations.map { "at choice \($0.choice) run ready[\($0.index)]" }.joined(separator: "; ")
    }

    static let gen: Gen<TieSchedule> = array(
        of: Hegel.zip(Gen<Int64>.int(in: 0...30), Gen<Int64>.int(in: 1...5)).map { Deviation(choice: Int($0), index: Int($1)) },
        count: 0...6
    ).map { TieSchedule(deviations: $0) }
}
