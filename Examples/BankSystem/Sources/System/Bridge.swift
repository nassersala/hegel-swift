import Ledger
import Teller

// The seam. Each component defined its own `Req`, `Rep`, `Id`: the teller's
// `Id(teller: String, n: Int)` and `dep/wd`, the ledger's `Id(teller, seq)`
// with `deposit/withdraw` on an account. The wire carries the teller's
// types (the teller puts messages on it; the ledger reads `id(m)`,
// `acct(m)`, `req(m)` off them, Phase A section 4). `Bridge` is that
// projection and its inverse, and `Bug` is the planted seam bug: an id
// scheme that differs between the two sides.

public enum Bridge {
    /// The planted seam bug.
    public enum Bug: Sendable, CaseIterable {
        /// The bridge numbers every copy it forwards with its own per-teller
        /// counter: the ledger sees each resend or network copy as a fresh
        /// `(teller, seq)` and applies it again. The reply is routed back
        /// to the wire request it came from, so the teller's side stays
        /// consistent; only the ledger's `seen` is fooled.
        case freshSeqPerCopy
        /// The bridge drops the teller from the id: `Id("t", n)` for every
        /// teller, so two tellers' first requests collide at the ledger.
        case idWithoutTeller
    }

    public static let acct: Acct = "a"

    /// `id(m)`, `acct(m)`, `req(m)`: the honest projection, the identity on
    /// `Teller × ℕ⁺`.
    public static func ledgerId(_ i: TellerId) -> LedgerId { LedgerId(i.teller, i.n) }
    public static func tellerId(_ i: LedgerId) -> TellerId { TellerId(teller: i.teller, n: i.seq) }

    public static func ledgerReq(_ r: TellerReq) -> LedgerReq {
        switch r {
        case .dep(let n): .deposit(n)
        case .wd(let n): .withdraw(n)
        }
    }
    public static func tellerReq(_ r: LedgerReq) -> TellerReq {
        switch r {
        case .deposit(let n): .dep(n)
        case .withdraw(let n): .wd(n)
        }
    }
    public static func tellerRep(_ r: LedgerRep) -> TellerRep {
        switch r {
        case .ok(let b): .ok(b)
        case .refused(let b): .refused(b)
        }
    }
    public static func ledgerRep(_ r: TellerRep) -> LedgerRep {
        switch r {
        case .ok(let b): .ok(b)
        case .refused(let b): .refused(b)
        }
    }

    /// The ledger's view of a wire request, honest bridge.
    public static func ledgerRequest(_ q: TellerRequest) -> LedgerRequest {
        LedgerRequest(ledgerId(q.id), acct, ledgerReq(q.req))
    }
}
