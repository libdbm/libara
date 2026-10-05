# Theory

libara implements a family of papers written in 2002 by Gavin Thomas Nicol
at Red Bridge Interactive: *Core Range Algebra*, *Attributed Range
Algebra*, the *Range Constructors* draft, and the *Range Algebra* talk
given at Extreme Markup Languages 2002. The originals are online. 
This page consolidates them: what problem they address, the
model they define, and where libara follows, corrects, or goes beyond
them.

## The problem: markup inside the data

A text is a sequence of characters. Markup is added to it to annotate,
correct, give meaning, or guide formatting:

```text
<doc>This is a piece of <i>italic</i> text.</doc>
```

Embedded markup such as XML has to nest, so tools treat it as a tree, and
formal models of XML treat the tree as the document. The papers question
that choice on three grounds.

- **Documents are not trees.** Real texts carry annotations, cross-
  references, and structures that overlap: a verse line that crosses a
  sentence, a quotation that crosses a page. Humanities encoding (TEI,
  Durand, DeRose, Renear) has documented this for decades. A tree can only
  hold one hierarchy at a time.
- **Node models are not closed over text.** A query for text that spans a
  node boundary returns something that is not a set of nodes, and a
  fragment of a well-formed document need not be well-formed. A model
  whose operations stay inside the model needs a different unit.
- **There is no canonical structure.** Interpretation is in the eye of the
  reader, and it changes over time. Forcing one structure, and one syntax,
  on every consumer makes data hard to evolve.

The alternative is older than XML. Ted Nelson's *parallel markup* holds
that markup is not part of the text but an interpretation imposed on a
range of it, stored beside it ("Embedded Markup Considered Harmful"). The
range algebra papers give that view a formal basis.

## Core Range Algebra

Core Range Algebra (CRA) is an algebra over a **sequence** of items drawn
from a finite **alphabet**, closed over its operations. "Sequence" is
meant mathematically: characters, DNA bases, records, or anything else.
Three abstract data types make it up.

### Sequences

A sequence is a totally ordered, finite list of items. A **position** is
an index from 0 to n - 1.

| Group | Operations |
|---|---|
| Predicates | `IsEmpty`, `Contains`, `Equals` |
| Operators | `Diff`, `Union`, `Intersect`, `Concat` |
| Operations | `Insert`, `Delete`, `ItemAt`, `First`, `Last`, `Length` |

The paper singles out **concatenation**. With the empty sequence as its
identity it forms a monoid, which gives the Kleene closure, and so the
regular expressions that later serve as range constructors.

### Ranges

A range is a `{start, length}` pair over a sequence: a marker for a
sub-sequence, which knows nothing about the items it spans. The paper
writes `{4,5}` for the range starting at position 4 holding 5 items.

| Group | Operations |
|---|---|
| Predicates | `StartsBefore`, `StartsAfter`, `StartsWithin`, `EndsBefore`, `EndsAfter`, `EndsWithin`, `Within`, `Same` |
| Operations | `Create`, `Flatten` (extract the items), `StartOf`, `EndOf`, `LengthOf`, `Move`, `Resize` |

Every predicate compares starts and ends only, so each is constant time.
Two ranges may overlap in any way: nothing in the model requires nesting.

### Sequences of ranges

Structure is inferred from how ranges relate. Given a sequence of ranges:

| Operation | Result |
|---|---|
| `StartOrder` | ranges by ascending start, ties by ascending length |
| `EndOrder` | ranges by ascending end, ties by ascending length |
| `Unique` | no two ranges with the same start and length |
| `Ancestor(R, S)` | every range in S that contains R |
| `Descendant(R, S)` | every range in S that R contains |
| `Parent(R, S)` | the container of R whose start is closest to R's |
| `Child(R, S)` | the ranges whose parent is R |

Containment plays the part of the element tree. Where ranges nest, these
operations recover the tree; where they overlap, they still answer, and
each range simply has the ancestors it has.

CRA also sketches a small functional **expression language** (constants,
operators, `if`, `let`, `for`, function application) over these types.

## Allen's interval algebra

The papers do not mention it, but CRA's range predicates are close kin of
Allen's interval algebra (Allen, 1983), the standard calculus for
reasoning about intervals of time. Allen defines thirteen relations
between two intervals: seven basic ones and the inverses of the six that
are not symmetric.

