// A support-inbox agent that can refund. Six tools the agent may call; two of
// them irreversible; one of them (requestApproval) answered by a human, whose
// answer comes back as a tool result the agent cannot fake. The policy is the
// `policy` table below and nothing else: states named by the sequence that
// reaches them, one block per state, every stimulus in every block, each cell
// `allow ⋄ →next` or `deny`. Everything that enforces or tests the policy is
// derived from it.

import CryptoKit
import Foundation
import Hegel

// MARK: Stimuli

/// What can happen at the boundary: an action the agent calls, or a result a
/// trusted tool returns. The planner's vocabulary is `actions` only — a plan
/// that contains a tool result is rejected before the table is consulted.
enum Stimulus: String, CaseIterable, Sendable, Codable {
    case readTicket, lookupOrder, draftReply, requestApproval, issueRefund, sendReply
    case approvalGranted, approvalDenied

    var isToolResult: Bool { self == .approvalGranted || self == .approvalDenied }
    var irreversible: Bool { self == .issueRefund || self == .sendReply }
    static let actions = allCases.filter { !$0.isToolResult }
}

// MARK: The enumeration table

/// A semantic Swift name paired with the shortest canonical stimulus history
/// that represents the state. Source code uses the descriptive case; reports
/// use `canonicalSequence`, preserving the notation of sequence enumeration.
enum State: String, CaseIterable, Hashable, Sendable, CustomStringConvertible {
    case initial = "Δ"
    case ticketRead = "T"
    case ticketReadApprovalPending = "T.p"
    case ticketReadApprovalHeld = "T.p.A"
    case orderKnown = "T.O"
    case orderKnownApprovalPending = "T.O.p"
    case orderKnownApprovalHeld = "T.O.p.A"
    case refunded = "T.O.p.A.r"
    case refundApprovalPending = "T.O.p.A.r.p"
    case closed = "T.S"

    var canonicalSequence: String { rawValue }
    var description: String { canonicalSequence }
}

enum Outcome: Sendable, Equatable {
    case allow(next: State, req: String)
    case deny(String)
}
typealias Block = [Stimulus: Outcome]
typealias Policy = [State: Block]

/// A block for a state where no approval is pending: the six actions as given,
/// the two tool results denied (nothing was asked).
private func block(_ actions: Block) -> Block {
    actions.merging([
        .approvalGranted: .deny("R4 no approval pending"),
        .approvalDenied: .deny("R4 no approval pending"),
    ]) { a, _ in a }
}

/// A block for a state waiting on the manager: every action denied until the
/// answer arrives; the answer moves the state.
private func pending(granted: State, denied: State) -> Block {
    var b: Block = [
        .approvalGranted: .allow(next: granted, req: "R4 the manager granted"),
        .approvalDenied: .allow(next: denied, req: "R4 the manager denied"),
    ]
    for a in Stimulus.actions { b[a] = .deny("R4 awaiting the manager") }
    return b
}

