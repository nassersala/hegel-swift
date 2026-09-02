import Hegel

/// The wire format, in the calculation form (Examples/AboveTheCode/Bank.swift,
/// Pilot/C-calculation.md). Phase A fixed the meaning
///
///     ⟦ dep n ⟧ b  =  ⟨b + n, ok (b + n)⟩
///     ⟦ wd n ⟧ b   =  if n ≤ b then ⟨b − n, ok (b − n)⟩ else ⟨b, refused b⟩
///
/// and the equation  `⟦ r ⟧ b ≡ apply (send r) b`,  with `Msg` having no
/// constructors and `send` partial. Hegel finds each stuck goal as the
/// smallest `(r, b)` the definitions do not cover; a constructor whose
/// fields are the variables in scope at that goal is proposed, `apply` is
/// defined on it so the goal computes, `send` is read off, and the next
/// run finds the next goal. `Birth` records how far that has gone.

/// `Req`, as Phase A drew it: `n ∈ ℕ⁺`. No `then`; a teller sends one
/// request at a time (P5a).
public enum Req: Hashable, Sendable, CustomStringConvertible {
    case dep(Int)
    case wd(Int)

    public var description: String {
        switch self {
        case .dep(let n): return "dep \(n)"
        case .wd(let n): return "wd \(n)"
        }
    }

    /// `⟦ r ⟧ b`: the pair ⟨balance after, reply⟩. `wd n` is refused when
    /// `n > b`; not monus. The reply carries the balance (P6a).
    public func meaning(_ b: Int) -> (bal: Int, rep: Rep) {
        switch self {
        case .dep(let n): return (b + n, .ok(b + n))
        case .wd(let n): return n <= b ? (b - n, .ok(b - n)) : (b, .refused(b))
        }
    }

    /// Drawn requests, `dep` first so a counterexample shrinks toward
    /// `dep 1`, then `wd 1`; `n` shrinks toward 1 because ℕ⁺ starts there.
    public static let gen: Gen<Req> = Gen { tc in
        let n = Int(try tc.drawInteger(in: Int64(1)...9))
        return try tc.drawInteger(in: Int64(0)...1) == 0 ? .dep(n) : .wd(n)
    }
}

/// `Rep`, as Phase A drew it: both constructors carry the balance (P6a).
public enum Rep: Hashable, Sendable, CustomStringConvertible {
    case ok(Int)
    case refused(Int)

    public var description: String {
        switch self {
        case .ok(let b): return "ok \(b)"
        case .refused(let b): return "refused \(b)"
        }
    }
}

/// How far the calculation has gone. Round 1 gives birth to `DEPOSIT`,
/// round 2 to `WITHDRAW` with `apply` defined in the case in scope at the
/// goal (`n > b`, the refusal), round 3 gives birth to nothing: the same
/// constructor, `apply` completed in the other case (`n ≤ b`).
public enum Birth: Int, Comparable, Sendable, CaseIterable {
    case nothing, deposit, withdrawRefused, withdrawBothCases
    public static func < (a: Birth, b: Birth) -> Bool { a.rawValue < b.rawValue }
}

/// `Msg`: the constructors the stuck goals gave birth to, and nothing else.
/// Every field is a variable in scope at a goal; `b` is the ledger's
/// argument at every goal, so it is never a field.
public enum Msg: Hashable, Sendable, CustomStringConvertible {
    case deposit(Int)     // round 1: n from ⟦ dep n ⟧ b
    case withdraw(Int)    // round 2: n from ⟦ wd n ⟧ b

    public var description: String {
        switch self {
        case .deposit(let n): return "DEPOSIT \(n)"
        case .withdraw(let n): return "WITHDRAW \(n)"
        }
    }

