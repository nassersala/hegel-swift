/// Categories and functors as witnesses, in the layering of
/// `denotational-design/sketches/Essence04.lagda.md`: a quiver (objects,
/// and the arrows out of each object), a signature (`identity`, `compose`),
/// an equivalence on arrows (`equal`), and the laws as a suite.
///
/// Objects are values a generator can draw — dimensions, states, indices —
/// and every arrow knows its codomain, so composable chains are drawn
/// without preconditions: an arrow out of `a`, then an arrow out of its
/// codomain. Swift's own category of functions is not of this kind (its
/// objects are types); it is testable one hom-set at a time with
/// `Laws.functor(_:map:equal:)`.
///
/// Use it for anything with a compose function and a do-nothing value,
/// where the things composed carry a "from" and a "to":
///
/// - schema migrations (objects: schemas; a squash must equal the chain it
///   replaces; "run against the database" is a functor —
///   `Examples/SchemaMigrations`, against real SQLite),
/// - currency or unit conversion with rounding (objects: currencies;
///   USD→EUR→GBP against USD→GBP is an associativity failure, found at the
///   smallest amount),
/// - tensor and image pipelines (objects: shapes; the bug is a shape
///   mismatch; the quantized or GPU backend is a functor, `equal:` is the
///   tolerance),
/// - patches, diffs, CRDT operation logs (objects: document states;
///   "apply the composed patch" against "apply in sequence" is a functor),
/// - coordinate frames in a scene graph (objects: frames; arrows: affine
///   transforms; a representation change, doubles to floats, is a functor),
/// - format converters (objects: formats; v1→v2→v3 against v1→v3),
/// - screens and navigation actions (the app run against the model is a
///   functor; every `Enumeration` is already a quiver of this kind).
///
/// A monoid is the one-object case, `Category.monoid`, and a monoid
/// homomorphism is a functor between two of them. The one-object catalog
/// entries (`Laws.monoid`, `Laws.monoidHomomorphism`) keep their own
/// generators and labels so that a counterexample does not print a unit
/// object; this is the general form they are instances of.
public struct Category<Ob: Sendable, Arrow: Sendable>: Sendable {
    public let objects: Gen<Ob>
    /// The arrows out of an object.
    public let arrows: @Sendable (Ob) -> Gen<Arrow>
    public let codomain: @Sendable (Arrow) -> Ob
    public let identity: @Sendable (Ob) -> Arrow
    /// `compose(g, f)` is `g ∘ f`, first `f` then `g`; the laws only form
    /// it when `g` was drawn out of the codomain of `f`.
    public let compose: @Sendable (Arrow, Arrow) -> Arrow
    /// How a failure prints composition.
    public let label: String
    /// Equality of parallel arrows: only ever applied to two arrows drawn
    /// out of one object. Must be an equivalence relation
    /// (`Laws.equivalence`); `Laws.category` checks it is a congruence.
    public let equal: @Sendable (Arrow, Arrow) -> Bool

    public init(
        objects: Gen<Ob>,
        arrows: @escaping @Sendable (Ob) -> Gen<Arrow>,
        codomain: @escaping @Sendable (Arrow) -> Ob,
        identity: @escaping @Sendable (Ob) -> Arrow,
        compose: @escaping @Sendable (Arrow, Arrow) -> Arrow,
        label: String = "∘",
        equal: @escaping @Sendable (Arrow, Arrow) -> Bool
    ) {
        self.objects = objects
        self.arrows = arrows
        self.codomain = codomain
        self.identity = identity
        self.compose = compose
        self.label = label
        self.equal = equal
    }
}

extension Category where Ob == Void {
    /// A monoid as a category with one object: every element is an arrow
    /// from the object to itself, `op` is composition, `identity` is `id`.
    public static func monoid(
        _ gen: Gen<Arrow>, _ label: String, _ op: @escaping @Sendable (Arrow, Arrow) -> Arrow,
        identity: Arrow, equal: @escaping @Sendable (Arrow, Arrow) -> Bool
    ) -> Category {
        Category(
            objects: Gen<Void>.constant(()),
            arrows: { _ in gen },
            codomain: { _ in () },
            identity: { _ in identity },
            compose: op,
            label: label,
            equal: equal)
    }
}

extension Category where Ob == Void, Arrow: Equatable {
    public static func monoid(
        _ gen: Gen<Arrow>, _ label: String, _ op: @escaping @Sendable (Arrow, Arrow) -> Arrow,
        identity: Arrow
    ) -> Category {
        monoid(gen, label, op, identity: identity, equal: ==)
    }
}

// MARK: Category and functor laws