/// Canonical stimulus symbols: T read ticket · O look up order · p request
/// approval · A approval granted · r issue refund · S send reply.
/// Equivalent longer histories return to the shortest case above: for example,
/// `T.O.p.A.r.p.A` returns to `T.O.p.A` because their future behavior is equal.
let policy: Policy = [
    .initial: block([
        .readTicket: .allow(next: .ticketRead, req: "R1 read the ticket first"),
        .lookupOrder: .deny("R1 ticket not read"), .draftReply: .deny("R1 ticket not read"),
        .requestApproval: .deny("R1 ticket not read"), .issueRefund: .deny("R1 ticket not read"),
        .sendReply: .deny("R1 ticket not read"),
    ]),
    .ticketRead: block([
        .readTicket: .allow(next: .ticketRead, req: "R1"),
        .lookupOrder: .allow(next: .orderKnown, req: "R2 reads are free"),
        .draftReply: .allow(next: .ticketRead, req: "R2"),
        .requestApproval: .allow(
            next: .ticketReadApprovalPending, req: "R4 approval may be requested"),
        .issueRefund: .deny("R3 refund needs order + approval"),
        .sendReply: .allow(next: .closed, req: "R5 reply needs no approval"),
    ]),
    .ticketReadApprovalPending: pending(granted: .ticketReadApprovalHeld, denied: .ticketRead),
    .ticketReadApprovalHeld: block([
        .readTicket: .allow(next: .ticketReadApprovalHeld, req: "R1"),
        .lookupOrder: .allow(next: .orderKnownApprovalHeld, req: "R2"),
        .draftReply: .allow(next: .ticketReadApprovalHeld, req: "R2"),
        .requestApproval: .deny("R4 already holds an unused approval"),
        .issueRefund: .deny("R3 order not looked up"),
        .sendReply: .allow(next: .closed, req: "R5"),
    ]),
    .orderKnown: block([
        .readTicket: .allow(next: .orderKnown, req: "R1"),
        .lookupOrder: .allow(next: .orderKnown, req: "R2"),
        .draftReply: .allow(next: .orderKnown, req: "R2"),
        .requestApproval: .allow(next: .orderKnownApprovalPending, req: "R4"),
        .issueRefund: .deny("R3 no approval"),
        .sendReply: .allow(next: .closed, req: "R5"),
    ]),
    .orderKnownApprovalPending: pending(granted: .orderKnownApprovalHeld, denied: .orderKnown),
    .orderKnownApprovalHeld: block([
        .readTicket: .allow(next: .orderKnownApprovalHeld, req: "R1"),
        .lookupOrder: .allow(next: .orderKnownApprovalHeld, req: "R2"),
        .draftReply: .allow(next: .orderKnownApprovalHeld, req: "R2"),
        .requestApproval: .deny("R4 already holds an unused approval"),
        .issueRefund: .allow(next: .refunded, req: "R3 refund with order + approval"),
        .sendReply: .allow(next: .closed, req: "R5"),
    ]),
    .refunded: block([
        .readTicket: .allow(next: .refunded, req: "R1"),
        .lookupOrder: .allow(next: .refunded, req: "R2"),
        .draftReply: .allow(next: .refunded, req: "R2"),
        .requestApproval: .allow(
            next: .refundApprovalPending, req: "R4 a new approval allows one more refund"),
        .issueRefund: .deny("R4 one approval, one refund"),  // the cell a hand-written gate forgets
        .sendReply: .allow(next: .closed, req: "R5"),
    ]),
    .refundApprovalPending: pending(granted: .orderKnownApprovalHeld, denied: .refunded),
    .closed: Dictionary(
        uniqueKeysWithValues: Stimulus.allCases.map { ($0, Outcome.deny("R6 closed")) }),
]

func show(_ state: State) -> String { state.canonicalSequence }

/// Completeness: every state has a block, every block has every stimulus, and
/// every →next has a block. The `State` type makes misspelled targets impossible.
func tableProblems(_ table: Policy) -> [String] {
    var out: [String] = []
    for state in State.allCases where table[state] == nil {
        out.append("missing state \(show(state))")
    }
    for (state, block) in table {
        for s in Stimulus.allCases where block[s] == nil {
            out.append("\(show(state)) missing \(s)")
        }
        for case .allow(let next, _) in block.values where table[next] == nil {
            out.append("\(show(state)) → \(next) undefined")
        }
    }
    return out.sorted()
}

/// A fingerprint of the table, stamped on every `VerifiedWorkflow`.
let policyVersion: String = {
    let text = policy.sorted { $0.key.rawValue < $1.key.rawValue }
        .map { state, block in
            "\(state):"
                + block.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key)=\($0.value)" }
                .joined(
                    separator: ",")
        }
        .joined(separator: ";")
    return SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
}()

// MARK: Consumer 1 — the gate: walk a whole plan

enum Verdict: Equatable, Sendable {
    case accepted(end: State)
    case rejected(at: Int, Stimulus, String)
    var isAccepted: Bool { if case .accepted = self { return true } else { return false } }
}

/// Walk a plan through the table from `start`. A plan is agent actions only;
/// a tool result inside it is rejected (R7). After `requestApproval` the walk
/// takes the granted path, because that is the only path on which the rest
/// of the plan runs — the executor stops at a denial.
func walk(_ plan: [Stimulus], from start: State = .initial) -> Verdict {
    var s = start
    for (i, a) in plan.enumerated() {
        if a.isToolResult {
            return .rejected(
                at: i, a, "\(show(s)) ▸ \(a): R7 the planner cannot assert a tool result")
        }
        switch policy[s]![a]! {
        case .deny(let why): return .rejected(at: i, a, "\(show(s)) ▸ \(a): \(why)")
        case .allow(let next, _):
            s = next
            if a == .requestApproval, case .allow(let granted, _) = policy[s]![.approvalGranted]! {
                s = granted
            }
        }
    }
    return .accepted(end: s)
}

