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

private struct Cell: Hashable, Sendable {
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
    let table: [Cell: Transition]

    static func load() throws -> VerifiedDoorModel {
        let url = try #require(
            Bundle.module.url(
                forResource: "door-model", withExtension: "json", subdirectory: "Fixtures"))
        let artifact = try JSONDecoder().decode(Artifact.self, from: Data(contentsOf: url))
        let pairs = artifact.transitions.map { (Cell(state: $0.state, command: $0.command), $0) }
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

private struct RefinementMismatch: Error, CustomStringConvertible, Sendable {
    let state: DoorState
    let command: DoorCommand
    let expected: Transition
    let observed: DoorObservation
    let actualState: DoorState

    var description: String {
        "\(state.rawValue) ▸ \(command.rawValue): expected \(expected.observation.rawValue) "
            + "→ \(expected.next.rawValue), got \(observed.rawValue) → \(actualState.rawValue)"
    }
}

/// The Agda theorem `open-only-when-unlocked`, transported: if the Swift
/// door refines the table, it inherits the theorem. Checked directly so a
/// door that opens while locked violates the theorem, not only the row.
private struct Drift: Error, CustomStringConvertible, Sendable {
    let door: DoorState
    let model: DoorState
    var description: String { "door is \(door.rawValue), model is \(model.rawValue)" }
}

private struct TheoremViolated: Error, CustomStringConvertible, Sendable {
    let name: String
    var description: String { "theorem \(name) does not hold for the Swift door" }
}

/// The generated table is the only abstract transition implementation used
/// by Swift. Each command lowers to one `Command`: `model:` is a lookup in
/// the Agda-evaluated table, `post:` compares the SUT's observation and
/// state with the row and checks the transported theorem.
private func commands(_ model: VerifiedDoorModel) -> [Command<Door, DoorState>] {
    DoorCommand.allCases.map { command in
        Command(
            command.rawValue,
            precondition: { model.table[Cell(state: $0, command: command)] != nil },
            run: { (door: inout Door) -> (observed: DoorObservation, state: DoorState) in
                (observed: door.run(command), state: door.state)
            },
            model: { state in state = model.table[Cell(state: state, command: command)]!.next },
            post: { before, result in
                let expected = model.table[Cell(state: before, command: command)]!
                guard result.observed == expected.observation, result.state == expected.next else {
                    throw RefinementMismatch(
                        state: before, command: command, expected: expected,
                        observed: result.observed, actualState: result.state)
                }
                if result.observed == .opened, before != .unlocked {
                    throw TheoremViolated(name: "open-only-when-unlocked")
                }
            },
            describeObserved: { $0.observed.rawValue })
    }
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
                #expect(model.table[Cell(state: state, command: command)] != nil)
            }
        }
    }

    @Test func correctSwiftDoorRefinesTheVerifiedModel() throws {
        let model = try VerifiedDoorModel.load()
        try forAll(
            sut: Gen { _ in Door(state: model.artifact.initial, opensWhileLocked: false) },
            model: model.artifact.initial,
            commands: commands(model),
            consistent: { door, state in
                guard door.state == state else { throw Drift(door: door.state, model: state) }
            },
            testCases: 200,
            database: "",
            settings: Settings(statefulStepCount: 12))
    }

    @Test func buggySwiftDoorShrinksToOneOpenCommand() throws {
        let model = try VerifiedDoorModel.load()

        do {
            try forAll(
                sut: Gen { _ in Door(state: model.artifact.initial, opensWhileLocked: true) },
                model: model.artifact.initial,
                commands: commands(model),
                testCases: 200,
                seed: 1,
                database: "",
                settings: Settings(statefulStepCount: 12))
            Issue.record("the planted refinement bug was not found")
        } catch let failure as PropertyFailure {
            let counterexample = try #require(failure.failures.first?.counterexample)
            #expect(counterexample.contains("initial: sut locked, model locked"))
            #expect(counterexample.components(separatedBy: "  open() -> opened failed").count - 1 == 1)
            #expect(!counterexample.contains("  lock\n"))
            #expect(!counterexample.contains("  unlock\n"))
            #expect(
                counterexample.contains(
                    "locked ▸ open: expected denied → locked, got opened → locked"))
        }
    }
}
