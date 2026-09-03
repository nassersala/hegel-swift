# Joy in Arabic: a machine derived by refutation, then laid out like Zig's

Status: experiment draft, 2026-09-03. Nothing here is built. It is the
test of a claim made at the end of `calculation-by-refutation.md`: that the
method does not find a fast layout, but makes one safe to reach for and
keeps a program from storing what its meaning can compute. Reading order:
after `calculation-by-refutation.md` and `system-from-specifications.md`.
Every claim below is a prediction the run can refute; the ones I would bet
against are marked.

## The claim under test

> Take a language whose semantics is already an equation, Joy's. Derive its
> machine from that equation by refutation, the unknowns partial, one
> instruction per stuck goal. Then re-represent the machine's data along
> Kelley's ladder, indices for pointers, struct of arrays, encodings, each
> rung a refinement of the same relation, checked against Joy's published
> laws. The derivation births only the fields the meaning needs, the
> ladder halves the bytes per instruction at least twice, and every rung
> that breaks meaning is caught at the smallest program that shows it.

Four things are borrowed, one is the script's, and one is new. The
script's: modifiers as marks on a word, so that the machine's encoding of
a modified word is decided by the spelling. Borrowed: the semantics (von
Thun), the categorical reading of quotations (Elliott), the layout tricks
(Kelley), and the end of the ladder, the tree as arrays with no pointers
at all (Hsu). New: doing the layouts under a checked equation, which none of
the three had, and asking whether the calculation refuses the memoised
fields Kelley had to delete by hand.

## What this does not claim

- Anything about a real compiler. The language has eight words and
  quotations. It is big enough for bytes per instruction to mean something
  and small enough for an afternoon of agents.
- A proof. Holds means holds on drawn programs; `calculation-by-refutation.md`
  says what that is not.
- That Arabic script changes the semantics. It does not. It changes what
  the source is as data, which is one rung of the ladder, and it makes the
  program read in the order the composition equation reads.

## What the script gives

The first draft of this page used Arabic letters as if they were Latin
letters with different shapes. They are not. Arabic puts on a letter what
Uiua puts beside a glyph, and Uiua is the closest existing design to what
this language wants: every glyph does one thing; a modifier is a mark
that consumes the function written after it (`/+` is reduce with add,
`∩` both, `⊃` fork); planet notation picks a stack position with `⊙`
dip, `⋅` gap, `∘` identity and no names; a subscript attaches a variant
to a glyph; a formatter turns ASCII names into glyphs on save; and code
runs from the right. Each of those has a native counterpart in the
script, and the language uses the script's version.

| the script has | it is | Uiua does it with | here it means |
|---|---|---|---|
| harakat, the marks fatha َ kasra ِ damma ُ sukun ْ shadda ّ | zero-width marks that sit on a letter | modifiers and subscripts, separate code points before or after the glyph | a modifier lives on the word it modifies and takes no room |
| sukun ْ, "quiet" | the letter carries no vowel | `[f]` for one function | `ضْ` is `[ض]`: a one-word quotation has no brackets |
| shadda ّ, doubling | the consonant sounds twice | `∩` both | the word applies to the top two values independently |
| the three vowels fatha, kasra, damma | above, below, above | planet notation `∘` `⊙` `⋅` | how the word meets the top: on it, under it with the top kept, under it with the top discarded |
| root and pattern | a root of consonants and a vowel pattern make related words: جمع add, جامع the adder, مجموع the sum, تجميع accumulating | subscript variants | one root, several words, each with an equation: the function as a value, the fold, the scan |
| tatweel ـ, the elongation stroke | no sound, only length | `∘` identity | the identity word, and a visual spacer that means nothing, which is what identity is |
| the ligature لا | lam and alef always join, and the word means no | | logical not, spelled the way the language says no |
| the non-joining letters ا د ذ ر ز و | the cursive run breaks after them | | presentation only; the parser never depends on joining |
| digits run left to right inside right-to-left text | the bidi algorithm orders a digit run on its own | | a multi-digit literal reads most-significant first, as in prose; nothing to decide |

Root-and-pattern parsing is a hard problem for natural Arabic. It is
trivial here because the roots are a closed set of primitives and the
patterns are a closed set of three, so recognising a pattern is a
template match against a known consonant skeleton.

