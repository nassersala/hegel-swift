import DequeModule
import Hegel
import Testing

/// The operations the model describes. `Deque` conforms as is; `BuggyDeque`
/// plants one bug so the shrunk trace can be pinned.
private protocol DequeLike: Sendable, CustomStringConvertible {
    init()
    var count: Int { get }
    var asArray: [Int] { get }
    mutating func append(_ x: Int)
    mutating func prepend(_ x: Int)
    mutating func popFirst() -> Int?
    mutating func popLast() -> Int?
    mutating func remove(at i: Int) -> Int
}

extension Deque<Int>: DequeLike {
    var asArray: [Int] { Array(self) }
}

private struct BuggyDeque: DequeLike {
    var deque = Deque<Int>()
    var count: Int { deque.count }
    var asArray: [Int] { Array(deque) }
    var description: String { deque.description }
    mutating func append(_ x: Int) { deque.append(x) }
    mutating func prepend(_ x: Int) { deque.prepend(x) }
    mutating func popFirst() -> Int? { deque.popLast() }  // the planted bug
    mutating func popLast() -> Int? { deque.popLast() }
    mutating func remove(at i: Int) -> Int { deque.remove(at: i) }
}

private struct Drift: Error, CustomStringConvertible {
    let sut: [Int]
    let model: [Int]
    var description: String { "Deque \(sut) vs model \(model)" }
}

private func commands<D: DequeLike>(_: D.Type) -> [Command<D, [Int]>] {
    [
        Command("pushBack",
                args: { _, tc in Int(try tc.drawInteger(in: Int64(-100)...100)) },
                run: { d, x in d.append(x) },
                model: { m, x in m.append(x) }),
        Command("pushFront",
                args: { _, tc in Int(try tc.drawInteger(in: Int64(-100)...100)) },
                run: { d, x in d.prepend(x) },
                model: { m, x in m.insert(x, at: 0) }),
        Command("popFirst",
                precondition: { !$0.isEmpty },
                run: { d in d.popFirst() },
                model: { m in m.removeFirst() }),
        Command("popLast",
                precondition: { !$0.isEmpty },
                run: { d in d.popLast() },
                model: { m in m.removeLast() }),
        Command("removeAt",                      // the argument depends on the model
                precondition: { !$0.isEmpty },
                args: { m, tc in Int(try tc.drawInteger(in: 0...Int64(m.count - 1))) },
                run: { d, i in d.remove(at: i) },
                model: { m, i in m.remove(at: i) }),
        Command("count",
                run: { d in d.count },
                model: { m in m.count }),
    ]
}

private let consistent: @Sendable (any DequeLike, [Int]) throws -> Void = { d, m in
    guard d.asArray == m else { throw Drift(sut: d.asArray, model: m) }
}

@Suite struct DequeProperties {
    @Test func dequeRefinesArray() throws {
        try forAll(
            sut: Gen { _ in Deque<Int>() }, model: [],
            commands: commands(Deque<Int>.self),
            consistent: { d, m in try consistent(d, m) },
            testCases: 500, database: "")
    }

    /// popFirst that pops the last element: two distinct pushes and a
    /// popFirst are the minimal witness.
    @Test func plantedPopFirstBugShrinksToThreeSteps() throws {
        do {
            try forAll(
                sut: Gen { _ in BuggyDeque() }, model: [],
                commands: commands(BuggyDeque.self),
                consistent: { d, m in try consistent(d, m) },
                testCases: 500, seed: 1, database: "")
            Issue.record("the planted bug was not found")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            let lines = trace.split(separator: "\n").map(String.init)
            #expect(lines.count == 5, "\(trace)")  // initial, 2 pushes, popFirst, violated
            #expect(lines[1].hasPrefix("  push"))
            #expect(lines[2].hasPrefix("  push"))
            #expect(lines[3].hasPrefix("  popFirst -> Optional("))
            #expect(lines[3].hasSuffix(") failed"))
            #expect(lines[4].hasPrefix("violated: popFirst: observed Optional("))
        }
    }
}