// MARK: Consumer 2 — the monitor: walk one step at a time

struct Monitor: Sendable {
    var state: State = .initial
    let bug: Bug?
    mutating func check(_ s: Stimulus) -> Outcome {
        let outcome = policy[state]![s]!
        if case .allow(let next, _) = outcome {
            if !(bug == .monitorSkipsApproval && s == .approvalGranted) { state = next }
        }
        return outcome
    }
}

// MARK: The type boundary

/// Evidence that `walk` accepted `plan` from `from` under `policyVersion`.
/// Only `verify` can make one; only one of these can be executed, and only
/// from the state it was verified from.
struct VerifiedWorkflow: Sendable {
    let plan: [Stimulus]
    let from: State
    let policyVersion: String
    fileprivate init(_ plan: [Stimulus], from: State) {
        self.plan = plan
        self.from = from
        policyVersion = AgentPropertyTests.policyVersion
    }
}

struct PolicyViolation: Error, CustomStringConvertible {
    let description: String
}

func verify(_ plan: [Stimulus], from start: State = .initial) -> Result<
    VerifiedWorkflow, PolicyViolation
> {
    switch walk(plan, from: start) {
    case .accepted: return .success(VerifiedWorkflow(plan, from: start))
    case .rejected(_, _, let why): return .failure(PolicyViolation(description: why))
    }
}

// MARK: The executor and the tools

/// Fake tools: every call, and every result received, is an event in the log.
struct Tools: Sendable {
    var effects: [Stimulus] = []
    mutating func perform(_ s: Stimulus) { effects.append(s) }
}

/// The bugs the tests plant. Each is one line in the code around it.
enum Bug: Sendable {
    case gateForgetsOneApprovalOneRefund  // hand-written verifier never clears the approval flag
    case executorFiresOnDeny  // adapter already enqueued the call when the monitor said no
    case monitorSkipsApproval  // monitor does not advance on approvalGranted
    case replanGatedFromStart  // a replanned suffix is walked from Δ, not from the current state
    case executorAssumesApproval  // executor treats a sent request as a granted one
}

/// Thrown by `execute`: the boundary itself disagreed with the evidence it was handed.
enum BoundaryViolation: Error, Equatable {
    case wrongStartState(expected: State, actual: State)
    case policyChanged
    case deniedAtRuntime(String)
}

enum Execution: Equatable, Sendable {
    case completed
    case stopped(at: Int, reason: String)  // the manager denied; the rest of the plan did not run
}

struct Agent: Sendable {
    var monitor: Monitor
    var tools = Tools()
    var blocked: [(state: State, stimulus: Stimulus)] = []
    let bug: Bug?
    /// The human behind `requestApproval`: decides the n-th request. Default: grants.
    var manager: @Sendable (Int) -> Bool = { _ in true }
    private var requests = 0

    init(bug: Bug? = nil, manager: @escaping @Sendable (Int) -> Bool = { _ in true }) {
        self.bug = bug
        self.manager = manager
        monitor = Monitor(bug: bug)
    }

    /// One step through the boundary: the monitor first, then the tool.
    mutating func runOne(_ s: Stimulus) -> Outcome {
        let before = monitor.state
        let outcome = monitor.check(s)
        switch outcome {
        case .allow: tools.perform(s)
        case .deny:
            blocked.append((before, s))
            if bug == .executorFiresOnDeny { tools.perform(s) }
        }
        return outcome
    }

    /// Run a verified workflow. Every step goes through the monitor anyway; a
    /// runtime deny on verified evidence is a boundary bug and throws. After
    /// `requestApproval` the manager's answer is injected as a tool result; a
    /// denial stops the plan.
    mutating func execute(_ w: VerifiedWorkflow) throws -> Execution {
        guard w.policyVersion == policyVersion else { throw BoundaryViolation.policyChanged }
        guard monitor.state == w.from else {
            throw BoundaryViolation.wrongStartState(expected: w.from, actual: monitor.state)
        }
        for (i, a) in w.plan.enumerated() {
            guard case .allow = runOne(a) else {
                throw BoundaryViolation.deniedAtRuntime("\(show(monitor.state)) ▸ \(a)")
            }
            if a == .requestApproval {
                requests += 1
                let granted = bug == .executorAssumesApproval ? true : manager(requests)
                let result: Stimulus = granted ? .approvalGranted : .approvalDenied
                guard case .allow = runOne(result) else {
                    throw BoundaryViolation.deniedAtRuntime("\(show(monitor.state)) ▸ \(result)")
                }
                if !granted {
                    return .stopped(at: i, reason: "the manager denied request \(requests)")
                }
            }
        }
        return .completed
    }
}