extension Laws {
    /// The category laws over a `Category` witness: `id ∘ f ≈ f`,
    /// `f ∘ id ≈ f`, `(h ∘ g) ∘ f ≈ h ∘ (g ∘ f)`, and `∘` respects `≈` in
    /// each argument. Chains are drawn along codomains, so every
    /// composition the laws form is defined. The congruence premise is drawn
    /// as in `equivalent`: a batch of arrows out of one object, or one class
    /// from `equivalents:` (indexed by the object it is out of).
    /// Not for: a witness whose `equal` relates non-parallel arrows.
    public static func category<Ob, Arrow>(
        _ c: Category<Ob, Arrow>,
        equivalents: (@Sendable (Ob) -> Gen<[Arrow]>)? = nil
    ) -> LawSuite {
        let one = c.objects.flatMap { a in c.arrows(a).map { f in (a: a, f: f) } }
        let two = one.flatMap { v in c.arrows(c.codomain(v.f)).map { g in (a: v.a, f: v.f, g: g) } }
        let three = two.flatMap { v in
            c.arrows(c.codomain(v.g)).map { h in (a: v.a, f: v.f, g: v.g, h: h) }
        }
        let classOut: @Sendable (Ob) -> Gen<[Arrow]> = { a in
            batch(c.arrows(a), or: equivalents?(a)).filter { !$0.isEmpty }
        }
        let leftCongruence = c.objects.flatMap { a in
            classOut(a).flatMap { fs in c.arrows(c.codomain(fs[0])).map { g in (a: a, fs: fs, g: g) } }
        }
        let rightCongruence = one.flatMap { v in
            classOut(c.codomain(v.f)).map { gs in (a: v.a, f: v.f, gs: gs) }
        }
        let o = c.label
        return LawSuite("category over \(Ob.self) with arrows \(Arrow.self) (\(o))", [
            Law("id \(o) f = f", one) { v in
                try requireEqual(
                    "id \(o) f", c.compose(c.identity(c.codomain(v.f)), v.f), "f", v.f, c.equal)
            },
            Law("f \(o) id = f", one) { v in
                try requireEqual("f \(o) id", c.compose(v.f, c.identity(v.a)), "f", v.f, c.equal)
            },
            Law("associativity", three) { v in
                try requireEqual(
                    "(h \(o) g) \(o) f", c.compose(c.compose(v.h, v.g), v.f),
                    "h \(o) (g \(o) f)", c.compose(v.h, c.compose(v.g, v.f)), c.equal)
            },
            Law("f ≈ f′ ⇒ g \(o) f ≈ g \(o) f′", leftCongruence) { v in
                for j in 1..<v.fs.count where c.equal(v.fs[0], v.fs[j]) {
                    try requireEqual(
                        "g \(o) \(v.fs[0])", c.compose(v.g, v.fs[0]),
                        "g \(o) \(v.fs[j])", c.compose(v.g, v.fs[j]), c.equal)
                }
            },
            Law("g ≈ g′ ⇒ g \(o) f ≈ g′ \(o) f", rightCongruence) { v in
                for j in 1..<v.gs.count where c.equal(v.gs[0], v.gs[j]) {
                    try requireEqual(
                        "\(v.gs[0]) \(o) f", c.compose(v.gs[0], v.f),
                        "\(v.gs[j]) \(o) f", c.compose(v.gs[j], v.f), c.equal)
                }
            },
        ])
    }

    /// A functor from `source` to `target`: `F(id a) ≈ id (F a)` and
    /// `F(g ∘ f) ≈ F g ∘ F f`, under `target.equal`. `arrows` must send an
    /// arrow out of `a` to an arrow out of `objects(a)`. That `F` also sends
    /// `≈` to `≈` is `congruent`'s law, and free when `source.equal` is
    /// the pullback of `target.equal` along `F`.
    /// A monoid homomorphism is the case of two one-object categories.
    /// Not for: contravariant maps (transpose), maps that scale (`2·f`),
    /// maps whose object part is not `codomain`-compatible with the arrow
    /// part.
    public static func functor<Ob, Arrow, Ob2, Arrow2>(
        _ label: String,
        objects mapObject: @escaping @Sendable (Ob) -> Ob2,
        arrows mapArrow: @escaping @Sendable (Arrow) -> Arrow2,
        from source: Category<Ob, Arrow>, to target: Category<Ob2, Arrow2>
    ) -> LawSuite {
        let one = source.objects.flatMap { a in source.arrows(a).map { f in (a: a, f: f) } }
        let two = one.flatMap { v in
            source.arrows(source.codomain(v.f)).map { g in (a: v.a, f: v.f, g: g) }
        }
        let s = source.label, t = target.label
        return LawSuite("functor \(label): \(Arrow.self) → \(Arrow2.self)", [
            Law("\(label)(id) = id", source.objects) { a in
                try requireEqual(
                    "\(label)(id)", mapArrow(source.identity(a)),
                    "id", target.identity(mapObject(a)), target.equal)
            },
            Law("\(label)(g \(s) f) = \(label)(g) \(t) \(label)(f)", two) { v in
                try requireEqual(
                    "\(label)(g \(s) f)", mapArrow(source.compose(v.g, v.f)),
                    "\(label)(g) \(t) \(label)(f)", target.compose(mapArrow(v.g), mapArrow(v.f)),
                    target.equal)
            },
        ])
    }
}
