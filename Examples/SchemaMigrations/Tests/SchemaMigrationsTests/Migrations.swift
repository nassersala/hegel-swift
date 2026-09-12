import SQLite3

// The code under test: a tiny migration language, an in-memory model of
// what a step does to a schema, a squash optimizer, and a runner that
// executes the steps against a real SQLite database and reads back the
// schema SQLite reports.

enum ColumnType: String, CaseIterable, Hashable, Sendable {
    case integer = "INTEGER", text = "TEXT", real = "REAL"
}

struct Column: Hashable, Sendable, CustomStringConvertible {
    let name: String
    let type: ColumnType
    var description: String { "\(name) \(type.rawValue)" }
}

/// Columns in the order SQLite reports them. Order is observable
/// (`SELECT *`), so it is part of the meaning.
struct Schema: Hashable, Sendable, CustomStringConvertible {
    var columns: [Column]
    var description: String { "(\(columns.map(\.description).joined(separator: ", ")))" }
    var names: Set<String> { Set(columns.map(\.name)) }
}

enum Step: Hashable, Sendable, CustomStringConvertible {
    case add(String, ColumnType)
    case drop(String)
    case rename(String, String)

    var description: String {
        switch self {
        case .add(let n, let t): "add \(n) \(t.rawValue)"
        case .drop(let n): "drop \(n)"
        case .rename(let a, let b): "rename \(a)→\(b)"
        }
    }

    /// Does the step mention `name` in any role?
    func references(_ name: String) -> Bool {
        switch self {
        case .add(let n, _), .drop(let n): n == name
        case .rename(let a, let b): a == name || b == name
        }
    }

    var sql: String {
        switch self {
        case .add(let n, let t): "ALTER TABLE t ADD COLUMN \"\(n)\" \(t.rawValue)"
        case .drop(let n): "ALTER TABLE t DROP COLUMN \"\(n)\""
        case .rename(let a, let b): "ALTER TABLE t RENAME COLUMN \"\(a)\" TO \"\(b)\""
        }
    }
}

extension Schema {
    /// The model: what a step does, or `nil` if it is not applicable.
    func applying(_ step: Step) -> Schema? {
        var s = self
        switch step {
        case .add(let n, let t):
            guard !names.contains(n) else { return nil }
            s.columns.append(Column(name: n, type: t))
        case .drop(let n):
            guard let i = columns.firstIndex(where: { $0.name == n }) else { return nil }
            s.columns.remove(at: i)
        case .rename(let a, let b):
            guard let i = columns.firstIndex(where: { $0.name == a }), !names.contains(b) else { return nil }
            s.columns[i] = Column(name: b, type: columns[i].type)
        }
        return s
    }

    func applying(_ steps: [Step]) -> Schema? {
        var s = self
        for step in steps {
            guard let next = s.applying(step) else { return nil }
            s = next
        }
        return s
    }
}

/// A migration between two schemas. `to` is what the model says the steps
/// do; whether SQLite agrees is one of the things the functor law checks.
struct Migration: Hashable, Sendable, CustomStringConvertible {
    let from: Schema
    let steps: [Step]
    let to: Schema
    var description: String { "\(from) —[\(steps.map(\.description).joined(separator: "; "))]→ \(to)" }
}

/// The optimizer. Two sound rewrites (the second was unsound in its first
/// draft; see the comment there), and one planted bug that every squash
/// tool has shipped at some point.
struct Squash: Sendable {
    /// `drop x … add x T` → nothing. Wrong: the type may change, and in
    /// SQLite the column moves to the end.
    var dropThenAdd = false

    func callAsFunction(_ steps: [Step]) -> [Step] {
        var s = steps
        while let (i, j, replacement) = firstRewrite(in: s) {
            s.replaceSubrange(i...j, with: replacement + Array(s[(i + 1)..<j]))
        }
        return s
    }

    /// The first pair `i < j` a rule applies to, and what replaces the pair
    /// (the steps strictly between them are kept, after the replacement).
    private func firstRewrite(in s: [Step]) -> (Int, Int, [Step])? {
        for i in s.indices {
            for j in s.indices where j > i {
                let between = s[(i + 1)..<j]
                switch (s[i], s[j]) {
                case (.add(let x, _), .drop(let y)) where x == y && !between.contains { $0.references(x) }:
                    return (i, j, [])
                case (.rename(let a, let b), .rename(let c, let d))
                where b == c && !between.contains(where: { $0.references(b) || $0.references(d) }):
                    // The merged rename lands on `d`, so nothing between may
                    // touch `d` either — the first version of this rule
                    // checked only `b`, and the category laws found
                    // `rename b→c; drop a; rename c→a`. A chain back to its
                    // start is no change at all.
                    return (i, j, a == d ? [] : [.rename(a, d)])
                case (.drop(let x), .add(let y, _)) where dropThenAdd && x == y && !between.contains { $0.references(x) }:
                    return (i, j, [])
                default:
                    continue
                }
            }
        }
        return nil
    }
}

/// What SQLite did: the schema it reports afterwards, or its error.
enum Outcome: Hashable, Sendable, CustomStringConvertible {
    case schema(Schema)
    case rejected(String)
    var description: String {
        switch self {
        case .schema(let s): s.description
        case .rejected(let e): "rejected: \(e)"
        }
    }
}

/// Runs the steps on a fresh in-memory database whose table `t` has
/// `schema` (plus a fixed `id INTEGER PRIMARY KEY`, since a table needs a
/// column and a primary key cannot be dropped), and reads the schema back
/// from `PRAGMA table_info`.
func run(_ steps: [Step], on schema: Schema) -> Outcome {
    var db: OpaquePointer?
    guard sqlite3_open(":memory:", &db) == SQLITE_OK else { return .rejected("cannot open") }
    defer { sqlite3_close(db) }

    func exec(_ sql: String) -> String? {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            return message
        }
        return nil
    }

    let columns = (["id INTEGER PRIMARY KEY"] + schema.columns.map { "\"\($0.name)\" \($0.type.rawValue)" })
        .joined(separator: ", ")
    if let e = exec("CREATE TABLE t (\(columns))") { return .rejected(e) }
    for step in steps {
        if let e = exec(step.sql) { return .rejected("\(step): \(e)") }
    }

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA table_info(t)", -1, &stmt, nil) == SQLITE_OK else {
        return .rejected("pragma")
    }
    defer { sqlite3_finalize(stmt) }
    var reported: [Column] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let name = String(cString: sqlite3_column_text(stmt, 1))
        let type = String(cString: sqlite3_column_text(stmt, 2))
        if name == "id" { continue }
        guard let t = ColumnType(rawValue: type) else { return .rejected("type \(type)") }
        reported.append(Column(name: name, type: t))
    }
    return .schema(Schema(columns: reported))
}
