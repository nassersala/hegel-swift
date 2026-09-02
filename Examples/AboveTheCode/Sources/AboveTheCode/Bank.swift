import Hegel

/// The calculation twin of the drawing. Bahr and Hutton derive a
/// compiler by proving its correctness equation and, at every goal the
/// proof cannot take, defining the instruction that makes it compute.
/// The sketch this follows does it for a bank: `⟦ r ⟧ b ≡ apply (send r) b`
/// with the messages unknown, and the wire format is what the stuck goals
/// give birth to. Every field of every message is a variable in scope at
/// a stuck goal.
///
/// Hegel cannot solve a goal. It can find one: with `send` partial, the
/// equation as a property fails, and the shrunk counterexample is the
/// smallest request the definitions do not cover, with the values in
/// scope. That is the stuck goal as a concrete term. Something proposes
/// a constructor for it, the property runs again, and the next
/// counterexample is the next goal. The calculation becomes propose,
/// refute, propose, refute; `Birth` is how far it has gone.
public indirect enum Req: Hashable, Sendable, CustomStringConvertible {
    case deposit(Int)
    case withdraw(Int)
    case then(Req, Req)

    public var description: String {
        switch self {
        case .deposit(let n): return "deposit \(n)"
        case .withdraw(let n): return "withdraw \(n)"
        case .then(let r, let s): return "(\(r) then \(s))"
        }
    }

    /// `⟦ r ⟧ b`: balance before to balance after. Withdraw is monus.
    public func meaning(_ b: Int) -> Int {
        switch self {
        case .deposit(let n): return b + n
        case .withdraw(let n): return max(0, b - n)
        case .then(let r, let s): return s.meaning(r.meaning(b))
        }
    }

    /// Drawn requests, deposit first so a counterexample shrinks toward
    /// `deposit 0`, `then` only while depth remains.
    public static func gen(depth: Int = 3) -> Gen<Req> {
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

/// How far the calculation has gone: which constructors have been born.
public enum Birth: Int, Comparable, Sendable, CaseIterable {
    case nothing, credit, debit, sequence
    public static func < (a: Birth, b: Birth) -> Bool { a.rawValue < b.rawValue }
}

/// Fork A: accept the stuck goal at `then` as it stands, and the wire
/// carries a tree. `SEQ` is born with two messages as its fields.
public enum Tree: Hashable, Sendable, CustomStringConvertible {
    case credit(Int)
    case debit(Int)
    indirect case seq(Tree, Tree)

    public var description: String {
        switch self {
        case .credit(let n): return "CREDIT \(n)"
        case .debit(let n): return "DEBIT \(n)"
        case .seq(let a, let b): return "SEQ (\(a)) (\(b))"
        }
    }

    public static func apply(_ m: Tree, _ b: Int) -> Int {
        switch m {
        case .credit(let n): return b + n
        case .debit(let n): return max(0, b - n)
        case .seq(let x, let y): return apply(y, apply(x, b))
        }
    }

    /// `send`, defined as far as `born`. `nil` is the stuck goal.
    public static func send(_ r: Req, born: Birth) -> Tree? {
        switch r {
        case .deposit(let n): return born >= .credit ? .credit(n) : nil
        case .withdraw(let n): return born >= .debit ? .debit(n) : nil
        case .then(let x, let y):
            guard born >= .sequence, let a = send(x, born: born), let b = send(y, born: born) else { return nil }
            return .seq(a, b)
        }
    }
}

/// Fork B: refuse `SEQ`, the wire is a flat stream. Two ways to write
/// `send` for `then`, and the property cannot tell them apart: append,
/// which is correct and needs the lemma `apply (c ++ d) b = apply d (apply c b)`
/// in the proof, and the continuation, `send r m`, which is what refusing
/// `SEQ` costs in the proof and what makes every case compute. Refutation
/// sees only that both pass. The fork is visible to the prover and not to
/// the tester; that is the finding this fixture exists to make concrete.
public enum Wire: Hashable, Sendable, CustomStringConvertible {
    case credit(Int)
    case debit(Int)

    public var description: String {
        switch self {
        case .credit(let n): return "CREDIT \(n)"
        case .debit(let n): return "DEBIT \(n)"
        }
    }

    /// The ledger: one message at a time, `DONE` is the end of the list.
    public static func apply(_ ms: [Wire], _ b: Int) -> Int {
        ms.reduce(b) { b, m in
            switch m {
            case .credit(let n): return b + n
            case .debit(let n): return max(0, b - n)
            }
        }
    }

    /// `send` by append.
    public static func send(_ r: Req, born: Birth) -> [Wire]? {
        switch r {
        case .deposit(let n): return born >= .credit ? [.credit(n)] : nil
        case .withdraw(let n): return born >= .debit ? [.debit(n)] : nil
        case .then(let x, let y):
            guard born >= .sequence, let a = send(x, born: born), let b = send(y, born: born) else { return nil }
            return a + b
        }
    }

    /// `send r m`, the continuation: the messages for `r`, then `m`.
    /// `then` is not a birth here; nothing new is needed.
    public static func send(_ r: Req, then m: [Wire], born: Birth) -> [Wire]? {
        switch r {
        case .deposit(let n): return born >= .credit ? [.credit(n)] + m : nil
        case .withdraw(let n): return born >= .debit ? [.debit(n)] + m : nil
        case .then(let x, let y):
            guard let rest = send(y, then: m, born: born) else { return nil }
            return send(x, then: rest, born: born)
        }
    }
}

/// The stuck goal: the shrunk `(r, b)` at which the equation cannot be
/// checked because `send` is undefined, or `nil` when every drawn request
/// is covered. Hegel's half of the calculation.
public struct Stuck: Error, CustomStringConvertible {
    public let r: Req
    public let b: Int
    public var description: String { "stuck at ⟦ \(r) ⟧ \(b) = \(r.meaning(b)): send is undefined" }
}

public struct Unequal: Error, CustomStringConvertible {
    public let r: Req
    public let b: Int
    public let got: Int
    public var description: String { "⟦ \(r) \(b) ⟧ = \(r.meaning(b)) but apply (send r) b = \(got)" }
}

public enum Calculation {
    public static let inputs: Gen<(Req, Int)> = Hegel.zip(Req.gen(), Gen<Int>.int(in: 0...9))

    /// Checks the equation with `send` defined as far as `born`, and
    /// returns the stuck goal if there is one. Throws `Unequal` if a
    /// defined case is wrong, which is a different kind of failure.
    public static func stuckGoal(
        born: Birth, seed: UInt64 = 1,
        applySend: @escaping @Sendable (Req, Int, Birth) -> Int?  // apply (send r) b, or nil where send is undefined
    ) throws -> Stuck? {
        do {
            try forAll(inputs, seed: seed, database: "") { r, b in
                guard let got = applySend(r, b, born) else { throw Stuck(r: r, b: b) }
                if got != r.meaning(b) { throw Unequal(r: r, b: b, got: got) }
            }
            return nil
        } catch let failure as PropertyFailure {
            let (r, b) = try replay(inputs, blob: failure.failures.first!.reproduceBlob!)
            guard let got = applySend(r, b, born) else { return Stuck(r: r, b: b) }
            throw Unequal(r: r, b: b, got: got)
        }
    }
}
