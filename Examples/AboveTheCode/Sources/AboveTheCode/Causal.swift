import Hegel
import Synchronization

/// A stream function above the code, and what the modal types would
/// have guaranteed. Lively RaTT (Bahr, Graulund, Møgelberg 2021) makes
/// three things type errors in reactive code: reading the future, since
/// a later value cannot be advanced before the tick; holding the past,
/// since only stable values survive a tick; and an unproductive tick,
/// since every recursive call sits behind one. Swift has none of that.
/// This is the relation that says the same three things about a trace,
/// so the tester can be asked what it recovers of the type checker.
///
/// Drawn first as a moving average over the last two samples, input
/// 4, 8, 6, three ticks:
///
///     [now: 0, emitted: {}, held: {}]
///      ─x0 arrives─▶
///      ─read 0─▶      [now: 0, emitted: {},        held: {0}]
///      ─emit 0 = 4─▶  [now: 0, emitted: {0},       held: {0}]
///      ─tick─▶        [now: 1, emitted: {0},       held: {0}]
///      ─x1 arrives─▶
///      ─read 1─▶      [now: 1, emitted: {0},       held: {0, 1}]
///      ─emit 1 = 6─▶  [now: 1, emitted: {0, 1},    held: {0, 1}]     forgets 0 here, or never
///      ─tick─▶        [now: 2, emitted: {0, 1},    held: {1}]
///      ─read 2─▶      [now: 2, emitted: {0, 1},    held: {1, 2}]
///      ─emit 2 = 7─▶  [now: 2, emitted: {0, 1, 2}, held: {1, 2}]
///
/// Three things the rows carry. A read carries the tick it reads, so
/// "read 3 while now is 2" is a row that should not exist: causality.
/// An emit carries the tick it is for, so "emit 1 while now is 2" is
/// visible. The tick row needs the current tick to have been emitted,
/// or the output stream has a hole: productivity, as a safety clause on
/// Tick, because the clock is the environment and only advances when
/// nothing is ready. And `held` is where the space leak lives: at each
/// emit it contains nothing older than the window.
///
/// A step is one read of one input tick, one output for one tick, or one
/// tick of the clock. The arrival of an input is the environment's move.
///
///     Init:  now = 0 ∧ emitted = {}
///     Next:  Read(k):        k ≤ now
///          ∨ Emit(k, held):  k = now ∧ k ∉ emitted ∧ held ⊆ k−W..k ∧ emitted′ = emitted ∪ {k}
///          ∨ Tick:           now ∈ emitted ∧ now′ = now + 1
///
/// The later modality is the Read clause. The box modality is the
/// `held` clause, with W the window the function declares. Guarded
/// recursion is the Tick clause, and it is where the tester and the
/// type checker part: the clause says a tick without an output is not
/// a step, which the trace refutes at the next tick, and it says nothing
/// about a function that never idles, which is only a step budget.
public struct Causal: Equatable, Sendable, CustomStringConvertible {
    /// A recorded step, with the tick it happened at.
    public struct Moment: Hashable, Sendable, CustomStringConvertible {
        public enum Kind: Hashable, Sendable {
            case read(Int)
            /// The output for a tick, and the input ticks the function
            /// still held when it produced it.
            case emit(Int, held: [Int])
            case tick
        }
        public let kind: Kind
        public let at: Int
        public init(_ kind: Kind, at: Int) {
            self.kind = kind
            self.at = at
        }
        public var description: String {
            switch kind {
            case .read(let k): return "read \(k) @\(at)"
            case .emit(let k, let held): return "emit \(k) holding \(held) @\(at)"
            case .tick: return "tick @\(at)"
            }
        }
    }

    public var now: Int
    public var emitted: Set<Int>
    public let window: Int

    public init(window: Int) {
        now = 0
        emitted = []
        self.window = window
    }

    public var description: String { "[now: \(now), emitted: \(emitted.sorted())]" }

    /// `Next(self, m)` is enabled; the reason when it is not.
    public func refused(_ m: Moment) -> String? {
        guard m.at == now else { return "recorded at tick \(m.at), the relation is at \(now)" }
        switch m.kind {
        case .read(let k):
            return k <= now ? nil : "reads tick \(k) at tick \(now): the future"
        case .emit(let k, let held):
            if k != now { return "the output for tick \(k) produced at tick \(now): \(k < now ? "late" : "early")" }
            if emitted.contains(k) { return "a second output for tick \(k)" }
            if let old = held.first(where: { $0 < k - window }) {
                return "holds tick \(old) at tick \(k), older than the window of \(window)"
            }
            return nil
        case .tick:
            return emitted.contains(now) ? nil : "tick \(now + 1) with no output for tick \(now): unproductive"
        }
    }

