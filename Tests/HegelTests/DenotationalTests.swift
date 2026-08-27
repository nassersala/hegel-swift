import Hegel
import Testing

/// Denotational design as a model-based property: the type's meaning is a
/// simpler type, every operation is written twice, and the drawn command
/// sequence is a stack program, so terms of any shape (`scale(3)(a + b) + a`)
/// arise from a linear sequence. `push` is the leaf, `add`/`scale`/`dup`
/// are the vocabulary, and `consistent` is ⟦·⟧ applied to every stack slot.
///
/// The type: a sparse vector as sorted `(index, value)` pairs. Its meaning:
/// `[Int: Int]`, zeros absent. The planted bug is Elliott's `Map` example
/// (Denotational Design with Type Class Morphisms, §3): merge is left-biased
/// where the meaning says it sums.
private struct SparseVector: Sendable, CustomStringConvertible {
    enum Bug: Sendable { case none, leftBiasedMerge }
    private(set) var entries: [(index: Int, value: Int)]  // sorted by index, no zeros
    let bug: Bug

    init(bug: Bug = .none) { entries = []; self.bug = bug }

    static func unit(_ i: Int, _ v: Int, bug: Bug) -> SparseVector {
        var s = SparseVector(bug: bug)
        if v != 0 { s.entries = [(i, v)] }
        return s
    }

    /// ⟦·⟧
    var meaning: [Int: Int] { Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0.value) }) }
    var description: String { "SparseVector(\(entries.map { "\($0.index):\($0.value)" }.joined(separator: " ")))" }

    func adding(_ other: SparseVector) -> SparseVector {
        var out = SparseVector(bug: bug)
        var i = 0, j = 0
        while i < entries.count || j < other.entries.count {
            if j == other.entries.count || (i < entries.count && entries[i].index < other.entries[j].index) {
                out.entries.append(entries[i]); i += 1
            } else if i == entries.count || other.entries[j].index < entries[i].index {
                out.entries.append(other.entries[j]); j += 1
            } else {
                let v = bug == .leftBiasedMerge ? entries[i].value : entries[i].value + other.entries[j].value
                if v != 0 { out.entries.append((entries[i].index, v)) }
                i += 1; j += 1
            }
        }
        return out
    }

    func scaled(by k: Int) -> SparseVector {
        var out = SparseVector(bug: bug)
        if k != 0 { out.entries = entries.map { ($0.index, $0.value * k) } }
        return out
    }
}

private extension Dictionary where Key == Int, Value == Int {
    func adding(_ other: [Int: Int]) -> [Int: Int] {
        merging(other, uniquingKeysWith: +).filter { $0.value != 0 }
    }
    func scaled(by k: Int) -> [Int: Int] { mapValues { $0 * k }.filter { $0.value != 0 } }
}

private struct Drift: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// The stack program's instructions. The state is a stack of representations
/// paired with a stack of meanings; the precondition is the arity.
private func vocabulary(bug: SparseVector.Bug) -> [Command<[SparseVector], [[Int: Int]]>] {
    [
        Command("push",
                args: { _, tc in
                    (Int(try tc.drawInteger(in: Int64(0)...2)), Int(try tc.drawInteger(in: Int64(-3)...3)))
                },
                run: { s, iv in s.append(.unit(iv.0, iv.1, bug: bug)) },
                model: { m, iv in m.append(iv.1 == 0 ? [:] : [iv.0: iv.1]) },
                describe: { "\($0.0), \($0.1)" }),
        Command("add",
                precondition: { $0.count >= 2 },
                run: { s in let b = s.removeLast(), a = s.removeLast(); s.append(a.adding(b)) },
                model: { m in let b = m.removeLast(), a = m.removeLast(); m.append(a.adding(b)) }),
        Command("scale",
                precondition: { !$0.isEmpty },
                args: { _, tc in Int(try tc.drawInteger(in: Int64(-2)...2)) },
                run: { s, k in s.append(s.removeLast().scaled(by: k)) },
                model: { m, k in m.append(m.removeLast().scaled(by: k)) }),
        Command("dup",
                precondition: { !$0.isEmpty },
                run: { s in s.append(s[s.count - 1]) },
                model: { m in m.append(m[m.count - 1]) }),
    ]
}

/// ⟦·⟧ on every slot: the two interpretations of the program agree.
private let consistent: @Sendable ([SparseVector], [[Int: Int]]) throws -> Void = { s, m in
    guard s.count == m.count else { throw Drift(message: "stack depth \(s.count) vs \(m.count)") }
    for (v, d) in zip(s, m) where v.meaning != d {
        throw Drift(message: "⟦\(v)⟧ = \(v.meaning) vs meaning \(d)")
    }
}

@Suite struct DenotationalTests {
    @Test func sparseVectorRefinesItsMeaning() throws {
        try forAll(
            sut: Gen { _ in [SparseVector]() }, model: [[Int: Int]](),
            commands: vocabulary(bug: .none),
            consistent: consistent,
            testCases: 300, database: "")
    }

    /// The left-biased merge is only visible when two operands share an
    /// index. The shrinker finds `a + a` with one leaf: push, dup, add —
    /// smaller than two pushes, since dup is how sharing is spelled here.
    @Test func leftBiasedMergeShrinksToPushDupAdd() throws {
        do {
            try forAll(
                sut: Gen { _ in [SparseVector]() }, model: [[Int: Int]](),
                commands: vocabulary(bug: .leftBiasedMerge),
                consistent: consistent,
                testCases: 300, seed: 1, database: "")
            Issue.record("the planted bug was not found")
        } catch let failure as PropertyFailure {
            let trace = try #require(failure.failures.first?.counterexample)
            #expect(trace.hasPrefix("initial: sut [], model []"), "\(trace)")
            #expect(trace.components(separatedBy: "  push(").count - 1 == 1, "\(trace)")
            #expect(trace.contains("  dup\n  add\n"), "\(trace)")
            #expect(!trace.contains("scale"), "\(trace)")
            #expect(trace.contains("invariant consistent failed"), "\(trace)")
            #expect(trace.contains("violated: ⟦SparseVector(0:1)⟧ = [0: 1] vs meaning [0: 2]"), "\(trace)")
        }
    }
}
