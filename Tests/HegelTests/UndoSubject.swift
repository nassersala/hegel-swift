import Hegel

// The undo subject from the 2026-09-02 syntax experiment, ported without
// its operator glyphs. The equation is
//
//     meaning(undo(record(e, d, h)))(meaning(e)(d)) == d
//
// with `record` and `undo` the unknowns. `Draft` is the first attempt at
// them: an entry is the edit alone, and `undo` has no case for a delete
// because nothing remembers what was deleted. The second attempt, at top
// level, records the deleted text and `undo` is total.

typealias Doc = String

enum Edit: Equatable, Sendable, CustomStringConvertible {
    case insert(at: Int, String)
    case delete(at: Int, count: Int)

    var description: String {
        switch self {
        case let .insert(at: i, s): return "insert(at: \(i), \(s.debugDescription))"
        case let .delete(at: i, count: n): return "delete(at: \(i), count: \(n))"
        }
    }
}

/// The meaning of an edit: a function on documents. Indices clamp.
func meaning(_ e: Edit) -> (Doc) -> Doc {
    { d in
        var d = d
        switch normalise(e, in: d) {
        case let .insert(at: i, s):
            d.insert(contentsOf: s, at: d.index(d.startIndex, offsetBy: i))
        case let .delete(at: i, count: n):
            let lo = d.index(d.startIndex, offsetBy: i)
            d.removeSubrange(lo..<d.index(lo, offsetBy: n))
        }
        return d
    }
}

/// The edit as it applies to `d`: index and count clamped to the document.
func normalise(_ e: Edit, in d: Doc) -> Edit {
    switch e {
    case let .insert(at: i, s): return .insert(at: min(max(i, 0), d.count), s)
    case let .delete(at: i, count: n):
        let i = min(max(i, 0), d.count)
        return .delete(at: i, count: min(max(n, 0), d.count - i))
    }
}

// MARK: - Draft: the entry is the edit alone; undo is partial

enum Draft {
    struct Entry: Equatable, Sendable, CustomStringConvertible {
        let edit: Edit
        var description: String { "Entry(\(edit))" }
    }

    static func record(_ e: Edit, _ d: Doc, _ h: [Entry]) -> [Entry] {
        h + [Entry(edit: normalise(e, in: d))]
    }

    /// nil at a delete: the entry does not say what to put back.
    static func undo(_ h: [Entry]) -> Edit? {
        switch h.last?.edit {
        case nil: return .insert(at: 0, "")
        case let .insert(at: i, s): return .delete(at: i, count: s.count)
        case .delete: return nil
        }
    }
}

// MARK: - The entry records the deleted text; undo is total

struct Entry: Equatable, Sendable, CustomStringConvertible {
    let edit: Edit
    let deleted: String
    init(edit: Edit, deleted: String = "") { self.edit = edit; self.deleted = deleted }
    var description: String { "Entry(\(edit), deleted: \(deleted.debugDescription))" }
}

func record(_ e: Edit, _ d: Doc, _ h: [Entry]) -> [Entry] {
    let e = normalise(e, in: d)
    guard case let .delete(at: i, count: n) = e else { return h + [Entry(edit: e)] }
    let lo = d.index(d.startIndex, offsetBy: i)
    return h + [Entry(edit: e, deleted: String(d[lo..<d.index(lo, offsetBy: n)]))]
}

func undo(_ h: [Entry]) -> Edit {
    switch h.last {
    case nil: return .insert(at: 0, "")
    case let .some(x):
        switch x.edit {
        case let .insert(at: i, s): return .delete(at: i, count: s.count)
        case let .delete(at: i, count: _): return .insert(at: i, x.deleted)
        }
    }
}

/// Deliberately wrong: undoing an insert deletes one character too few.
func wrongUndo(_ h: [Entry]) -> Edit {
    switch h.last {
    case nil: return .insert(at: 0, "")
    case let .some(x):
        switch x.edit {
        case let .insert(at: i, s): return .delete(at: i, count: s.count - 1)
        case let .delete(at: i, count: _): return .insert(at: i, x.deleted)
        }
    }
}

// MARK: - Generators

extension Edit: DefaultGen {
    static var gen: Gen<Edit> {
        oneOf([
            zip(Gen<Int>.int(in: 0...4), String.gen).map { Edit.insert(at: $0, $1) },
            zip(Gen<Int>.int(in: 0...4), Gen<Int>.int(in: 0...3)).map { Edit.delete(at: $0, count: $1) },
        ])
    }
}

extension Draft.Entry: DefaultGen {
    static var gen: Gen<Draft.Entry> { Edit.gen.map { Draft.Entry(edit: $0) } }
}

extension Entry: DefaultGen {
    static var gen: Gen<Entry> { Edit.gen.map { Entry(edit: $0) } }
}

/// The experiment's own generators: documents over the letters a to c.
enum ABC {
    static let doc: Gen<Doc> = .string(count: 0...4, codepoints: 97...99)
    static let edit: Gen<Edit> = oneOf([
        zip(Gen<Int>.int(in: 0...4), doc).map { Edit.insert(at: $0, $1) },
        zip(Gen<Int>.int(in: 0...4), Gen<Int>.int(in: 0...3)).map { Edit.delete(at: $0, count: $1) },
    ])
    static let inputs = zip(edit, doc, array(of: edit.map { Entry(edit: $0) }, count: 0...3))
    static let draftInputs = zip(edit, doc, array(of: edit.map { Draft.Entry(edit: $0) }, count: 0...3))
}