| Relation | Inverse | Meaning, for `a = [s, e)` and `b = [t, f)` |
|---|---|---|
| `a` before `b` | after | `e < t`: a gap between them |
| `a` meets `b` | met by | `e == t`: `a` ends where `b` starts |
| `a` overlaps `b` | overlapped by | `s < t < e < f` |
| `a` starts `b` | started by | `s == t` and `e < f` |
| `a` during `b` | contains | `t < s` and `e < f` |
| `a` finishes `b` | finished by | `t < s` and `e == f` |
| `a` equals `b` | equals | `s == t` and `e == f` |

For any two intervals of positive length, exactly one of the thirteen
holds: the relations are jointly exhaustive and pairwise disjoint.

### Allen as compositions of range operations

Each relation is a composition of CRA's predicates, with `Resize` to tell
"before" from "meets". In libara's terms, with `end` exclusive:

| Allen | Range algebra |
|---|---|
| `a` before `b` | `a.resize(1).endsBefore(b)` |
| `a` meets `b` | `a.endsBefore(b) && !a.resize(1).endsBefore(b)` |
| `a` overlaps `b` | `a.startsBefore(b) && !a.endsBefore(b) && b.endsAfter(a)` |
| `a` starts `b` | `!a.startsBefore(b) && !a.startsAfter(b) && b.endsAfter(a)` |
| `a` during `b` | `a.startsAfter(b) && b.endsAfter(a)` |
| `a` finishes `b` | `a.startsAfter(b) && !a.endsAfter(b) && !b.endsAfter(a)` |
| `a` equals `b` | `a.same(b)` |

The inverses swap the arguments. `endsBefore` tests `a.end <= b.start`,
which holds for both "before" and "meets"; growing `a` by one item keeps
it true only when there is a gap. Positions are integers, so `Resize` by
one is the smallest step there is. The table was checked against Allen's
definitions for every pair of ranges with starts and lengths up to five.

CRA's coarser predicates are in turn unions of Allen's relations, for
ranges of positive length:

| Range algebra | Allen relations |
|---|---|
| `a.within(b)` | during, starts, finishes, equals |
| `a.contains(b)` | contains, started by, finished by, equals |
| `a.overlaps(b)`, sharing a position | every relation but before, meets, and their inverses |
| `a.same(b)` | equals |

libara's selectors express the same unions over sets of ranges:

| Selector | Allen relations of a matched range `a` to some range `b` |
|---|---|
| `b a` (`a` a descendant of `b`) | during, starts, finishes |
| `a:overlaps(b)` | every relation but before, meets, and their inverses |
| `a:crosses(b)` | overlaps, overlapped by |

`:crosses` is exactly the pair of relations that a tree cannot hold, and
the one the music example in [example.md](example.md) uses to find the
bars a phrase crosses.

### What Allen adds, and where the two differ

- **Composition.** Allen's algebra is built for inference: given the
  relation of `a` to `b` and of `b` to `c`, a composition table gives the
  possible relations of `a` to `c`, and path consistency propagates
  constraints through a network of intervals. Range algebra computes
  relations from known positions instead, so it never needs the table,
  and libara does not implement it.
- **Zero-length ranges.** Allen's intervals have positive length. Range
  algebra allows a zero-length range, a point between two items, and
  there the relations stop being disjoint: an empty range at the start of
  `b` both meets `b` and starts it. Allen's point algebra, or the
  point-interval relations of Vilain, covers that case.
- **Discrete positions.** Allen's intervals lie on a dense line. Range
  algebra's positions are integers, which is what lets `Resize` by one
  separate "before" from "meets".
- **Interpretation.** Allen relates intervals of time; range algebra
  relates spans of a sequence, attributes them, and infers structure
  from containment. Every Allen relation can be asked of two ranges, and
  the selectors above ask the common unions of whole sets at once.

## Range constructors

CRA's `Create` makes one range from a position and a length, but leaves
open what decides where ranges go. A **range constructor** is a function
from a sequence to a sequence of ranges:

```text
constructor: sequence -> sequence (of ranges)
```

It is a lexical analyser generalised: lex reads characters and gives
tokens, a constructor reads items of any type and gives ranges. Applied to
`Sample text sequence.`, a constructor that knows English word boundaries
gives `{0,6} {7,4} {12,8}`.

Regular expressions are the natural constructor, since they are defined
over an alphabet just as sequences are: each match becomes a range.

