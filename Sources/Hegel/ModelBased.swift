/// The state of a model-based stateful test: the system under test paired
/// with the abstract model that describes it. `Model` should have value
/// semantics; `modelBefore` in a postcondition means "before" only if
/// assigning copies.
public struct Modelled<SUT, Model>: CustomStringConvertible {
    public var sut: SUT
    public var model: Model

    public init(sut: SUT, model: Model) {
        self.sut = sut
        self.model = model
    }

    public var description: String { "sut \(sut), model \(model)" }
}

/// Thrown when an operation's `run` or `post` throws `HegelError.assume`.
/// Rejection is only meaningful before the SUT ran (in `args`); afterwards a
/// reference-typed SUT may already have changed, so it is reported as a
/// violation rather than silently rolled back.
public struct CommandMisuse: Error, CustomStringConvertible, Sendable {
    public let command: String
    public let phase: String
    public var description: String {
        "\(command): HegelError.assume thrown in \(phase); reject in args instead"
    }
}

/// Thrown by the expected-result form when the observed and modelled
/// results differ under the `equal` witness.
public struct ObservationMismatch: Error, CustomStringConvertible, Sendable {
    public let command: String
    public let expected: String
    public let observed: String
    public var description: String {
        "\(command): observed \(observed), model expected \(expected)"
    }
}

/// One command family of a model-based stateful test (Hughes's
/// commuting square in stateful form, Quviq's eqc_statem shape): draw
/// arguments from the model, run the real system, advance the abstract
/// model, compare what happened with what the model says must happen.
///
/// Applicability (`precondition`) and argument generation (`args`) see the
/// model only, never the SUT: needing the SUT to decide what is legal means
/// the model is too weak. `HegelError.assume` thrown from `args` rejects the
/// drawn arguments before the SUT runs; thrown from `run` or `post` it is a
/// violation (`CommandMisuse`). An expected SUT error is not a violation:
/// capture it as the `Observed` value (`Result`-shaped) and let `post`
/// assert on it.
///
/// Lowers onto the stateful runner via `rule()`; the engine never learns
/// about commands.
public struct Command<SUT, Model>: Sendable {
    public let name: String
    let precondition: @Sendable (Model) -> Bool
    let labeledStep: @Sendable (inout Modelled<SUT, Model>, TestCase) throws -> String

    // MARK: Explicit postcondition

    public init<Args: Sendable, Observed: Sendable>(
        _ name: String,
        precondition: @escaping @Sendable (Model) -> Bool = { _ in true },
        args: @escaping @Sendable (Model, TestCase) throws -> Args,
        run: @escaping @Sendable (inout SUT, Args) throws -> Observed,
        model: @escaping @Sendable (inout Model, Args) -> Void,
        post: @escaping @Sendable (_ modelBefore: Model, _ args: Args, _ observed: Observed) throws -> Void,
        describe: @escaping @Sendable (Args) -> String = { "\($0)" },
        describeObserved: @escaping @Sendable (Observed) -> String? = { _ in nil }
    ) {
        self.name = name
        self.precondition = precondition
        self.labeledStep = { state, tc in
            let a = try args(state.model, tc)  // assume propagates: rejection
            let label = Args.self == Void.self ? name : "\(name)(\(describe(a)))"
            let before = state.model
            let observed: Observed
            do {
                observed = try run(&state.sut, a)
            } catch HegelError.assume {
                throw LabeledStepFailure(label: label, underlying: CommandMisuse(command: name, phase: "run"))
            } catch {
                throw LabeledStepFailure(label: label, underlying: error)
            }
            let shown = describeObserved(observed).map { "\(label) -> \($0)" } ?? label
            model(&state.model, a)
            do {
                try post(before, a, observed)
            } catch HegelError.assume {
                throw LabeledStepFailure(label: shown, underlying: CommandMisuse(command: name, phase: "post"))
            } catch {
                throw LabeledStepFailure(label: shown, underlying: error)
            }
            return shown
        }
    }

