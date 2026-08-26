import Hegel
import Testing

// MARK: The model the stateful driver tracks

struct Model: Sendable, CustomStringConvertible {
    var state: State = .initial
    var agent: Agent
    var history: [String] = []
    var description: String {
        "\(show(state)); effects \(agent.tools.effects.map(\.rawValue)); blocked \(agent.blocked.count)"
    }
}

/// One rule per cell, deny cells and tool-result cells included: the driver
/// plays the agent and the manager. The table says what should happen; the
/// executor and monitor say what did.
func cellRules(_ table: Policy) -> [Rule<Model>] {
    // Sorted: dictionary order is randomized per process, and the engine
    // addresses rules by index, so a pinned seed needs a fixed order.
    table.sorted { $0.key.rawValue < $1.key.rawValue }.flatMap { state, block in
        block.sorted { $0.key.rawValue < $1.key.rawValue }.map { stimulus, expected in
            Rule("\(show(state)) ▸ \(stimulus)", precondition: { $0.state == state }) { m, _ in
                let before = m.agent.tools.effects.count
                let got = m.agent.runOne(stimulus)
                let fired = m.agent.tools.effects.count - before
                m.history.append("\(show(state)) ▸ \(stimulus)")
                switch expected {
                case .allow(let next, let req):
                    guard case .allow = got else {
                        throw Mismatch(
                            "\(show(state)) ▸ \(stimulus): expected allow (\(req)), monitor said \(got)"
                        )
                    }
                    guard fired == 1 else {
                        throw Mismatch("\(show(state)) ▸ \(stimulus): allowed but \(fired) effects")
                    }
                    m.state = next
                case .deny(let why):
                    guard case .deny = got else {
                        throw Mismatch(
                            "\(show(state)) ▸ \(stimulus): expected deny (\(why)), monitor said \(got)"
                        )
                    }
                    guard fired == 0 else {
                        throw Mismatch(
                            "\(show(state)) ▸ \(stimulus): denied (\(why)) but the tool fired")
                    }
                }
            }
        }
    }
}

/// α(effects) == the tracked state: the event log is a legal walk of the
/// table and ends where the model says.
let effectsLegal = Invariant<Model>("effects log is a legal walk to the model state") { m in
    guard let s = alpha(m.agent.tools.effects) else {
        throw Mismatch("effects \(m.agent.tools.effects.map(\.rawValue)) are not a legal walk")
    }
    guard s == m.state else {
        throw Mismatch("α(effects) = \(show(s)) but model is \(show(m.state))")
    }
}

func fresh(_ bug: Bug? = nil) -> Gen<Model> { Gen { _ in Model(agent: Agent(bug: bug)) } }

/// Continuous mode: the planner emits a fresh suffix, the gate re-walks it
/// from the current state, and an accepted suffix runs through `execute` —
/// which throws if the monitor disagrees with the gate.
func replan(bug: Bug? = nil, regate: Bool = true) -> Rule<Model> {
    Rule("replan") { m, tc in
        let suffix = try plans(from: m.state, length: 1...6).run(tc)
        let from: State = (bug == .replanGatedFromStart) ? .initial : m.state
        if regate {
            guard case .success(let w) = verify(suffix, from: from) else { return }
            do { _ = try m.agent.execute(w) } catch {
                throw Mismatch(
                    "replan \(suffix.map(\.rawValue)) accepted by the gate (walked from \(show(from))) but \(error)"
                )
            }
        } else {
            for a in suffix { _ = m.agent.runOne(a) }
        }
        m.state = m.agent.monitor.state
        m.history.append("replan")
    }
}

func counterexample(_ body: () throws -> Void) -> String {
    do {
        try body()
        return ""
    } catch let f as PropertyFailure { return f.failures.first?.counterexample ?? "" } catch {
        return "\(error)"
    }
}

// MARK: Tests

@Suite struct AgentPolicyTests {