The draft's central point is **ambiguity**. Lexers resolve overlapping
patterns by declaration order or greediness, and languages are designed to
avoid the overlap. Range algebra keeps it instead. Given

```text
*day              anything ending in "day"
(Mon|Wednes)day   Monday or Wednesday
(Tues|Fri)day     Tuesday or Friday
```

each pattern runs on its own, and the results are combined with `Union`
(unordered, duplicates removed) or `Concat` (in order). Constructors have
no side effects, so they can run in parallel.

Constructors also stack: a constructor over the ranges of a lower layer
builds higher structure, and a recursive one can infer structurally
recursive data.

## Attributed Range Algebra

A range says that something is at `{4,5}` but not what. HTML
`<i>quick</i>`, LaTeX `\emph{quick}`, and Lout `@i{quick}` all label the
same characters, and labelling is the purpose of markup. Attributed Range
Algebra (ARA) adds that.

- An **attributed range** (arange) is a range with a set of named
  attributes, written `{0,5,type:header}`. Attributes are read with the
  dot operator, `R.type`, and edited with `SetAttributeValue`,
  `RemoveAttribute`, `GetAttributeNames`, and so on, each returning a new
  arange.
- An **attribute** is a `{name, value}` pair.
- A **string** is a sequence of Unicode code points, compared code point
  by code point.

ARA distinguishes **Equals**, deep comparison of position and attributes,
from **Same**, identity: two ranges can be equal without being the same.

### Layers of interpretation

ARA's main application is a stack of sequences, each layer a sequence of
ranges over the layer below:

```text
layer 3  application structure   element{p}  element{i}
layer 2  lexical structure       start{p} text start{i} text end{i} text end{p}
layer 1  data stream             < p > T h e   < i > q u i c k < / i > ...
```

- The **data stream** is the sequence itself; it need not be characters.
- The **lexical layer** identifies the tokens that delimit markup, as
  attributed ranges over the stream.
- The **application layer** orders the tokens canonically (by
  `StartOrder`) and identifies higher structures over them, as a parser
  built with lex and yacc would.

Three layers are typical, not required. Over the application layer,
`Parent` and `Child` give the containment tree, so a DOM-like interface
can sit on top.

Two consequences follow.

- **Markup suppression.** Removing the ranges of a kind from the layer an
  interface reads hides that markup without touching the data. Removing
  every `<i>` element leaves one `<p>` spanning the document. Since
  overlapping ranges are allowed, suppression can derive many well-formed
  trees from one set of ranges.
- **Syntax independence.** Everything above the lexical layer is
  independent of syntax. XML, LaTeX, and an invented notation for the same
  document differ only in their lexical ranges; an application that reads
  the application layer sees the same structure. One processing model can
  serve many domain-specific syntaxes, with transformations between them
  at the edges.

## What the papers left for later

The papers name their own future work:

- a full Range Constructor formalism, including regular expressions
  extended with feature logic over attributes, such as
  `[%type=word%]+[%type=period%]` to build sentences from words;
- RAQUEL, a query language for extraction and transformation across
  syntaxes;
- validation by forest regular expressions, partial validation, and "type
  by projection";
- mappings from node-centric models such as XML into ARA, and a formal
  basis for XLink ranges and incremental transformation.

## How libara relates to the papers

### What it implements

| Paper concept | libara |
|---|---|
| sequence | `Sequence<T>`, `Items<T>`; `Text` for code points |
| range | `Range`, made by `Range.create` |
| sequence of ranges | `Ranges`, with `startOrder`, `endOrder`, `unique`, `ancestors`, `descendants`, `parent`, `children` |
| range constructor | `Constructor<T>`, `regex`, and `union`, `concat`, `layer` to compose them |
| attributed range | `ARange`, with `get`, `set`, `remove`, `has`, `names`, `all` |
| attribute | `Attribute` |
| string | `Text`, with `compare` as the paper defines it |
| layers of ranges | `Layered<T>`, driven by a caller's `Grammar<T>` |
| a query language | `Selector`, CSS-like queries over containment and overlap |

### Where it departs

