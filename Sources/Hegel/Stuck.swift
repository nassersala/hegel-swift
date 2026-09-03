/// The stuck verdict: an equation checked while its unknowns are still
/// partial. Hegel as a poor man's proof assistant: it finds the stuck goal
/// and shows the values in scope; it cannot close it.
/// `specs/calculation-by-refutation.md` is the method.
///
/// Bahr and Hutton calculate a program from its correctness equation: at
/// every goal the proof cannot take, they define the thing that makes it
/// go through. Hegel cannot solve a goal; it can find one. Leave the
/// unknown partial (an Optional, or a function that throws `Stuck`), state
/// the equation as a property, and the shrunk counterexample is the
/// smallest input the definitions do not cover, with the values in scope.
/// That is the stuck goal as a concrete term. Propose a definition, run
/// again, and the next counterexample is the next goal.
///
/// A run of the equation stops in two ways, and they are different
/// findings. A `Stuck` thrown from inside the equation is a hole: the next
/// goal, what the calculation should define next. Any other error is a
/// refutation: a case that is defined and wrong, to be fixed before the
/// calculation goes on. `stuckGoal` tells them apart and hands back the
/// shrunk input as a value, so the goal can be read, printed, or fed to
/// the next round.

/// A hole in a definition, reached at a concrete input. `goal` names what
/// is undefined (`"send (deposit 0 then deposit 0)"`); `scope` is optional
/// and lists the values in scope by name, for the case where the input the
/// runner shows is not the whole story.
///
/// Thrown from a property, it is a distinct bug from any refutation (the
/// runner groups bugs by the thrown error's type) and the report reads
/// `stuck: <goal>`.
public struct Stuck: Error, CustomStringConvertible, Sendable {
    public let goal: String
    public let scope: [(name: String, value: String)]

    public init(_ goal: String, scope: [(name: String, value: String)] = []) {
        self.goal = goal
        self.scope = scope
    }

    public var description: String {
        guard !scope.isEmpty else { return "stuck: \(goal)" }
        return "stuck: \(goal)\n  where " + scope.map { "\($0.name) = \($0.value)" }.joined(separator: ", ")
    }
}

/// The value of a partial unknown, or `Stuck` at `goal`.
///
///     let message = try defined(send(r), "send (\(r))")
///
/// Reads as "send r, defined, or stuck at the goal `send r`". `defined` is
/// the calculation's own word: the proof is stuck exactly where a function
/// is not yet defined. The goal is an autoclosure, so the string is only
/// built at the hole.
public func defined<T>(_ value: T?, _ goal: @autoclosure () -> String) throws -> T {
    guard let value else { throw Stuck(goal()) }
    return value
}

/// Where a calculation stopped: `stuck` at a hole, with the shrunk input
/// that reaches it, or `refuted` at a defined case that is wrong, with the
/// shrunk input and the error's description. A run that holds on every
/// drawn input has no verdict: `stuckGoal` returns nil.
public enum Verdict<Input>: CustomStringConvertible {
    case stuck(Input, Stuck)
    case refuted(Input, String)

    public var input: Input {
        switch self {
        case .stuck(let input, _), .refuted(let input, _): return input
        }
    }

    public var description: String {
        switch self {
        case .stuck(let input, let stuck): return "\(stuck)\n  at \(input)"
        case .refuted(let input, let message): return "refuted at \(input): \(message)"
        }
    }
}

/// Checks `equation` on drawn `inputs` and returns where it stopped.
///
/// A new function rather than a mode of `forAll`, because the contract
/// differs: `forAll` throws on any failure and its counterexample is a
/// string for a report, while a calculation has three outcomes (holds,
/// stuck, refuted) and needs the stopping input as a value to continue
/// from. Underneath it is one `forAll` run, the same shrinking, the same
/// database and seed; the minimal input is recovered by replaying the
/// failure's blob through `inputs`, then the equation is run once more at
/// that input to classify what it throws.
///
/// With `reportMultipleFailures` a run can stop at both a hole and a wrong
/// case; a refutation is returned first, since a wrong definition has to
/// be fixed before the next goal means anything. A run error (health
/// check, a broken generator) is rethrown as the `PropertyFailure` it is.
public func stuckGoal<A>(
    _ inputs: Gen<A>,
    testCases: UInt64? = nil,
    seed: UInt64? = nil,
    database: String? = nil,
    settings: Settings = Settings(),
    file: StaticString = #fileID,
    line: UInt = #line,
    _ equation: (A) throws -> Void
) throws -> Verdict<A>? {
    let settings = resolve(settings, testCases: testCases, seed: seed, database: database)
    let failure: PropertyFailure
    do {
        try forAll(inputs, settings: settings, file: file, line: line, equation)
        return nil
    } catch let caught as PropertyFailure {
        failure = caught
    }
    guard failure.runError == nil else { throw failure }

    var stuck: Verdict<A>?
    for found in failure.failures {
        guard let blob = found.reproduceBlob else { continue }
        let input = try replay(inputs, blob: blob, settings: settings)
        do {
            try equation(input)
        } catch let hole as Stuck {
            if stuck == nil { stuck = .stuck(input, hole) }
        } catch {
            return .refuted(input, "\(error)")
        }
    }
    // The equation passed at every replayed input: the failure did not
    // reproduce, which is the runner's finding, not a verdict.
    guard let stuck else { throw failure }
    return stuck
}