    /// `apply m b`, the ledger's step on one message, defined as far as
    /// `born`. `nil` is a case the calculation has not reached.
    public static func apply(_ m: Msg, _ b: Int, born: Birth = .withdrawBothCases) -> (bal: Int, rep: Rep)? {
        switch m {
        case .deposit(let n):
            return born >= .deposit ? (b + n, .ok(b + n)) : nil
        case .withdraw(let n):
            if n > b { return born >= .withdrawRefused ? (b, .refused(b)) : nil }
            return born >= .withdrawBothCases ? (b - n, .ok(b - n)) : nil
        }
    }

    /// `send r`, read off the goals, defined as far as `born`. Total once
    /// `WITHDRAW` is born.
    public static func send(_ r: Req, born: Birth = .withdrawBothCases) -> Msg? {
        switch r {
        case .dep(let n): return born >= .deposit ? .deposit(n) : nil
        case .wd(let n): return born >= .withdrawRefused ? .withdraw(n) : nil
        }
    }

    /// `apply (send r) b`, or `nil` at a stuck goal.
    public static func applySend(_ r: Req, _ b: Int, born: Birth = .withdrawBothCases) -> (bal: Int, rep: Rep)? {
        send(r, born: born).flatMap { apply($0, b, born: born) }
    }

    // MARK: The stream form, the flat wire Phase A's `net` acts on.

    /// `apply*`: the fold over a stream, `DONE` the empty list. Returns the
    /// balance after and the replies in order; `apply* [] b = ⟨b, []⟩`.
    public static func applyAll(_ ms: [Msg], _ b: Int) -> (bal: Int, reps: [Rep]) {
        var b = b, reps: [Rep] = []
        for m in ms {
            let (b1, rep) = apply(m, b)!
            b = b1
            reps.append(rep)
        }
        return (b, reps)
    }

    /// `send r m`, the continuation: the messages for `r`, then `m`. With
    /// no `then` in `Req` there is nothing to append; the equation
    /// `apply* (send r m) b ≡ apply* m (bal⟦ r ⟧ b)` holds by computation
    /// in both cases and no constructor is born.
    public static func send(_ r: Req, then m: [Msg]) -> [Msg] {
        [send(r)!] + m
    }

    /// The top level, `m = DONE`: `send : Req → [Msg]` as Phase A typed it.
    public static func sendAll(_ r: Req) -> [Msg] { send(r, then: []) }
}

/// The stuck goal: the shrunk `(r, b)` at which the equation cannot be
/// computed because `send` or `apply` is undefined there, printed with the
/// variables and the hypothesis in scope.
public struct Stuck: Error, CustomStringConvertible {
    public let r: Req
    public let b: Int
    public var description: String {
        let (bal, rep) = r.meaning(b)
        let scope: String
        switch r {
        case .dep(let n): scope = "n = \(n), b = \(b)"
        case .wd(let n): scope = "n = \(n), b = \(b), \(n <= b ? "n ≤ b" : "n > b")"
        }
        return "stuck at ⟦ \(r) ⟧ \(b) = ⟨\(bal), \(rep)⟩; in scope \(scope)"
    }
}

/// A defined case that is wrong: a different failure from a stuck goal.
public struct Unequal: Error, CustomStringConvertible {
    public let r: Req
    public let b: Int
    public let got: (bal: Int, rep: Rep)
    public var description: String {
        let (bal, rep) = r.meaning(b)
        return "⟦ \(r) ⟧ \(b) = ⟨\(bal), \(rep)⟩ but apply (send r) b = ⟨\(got.bal), \(got.rep)⟩"
    }
}

public enum Calculation {
    /// `(r, b)`, `b ∈ 0...9`.
    public static let inputs: Gen<(Req, Int)> = Hegel.zip(Req.gen, Gen<Int>.int(in: 0...9))

    /// Checks the equation with the definitions as far as `born` and
    /// returns the stuck goal if there is one; throws `Unequal` if a
    /// defined case is wrong.
    public static func stuckGoal(
        born: Birth, seed: UInt64 = 1,
        applySend: @escaping @Sendable (Req, Int, Birth) -> (bal: Int, rep: Rep)? = { Msg.applySend($0, $1, born: $2) }
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
