import Hegel
import Testing

/// A ring-buffer queue: the system under test. `[Int]` is its model.
private struct Queue: Sendable, CustomStringConvertible {
    enum Bug: Sendable { case none, popsLast, clearLeavesOne }
    private var storage: [Int] = []
    let bug: Bug

    init(bug: Bug = .none) { self.bug = bug }

    var count: Int { storage.count }
    var elements: [Int] { storage }
    var description: String { "Queue(\(storage))" }

    mutating func push(_ x: Int) { storage.append(x) }

    mutating func pop() -> Int? {
        if storage.isEmpty { return nil }
        return bug == .popsLast ? storage.removeLast() : storage.removeFirst()
    }

    mutating func clear() {
        if bug == .clearLeavesOne, storage.count > 1 { storage.removeFirst(storage.count - 1) }
        else { storage.removeAll() }
    }
}

private struct Drift: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private let push = Command<Queue, [Int]>(
    "push",
    args: { _, tc in Int(try tc.drawInteger(in: Int64(-100)...100)) },
    run: { q, x in q.push(x) },
    model: { m, x in m.append(x) })  // effect-only

private let pop = Command<Queue, [Int]>(
    "pop",
    precondition: { !$0.isEmpty },
    run: { q in q.pop() },
    model: { m in m.removeFirst() })  // expected-result, Equatable

private let clear = Command<Queue, [Int]>(
    "clear",
    run: { q in q.clear() },
    model: { m in m.removeAll() })

private let count = Command<Queue, [Int]>(
    "count",
    run: { q in q.count },
    model: { m in m.count })

private let consistent: @Sendable (Queue, [Int]) throws -> Void = { q, m in
    guard q.elements == m else { throw Drift(message: "queue \(q.elements) vs model \(m)") }
}

@Suite struct ModelBasedTests {
    @Test func correctQueueRefinesTheArrayModel() throws {
        try forAll(
            sut: Gen { _ in Queue() }, model: [],
            commands: [push, pop, clear, count],
            consistent: consistent,
            testCases: 300, database: "")
    }

    /// The planted bug pops the last element. The minimal witness is two
    /// pushes of distinct values and a pop, displayed with its arguments and
    /// the observed value.
    @Test func popsLastShrinksToTwoPushesAndAPop() throws {
        do {
            try forAll(
                sut: Gen { _ in Queue(bug: .popsLast) }, model: [],
                commands: [push, pop, clear, count],
                consistent: consistent,
                testCases: 300, seed: 1, database: "")
            Issue.record("the planted bug was not found")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            #expect(trace.hasPrefix("initial: sut Queue([]), model []"), "\(trace)")
            #expect(trace.components(separatedBy: "  push(").count - 1 == 2)
            #expect(!trace.contains("clear"))
            #expect(!trace.contains("count"))
            #expect(trace.contains("pop() -> Optional("))
            #expect(trace.contains(") failed"))
            #expect(trace.contains("violated: pop: observed Optional("))
        }
    }

    /// `clear` leaves one element but observes nothing: only α catches it.
    @Test func consistentCatchesDriftNoObservationShows() throws {
        do {
            try forAll(
                sut: Gen { _ in Queue(bug: .clearLeavesOne) }, model: [],
                commands: [push, clear],
                consistent: consistent,
                testCases: 300, seed: 1, database: "")
            Issue.record("the planted bug was not found")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            #expect(trace.components(separatedBy: "  push(").count - 1 == 2)
            #expect(trace.contains("  clear()\n"))
            #expect(trace.contains("invariant consistent failed"))
            #expect(trace.contains("violated: queue ["))
        }
    }

    @Test func assumeInArgsRejectsBeforeTheSutRuns() throws {
        let pushEven = Command<Queue, [Int]>(
            "pushEven",
            args: { _, tc in
                let x = Int(try tc.drawInteger(in: Int64(0)...9))
                guard x.isMultiple(of: 2) else { throw HegelError.assume }
                return x
            },
            run: { q, x in q.push(x) },
            model: { m, x in m.append(x) })
        try forAll(
            sut: Gen { _ in Queue() }, model: [],
            commands: [pushEven, pop],
            consistent: consistent,
            invariants: [Invariant("all even") { s in
                if !s.model.allSatisfy({ $0.isMultiple(of: 2) }) { throw Drift(message: "odd") }
            }],
            testCases: 100, database: "")
    }