## The language

Eight roots, each one letter; two more words the script hands over;
marks as modifiers; digits Arabic-Indic; brackets for quotations of more
than one word. A program executes from the right.

| word | from | meaning on a stack `s` |
|---|---|---|
| ض | ضاعف | `x : s ↦ x : x : s` (dup) |
| ب | بدّل | `x : y : s ↦ y : x : s` (swap) |
| ح | حذف | `x : s ↦ s` (drop) |
| ج | جمع | `x : y : s ↦ (y + x) : s` |
| ط | طرح | `x : y : s ↦ (y − x) : s` |
| ر | ضرب | `x : y : s ↦ (y × x) : s` |
| ن | نفّذ | `f : s ↦ f s` (i) |
| غ | غطّس | `f : x : s ↦ x : f s` (dip) |
| لا | no | `x : s ↦ (x = 0 ? 1 : 0) : s` (not) |
| ـ | tatweel | `s ↦ s` (identity) |
| ٠…٩ | | a literal, pushed |
| [ p ] | | pushes `⟦ p ⟧` as a value |

Marks on a word `w`:

| mark | on `w` it means |
|---|---|
| `wْ` sukun | `s ↦ ⟦ w ⟧ : s`, the word quoted; `wْ` is `[w]` |
| `wّ` shadda | both: `w` applied to `x` alone and to `y` alone, results in the same order, `⟦ wّ ⟧ (x : y : s) = a : b : s` where `a : _ = ⟦ w ⟧ (x : s)` and `b : _ = ⟦ w ⟧ (y : s)`, for a `w` that takes one value |
| `wَ` fatha | `⟦ w ⟧`, the word on the top, written when a position is being made explicit |
| `wِ` kasra | `x : s ↦ x : ⟦ w ⟧ s`, the word one below the top: dip without a quotation |
| `wُ` damma | `x : s ↦ ⟦ w ⟧ s`, the top discarded and the word applied beneath it: gap |

So `[ر ض] غ` is `رِ ضِ`, with no quotation and no dip word. Sum of two
squares, before and after the marks:

```
ج غ [ر ض] ر ض ٤ ٣
ج رِ ضِ ر ض ٤ ٣
```

Patterns on a root `w` with consonants `w₁w₂w₃` (given for `ج` as جمع):

| pattern | word for جمع | meaning |
|---|---|---|
| فاعل, the doer | جامع | `s ↦ ⟦ w ⟧ : s`, the function as a value; the same as `wْ`, and kept because a name reads where a mark does not |
| مفعول, the done | مجموع | `A : s ↦ (fold ⟦ w ⟧ A) : s`, the fold over an array value |
| تفعيل, the doing | تجميع | `A : s ↦ (scan ⟦ w ⟧ A) : s`, the scan |

The two pattern rows that take arrays need arrays as values, a shape and
flat data in Uiua's model. Arrays are not in this experiment (D4 below);
the patterns are stated so the vocabulary is complete and are marked
"after arrays" in Phase A.

Square: `ر ض`. Three squared, stack after each step, read right to left:

```
ر ض ٣
٩ ← ٣ ٣ ← ٣
```

Values on the stack are integers and quotations. A word applied to a
stack that does not have its shape (underflow, a number where a quotation
is needed) is an error value `⊥`, and `⊥` is absorbing: every word maps
`⊥` to `⊥`. That is the whole of the meaning's treatment of failure, and
it is stated here so the laws below quantify over it.

Lexical rules, decided now so no agent has to. A token is a grapheme
cluster: a base letter with the marks that sit on it, or a run of
digits, or a bracket, or tatweel. Whitespace separates tokens but is not
needed between single-letter words. A defined word is two or more letters
(D3): a joined run of letters is tried as a defined word first and split
into single-letter primitives otherwise, so `رض` is `ر ض` unless someone
defined `رض`. The renderer's cursive joining and the six non-joining
letters are presentation and the parser never consults them. Every code
point in a program is strongly right-to-left, a mark, a digit, tatweel,
or a bracket, so the bidi algorithm never reorders a run. Kerby's result
on combinator bases says `ن`, `غ`, `ض`, `ب`, `ح` with quotations are
complete; `ج`, `ط`, `ر` are there so programs compute something; `لا`
and `ـ` are there because the script offered them.

