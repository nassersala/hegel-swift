/// Linear temporal logic over a finite trace of states, PropRatt's
/// operator set (Nielsen, Kristiansen & Bahr, PADL 2026) with the atoms
/// as Swift closures. A `Pred` is checked at a position of the trace;
/// `evaluate(_:over:)` checks it at position 0.
///
/// Only safety is testable on a finite trace: `eventually` and strict
/// `until` can only be refuted by an infinite trace, so a passing test
/// would prove nothing. There is no `eventually`; `until` is weak
/// (`weakUntil`: the right side may never arrive, as long as the left
/// side holds to the end of the trace), and `not(eventually p)` is
/// `always(not p)`.
///
/// End-of-trace conventions, as in PropRatt's evaluator: `next` is true
/// at the last position; `weakUntil` at the last position is `q ∨ p`;
/// `prev` and `changed` are false at position 0 (PropRatt rejects `prev` there); every
/// formula is true on the empty trace.
public indirect enum Pred<State>: Sendable {
    /// An atom: the state at this position.
    case now(@Sendable (State) -> Bool)
    /// An atom over the preceding and current states, PropRatt's
    /// expression-level `prev` (`prev sig < sig`); false at position 0.
    case changed(@Sendable (State, State) -> Bool)
    case not(Pred)
    case and(Pred, Pred)
    case or(Pred, Pred)
    case implies(Pred, Pred)
    /// Holds at the following position (true at the last one).
    case next(Pred)
    /// Holds here and at every later position.
    case always(Pred)
    /// The left side holds at every position until the first where the
    /// right side holds; the right side need not ever hold.
    case weakUntil(Pred, Pred)
    /// Held at the preceding position (false at position 0).
    case prev(Pred)

    public static var tt: Pred { .now { _ in true } }
    public static var ff: Pred { .now { _ in false } }

    public static func && (lhs: Pred, rhs: Pred) -> Pred { .and(lhs, rhs) }
    public static func || (lhs: Pred, rhs: Pred) -> Pred { .or(lhs, rhs) }
    public static prefix func ! (p: Pred) -> Pred { .not(p) }
    /// Implication; binds looser than `&&` and `||`.
    public static func => (lhs: Pred, rhs: Pred) -> Pred { .implies(lhs, rhs) }

    /// Evaluates the formula at `position` of `trace`.
    public func holds(at position: Int, in trace: [State]) -> Bool {
        guard position < trace.count else { return true }
        let last = position == trace.count - 1
        switch self {
        case .now(let atom): return atom(trace[position])
        case .changed(let atom): return position > 0 && atom(trace[position - 1], trace[position])
        case .not(let p): return !p.holds(at: position, in: trace)
        case .and(let p, let q): return p.holds(at: position, in: trace) && q.holds(at: position, in: trace)
        case .or(let p, let q): return p.holds(at: position, in: trace) || q.holds(at: position, in: trace)
        case .implies(let p, let q): return !p.holds(at: position, in: trace) || q.holds(at: position, in: trace)
        case .next(let p): return last || p.holds(at: position + 1, in: trace)
        case .always(let p):
            var i = position
            while i < trace.count {
                if !p.holds(at: i, in: trace) { return false }
                i += 1
            }
            return true
        case .weakUntil(let p, let q):
            var i = position
            while i < trace.count {
                if q.holds(at: i, in: trace) { return true }
                if !p.holds(at: i, in: trace) { return false }
                i += 1
            }
            return true
        case .prev(let p): return position > 0 && p.holds(at: position - 1, in: trace)
        }
    }
}

infix operator =>: TernaryPrecedence

public func always<State>(_ p: Pred<State>) -> Pred<State> { .always(p) }
public func next<State>(_ p: Pred<State>) -> Pred<State> { .next(p) }
public func prev<State>(_ p: Pred<State>) -> Pred<State> { .prev(p) }
public func weakUntil<State>(_ p: Pred<State>, _ q: Pred<State>) -> Pred<State> { .weakUntil(p, q) }
public func now<State>(_ atom: @escaping @Sendable (State) -> Bool) -> Pred<State> { .now(atom) }
public func changed<State>(_ atom: @escaping @Sendable (_ previous: State, _ current: State) -> Bool) -> Pred<State> { .changed(atom) }

/// Checks `formula` at position 0 of `trace`. True on the empty trace.
public func evaluate<State>(_ formula: Pred<State>, over trace: [State]) -> Bool {
    formula.holds(at: 0, in: trace)
}

/// The first position at which `formula` fails, or `nil` if it holds at 0.
/// For `always(p)` this is the offending step; for other shapes it is 0.
public func firstFailure<State>(of formula: Pred<State>, over trace: [State]) -> Int? {
    guard !evaluate(formula, over: trace) else { return nil }
    if case .always(let p) = formula {
        return trace.indices.first { !p.holds(at: $0, in: trace) }
    }
    return 0
}