    @Test func assumeInRunIsMisuse() throws {
        let bad = Command<Queue, [Int]>(
            "bad",
            run: { _ in throw HegelError.assume },
            model: { _ in })
        do {
            try forAll(
                sut: Gen { _ in Queue() }, model: [],
                commands: [bad], testCases: 20, database: "")
            Issue.record("misuse should be a violation")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            #expect(trace.contains("  bad() failed"))
            #expect(trace.contains("assume thrown in run"))
        }
    }

    @Test func modelDependentArgsDrawFromTheModel() throws {
        // remove(at:) needs an index that exists in the model.
        let removeAt = Command<Queue, [Int]>(
            "removeAt",
            precondition: { !$0.isEmpty },
            args: { m, tc in Int(try tc.drawInteger(in: 0...Int64(m.count - 1))) },
            run: { q, i in
                var xs = q.elements
                let removed = xs.remove(at: i)
                q = Queue()
                xs.forEach { q.push($0) }
                return removed
            },
            model: { m, i in m.remove(at: i) })
        try forAll(
            sut: Gen { _ in Queue() }, model: [],
            commands: [push, removeAt],
            consistent: consistent,
            testCases: 200, database: "")
    }
}

@Suite struct DescribeStepTests {
    struct Boom: Error {}
    let rules: [Rule<[Int]>] = [
        Rule("plain") { s, _ in s.append(0) },
        Rule("add", describeStep: { "add(\($0.last!))" }) { s, tc in
            s.append(Int(try tc.drawInteger(in: Int64(1)...9)))
        },
    ]

    /// A rule without `describeStep` prints its static name, as before.
    @Test func plainRuleDisplayIsUnchanged() throws {
        do {
            try forAll(
                initial: Gen<[Int]> { _ in [] }, rules: rules,
                invariants: [Invariant("empty") { s in if !s.isEmpty { throw Boom() } }],
                testCases: 200, seed: 1, database: "")
            Issue.record("should fail")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            #expect(trace == "initial: []\n  plain\n  invariant empty failed\nviolated: Boom()", "\(trace)")
        }
    }

    /// A rule with `describeStep` names its drawn argument in the trace.
    @Test func describedStepNamesItsArgs() throws {
        do {
            try forAll(
                initial: Gen<[Int]> { _ in [] }, rules: rules,
                invariants: [Invariant("no positives") { s in if s.contains(where: { $0 > 0 }) { throw Boom() } }],
                testCases: 200, seed: 1, database: "")
            Issue.record("should fail")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            #expect(trace == "initial: []\n  add(1)\n  invariant no positives failed\nviolated: Boom()", "\(trace)")
        }
    }
}

@Suite struct FrequencyTests {
    @Test func everyBranchIsInSupportAndWeightsGuideSearch() throws {
        var seen: Set<Int> = []
        let three = frequency([
            (weight: 8, gen: Gen.int(in: 0...0)),
            (weight: 1, gen: Gen.int(in: 1...1)),
            (weight: 1, gen: Gen.int(in: 2...2)),
        ])
        try forAll(three, testCases: 300, database: "") { x in seen.insert(x) }
        #expect(seen == [0, 1, 2])
    }

    @Test func shrinksTowardTheFirstGenerator() throws {
        struct Big: Error {}
        let g = frequency([(weight: 1, gen: Gen.int(in: 0...0)), (weight: 1, gen: Gen.int(in: 5...9))])
        do {
            try forAll(g, testCases: 100, database: "") { x in if x > 0 { throw Big() } }
            Issue.record("should fail")
        } catch let failure as PropertyFailure {
            #expect(failure.failures.first?.counterexample == "5")
        }
    }
}