Decisions the script forces, for the person, with the alternatives as
clauses:

- **D1, shadda.** (a) both, as above, since Uiua's `∩` is the one that
  composes; (b) apply twice, `⟦ wّ ⟧ = ⟦ w ⟧ ∘ ⟦ w ⟧`. Recommended: (a).
- **D2, the vowels.** (a) positions, planet notation, as above; (b)
  iteration modifiers, fatha reduce, kasra each, damma table, which need
  arrays. Recommended: (a); iteration arrives with the patterns.
- **D3, joined runs.** (a) tried as a defined word, else split, as above;
  (b) whitespace required between primitives, as the first draft had.
  Recommended: (a).
- **D4, arrays.** (a) after the layout experiment, patterns stated and
  marked; (b) now, with Uiua's array model, which moves Hsu's rung into
  the value model as well as the code. Recommended: (a).

## The equations, all borrowed

Von Thun: the syntax is a monoid under concatenation, the semantics is a
monoid under composition, and the meaning is a homomorphism.

```
⟦ p q ⟧  =  ⟦ q ⟧ ∘ ⟦ p ⟧          ⟦ ε ⟧ = id
```

Elliott: a quotation is the name of a morphism and `ن` is evaluation, the
closed structure; `غ` is evaluation under one value.

```
⟦ [p] ⟧ s     =  ⟦ p ⟧ : s
⟦ ن ⟧ (f : s)  =  f s
⟦ غ ⟧ (f : x : s)  =  x : f s
```

Von Thun's algebra, the laws Hegel runs at every rung, over drawn `p`,
`q`, `s`:

```
ن [p]            =  p
[p] [q] concat   =  [p q]              (concat is a derived word; the law is the check on quotation representation)
ح ض              =  ε
ب ب              =  ε
غ [p] x          =  x p                for a literal x
ن غ [p] [q]      =  p q  ... and the dip/i commutations in "The Algebra of Joy"
```

The compiler equation, Bahr and Hutton's shape with `Code`, `comp`, and
`exec` unknown:

```
exec (comp p) s  ≡  ⟦ p ⟧ s
```

The token equation, Kelley's finding as an equation, `Token` unknown,
over grapheme clusters rather than scalars, since a mark is part of the
word it sits on:

```
lexeme (src, tokens(src)[i])  ≡  clusters(src)[i]
```

And three of our own, for what the script adds. A marked word is a word,
so the homomorphism is untouched; the marks have meanings of their own:

```
⟦ wْ ⟧  =  ⟦ [w] ⟧
⟦ wِ ⟧  =  ⟦ [w] غ ⟧            ⟦ wُ ⟧ = ⟦ w ح ⟧             ⟦ wَ ⟧ = ⟦ w ⟧
⟦ wّ ⟧ (x : y : s)  =  a : b : s   where a : _ = ⟦ w ⟧ (x : s),  b : _ = ⟦ w ⟧ (y : s)
⟦ فاعل(w) ⟧  =  ⟦ wْ ⟧            ⟦ مفعول(w) ⟧ = fold ⟦ w ⟧     ⟦ تفعيل(w) ⟧ = scan ⟦ w ⟧
```

The first line says a mark is a spelling of a quotation, which is what
lets Phase A treat the marks as an encoding the script already did. The
laws for the marks follow from von Thun's by substitution, and the run
checks them as their own suite because they are where the parser can go
wrong.

## Phase A: derive the machine

One agent under `calculation-by-refutation.md`, no layouts yet. `Token`,
`Code`, `comp`, `exec` empty; `stuckGoal` over drawn programs (depth 3,
quotations nested to 2, literals 0…9, stacks of 0…4 values) and drawn
sources. Record every round: the goal as printed, the constructor born,
where each field came from.

Predictions:

- The token equation births a letter and a set of marks and nothing else.
  No end offset: for a word the letter decides it, for a digit run
  rescanning does. No line, no column, no lexeme string. If it births
  `end`, the equation was stated wrong and the report says so first.
- With marks as bits the calculation goes one step further than Kelley:
  the goal at a marked letter has the base scalar and its combining marks
  in scope and nothing to add, so a token is one byte for the letter and
  one for the marks, two bytes against his five, and the token array is
  the decoded source with digit runs marked. The modifier bits are in the
  script, so the encoding rung of the ladder (rung 4) is the tokenizer's
  default rather than a later optimisation. I would bet on this and it is
  the finding I most want.