    /// Nullary explicit-postcondition form.
    public init<Observed: Sendable>(
        _ name: String,
        precondition: @escaping @Sendable (Model) -> Bool = { _ in true },
        run: @escaping @Sendable (inout SUT) throws -> Observed,
        model: @escaping @Sendable (inout Model) -> Void,
        post: @escaping @Sendable (_ modelBefore: Model, _ observed: Observed) throws -> Void,
        describeObserved: @escaping @Sendable (Observed) -> String? = { _ in nil }
    ) {
        self.init(
            name, precondition: precondition,
            args: { _, _ in () },
            run: { sut, _ in try run(&sut) },
            model: { m, _ in model(&m) },
            post: { before, _, observed in try post(before, observed) },
            describe: { _ in "" },
            describeObserved: describeObserved)
    }

    // MARK: Expected result

    /// The model operation returns what the SUT must observe; `equal` is the
    /// observational equivalence.
    public init<Args: Sendable, Observed: Sendable>(
        _ name: String,
        precondition: @escaping @Sendable (Model) -> Bool = { _ in true },
        args: @escaping @Sendable (Model, TestCase) throws -> Args,
        run: @escaping @Sendable (inout SUT, Args) throws -> Observed,
        model: @escaping @Sendable (inout Model, Args) -> Observed,
        equal: @escaping @Sendable (Observed, Observed) -> Bool,
        describe: @escaping @Sendable (Args) -> String = { "\($0)" },
        describeObserved: @escaping @Sendable (Observed) -> String? = { "\($0)" }
    ) {
        self.init(
            name, precondition: precondition, args: args, run: run,
            model: { m, a in
                // The expected value is recomputed in `post` from `modelBefore`
                // so the closures stay pure; the model op runs once here to
                // advance the state.
                _ = model(&m, a)
            },
            post: { before, a, observed in
                var m = before
                let expected = model(&m, a)
                guard equal(observed, expected) else {
                    throw ObservationMismatch(
                        command: name, expected: "\(expected)", observed: "\(observed)")
                }
            },
            describe: describe, describeObserved: describeObserved)
    }

    public init<Args: Sendable, Observed: Sendable & Equatable>(
        _ name: String,
        precondition: @escaping @Sendable (Model) -> Bool = { _ in true },
        args: @escaping @Sendable (Model, TestCase) throws -> Args,
        run: @escaping @Sendable (inout SUT, Args) throws -> Observed,
        model: @escaping @Sendable (inout Model, Args) -> Observed,
        describe: @escaping @Sendable (Args) -> String = { "\($0)" },
        describeObserved: @escaping @Sendable (Observed) -> String? = { "\($0)" }
    ) {
        self.init(
            name, precondition: precondition, args: args, run: run, model: model,
            equal: ==, describe: describe, describeObserved: describeObserved)
    }

    /// Nullary expected-result form.
    public init<Observed: Sendable>(
        _ name: String,
        precondition: @escaping @Sendable (Model) -> Bool = { _ in true },
        run: @escaping @Sendable (inout SUT) throws -> Observed,
        model: @escaping @Sendable (inout Model) -> Observed,
        equal: @escaping @Sendable (Observed, Observed) -> Bool,
        describeObserved: @escaping @Sendable (Observed) -> String? = { "\($0)" }
    ) {
        self.init(
            name, precondition: precondition,
            args: { _, _ in () },
            run: { sut, _ in try run(&sut) },
            model: { m, _ in model(&m) },
            equal: equal, describe: { _ in "" }, describeObserved: describeObserved)
    }

    public init<Observed: Sendable & Equatable>(
        _ name: String,
        precondition: @escaping @Sendable (Model) -> Bool = { _ in true },
        run: @escaping @Sendable (inout SUT) throws -> Observed,
        model: @escaping @Sendable (inout Model) -> Observed,
        describeObserved: @escaping @Sendable (Observed) -> String? = { "\($0)" }
    ) {
        self.init(
            name, precondition: precondition, run: run, model: model,
            equal: ==, describeObserved: describeObserved)
    }

