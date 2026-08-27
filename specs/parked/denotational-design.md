# Denotational design: mathematical meanings before models and runners

Status: draft 1, 2026-08-27. Nothing in this document is a public API
commitment. It proposes the semantic vocabulary against which the other specs
should be reviewed.

## Question

What do hegel-swift's central abstractions mean independently of their Swift
representations, formal encodings, and execution strategies?

The answer must be mathematical. Groups, monoids, orders, relations,
functions, measures, propositions, traces, and categories are possible
semantic objects. A simulator, transition table, generator implementation,
proof-assistant datatype, or serialized file is not itself the answer.

## Governing principle

Choose the simplest adequate mathematical meaning first. Then derive
representations and interpreters whose correctness is stated as preservation
of that meaning.

The order is:

```text
mathematical denotation
        |
        | representation/adequacy argument
        v
formal or executable model
        |
        | interpreter/export
        v
Hegel oracle and search strategy
        |
        | observed refinement checks
        v
concrete Swift implementation
```

Executability is not required of a denotation. A continuous function, an
infinite set of behaviours, or an extensional relation may be the clearest
meaning even when no program can enumerate it directly.

## Small semantic kernel

The first draft uses the following ordinary mathematics rather than choosing
one universal categorical encoding.

- A **carrier** is a set or type of values under discussion.
- A **predicate** `P` on `A` is a proposition for each `a in A`, equivalently
  a subset of `A`.
- A **function** maps every input to one output.
- A **relation** `R : A <-> B` is a subset of `A x B`. Functions embed as
  deterministic total relations.
- **Relational composition** hides an intermediate value: `R ; S` relates
  `a` to `c` when some `b` relates the two steps.
- An **observation** maps a concrete value or behaviour to the abstract value
  that clients can distinguish.
- A **refinement** permits no concrete observation outside the abstract
  specification.
- An **equation** says two constructions have the same meaning under the
  chosen equality or observation.

Algebraic structures such as monoids and groups add operations and equations
to a carrier. Category theory becomes useful when the objects,
transformations, identities, and composition are settled; it organizes the
meanings and their interpretations. The draft deliberately does not declare
that every Hegel concept "is a category".

## Proposed denotations

These are hypotheses for review, not definitions made true by this document.

| Hegel concept | Proposed mathematical meaning |
|---|---|
| property over `A` | proposition quantified over a stated domain in `A` |
| `Law` | named equation, implication, or relation over a structure |
| `LawSuite` | finite named conjunction of laws, reported separately |
| metamorphic `Relation` | relation between a source observation and a follow-up observation |
| `Rule` | executable driver for one family of transitions; not by itself the specification |
| `Operation` | relation in `Model x Args x Observation x Model` |
| `Invariant` | predicate on reachable abstract states or observations |
| `Enumeration` | finite presentation of a transition relation |
| model conformance | forward simulation or observational refinement |
| `UsageModel` | Markov kernel restricted to permitted transitions |
| `Gen<A>` | a witness/search interpretation for a domain; detailed separately |
| schedule | witness selecting one execution compatible with a concurrent behaviour |
| test failure | finite witness refuting a proposition or refinement claim |

The table is intentionally heterogeneous. A monoid law and a probabilistic
usage profile need not share one concrete representation to share a runner.

## Compositionality

A semantic function is useful when it is compositional: the meaning of a
compound construction is determined by the meanings of its parts.

If `[[x]]` denotes `x`, an interpreter for sequential composition should
satisfy a preservation equation of the form:

```text
[[compose(x, y)]] = compose([[x]], [[y]])
```

The operation named `compose` may be function composition, relational
composition, monoidal combination, trace concatenation, or another operation
appropriate to the domain. The equation, not the shared spelling, is the
important part.

Conal Elliott's type-class-morphism principle sharpens this requirement: an
implementation's meaning should follow the corresponding operation on the
meaning, transferring laws from the semantic structure to the representation.
For Hegel, this suggests deriving generators, executors, diagrams, and formal
exports as interpretations of one small domain vocabulary rather than adding
unrelated helper APIs.

## Model-based testing as a commuting square

For a generated command program `p`, model-based correctness has this shape:

```text
p ---------------- run in Swift ----------------> concrete result
|                                                     |
| denote                                              | observe
v                                                     v
abstract behaviour -------- evaluate ----------> abstract result
```

Hegel checks that the two paths agree for generated finite programs. A
failure is evidence that the square does not commute. A passing randomized
run does not prove that it commutes for every program.

The observation map is part of the specification. Comparing concrete and
abstract states directly is only a special case in which their public
observations happen to have the same representation.

## Four kinds of evidence

The project must label these separately:

1. **Mathematical argument:** a paper or review establishes equations about
   the proposed denotation.
2. **Machine-checked theorem:** Agda, F*, Rocq, or another prover checks a
   proposition within a stated trusted base.