    @Test func tableIsComplete() {
        #expect(tableProblems(policy).isEmpty)
        #expect(policy.count == 10 && policy.values.reduce(0) { $0 + $1.count } == 80)
        var dropped = policy
        dropped[.refunded]![.issueRefund] = nil
        #expect(tableProblems(dropped) == ["T.O.p.A.r missing issueRefund"])
        var missing = policy
        missing[.closed] = nil
        #expect(tableProblems(missing).contains("missing state T.S"))
        #expect(tableProblems(missing).contains("T → T.S undefined"))
        #expect(policyVersion.count == 12)
    }

    // The table is the oracle for a hand-written verifier — sampled, and exhaustively.
    @Test func handWrittenGateAgreesWithTheTable() throws {
        try forAll(plans(), testCases: 500, database: "") { p in
            guard handWrittenVerify(p) == walk(p).isAccepted else {
                throw Mismatch(
                    "plan \(p.map(\.rawValue)): hand-written \(handWrittenVerify(p)), table \(walk(p))"
                )
            }
        }
        #expect(shortestDisagreement() == nil)
    }

    @Test func handWrittenGateThatForgetsOneApprovalOneRefund() {
        // Exhaustive: the shortest plan on which the two disagree — five steps,
        // the bug's other face: the flag is never cleared, so a second approval
        // after a refund (allowed by the table) is rejected.
        #expect(
            shortestDisagreement(bug: .gateForgetsOneApprovalOneRefund)
                == [.readTicket, .lookupOrder, .requestApproval, .issueRefund, .requestApproval])
        // Sampled: the same plan, shrunk to.
        let ce = counterexample {
            try forAll(plans(), testCases: 200, seed: 1, database: "") { p in
                guard
                    handWrittenVerify(p, bug: .gateForgetsOneApprovalOneRefund)
                        == walk(p).isAccepted
                else {
                    throw Mismatch(
                        "plan \(p.map(\.rawValue)): hand-written \(handWrittenVerify(p, bug: .gateForgetsOneApprovalOneRefund)), table \(walk(p))"
                    )
                }
            }
        }
        #expect(
            ce.contains(
                "readTicket, AgentPropertyTests.Stimulus.lookupOrder, AgentPropertyTests.Stimulus.requestApproval, AgentPropertyTests.Stimulus.issueRefund, AgentPropertyTests.Stimulus.requestApproval]"
            ), "\(ce)")
    }

    // Model-based: cells as rules against executor + monitor, with α as the invariant.
    @Test func executorAndMonitorAgreeWithTheTable() throws {
        try forAll(
            initial: fresh(), rules: cellRules(policy), invariants: [effectsLegal], testCases: 300,
            database: "")
    }

    @Test func executorThatFiresOnDeny() {
        let ce = counterexample {
            try forAll(
                initial: fresh(.executorFiresOnDeny), rules: cellRules(policy),
                invariants: [effectsLegal],
                testCases: 200, seed: 1, database: "")
        }
        #expect(
            ce.contains("denied (R1 ticket not read) but the tool fired")
                || ce.contains("denied (R4 no approval pending) but the tool fired"), "\(ce)")
        #expect(ce.split(separator: "\n").count == 3, "one step: \(ce)")
    }

    @Test func monitorThatSkipsApproval() {
        let ce = counterexample {
            try forAll(
                initial: fresh(.monitorSkipsApproval), rules: cellRules(policy),
                invariants: [effectsLegal],
                testCases: 200, seed: 1, database: "")
        }
        // The monitor stays in the pending state after the grant, so a second
        // manager answer — which the table denies in T.O.p.A — is let through.
        #expect(
            ce.contains("T.O.p ▸ approvalGranted")
                && ce.contains(
                    "T.O.p.A ▸ approvalDenied: expected deny (R4 no approval pending), monitor said allow"
                ),
            "\(ce)")
        #expect(ce.split(separator: "\n").count == 7, "five steps: \(ce)")
    }

    // The executor must not treat a request as a grant: with a manager who
    // always denies, no verified plan ever refunds.
    @Test func aDeniedApprovalNeverRefunds() throws {
        let denying: @Sendable (Int) -> Bool = { _ in false }
        try forAll(plans(), testCases: 300, database: "") { p in
            guard case .success(let w) = verify(p) else { return }
            var agent = Agent(manager: denying)
            let outcome = try agent.execute(w)
            guard !agent.tools.effects.contains(.issueRefund) else {
                throw Mismatch(
                    "refunded after denial: \(agent.tools.effects.map(\.rawValue)), \(outcome)")
            }
            if p.contains(.requestApproval) {
                guard case .stopped = outcome else {
                    throw Mismatch("denied but not stopped: \(outcome)")
                }
            }
        }
        let ce = counterexample {
            try forAll(plans(), testCases: 200, seed: 1, database: "") { p in
                guard case .success(let w) = verify(p) else { return }
                var agent = Agent(bug: .executorAssumesApproval, manager: denying)
                _ = try agent.execute(w)
                guard !agent.tools.effects.contains(.issueRefund) else {
                    throw Mismatch("refunded after denial: \(agent.tools.effects.map(\.rawValue))")
                }
            }
        }
        #expect(
            ce.contains(
                "[AgentPropertyTests.Stimulus.readTicket, AgentPropertyTests.Stimulus.lookupOrder, AgentPropertyTests.Stimulus.requestApproval, AgentPropertyTests.Stimulus.issueRefund]"
            ), "\(ce)")
    }

    // The evidence is bound to its start state; running it elsewhere throws.
    @Test func aVerifiedWorkflowRunsOnlyFromItsStartState() throws {
        let w = try verify(
            [.lookupOrder, .requestApproval, .issueRefund, .sendReply], from: .ticketRead
        ).get()
        var cold = Agent()
        #expect(throws: BoundaryViolation.wrongStartState(expected: .ticketRead, actual: .initial))
        {
            _ = try cold.execute(w)
        }
        #expect(cold.tools.effects.isEmpty)
        var warm = Agent()
        _ = warm.runOne(.readTicket)
        #expect(try warm.execute(w) == .completed)
        #expect(
            warm.tools.effects == [
                .readTicket, .lookupOrder, .requestApproval, .approvalGranted, .issueRefund,
                .sendReply,
            ])
        #expect(w.policyVersion == policyVersion)
    }

    // Continuous: re-gate every suffix from the monitor's state; the gate and the monitor agree.
    @Test func regatedReplansRunFully() throws {
        try forAll(
            initial: fresh(), rules: cellRules(policy) + [replan()], invariants: [effectsLegal],
            testCases: 300, database: "")
        // Planner-only: with every suffix re-gated, the monitor never has to block.
        try forAll(
            initial: fresh(), rules: [replan()],
            invariants: [
                effectsLegal,
                Invariant("monitor never blocks") { m in
                    guard m.agent.blocked.isEmpty else {
                        throw Mismatch(
                            "monitor blocked \(m.agent.blocked.map { "\(show($0.state)) ▸ \($0.stimulus)" })"
                        )
                    }
                },
            ],
            testCases: 300, database: "")
    }

    @Test func replanGatedFromTheStartInsteadOfTheCurrentState() {
        let ce = counterexample {
            try forAll(
                initial: fresh(.replanGatedFromStart),
                rules: cellRules(policy) + [replan(bug: .replanGatedFromStart)],
                invariants: [effectsLegal], testCases: 200, seed: 2, database: "")
        }
        #expect(ce.contains("accepted by the gate (walked from Δ) but wrongStartState"), "\(ce)")
    }

    // No re-gate at all — a direct agent loop. The monitor bounds execution to
    // the table (effects always legal); it does not prevent partial plans.
    @Test func withoutRegatingTheMonitorHasToBlock() throws {
        nonisolated(unsafe) var runs = 0
        nonisolated(unsafe) var blockedRuns = 0
        try forAll(
            initial: fresh(), rules: [replan(regate: false)],
            invariants: [
                effectsLegal,
                Invariant("count") { m in
                    if m.history.count == 1 {
                        runs += 1
                        if !m.agent.blocked.isEmpty { blockedRuns += 1 }
                    }
                },
            ],
            testCases: 300, database: "")
        #expect(
            blockedRuns > runs / 4,
            "after one unchecked replan the monitor had blocked in \(blockedRuns)/\(runs) runs")
    }
}
