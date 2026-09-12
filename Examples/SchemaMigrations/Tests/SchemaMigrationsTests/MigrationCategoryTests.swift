import Hegel
import Testing

// Migrations as a category and running them as a functor into SQLite.
//
// Objects are schemas (not version numbers: a migration out of "version 3"
// is only composable with what *this* migration actually produced, so the
// object has to be the schema itself). Arrows out of a schema are the
// migrations valid from it; composition concatenates and squashes; two
// parallel migrations are equal when SQLite reports the same schema after
// them. That equality is the pullback along the meaning, so by
// `laws-by-meaning` the category laws hold whenever the squash is sound —
// and they fail, naming the law, when it is not.

private let names = ["a", "b", "c", "d"]

/// One step valid from `schema`, or `nil` if none is (four columns and
/// nothing to drop cannot happen; kept for totality).
private func step(from schema: Schema) -> Gen<Step>? {
    let fresh = names.filter { !schema.names.contains($0) }
    let existing = schema.columns.map(\.name)
    var options: [Gen<Step>] = []
    if !fresh.isEmpty {
        options.append(zip(element(of: fresh), element(of: ColumnType.allCases)).map { Step.add($0, $1) })
    }
    if !existing.isEmpty {
        options.append(element(of: existing).map { Step.drop($0) })
    }
    if !existing.isEmpty && !fresh.isEmpty {
        options.append(zip(element(of: existing), element(of: fresh)).map { Step.rename($0, $1) })
    }
    return options.isEmpty ? nil : oneOf(options)
}

/// `count` valid steps in a row, each drawn from the schema the previous
/// ones produce.
private func steps(from schema: Schema, count: Int) -> Gen<[Step]> {
    guard count > 0, let next = step(from: schema) else { return Gen<[Step]>.constant([]) }
    return next.flatMap { s in
        steps(from: schema.applying(s)!, count: count - 1).map { [s] + $0 }
    }
}

private let schemas: Gen<Schema> =
    array(of: zip(element(of: names), element(of: ColumnType.allCases)), count: 0...3).map { drawn in
        var seen = Set<String>()
        return Schema(columns: drawn.compactMap { name, type in
            seen.insert(name).inserted ? Column(name: name, type: type) : nil
        })
    }

private func migrationsOut(of schema: Schema) -> Gen<Migration> {
    Gen<Int>.int(in: 0...4).flatMap { n in
        steps(from: schema, count: n).map { Migration(from: schema, steps: $0, to: schema.applying($0)!) }
    }
}

/// Migrations, composed by `squash`, equal when SQLite agrees.
private func migrations(_ squash: Squash) -> Category<Schema, Migration> {
    Category(
        objects: schemas,
        arrows: migrationsOut,
        codomain: { $0.to },
        identity: { Migration(from: $0, steps: [], to: $0) },
        compose: { g, f in Migration(from: f.from, steps: squash(f.steps + g.steps), to: g.to) },
        label: "then",
        equal: { a, b in run(a.steps, on: a.from) == run(b.steps, on: b.from) })
}

/// The meaning of a migration: what SQLite did to its source schema. An
/// effect out of `s` is determined by its outcome, so composition just
/// forwards the later outcome (or the first rejection).
struct Effect: Hashable, Sendable, CustomStringConvertible {
    let from: Schema
    let outcome: Outcome
    var description: String { "\(from) ⇒ \(outcome)" }
}

private let effects = Category<Schema, Effect>(
    objects: schemas,
    arrows: { s in migrationsOut(of: s).map { Effect(from: s, outcome: run($0.steps, on: s)) } },
    codomain: { e in if case .schema(let t) = e.outcome { t } else { e.from } },
    identity: { Effect(from: $0, outcome: .schema($0)) },
    compose: { g, f in
        if case .rejected = f.outcome { f } else { Effect(from: f.from, outcome: g.outcome) }
    },
    label: "∘",
    equal: ==)

/// `run`: a migration to its effect on SQLite.
private func running(_ squash: Squash) -> LawSuite {
    Laws.functor(
        "run",
        objects: { $0 },
        arrows: { m in Effect(from: m.from, outcome: run(m.steps, on: m.from)) },
        from: migrations(squash), to: effects)
}

private func counterexamples(_ suite: LawSuite, seed: UInt64? = nil) throws -> [String] {
    do {
        try forAll(suite, testCases: 200, seed: seed, database: "")
    } catch let failure as PropertyFailure {
        return try failure.failures.map { try #require($0.counterexample) }
    }
    Issue.record("expected \(suite.name) to fail")
    return []
}

@Suite struct MigrationCategoryTests {
    /// Sound squash: the category laws under SQLite-equality, and `run` is
    /// a functor — the composed-and-squashed script does to SQLite what
    /// running the two scripts in turn does. This also checks that the
    /// in-memory model (`Schema.applying`) agrees with SQLite about the
    /// resulting schema, since `g` is drawn from the model's codomain of
    /// `f` and run after SQLite's.
    @Test func squashedMigrationsFormACategoryAndRunningIsAFunctor() throws {
        try forAll(Laws.category(migrations(Squash())), testCases: 200, database: "")
        try forAll(running(Squash()), testCases: 200, database: "")
    }

    /// The planted rule: `drop x … add x T` squashed to nothing. The functor
    /// law finds a two-step script: the type changes, or the column moves
    /// to the end (SQLite appends added columns; order is observable).
    @Test func droppingThenAddingCannotBeSquashedAway() throws {
        let bug = Squash(dropThenAdd: true)
        let found = try counterexamples(running(bug), seed: 1)
        #expect(found.count == 1)
        let c = try #require(found.first)
        #expect(c.contains("law: run(g then f) = run(g) ∘ run(f)"))
        #expect(c.contains("drop") && c.contains("add"))
        // The same bug seen from inside the category: composing with the
        // identity squashes a lone script, so both identity laws fail too.
        let laws = try counterexamples(Laws.category(migrations(bug)), seed: 1)
        #expect(laws.contains { $0.contains("law: id then f = f") })
        #expect(laws.contains { $0.contains("law: f then id = f") })
    }
}