/// α, the abstraction function: the event log is a walk of the table, and
/// this is where it ends. nil if the log is not a legal walk.
func alpha(_ effects: [Stimulus]) -> State? {
    var s: State = .initial
    for e in effects {
        guard case .allow(let next, _) = policy[s]![e]! else { return nil }
        s = next
    }
    return s
}

// MARK: A hand-written verifier, Meijer style: flags, no table

/// The gate as it looks when written by hand: four flags. Plan-level like
/// `walk` (a request is assumed granted; the executor handles denial).
/// Correct as written; `bug: .gateForgetsOneApprovalOneRefund` removes one
/// line. The table is its oracle — by sampling and exhaustively — in the tests.
struct Flags: Hashable, Sendable {
    var ticketRead = false, orderLooked = false, approval = false, closed = false
}

func handWrittenStep(_ f: Flags, _ a: Stimulus, bug: Bug? = nil) -> Flags? {
    var f = f
    if f.closed || a.isToolResult { return nil }
    switch a {
    case .readTicket:
        f.ticketRead = true
    case .lookupOrder, .draftReply:
        guard f.ticketRead else { return nil }
        if a == .lookupOrder { f.orderLooked = true }
    case .requestApproval:
        guard f.ticketRead, !f.approval else { return nil }
        f.approval = true
    case .issueRefund:
        guard f.orderLooked, f.approval else { return nil }
        if bug != .gateForgetsOneApprovalOneRefund { f.approval = false }
    case .sendReply:
        guard f.ticketRead else { return nil }
        f.closed = true
    case .approvalGranted, .approvalDenied:
        return nil
    }
    return f
}

func handWrittenVerify(_ plan: [Stimulus], bug: Bug? = nil) -> Bool {
    var f = Flags()
    for a in plan {
        guard let next = handWrittenStep(f, a, bug: bug) else { return false }
        f = next
    }
    return true
}

/// Exhaustive: breadth-first search over the product of the table's states
/// and the hand-written verifier's flags, every agent action from every
/// reachable pair. Returns the shortest plan on which exactly one of the two
/// rejects, or nil if they agree everywhere. Both machines are finite, so this
/// is a proof of equivalence, not a sample.
func shortestDisagreement(bug: Bug? = nil) -> [Stimulus]? {
    struct Pair: Hashable {
        let state: State
        let flags: Flags
    }
    var seen: Set<Pair> = [Pair(state: .initial, flags: Flags())]
    var queue: [(Pair, [Stimulus])] = [(Pair(state: .initial, flags: Flags()), [])]
    while !queue.isEmpty {
        let (p, path) = queue.removeFirst()
        for a in Stimulus.actions {
            let table = walk([a], from: p.state)
            let hand = handWrittenStep(p.flags, a, bug: bug)
            switch (table, hand) {
            case (.accepted(let end), .some(let f)):
                let q = Pair(state: end, flags: f)
                if seen.insert(q).inserted { queue.append((q, path + [a])) }
            case (.rejected, .none):
                continue
            default:
                return path + [a]
            }
        }
    }
    return nil
}

// MARK: The fake planner

/// Plans that mostly make sense: from a start state, at each step 80% an
/// action the table allows there, 20% any stimulus — tool results included,
/// which a planner must not be able to assert. The untrusted planner CI uses.
func plans(from start: State = .initial, length: ClosedRange<Int64> = 0...10) -> Gen<[Stimulus]> {
    Gen { tc in
        let n = Int(try tc.drawInteger(in: length))
        var s = start
        var out: [Stimulus] = []
        for _ in 0..<n {
            let allowed = Stimulus.actions.filter {
                if case .allow = policy[s]![$0]! { return true } else { return false }
            }
            let a: Stimulus
            if !allowed.isEmpty, try tc.drawBool(probability: 0.8) {
                a = try element(of: allowed).run(tc)
            } else {
                a = try element(of: Stimulus.allCases).run(tc)
            }
            out.append(a)
            if case .accepted(let end) = walk([a], from: s) { s = end }
        }
        return out
    }
}

struct Mismatch: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}