- The compiler equation births one instruction per root and, at the first
  marked word, forks: one instruction per root-and-mark pair, or one
  instruction per root with a mark field. Both compute. It is stated, not
  chosen; the person picks.
- The compiler equation then births `PUSH n` with `n` from scope, and
  stops at `[p]` with `comp p` in scope. That is the fork:
  `QUOTE Code` with the code nested, an index and a length into one flat
  stream, or Hsu's form, a depth per instruction and no reference at all.
  All three compute. It is a decision, and the agent is told to stop
  there and state all three.
- Booleans are never born. Nothing in the meaning is a flag. If a rung
  later wants one, it is Kelley's out-of-band case and goes in the ladder.
- Rounds: under twelve. The shrinker will find `⟦ ٠ ⟧ []` first.

## Phase B: the ladder

One agent per rung or one agent in sequence, each rung a new
representation of `Code`, the stack, and the source, with `comp` and
`exec` rewritten over it. At every rung the same three checks: the
compiler equation, von Thun's laws, and the token equation, all with
`stuckGoal` so a rung that is refuted reports the smallest program. Bytes
per token and per instruction from `MemoryLayout` and array capacity,
measured, not estimated. Wall clock to tokenize, compile, and run a
generated corpus of one million words, ten runs, median.

| rung | source | code | quotations | stack values | Kelley's name for it |
|---|---|---|---|---|---|
| 0 | `String` | `indirect enum` | nested, one allocation each | `enum { int, quote(Program) }` | array of structs with pointers |
| 1 | grapheme clusters as `(letter: UInt8, marks: UInt8)` | same | same | same | the source as data (the rung Zig never needed); the marks are already the encoding |
| 2 | same | one flat `[Instr]` | index and length into the stream | `enum { int, quote(index) }` | indices instead of pointers |
| 3 | same | `tags: [UInt8]`, `payload: [UInt32]` | same | same | struct of arrays |
| 4 | same | literals 0…9 folded into the tag; one-word quotations are already `wْ` from rung 1 | same | same | encodings instead of polymorphism, the part the script did not do |
| 5 | same | same | same | ints and quotation indices in one `UInt64` with a tag bit | references encode simple values |
| 6 | same | `tags: [UInt8]`, `depth: [UInt8]`, `payload: [UInt32]` | the depth vector; no index, no length | quotation values are a start position, the extent read off the depths | Hsu's tree as arrays |

Predictions:

- Rung 0 is worse than Kelley's 64-byte token and 120-byte node once
  reference counting is counted: every quotation and every stack value
  holding one is an allocation with retain and release. Swift pays for a
  pointer twice.
- Rung 2 is the biggest single win, on time more than on bytes, because it
  removes the allocations. Larger than any number in the talk. I would bet
  on it.
- Rung 3 is a small win on bytes and nothing on time at this size; the
  padding it removes is one byte per instruction.
- Rung 4 halves the payload array's touched bytes on the drawn corpus,
  because most literals are one digit and most quotations are short, and
  the run reports the distribution it measured, as Kelley did.
- At least one rung is refuted by the laws with a program of three words
  or fewer, and the report says which law. Candidate: `[p] [q] concat` at
  rung 2, where a quotation is an index and concatenation has to copy or
  chain. If no rung is ever refuted, the laws are too weak for the
  representation and the report says so, with the planted bug below as
  the test.
- Rung 6 makes `exec` a pass over vectors with no tree walk: `ن` and `غ`
  find a quotation's extent by scanning the depth vector for the return
  to its own depth, and `concat` is vector concatenation with a depth
  shift. The laws become array identities, matching brackets is the depth
  vector returning to zero, and that is the rung where Joy's algebra and
  the representation are the same thing. Prediction: rung 6 is not faster
  than rung 2 in a sequential Swift loop, since the scan replaces a
  stored length; its gain is that every pass is data parallel by
  construction, which this experiment measures only as a note, not as a
  number, because it has no GPU rung.
- Plant: at rung 2, an off-by-one in a quotation's length. The laws must
  find it, shrunk to a one-word quotation. If they do not, nothing in
  Phase B counts.

## The control