3. **Model check or finite exhaustion:** a tool explores every state or trace
   within stated bounds.
4. **Property test:** Hegel samples/searches real executions and can produce a
   concrete counterexample.

None silently upgrades into another. In particular, a list of theorem names
inside an artifact is provenance, not a proof checked by the Swift consumer.

## Worked example: door

Let:

```text
State       = {locked, unlocked}
Command     = {lock, unlock, open}
Observation = {ok, opened, denied}
```

The meaning is a transition relation:

```text
DoorTransition subset State x Command x State x Observation
```

The relation is deterministic and total, so it can equivalently be presented
as a function:

```text
step : State x Command -> State x Observation
```

`Examples/AgdaVerifiedModel/Agda/DoorModel.agda` is a formal executable
representation. Its generated JSON is a complete finite tabulation. The Swift
fixture is a serialized representation. They are intended to share one
denotation, but they occupy different engineering layers.

The theorem "opening is observed only from unlocked" is a proposition about
`DoorTransition`, not about JSON formatting or the exporter.

## Worked example: concurrent withdrawals

A scheduler script such as `[run A, run B, run A]` is operational. Candidate
meanings for the concurrent account include:

- the set of permitted observable histories;
- a labelled transition relation;
- a partial order of causally constrained events;
- the relation from initial account state to possible final observations.

If two events are independent, exchanging their positions may preserve the
meaning even though it changes the script. A schedule is then a linearization
witness interpreted by the controlled executor. This distinction is the basis
for semantic schedule shrinking in `concurrency-semantics.md`.

## Design consequences

1. Public notation must follow semantic composition rather than runner
   mechanics.
2. Key paths are convenient observation constructors, not the fundamental
   meaning of a relation.
3. A transition table is acceptable when it faithfully presents the chosen
   relation; finiteness does not make it conceptually primary.
4. A formal model can be internally consistent yet describe the wrong real
   system. Choosing the denotation remains a human design obligation.
5. A verified executable model needs an adequacy statement relating it to the
   denotation, not merely unrelated theorems about its code.
6. Different formal backends may represent the same denotation and produce
   evidence with different scopes.

## Review worksheet

Every semantic abstraction should eventually answer:

```text
Name:
Carrier or domain:
Mathematical denotation:
Equality or observational equivalence:
Composition:
Identity, if any:
Laws:
Formal representations:
Executable interpretations:
Adequacy obligation:
What a Hegel counterexample witnesses:
```

If the worksheet can be completed only by mentioning seeds, mutable runner
state, a JSON schema, or a particular scheduler, the meaning has not yet been
separated from its implementation.

## Proposed decisions

1. Use relations as the common baseline for state transitions and
   nondeterminism; total functions are a special presentation.
2. Treat properties as propositions and property-testing runs as finite
   evidence, not probabilistic proofs unless a separate statistical contract
   explicitly applies.
3. Require an explicit observation/refinement boundary in model-based designs.
4. Keep category theory internal to design explanations until a public concept
   is made clearer, not merely more general, by exposing it.
5. Let each domain choose the simplest adequate mathematics rather than force
   every domain into an algebraic structure.

## Open questions

1. Is the denotation of `Gen<A>` its support, a measure, or a pair of semantic
   projections? `generator-semantics.md` proposes an answer.
2. Is a concurrent behaviour best represented initially by traces, labelled
   transition systems, or event partial orders?
3. What observation vocabulary is sufficient without adding an abstraction
   protocol to every model?
4. Which adequacy claims must be machine checked before Hegel labels an
   artifact "verified"?
5. Can `Enumeration`, `Operation`, and `UsageModel` be honest interpretations
   of one transition-system value without over-generalizing the API?

## Non-goals

- A foundational formalization of all of Hegel in one proof assistant.
- A category-theory DSL in Swift.
- Claiming that denotational semantics removes the need for operational cost,
  fairness, or failure models.
- Treating formal consistency as validation of real-world intent.

## Acceptance criteria

The draft is ready to guide API work when:

- every core abstraction can be described without implementation vocabulary;
- door and concurrent-withdrawal examples can be mapped through all layers;
- the generator and concurrency specs select compatible meanings;
- the model-based and usage-model specs use observation and refinement
  consistently;
- an independent reviewer can distinguish every proof, model-checking, and
  testing claim made by the documentation.

## References

- Conal Elliott, *Denotational Design with Type Class Morphisms*, LambdaPix
  Technical Report 2009-01:
  <https://www.cs.tufts.edu/~nr/cs257/archive/conal-elliott/type-class-morphisms-long.pdf>
- Conal Elliott, *Compiling to Categories*, ICFP 2017:
  <https://conal.net/papers/compiling-to-categories/compiling-to-categories.pdf>
- Agda documentation, *What is Agda?*:
  <https://agda.readthedocs.io/en/latest/getting-started/what-is-agda.html>