    public func enabled(_ m: Moment) -> Bool { refused(m) == nil }

    /// Precondition: `enabled(m)`.
    public mutating func apply(_ m: Moment) {
        precondition(enabled(m), "\(m) is not enabled at \(self)")
        switch m.kind {
        case .read: break
        case .emit(let k, _): emitted.insert(k)
        case .tick: now += 1
        }
    }

    public struct Violation: Equatable, CustomStringConvertible, Sendable {
        public let step: Int
        public let moment: Moment
        public let state: Causal
        public let reason: String
        public var description: String { "step \(step): \(moment) is not a Next step at \(state): \(reason)" }
    }

    /// Replay the tape's record against the relation. The first moment
    /// that is not a step is the report, with the reason the clause
    /// gives.
    public static func refines(_ moments: [Moment], window: Int) -> (violation: Violation?, final: Causal) {
        var s = Causal(window: window)
        for (i, m) in moments.enumerated() {
            if let reason = s.refused(m) { return (Violation(step: i, moment: m, state: s, reason: reason), s) }
            s.apply(m)
        }
        return (nil, s)
    }
}

// MARK: - The tape: the runtime a stream function runs on

/// Input cells written by the environment, output cells written by the
/// function, a tick counter advanced by the clock, and the record. A
/// read of a cell not yet written suspends until it is; that is the
/// freedom Swift gives that the later modality does not, and the record
/// is how the relation sees it used.
public final class Tape: @unchecked Sendable {
    private struct State {
        var now = 0
        var inputs: [Int: Int] = [:]
        var outputs: [Int: Int] = [:]
        var waiters: [Int: [CheckedContinuation<Int, Never>]] = [:]
        var tickWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
        var moments: [Causal.Moment] = []
    }
    private let state = Mutex(State())

    public init() {}

    public var now: Int { state.withLock { $0.now } }
    public var moments: [Causal.Moment] { state.withLock { $0.moments } }
    public var outputs: [Int: Int] { state.withLock { $0.outputs } }

    /// The environment's move: the input for tick `k` is available.
    public func write(_ k: Int, _ v: Int) {
        let waiters: [CheckedContinuation<Int, Never>] = state.withLock { s in
            s.inputs[k] = v
            return s.waiters.removeValue(forKey: k) ?? []
        }
        for w in waiters { w.resume(returning: v) }
    }

    /// The clock's move.
    public func tick() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
            s.moments.append(Causal.Moment(.tick, at: s.now))
            s.now += 1
            return s.tickWaiters.removeValue(forKey: s.now) ?? []
        }
        for w in waiters { w.resume() }
    }

    /// Suspends until tick `t` has begun. This is the later modality as
    /// a call: a function that advances on the tick rather than on the
    /// arrival of its input cannot read the future, whatever the source
    /// does.
    public func await(tick t: Int) async {
        if state.withLock({ $0.now >= t }) { return }
        await withCheckedContinuation { c in
            let begun: Bool = state.withLock { s in
                if s.now >= t { return true }
                s.tickWaiters[t, default: []].append(c)
                return false
            }
            if begun { c.resume() }
        }
    }

    /// Whether the input for tick `k` is there, without reading it.
    public func hasInput(_ k: Int) -> Bool { state.withLock { $0.inputs[k] != nil } }

    /// The function's read of tick `k`. Recorded when the value is in
    /// hand, at the tick that is current then.
    public func read(_ k: Int) async -> Int {
        let known: Int? = state.withLock { $0.inputs[k] }
        let v: Int
        if let known {
            v = known
        } else {
            v = await withCheckedContinuation { c in
                let known: Int? = state.withLock { s in
                    if let v = s.inputs[k] { return v }
                    s.waiters[k, default: []].append(c)
                    return nil
                }
                if let known { c.resume(returning: known) }
            }
        }
        state.withLock { s in s.moments.append(Causal.Moment(.read(k), at: s.now)) }
        return v
    }

    /// The function's output for tick `k`, with the input ticks it still
    /// holds.
    public func emit(_ k: Int, _ v: Int, holding held: [Int]) {
        state.withLock { s in
            s.outputs[k] = v
            s.moments.append(Causal.Moment(.emit(k, held: held.sorted()), at: s.now))
        }
    }
}

// MARK: - Stream functions