    // MARK: Effect only

    /// No observation: the comparison is carried by `consistent` and the
    /// invariants.
    public init<Args: Sendable>(
        _ name: String,
        precondition: @escaping @Sendable (Model) -> Bool = { _ in true },
        args: @escaping @Sendable (Model, TestCase) throws -> Args,
        run: @escaping @Sendable (inout SUT, Args) throws -> Void,
        model: @escaping @Sendable (inout Model, Args) -> Void,
        describe: @escaping @Sendable (Args) -> String = { "\($0)" }
    ) {
        self.init(
            name, precondition: precondition, args: args,
            run: { sut, a in try run(&sut, a) as Void },
            model: model,
            post: { _, _, _ in },
            describe: describe)
    }

    public init(
        _ name: String,
        precondition: @escaping @Sendable (Model) -> Bool = { _ in true },
        run: @escaping @Sendable (inout SUT) throws -> Void,
        model: @escaping @Sendable (inout Model) -> Void
    ) {
        self.init(
            name, precondition: precondition,
            args: { _, _ in () },
            run: { sut, _ in try run(&sut) },
            model: { m, _ in model(&m) },
            describe: { _ in "" })
    }

    /// The lowering onto the stateful runner.
    public func rule() -> Rule<Modelled<SUT, Model>> {
        Rule(labeled: name, precondition: { precondition($0.model) }, labeledStep)
    }
}

/// Runs a model-based stateful property: the engine picks commands whose
/// preconditions hold on the model, each runs the SUT and advances the
/// model, and `consistent` (α: recompute the abstraction from the SUT;
/// throw on illegality or drift) is checked on the initial pair and after
/// every successful step, before the invariants. Failing runs shrink to a
/// minimal command sequence, displayed with the drawn arguments.
public func forAll<SUT, Model>(
    initial: Gen<Modelled<SUT, Model>>,
    commands: [Command<SUT, Model>],
    consistent: (@Sendable (SUT, Model) throws -> Void)? = nil,
    invariants: [Invariant<Modelled<SUT, Model>>] = [],
    maximize: (@Sendable (Modelled<SUT, Model>) -> Double)? = nil,
    testCases: UInt64? = nil,
    seed: UInt64? = nil,
    database: String? = nil,
    settings: Settings = Settings(),
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    var all: [Invariant<Modelled<SUT, Model>>] = []
    if let consistent {
        all.append(Invariant("consistent") { try consistent($0.sut, $0.model) })
    }
    all.append(contentsOf: invariants)
    try forAll(
        initial: initial,
        rules: commands.map { $0.rule() },
        invariants: all,
        maximize: maximize,
        testCases: testCases, seed: seed, database: database, settings: settings,
        file: file, line: line)
}

/// The common empty start: a generated SUT paired with a fixed model value.
/// Valid because `model` is copied into every test case; a reference-typed
/// model would alias across cases.
public func forAll<SUT, Model: Sendable>(
    sut: Gen<SUT>,
    model: Model,
    commands: [Command<SUT, Model>],
    consistent: (@Sendable (SUT, Model) throws -> Void)? = nil,
    invariants: [Invariant<Modelled<SUT, Model>>] = [],
    maximize: (@Sendable (Modelled<SUT, Model>) -> Double)? = nil,
    testCases: UInt64? = nil,
    seed: UInt64? = nil,
    database: String? = nil,
    settings: Settings = Settings(),
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    try forAll(
        initial: sut.map { Modelled(sut: $0, model: model) },
        commands: commands, consistent: consistent, invariants: invariants,
        maximize: maximize, testCases: testCases, seed: seed, database: database,
        settings: settings, file: file, line: line)
}
