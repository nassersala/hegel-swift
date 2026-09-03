import Hegel
import Testing

@Suite struct StuckTests {
    // MARK: The undo equation

    /// The first draft cannot undo a delete. The smallest input that
    /// reaches the hole is the smallest delete on the empty document.
    @Test func draftIsStuckAtTheSmallestDelete() throws {
        let verdict = try stuckGoal(ABC.draftInputs, seed: 1, database: "") { e, d, h in
            let history = Draft.record(e, d, h)
            let past = try defined(Draft.undo(history), "undo \(history)")
            let got = meaning(past)(meaning(e)(d))
            if got != d { throw LawViolated("undo(e)(e(d)) = \(got.debugDescription), d = \(d.debugDescription)") }
        }
        print("stuck:\n\(verdict.map { "\($0)" } ?? "holds")")
        guard case let .stuck(input, stuck) = try #require(verdict) else {
            Issue.record("expected .stuck, got \(String(describing: verdict))"); return
        }
        #expect(input == (.delete(at: 0, count: 0), "", []))
        #expect(stuck.goal == "undo [Entry(delete(at: 0, count: 0))]")
    }

    /// With the deleted text in the entry, the equation holds.
    @Test func recordingTheDeletedTextHolds() throws {
        let verdict = try stuckGoal(ABC.inputs, seed: 1, database: "") { e, d, h in
            let got = meaning(undo(record(e, d, h)))(meaning(e)(d))
            if got != d { throw LawViolated("undo(e)(e(d)) = \(got.debugDescription), d = \(d.debugDescription)") }
        }
        print("holds:\n\(verdict.map { "\($0)" } ?? "holds")")
        #expect(verdict == nil)
    }

    /// A wrong `undo` is a refutation, not a hole: the smallest insert
    /// whose undo leaves a character behind.
    @Test func aWrongUndoIsRefuted() throws {
        let verdict = try stuckGoal(ABC.inputs, seed: 1, database: "") { e, d, h in
            let got = meaning(wrongUndo(record(e, d, h)))(meaning(e)(d))
            if got != d { throw LawViolated("undo(e)(e(d)) = \(got.debugDescription), d = \(d.debugDescription)") }
        }
        print("refuted:\n\(verdict.map { "\($0)" } ?? "holds")")
        guard case let .refuted(input, message) = try #require(verdict) else {
            Issue.record("expected .refuted, got \(String(describing: verdict))"); return
        }
        #expect(input == (.insert(at: 0, "a"), "", []))
        #expect(message == "undo(e)(e(d)) = \"a\", d = \"\"")
    }

    /// `Stuck` thrown inside a plain `forAll` is its own bug, and the
    /// report names the goal.
    @Test func stuckReadsAsStuckInAPlainForAll() throws {
        do {
            try forAll(ABC.draftInputs, seed: 1, database: "") { e, d, h in
                let history = Draft.record(e, d, h)
                let past = try defined(Draft.undo(history), "undo \(history)")
                if meaning(past)(meaning(e)(d)) != d { throw LawViolated("unequal") }
            }
            Issue.record("the draft must get stuck")
        } catch let failure as PropertyFailure {
            print("plain forAll:\n\(failure)")
            let bug = try #require(failure.failures.first)
            #expect(bug.error is Stuck)
            #expect(bug.origin.hasSuffix("[Hegel.Stuck]"))
            #expect("\(failure)".contains("counterexample: (delete(at: 0, count: 0), \"\", [])"))
            #expect("\(failure)".contains("\n  stuck: undo [Entry(delete(at: 0, count: 0))]"))
        }
    }

    /// The same equation refuted in a plain `forAll`: the error line is
    /// the violation, not a stuck goal.
    @Test func aRefutationReadsAsItsErrorInAPlainForAll() throws {
        do {
            try forAll(ABC.inputs, seed: 1, database: "") { e, d, h in
                let got = meaning(wrongUndo(record(e, d, h)))(meaning(e)(d))
                if got != d { throw LawViolated("undo(e)(e(d)) = \(got.debugDescription), d = \(d.debugDescription)") }
            }
            Issue.record("wrongUndo must fail")
        } catch let failure as PropertyFailure {
            print("plain forAll, refuted:\n\(failure)")
            let bug = try #require(failure.failures.first)
            #expect(bug.error is LawViolated)
            #expect("\(failure)".contains("\n  undo(e)(e(d)) = \"a\", d = \"\"\n"))
        }
    }

    /// Scope prints under the goal.
    @Test func scopePrintsUnderTheGoal() {
        let stuck = Stuck("send (deposit 0)", scope: [("r", "deposit 0"), ("b", "0")])
        #expect("\(stuck)" == "stuck: send (deposit 0)\n  where r = deposit 0, b = 0")
        #expect("\(Stuck("undo []"))" == "stuck: undo []")
    }

    // MARK: The bank's three stuck goals, through the new API

    /// `Examples/AboveTheCode/Bank.swift`'s Req and Tree, copied: the
    /// equation `apply(send(r), b) == meaning(r, b)` with `send` defined as
    /// far as `born`.
    indirect enum Req: Hashable, Sendable, CustomStringConvertible {
        case deposit(Int)
        case withdraw(Int)
        case then(Req, Req)

        var description: String {
            switch self {
            case .deposit(let n): return "deposit \(n)"
            case .withdraw(let n): return "withdraw \(n)"
            case .then(let r, let s): return "(\(r) then \(s))"
            }
        }

        func meaning(_ b: Int) -> Int {
            switch self {
            case .deposit(let n): return b + n
            case .withdraw(let n): return max(0, b - n)
            case .then(let r, let s): return s.meaning(r.meaning(b))
            }
        }

        static func gen(depth: Int = 3) -> Gen<Req> {
            Gen { tc in try draw(tc, depth: depth) }
        }

        private static func draw(_ tc: TestCase, depth: Int) throws -> Req {
            let kind = try tc.drawInteger(in: Int64(0)...(depth > 0 ? 2 : 1))
            switch kind {
            case 0: return .deposit(Int(try tc.drawInteger(in: Int64(0)...9)))
            case 1: return .withdraw(Int(try tc.drawInteger(in: Int64(0)...9)))
            default: return .then(try draw(tc, depth: depth - 1), try draw(tc, depth: depth - 1))
            }
        }
    }

    enum Birth: Int, Comparable {
        case nothing, credit, debit, sequence
        static func < (a: Birth, b: Birth) -> Bool { a.rawValue < b.rawValue }
    }

    enum Msg: Hashable, Sendable, CustomStringConvertible {
        case credit(Int)
        case debit(Int)
        indirect case seq(Msg, Msg)

        var description: String {
            switch self {
            case .credit(let n): return "CREDIT \(n)"
            case .debit(let n): return "DEBIT \(n)"
            case .seq(let a, let b): return "SEQ (\(a)) (\(b))"
            }
        }

        static func apply(_ m: Msg, _ b: Int) -> Int {
            switch m {
            case .credit(let n): return b + n
            case .debit(let n): return max(0, b - n)
            case .seq(let x, let y): return apply(y, apply(x, b))
            }
        }

        /// Wrong on purpose: debit is not monus.
        static func applyOverdrawing(_ m: Msg, _ b: Int) -> Int {
            switch m {
            case .credit(let n): return b + n
            case .debit(let n): return b - n
            case .seq(let x, let y): return applyOverdrawing(y, applyOverdrawing(x, b))
            }
        }

        static func send(_ r: Req, born: Birth) -> Msg? {
            switch r {
            case .deposit(let n): return born >= .credit ? .credit(n) : nil
            case .withdraw(let n): return born >= .debit ? .debit(n) : nil
            case .then(let x, let y):
                guard born >= .sequence, let a = send(x, born: born), let b = send(y, born: born) else { return nil }
                return .seq(a, b)
            }
        }
    }

    static let bank: Gen<(Req, Int)> = zip(Req.gen(), Gen<Int>.int(in: 0...9))

    func bankGoal(born: Birth, apply: @escaping (Msg, Int) -> Int = Msg.apply) throws -> Verdict<(Req, Int)>? {
        try stuckGoal(Self.bank, seed: 1, database: "") { r, b in
            let m = try defined(Msg.send(r, born: born), "send (\(r))")
            let got = apply(m, b)
            if got != r.meaning(b) { throw LawViolated("apply (send r) b", got, "meaning r b", r.meaning(b)) }
        }
    }

    @Test func theBanksThreeStuckGoalsInOrder() throws {
        var goals: [Verdict<(Req, Int)>?] = []
        for born in [Birth.nothing, .credit, .debit, .sequence] {
            goals.append(try bankGoal(born: born))
        }
        print("bank:\n" + goals.map { $0.map { "\($0)" } ?? "holds" }.joined(separator: "\n"))
        guard case let .stuck(first, s1) = try #require(goals[0]) else { Issue.record("nothing born"); return }
        #expect(first == (.deposit(0), 0) && s1.goal == "send (deposit 0)")
        guard case let .stuck(second, s2) = try #require(goals[1]) else { Issue.record("credit born"); return }
        #expect(second == (.withdraw(0), 0) && s2.goal == "send (withdraw 0)")
        guard case let .stuck(third, s3) = try #require(goals[2]) else { Issue.record("debit born"); return }
        #expect(third == (.then(.deposit(0), .deposit(0)), 0) && s3.goal == "send ((deposit 0 then deposit 0))")
        #expect(goals[3] == nil)
    }

    @Test func aWrongBirthIsRefutedNotStuck() throws {
        let verdict = try bankGoal(born: .sequence, apply: Msg.applyOverdrawing)
        print("bank, refuted:\n\(verdict.map { "\($0)" } ?? "holds")")
        guard case let .refuted(input, message) = try #require(verdict) else { Issue.record("must be refuted"); return }
        #expect(input == (.withdraw(1), 0))
        #expect(message == "apply (send r) b = -1, meaning r b = 0")
    }
}