/// The subjects: two that the types would accept, and four that the
/// types would refuse, one per modality and two for productivity.
public enum StreamFunction: Sendable, CaseIterable, CustomStringConvertible {
    /// `y[t] = mean(x[0...t])` as a fold: sum and count are the stable
    /// state, no input is held. Window 0.
    case runningAverage
    /// `y[t] = (x[t−1] + x[t]) / 2`, holding one input. Window 1.
    case movingAverage
    /// `y[t] = (x[t] + x[t+1]) / 2`: reads the next tick. Window 1.
    case lookahead
    /// The running average keeping every sample. Window 0.
    case keepsEverything
    /// At tick 1, waits for an input that never comes.
    case stalls
    /// At tick 1, polls for that input instead of waiting.
    case spins

    public var description: String {
        switch self {
        case .runningAverage: return "runningAverage"
        case .movingAverage: return "movingAverage"
        case .lookahead: return "lookahead"
        case .keepsEverything: return "keepsEverything"
        case .stalls: return "stalls"
        case .spins: return "spins"
        }
    }

    /// The window each declares, what the box modality would let it keep.
    public var window: Int {
        switch self {
        case .runningAverage, .keepsEverything, .stalls, .spins: return 0
        case .movingAverage, .lookahead: return 1
        }
    }

    /// The reference, over the whole input, for the outputs that are
    /// produced.
    public func reference(_ x: [Int], at t: Int) -> Int {
        switch self {
        case .runningAverage, .keepsEverything, .stalls, .spins:
            return x[0...t].reduce(0, +) / (t + 1)
        case .movingAverage:
            return t == 0 ? x[0] : (x[t - 1] + x[t]) / 2
        case .lookahead:
            return t + 1 < x.count ? (x[t] + x[t + 1]) / 2 : x[t]
        }
    }

    /// Runs for `n` ticks on the tape. `held` is the function's own
    /// buffer of inputs; what it forgets is its business, and the tape
    /// records what it kept at each emit.
    ///
    /// `waitsForTick` is the finding of the first run. As first written,
    /// every function advanced when its next input arrived, and the two
    /// the types would accept were refused at step 2 under a source one
    /// ahead: the running average read tick 1 at tick 0. The function
    /// must advance on the tick, not on the data; that is what `adv`
    /// under a tick means, and `false` keeps the refuted version.
    public func run(on tape: Tape, ticks n: Int, waitsForTick: Bool = true) async {
        var held: [Int: Int] = [:]
        var sum = 0
        for t in 0..<n {
            if waitsForTick { await tape.await(tick: t) }
            switch self {
            case .runningAverage:
                sum += await tape.read(t)
                tape.emit(t, sum / (t + 1), holding: [])
            case .keepsEverything:
                held[t] = await tape.read(t)
                tape.emit(t, held.values.reduce(0, +) / held.count, holding: Array(held.keys))
            case .movingAverage:
                held[t] = await tape.read(t)
                held[t - 2] = nil
                let y = t == 0 ? held[0]! : (held[t - 1]! + held[t]!) / 2
                tape.emit(t, y, holding: Array(held.keys))
            case .lookahead:
                held[t] = await tape.read(t)
                held[t - 1] = nil
                let next = t + 1 < n ? await tape.read(t + 1) : held[t]!
                tape.emit(t, (held[t]! + next) / 2, holding: Array(held.keys))
            case .stalls:
                sum += await tape.read(t)
                if t == 1 { sum += await tape.read(n + 1) }  // never written
                tape.emit(t, sum / (t + 1), holding: [])
            case .spins:
                sum += await tape.read(t)
                if t == 1 {
                    while !tape.hasInput(n + 1) { await Task.yield() }
                }
                tape.emit(t, sum / (t + 1), holding: [])
            }
        }
    }
}

/// The environment: the clock and the input source as one task. The
/// input for tick `t` is written when tick `t` begins; with `prefetch`
/// the source runs one ahead, the way a buffered source does. The clock
/// sleeps one unit per tick on the clock it is given; under the fake
/// clock that fires only when nothing is ready, which is what makes
/// "the tick came and the output had not" a schedule the run can reach.
public func drive<C: Clock>(_ tape: Tape, inputs x: [Int], prefetch: Bool, clock: C) async where C.Duration == Swift.Duration {
    let n = x.count
    func provide(_ t: Int) { if t < n { tape.write(t, x[t]) } }
    provide(0)
    if prefetch { provide(1) }
    for t in 1..<n {
        try? await clock.sleep(for: .seconds(1))
        tape.tick()
        provide(t)
        if prefetch { provide(t + 1) }
    }
}