One agent, no skill, no equations, the paragraph:

```
Write an interpreter in Swift for a small Joy-like concatenative language
written in Arabic script: single-letter words for dup, swap, drop, add,
subtract, multiply, i, and dip; Arabic-Indic numerals; quotations in
square brackets; programs execute right to left. Make it fast. Tests.
```

Measures: the same bytes and wall clock; which of von Thun's laws its
interpreter satisfies when they are run against it; whether its token or
node types store anything the meaning can compute (a lexeme string, a
line, an end offset, a boolean). Prediction: it stores the lexeme, it uses
an indirect enum, it is slower than rung 2 by more than two times, and it
passes every law, because the laws are easy to satisfy and hard to
represent for.

## Bidi and output

Failure output prints a program twice: once as Arabic inside bidi isolates
(U+2068 … U+2069) so it renders as one run, and once as the letter names
with their marks in execution order, `٣ ض ر` as `3 dup mul`, `ضْ` as
`dup quoted`, `جِ` as `add under`, so a terminal that cannot render Arabic
or stack its marks still shows the counterexample. The name form is not
only for output: a formatter, Uiua's idea, converts the name form to
Arabic with marks and back, so a program can be typed on any keyboard
and saved in the script. The formatter is required tooling, and its
round trip is a retraction law checked like the others. Shrunk programs are stated
in the report in the second form. Source files in the repository are
UTF-8 with no bidi control characters inside programs; the Trojan Source
rule.

## Measures, whole run

| | method | control |
|---|---|---|
| token fields born, and which were refused | | n/a |
| instruction fields born; the fork stated | | n/a |
| bytes per token, rung 0 → 6 | | one number |
| bytes per instruction, rung 0 → 6 | | one number |
| wall clock, one million words, rung 0 → 6 | | one number |
| rungs refuted by the laws, with the shrunk program | | laws failed |
| planted length bug found, shrunk size | | n/a |
| fields stored that the meaning can compute | 0 | |

## Kill criteria

- Phase A births `end`, `line`, or a lexeme on the token: the token
  equation is wrong or the claim is; stop and rewrite the equation before
  Phase B.
- The plant at rung 2 is not found: the laws do not see representation;
  stop.
- Rung 2 is not faster than rung 0: the allocation claim is wrong and the
  ladder's motivation in Swift is gone; finish the bytes column and stop
  the timing column.

## How to run it

1. Phase A, one agent, the calculation prompt from
   `calculation-by-refutation.md` with the three equations and the
   glyph table pasted in; stop at the quotation fork and bring back the
   two alternatives. The person picks. Budget: fifteen minutes of agent,
   two of person.
2. Phase B, one agent per rung in parallel from a shared rung-0 package,
   or one agent in sequence; the laws file is written once at rung 0 and
   never edited after.
3. The control in its own terminal, started with Phase A.
4. Score the table; write the report under "Result" in this file,
   failed predictions first.

## References

- Manfred von Thun, "Mathematical foundations of Joy" and "The Algebra
  of Joy": the homomorphism and the laws.
- Brent Kerby, "The Theory of Concatenative Combinators": which words
  are a basis.
- Conal Elliott, "Compiling to Categories": quotations as names, `i` as
  evaluation, in the wiki under compiling-to-categories.
- Bahr and Hutton, "Calculating Correct Compilers": the compiler equation
  and the constructor-per-goal move.
- Aaron W. Hsu, "A Data Parallel Compiler Hosted on the GPU" (PhD
  thesis, Indiana University, 2019) and Co-dfns: the tree as a depth
  vector and a type vector, passes as array operations, no pointers and no
  walk. Rung 6 and the third alternative at the quotation fork are his;
  his alarm table is already in `usage-models.md`.
- Andrew Kelley, "Practical Data Oriented Design" (Handmade Seattle
  2021): the ladder and the numbers to compare against.
- Uiua (Kai Schmidt): glyph per function, modifiers as marks that consume
  the following function, planet notation, subscripts as variants, and the
  formatter; the model for marks-as-modifiers here, met natively by
  harakat, patterns, and tatweel.
- Ramsey Nasser, قلب (Qalb): an Arabic Scheme, and the tooling notes.
- Boucher and Anderson, "Trojan Source": why every code point in a
  program is strongly right-to-left here.
