import Foundation
import Hegel
import Testing

private enum DoorState: String, CaseIterable, Codable, Sendable {
    case locked
    case unlocked
}

private enum DoorCommand: String, CaseIterable, Codable, Sendable {
    case lock
    case unlock
    case open
}

private enum DoorObservation: String, Codable, Sendable {
    case ok
    case opened
    case denied
}

private struct Key: Hashable, Sendable {
    let state: DoorState
    let command: DoorCommand
}

private struct Transition: Codable, Sendable {
    let state: DoorState
    let command: DoorCommand
    let next: DoorState
    let observation: DoorObservation
}

private struct Artifact: Codable, Sendable {
    let schema: Int
    let model: String
    let source: String
    let initial: DoorState
    let proofs: [String]
    let transitions: [Transition]
}

private struct VerifiedDoorModel: Sendable {
    let artifact: Artifact
    let table: [Key: Transition]

    static func load() throws -> VerifiedDoorModel {
        let url = try #require(
            Bundle.module.url(
                forResource: "door-model", withExtension: "json", subdirectory: "Fixtures"))
        let artifact = try JSONDecoder().decode(Artifact.self, from: Data(contentsOf: url))
        let pairs = artifact.transitions.map { (Key(state: $0.state, command: $0.command), $0) }
        let table = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        return VerifiedDoorModel(artifact: artifact, table: table)
    }
}

// MARK: - A separate Swift implementation under test

private struct Door: Sendable, CustomStringConvertible {
    var state: DoorState
    let opensWhileLocked: Bool
    var description: String { state.rawValue }

    mutating func run(_ command: DoorCommand) -> DoorObservation {
        switch command {
        case .lock:
            state = .locked
            return .ok
        case .unlock:
            state = .unlocked
            return .ok
        case .open:
            if state == .locked {
                // The planted refinement bug: the implementation reports an
                // open even though the verified model denies it.
                return opensWhileLocked ? .opened : .denied
            }
            return .opened
        }
    }
}

/// The Agda theorem `open-only-when-unlocked`, transported: if the Swift
/// door refines the table, it inherits the theorem. Checked as an invariant
/// over the walk so a door that opens while locked violates the theorem,
/// not only the row.
private struct TheoremViolated: Error, CustomStringConvertible, Sendable {
    let name: String
    var description: String { "theorem \(name) does not hold for the Swift door" }
}

private struct Drift: Error, CustomStringConvertible, Sendable {
    let door: DoorState
    let model: DoorState
    var description: String { "door is \(door.rawValue), model is \(model.rawValue)" }
}

extension VerifiedDoorModel {
    /// The generated table as an `Enumeration`: the only abstract transition
    /// implementation used by Swift. `problems()` is the completeness check
    /// on the artifact; `commands(run:)` derives one command per row.
    var enumeration: Enumeration<DoorState, DoorCommand, DoorObservation> {
        var table: [DoorState: [DoorCommand: Cell<DoorState, DoorObservation>]] = [:]
        for t in artifact.transitions {
            table[t.state, default: [:]][t.command] = .respond(t.observation, then: t.next)
        }
        return Enumeration(initial: artifact.initial, table: table)
    }
}

/// A door that records its last observation so the theorem can be stated
/// over the state alone.
private struct ObservedDoor: Sendable, CustomStringConvertible {
    var door: Door
    var last: DoorObservation? = nil
    var before: DoorState
    var description: String { door.state.rawValue }

    mutating func run(_ command: DoorCommand) -> DoorObservation {
        before = door.state
        last = door.run(command)
        return last!
    }
}

private func forAllDoor(bug: Bool, testCases: UInt64, seed: UInt64? = nil, model: VerifiedDoorModel) throws {
    let spec = model.enumeration
    try forAll(
        sut: Gen { _ in ObservedDoor(door: Door(state: model.artifact.initial, opensWhileLocked: bug), before: model.artifact.initial) },
        model: spec.initial,
        commands: spec.commands(run: { d, c in d.run(c) }),
        consistent: { d, state in
            guard d.door.state == state else { throw Drift(door: d.door.state, model: state) }
        },
        invariants: [
            Invariant("open-only-when-unlocked") { s in
                if s.sut.last == .opened, s.sut.before != .unlocked {
                    throw TheoremViolated(name: "open-only-when-unlocked")
                }
            }
        ],
        testCases: testCases, seed: seed, database: "",
        settings: Settings(statefulStepCount: 12))
}

@Suite struct AgdaVerifiedModelTests {
    @Test func generatedArtifactIsCompleteAndNamesItsProofs() throws {
        let model = try VerifiedDoorModel.load()

        #expect(model.artifact.schema == 1)
        #expect(model.artifact.model == "VerifiedDoor")
        #expect(model.artifact.source == "Agda/DoorModel.agda")
        #expect(
            Set(model.artifact.proofs)
                == ["open-only-when-unlocked", "locking-leaves-locked"])
        #expect(model.artifact.transitions.count == DoorState.allCases.count * DoorCommand.allCases.count)
        #expect(model.table.count == model.artifact.transitions.count, "duplicate cells in artifact")

        for state in DoorState.allCases {
            for command in DoorCommand.allCases {
                #expect(model.table[Key(state: state, command: command)] != nil)
            }
        }
    }

    @Test func correctSwiftDoorRefinesTheVerifiedModel() throws {
        let model = try VerifiedDoorModel.load()
        #expect(model.enumeration.problems().isEmpty)
        try forAllDoor(bug: false, testCases: 200, model: model)
    }

    @Test func buggySwiftDoorShrinksToOneOpenCommand() throws {
        let model = try VerifiedDoorModel.load()

        do {
            try forAllDoor(bug: true, testCases: 200, seed: 1, model: model)
            Issue.record("the planted refinement bug was not found")
        } catch let failure as PropertyFailure {
            let counterexample = try #require(failure.failures.first?.counterexample)
            #expect(counterexample == """
                initial: sut locked, model locked
                  locked ▸ open -> opened failed
                violated: locked ▸ open: observed opened, model expected denied
                """, "\(counterexample)")
        }
    }
}