| Point | Paper | libara | Why |
|---|---|---|---|
| `Within` | prose says "a contains b", formula tests a inside b | `within` follows the formula; `contains` is the converse | the formula is the definition |
| End of a range | `EndOf` is the last position | `end` is one past the last, so `end - start == length` | zero-length ranges, and no off-by-one in every predicate |
| `StartsWithin` | start at or before `EndOf(b)` | `start >= b.start && start < b.end` | follows from the exclusive end |
| Out-of-bounds `Insert`, `Delete` | no change, or an error | a `Failure` of kind `bounds` | failures are values, never silent |
| `Diff`, `Union`, `Intersect` | order not preserved | order of the receiver preserved | determinism |
| `Child` | returns a range | returns every child | as the paper's prose describes |
| `Parent` ties | start closest to R's | greatest start, then smallest length, then first in the sequence | a total rule |
| Attribute values | any sequence | scalar: `Str`, `Num`, `Bool`, `Nil` | a deliberate restriction for now |
| Expression language | defined | not implemented | deferred until queries beyond the Dart API are needed |

### Where it goes beyond

The papers model a static sequence. libara adds what an editor, a
language server, or a collaborative tool needs on top of the algebra:

- **Persistent, editable documents.** A `Document<T>` holds ranges under
  markers that move with every insert and delete, so a caller never
  adjusts an offset, and every edit makes a new version with the old one
  intact.
- **Endpoint gravity.** Each endpoint decides whether it moves past items
  inserted exactly at it.
- **Incremental layers.** `Layered<T>` re-derives only the region an edit
  touches, and turns structural edits at a higher layer into edits one
  layer down, so a structural edit never re-lexes text.
- **Selectors.** CSS selectors over containment, with `:overlaps` and
  `:crosses` for the relations a tree cannot express.
- **Replication.** `Replica<T>` merges concurrent edits from peers with no
  server.
- **Coordinates.** Conversion between code points, UTF-16 units, lines,
  columns, and grapheme clusters.

[algorithms.md](algorithms.md) describes how these work, and
[architecture.md](architecture.md) how they fit together.

## Bibliography

From the papers' references, consolidated.

- Adler, S. C. *DSSSL: Document Style Semantics and Specification
  Language*, 1989.
- Beeri, C. and Tzaban, Y. *SAL: An Algebra for Semistructured Data and
  XML*.
- Buneman, P., Fernandez, M. and Suciu, D. *UnQL: A Query Language and
  Algebra for Semistructured Data Based on Structural Recursion* (as the
  Range Constructors draft gives it).
- Cameron, R. D. *REX: XML Shallow Parsing Using Regular Expressions*,
  1998.
- Coupaye, T. *Extracting and Converting Data from Semistructured
  Biological Databanks with SRS*, 1996.
- Durand, D. G., DeRose, S. J. and Mylonas, E., 1996 (title not given in
  the paper).
- Durusau, P., work on Just In Time Trees (JITT), 2002 (cited as
  "Durasu").
- Fernandez, M., Simeon, J. and Wadler, P. *A Semi-Monad for
  Semi-Structured Data*.
- Fuhr, N. and Grossjohann, K. *XIRQL: A Query Language for Information
  Retrieval in XML Documents*.
- Grahne, G. and Nykanen, M., on Alignment Calculus, 1997 (title not given
  in the paper).
- Nelson, T. H. *Literary Machines*.
- Nelson, T. H. *Embedded Markup Considered Harmful*, 1997.
- Nicol, G. T. *Core Range Algebra: Toward a Formal Model of Markup*,
  2002.
- Nicol, G. T. *Attributed Range Algebra: Extending Core Range Algebra to
  Arbitrary Structures*, 2002.
- Nicol, G. T. *Range Constructors* (draft), 2002.
- Nicol, G. T. *Range Algebra*, Extreme Markup Languages, 2002.
- Sperberg-McQueen, C. M. and Burnard, L. *The Design of the TEI Encoding
  Scheme*, 1995.
- St. Laurent, S. *Regular Fragmentations*, 2001.
- W3C. *Document Object Model (DOM) Level 1*, 1998; *Extensible Stylesheet
  Language*; *XQuery 1.0: An XML Query Language*.

The section on Allen's interval algebra draws on:

- Allen, J. F. *Maintaining Knowledge about Temporal Intervals*,
  Communications of the ACM 26(11), 1983.
- Vilain, M. B. *A System for Reasoning About Time*, AAAI, 1982.

libara's own algorithms draw on further work, cited where they are used in
[algorithms.md](algorithms.md): treaps (Seidel and Aragon), Myers'
difference algorithm, hybrid logical clocks (Kulkarni et al.), and Fugue
(Weidner and Kleppmann).
