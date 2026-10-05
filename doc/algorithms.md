# Algorithms

This page describes how libara implements what [theory.md](theory.md)
defines and [architecture.md](architecture.md) lays out. Costs use `n`
for items, `m` for ranges, `k` for results found, and `q` for commands.
"Expected" costs hold for treaps, whose height is logarithmic in
expectation.

## Summary of costs

| Operation | Cost |
|---|---|
| `Items`: `item`, `length` | `O(1)` |
| `Items`: `insert`, `delete` | `O(n)` (a copy) |
| `Ranges.children`, first call | `O(m log m)`, then `O(1 + k)` per call |
| `Document.apply` of an item edit | expected `O(log n + log m)` |
| `Document.apply` of `Mark`, `Unmark`, `Update` | expected `O(log m)`, plus label length |
| `Document.resolve` | expected `O(log m)` |
| `Document.at`, `crossing` | expected `O(log m + k log m)` |
| `Document.overlapping`, `within` | expected `O(log m + k log m)` over candidates |
| `Document.markers`, `ranges` | `O(m log m)` |
| `Document.map` | `O(q)` for the commands between versions |
| `Document.compact` | expected `O(m log m)` |
| `edits(from, to)` | `O(n + m + (n' + m') D)` time, `O(n + m)` space |
| `Coordinates` conversions over a `Document<int>` | expected `O(log n + C)`, `C` = 64 |
| `Selector.select` | `O(m log m)` per term |
| `Layered` text edit | follows the affected region and nesting depth |
| `Replica.receive`, concurrent | `O(N)` per command for `N` items ever inserted |

## Sequences and ranges

`Items<T>` wraps an unmodifiable list. Reads are `O(1)`; `insert` and
`delete` copy, `O(n)`. `diff`, `union`, and `intersect` hash the other
sequence's items, so they are expected `O(n + u)`, and they keep the
receiver's order. `Text` holds code points and checks every item it adds
is in `0..0x10FFFF`. It is the reference implementation; editing belongs
to `Document`.

A `Range` stores a start and a length; its end is exclusive. Every
predicate compares two or four integers. `Range.create`, `move`, and
`resize` refuse a negative start or length and an end that would overflow.

### The containment hierarchy

`Ranges.parent(r)` is the innermost range that contains `r` at a
different position: the greatest start, then the smallest length, then
the first in the sequence. Asked for every range, that would be
`O(m^2)`. `Hierarchy` computes every parent at once in `O(m log m)`:

1. Sort the ranges by start, longest first at equal starts, then by list
   position.
2. Sweep in that order with a stack of candidate parents. Every range
   swept before the current one starts at or before it, so its parent is
   the latest swept range that ends at or after it. A range below another
   on the stack that ends no later can never be that, so the stack's ends
   decrease upwards.
3. Find the parent by binary search for the topmost stack entry ending at
   or after the current range's end. Pop every entry ending at or before
   it, and push it.
4. Ranges at the same position share one parent; the first of them stands
   for all.

The same pass records each range's place among its siblings, their count,
and the sibling before it. `Ranges.children` and the selector module use
them.

## Range constructors

A `Constructor<T>` is a function `Sequence<T> -> Result<Ranges>`. `union`
runs every part, removes exact duplicates, and sorts by start; `concat`
keeps every range in part order; `layer` runs a second function over the
ranges of the first, so its ranges index the lower layer's ranges.

`regex` works in code points while Dart's `RegExp` works in UTF-16 units.
It builds the string once, and two arrays over its UTF-16 offsets: `floor`,
the code point an offset falls in, and `ceiling`, the code point boundary
at or after it. They differ only inside a surrogate pair. A match from
`start` to `end` becomes the range `floor[start]` to `ceiling[end]`, which
widens a match that splits a pair to the whole character. An empty match
between the halves of a pair has no boundary to sit on and is dropped.
The cost is linear in the text plus the cost of matching, which a
backtracking pattern can make exponential.

## Persistent trees

Every persistent structure in libara is a **treap** (Seidel and Aragon): a
binary search tree in key order that is also a heap in a random priority,
which keeps it balanced in expectation. Two operations build everything
else:

- `split(tree, before)` divides a tree into the prefix where `before`
  holds and the rest, by walking one path.
- `join(left, right)` merges two trees, every node of `left` first, by
  following the higher priority down one spine.

Insertion is split, then join with the new node; deletion is two splits
and a join. Every node is immutable, so an operation copies the nodes on
the paths it walks, expected `O(log n)` of them, and shares the rest with
the version before. That sharing is all the persistence there is: an old
version is the old root.

Priorities come from a counter mixed through a 32-bit hash
(`priority.dart`). The same operations give trees of the same shape on
every run. The hash multiplies in 16-bit halves so no intermediate passes
2^53, which keeps it exact on the web, where integers are doubles.

Iteration uses `Walk`, an explicit-stack in-order cursor that carries a
context down the tree, such as an absolute position, without rebuilding
nodes or nesting generators.

Four treaps make up a document version: the content tree, two endpoint
trees, and the marker index. The replica module adds a `Table` and the
`History` tree on the same primitives.

## The content tree

The content tree holds the items in chunks of at most 64 per node, with
each node's subtree item count.

- `item(position)` descends by counts: expected `O(log n)`.
- `slice` splits twice and walks the middle.
- `insertAll` first tries to fit the new items into the chunk that holds
  the position (`_fit`). If they fit, it copies one path and one chunk and
  adds no node, so typing one character at a time adds no nodes until a
  chunk fills. Otherwise it splits at the position and joins in a new
  subtree of chunks.
- `deleteAll` splits at both ends of the span and joins the outsides.
- Content splits can cut inside a chunk. The two halves each keep the
  node's priority, so heap order still holds.

### Measures

Over code points, each node lazily caches a **measure** of its chunk and
of its subtree: UTF-16 units, line ends, and its first and last code
points. Two measures join by adding, except that a carriage return ending
the left and a line feed starting the right make one line end, not two;
the first and last points detect that. Nodes never change, so a measure
never goes stale, and a node shared by many versions is measured once.

Three descents answer every coordinate query in expected `O(log n + C)`,
where `C` is the chunk size: `before(position)` joins the measures of
everything left of a position; `at(units)` finds the position at a UTF-16
offset; `end(count)` finds the code point that completes the `count`th line
end.

## Endpoint trees

The start and end of every marked range is an **endpoint** in an endpoint
tree, ordered by position. Two techniques make an edit cost the same
however many endpoints it moves.

- **Relative positions.** Each node stores its position relative to its
  parent, and the root stores an absolute one. Moving a whole subtree is
  a change to its root. `shift(at, count)` splits at `at` and adds `count`
  to the right part's root.
- **Flat subtrees.** `collapse(from, to)`, for a deletion, splits the tree
  into before, inside, and after. The inside subtree's root is set to
  `from` and flagged flat, which places every endpoint below it at its
  root's position. The after part shifts back by `to - from`.

`open` and `make`, the hooks the shared treap code calls, convert
relative positions to absolute ones and back as nodes are taken apart
and rebuilt, and pass the flat flag down.

### Gravity

Each endpoint has a gravity, which decides only an insertion exactly at
it: right gravity moves past the inserted items, left stays before them.
A document keeps **one endpoint tree per gravity**. An `Insert` at
position `p` of `c` items shifts the right tree from `p` and the left tree
from `p + 1`, so a left endpoint at `p` stays. A range whose ends have
different gravities has one endpoint in each tree.

`Replace` is a delete and then an insert at the span's start, with the
same shifts as each: endpoints inside the span collapse to its start and
then follow their gravity. So a range covering exactly the span, with the
default right gravity at both ends, ends up empty after the new items.

### Labels

A position changes with every edit, so a document finds an endpoint
again by its **label**, a key that edits never change. A label is a
fraction in `(0, 1)` written as base-65,536 digits, never ending in a
zero digit, so comparing digit lists compares the fractions. Edits never
reorder endpoints, so labels stay in tree order forever.

- `Label.between(lower, upper)` makes a label strictly between two
  others, or an open end. It copies the shared prefix, then takes the
  midpoint where the bounds differ by more than one; where they differ
  by one, it keeps the lower digit and steps past the rest of the lower
  bound. At an open end it steps by one from the other bound instead of
  halving, so labels appended or prepended one after another share one
  digit's range. Below an open lower bound it steps by two, leaving room
  for the end of a range marked before every other endpoint.
- A new endpoint goes after every endpoint already at its position, so a
  range's start always precedes its end.
- `Label.spread(count)` gives `count` labels spaced evenly with as few
  digits as possible: one digit for fewer than 65,536.

Marking repeatedly into one gap lengthens labels. `compact()` relabels
every endpoint with `spread` and returns version 0, in expected
`O(m log m)`, dropping history.

### Finding endpoints

- `position(label, owner)` descends by label, summing relative positions:
  expected `O(log m)`.
- Each node caches the greatest **end label** among the start endpoints
  in its subtree: `reach` for ends in the same tree, `beyond` for ends in
  the other tree. Labels never change on shifts and collapses, so neither
  do these.
- `containing(position, other)` finds every range whose start is in this
  tree, at or before `position`, and whose end is after it. An end is
  after the position when its label is greater than the label of the last
  endpoint at or before the position in the tree that holds it, the
  **boundary**. The walk skips every subtree whose `reach` and `beyond`
  cannot pass the boundaries, so it costs expected `O(log m)` plus the
  ranges found.
- `starting(from, to)` finds the start endpoints strictly between two
  positions. Positions never decrease in tree order, so it prunes
  subtrees outside the interval, and each node caches whether its subtree
  holds any start, so it skips runs of ends.

## Document operations

| Command | Content tree | Right tree | Left tree | Index |
|---|---|---|---|---|
| `Insert(p, items)` | insert | shift from `p` | shift from `p + 1` | unchanged |
| `Delete(span)` | delete | collapse `span` | collapse `span` | unchanged |
| `Replace(span, items)` | delete, insert | collapse, shift from start | collapse, shift from start + 1 | unchanged |
| `Mark(range)` | unchanged | add endpoints | add endpoints | put entry |
| `Unmark(marker)` | unchanged | remove endpoints | remove endpoints | remove entry |
| `Update(marker, attributes)` | unchanged | unchanged | unchanged | put entry |

`Mark` with equal gravities adds both endpoints to one tree, labelling the
start and then the end after it. With different gravities, it adds the end
first, so the start can record its end's label as its **partner**, which
`containing` reads.

The **marker index** is a treap keyed by each marker's creation sequence
number, which compares markers in `O(log m)` without hashing.

Queries:

- `resolve(marker)` reads the entry, then the two positions: expected
  `O(log m)`. An end that reads before its start reads as a zero-length
  range at the start.
- `at(position)` runs `containing` on both trees, each with the other's
  boundary, and resolves each owner.
- `overlapping(range)` is `at(range.start)`, filtered to those that
  overlap, plus every range starting strictly inside, from `starting`. A
  range starting at or before the start overlaps only if it contains it,
  so the cost follows the ranges found.
- `within(region)` takes the ranges starting in the region, ends
  included, and keeps those that end inside it.
- `crossing(position)` is `at(position)` restricted to ranges starting
  strictly before it.
- `markers` walks both trees once, `O(m)`, and sorts, `O(m log m)`.

`transact` applies its commands in order to make one version whose
`commands` are all of them, so one step back undoes them all. When the
document has no ranges, a leading run of `Mark`s is placed in one pass:
each tree's endpoints are sorted as one-by-one marking would order them,
labelled with `spread`, and built in one pass, instead of `m` label
searches.

`map(from, position, gravity)` replays the logged commands between two
versions on one position, `O(q)`. Internally, `Anchors` carries many
positions through many commands at once by putting them in their own pair
of endpoint trees, which costs `O((q + r) log m)` for `r` positions
instead of `O(q r)`.

### Edit scripts

`edits(from, to)` gives commands that turn one sequence into another. It
trims the common prefix and suffix, then runs Myers' `O(ND)` difference
algorithm in its linear-space form: a forward and a backward search over
diagonals meet at the middle snake of a shortest path, and each half is
solved the same way. Adjacent changed runs are merged, and each run
becomes an `Insert`, `Delete`, or `Replace`, last run first, so every
command's positions are those of `from`.

## Coordinates and graphemes

A `Coordinates` value over a `Document<int>` converts positions with the
content tree's measures:

- code point to UTF-16: the units before it;
- UTF-16 to code point: `at(units)`, refusing an offset inside a pair;
- code point to line and column: the line ends before it give the line,
  and the line's start, found with `end(line)`, gives the column;
- line and column to code point: the reverse.

Lines end at `\n`, `\r\n`, `\r`, NEL, LINE SEPARATOR, and PARAGRAPH
SEPARATOR, counting a CR LF pair once.

Grapheme clusters come from `package:characters`. UAX #29 always breaks
around line ends, so a cluster never crosses one, and segmentation starts
at the start of the line holding a position. A grapheme query segments one
line, so it costs time in that line's width. `graphemes`, the total count,
is `O(n)` once per value. `snap` widens a range to cluster boundaries, and
`snapped(constructor)` snaps everything a constructor gives.

## Saving and loading

`JSONFormat` writes a document as JSON values only: the items through an
item format, and each marker as an integer id in the order of
`markers`, with its range, gravities, and attributes. With
`history: true` it writes version 0 and the commands of every later
version, and loading replays them. `restore` returns fresh markers by id.

Decoding never throws. A wrong shape is `syntax`, an unusable value is
`invalid`, each naming its JSON path. `Limits` bounds items in any
version, items decoded in total, markers, commands, attributes per range,
and nesting depth. Each bound is checked before the allocation it guards,
and replay checks after every command, so a short history cannot expand
past a bound.

## Layered documents

### A text edit

An `Edit(1, command)` with `Insert`, `Delete`, or `Replace` is always
accepted. The steps:

1. **Apply to layer 1.** The command edits layer 1's document. Layer 2's
   ranges are marks on it, so they move. The changed span is the inserted
   items' span in the new version, or an empty span at a deletion.
2. **For each layer k from 2 up**, derive again over the changed span of
   layer k - 1, and pass the span of layer k items that changed to layer
   k + 1.

Deriving layer k again:

1. **Repair order.** A deletion can collapse several starts to one
   position, leaving ranges at one start out of length order. Runs found
   by binary search are re-sorted, and the region widens over the layer
   above's ranges crossing them.
2. **Find the region.** Ask `grammar.affected(document, k, changed)`,
   take its hull with the changed span, then repeat until nothing
   changes: add every layer-k range crossing an end of the region, and
   every diagnostic touching the region but not inside it. Both are found
   with `crossing` and `within` at the two ends only, so diagnostics and
   ranges elsewhere cost nothing.
3. **Derive.** Call `grammar.derive(document, k, region)`. A range or
   diagnostic outside the region, or a diagnostic with no `message`,
   becomes a diagnostic over the whole region.
4. **Reconcile.** Find by binary search the run of layer-k items starting
   in the region. An old range lying in the region keeps its marker when
   an equal `ARange` (start, length, attributes) is derived again, matched
   greedily in order so kept items never reorder. Unmatched old ranges in
   the region are removed; unmatched new ones get new markers. Ranges
   that hold the region are left alone. Diagnostics are reconciled the
   same way.
5. **Write back.** One `transact` on layer k - 1 unmarks the removed and
   marks the new, with left gravity at the end. One linear merge gives the
   layer-k deletes and inserts that keep its items in start order.

Every mark has right gravity at its start and left at its end, so a range
grows only for items inserted strictly inside it; items inserted at
either end lie outside until derived again. A grammar's `affected` must
therefore include every range that starts or ends where the changed items
do.

The cost follows the region at each layer and the number of layers, not
the size of the document.

### A structural edit

Above layer 1, `Insert` and `Replace` are refused: new items there are
made by `Mark`. `Mark`, `Unmark`, `Update`, and `Delete` go to
`grammar.edit`, which refuses with a `Failure` or returns a
`Derivation`:

- `below`: edits one layer down, applied first;
- `created`: new ranges with their markers, in positions after `below`;
- `removed`: markers to remove;
- `updated`: new attributes for markers that keep their identity.

The edits in `below` are carried out first, recursively: an edit at layer
3 may give layer-2 marks, which the grammar turns into layer-1 inserts.
The library then checks the derivation (no unknown, duplicate, or
out-of-range markers), applies it on the layer below in one transaction,
places the items in start order, and derives again only the layers above
the edited one. The edited layer is trusted to be what `derive` would
give, which is why a grammar must be pure.

In the XML example, wrapping tokens in an element at layer 3 becomes two
tag marks at layer 2, end tag first, which become two text inserts at
layer 1. The grammar refuses any edit that would make the content parse
differently.

### Projection

`extent(layer, marker)` projects a range to layer-1 positions. At layer 2
that is direct; higher up it is the hull of the projections of the items
it covers, memoised per marker, since items below need not end in start
order. `Layered.across(layers)` projects several layers with one shared
memo, so one selector can relate ranges of different layers.

## Selectors

The parser is recursive descent over code points with no separate
tokenizer. It records the first error with its column and returns a
`syntax` failure. The syntax tree is immutable, compares structurally,
and prints back to canonical source. Nesting of `:not`, `:is`, `:has`,
`:overlaps`, and `:crosses` is bounded (64 by default), which bounds
parsing, evaluation, and printing for hostile input.

Containment stands in for the CSS element tree. A range's parent is its
`Hierarchy` parent; ranges at the same position are siblings. `:root` has
no parent; `:empty` is a zero-length range; sibling places follow scope
order.

Evaluation works on whole sets: every intermediate result is a list of
`m` booleans, and nothing backtracks.

- A compound tests each simple selector against each candidate.
- A complex selector runs left to right: the next compound's candidates
  are the ranges related to the current set by the combinator.
  - child: `set[parent[i]]`, `O(m)`;
  - next sibling: `set[previous[i]]`, `O(m)`;
  - later sibling: one pass with a set of parents already seen;
  - descendant: one sweep in hierarchy order keeping the greatest end
    among set members swept, `O(m)`.
- `:has` runs each relative selector right to left with the inverse
  combinators: parents, previous siblings, and a reverse sweep keeping the
  least end for containment.
- `:overlaps(s)` sweeps members of `s` in start order, keeping each
  prefix's greatest and second-greatest end, so a range can exclude
  itself; a binary search finds how many members start before a range's
  end. `O(m log m)`.
- `:crosses(s)` finds a member starting strictly before a range and
  ending strictly inside it, and, on negated spans, one starting strictly
  inside and ending strictly after, each by a sweep with an ordered
  multiset of ends. `O(m log m)`.
- Every nested selector list is evaluated once per selection and
  memoised.

Attribute conditions require the attribute to be present, even for
`!=`. `*=` and `~=` use Knuth-Morris-Pratt, with the failure table cached
on the condition. Ordering compares `Num` with `Num` and `Str` with
`Str` only.

A `Scope` builds the hierarchy and key index once; `Selector.select`
builds a fresh scope per call.

## Replicas

### Stamps

Each replica keeps a **hybrid logical clock** (Kulkarni et al.). A stamp
is `(time, count, replica)`. `tick` takes the greater of the physical
clock and the latest stamp seen, and increments the count when the time
did not advance. Receiving a greater stamp moves the latest forward, so
every later local stamp exceeds everything seen. Stamps compare by time,
count, then replica id, so the order is total and no two replicas make
the same stamp. A stamp more than `skew` (1,000 ms by default) ahead of
the physical clock is refused before it can move the clock, and accepted
when the caller offers it again later.

### Commit and receive

`commit(commands)` applies the commands with `transact`, stamps the
result, and returns an `Operation`: the stamp, the replica's current
**heads** as parents, the commands, and a `Key` for every marker named.
A new `Mark` at command index `i` gets `Key(stamp, i)`, which every
replica computes the same way.

`receive(operation)` checks the stamp is new (or an identical copy), the
parents are held, the stamp is not too far ahead and exceeds its parents',
and the keys are consistent. An operation whose parents are missing is a
`missing` failure; holding it for later is the caller's job.

The state is always the result of applying the held operations in stamp
order, which is a linear extension of causality since a stamp exceeds its
parents'. An operation stamped after every held one is applied to the
current state. An earlier one rewinds to the latest **checkpoint** at or
before its stamp, applies it, and re-applies every later operation,
recording a checkpoint for each. The commands that turn the old document
into the new one are then computed from the two histories.

### Concurrent operations

When an operation's parents are the current heads, its commands apply
unchanged. Otherwise each command is read against the document as its
author saw it: the `History` holds every item ever inserted, deleted ones
included, and a view restricted to the operation's causal past maps a
position in the author's document to a position in the current one. This
interpretation of each operation in its own version resembles Eg-walker,
though it scans the history, `O(N)` per command.

- **Inserts** follow **Fugue** (Weidner and Kleppmann). A new item is a
  right child of the item before it if that has no right children in
  context, and otherwise a left child of the next item. Each later item
  of a run is a right child of the one before, so runs stay together.
  Siblings are in identity order. Concurrent inserts at one position come
  out in stamp order and never interleave.
- **Deletes** record the deleting stamp on each item in context. An item
  is visible when no stamp has deleted it, so concurrent deletes of one
  item both succeed and the second does nothing.
- **Marks** map their range through the history by gravity: a right end
  stays before the item at its position, a left end after the item before
  it.
- **Updates** are last writer wins by stamp, since operations apply in
  stamp order.
- **Unmark wins** over a concurrent update: a later update finds no range
  and does nothing, and a later unmark removes the range.

Replicas holding the same operations hold equal documents, with each range
under the same `Key`. `since(heads)` returns the held operations a peer
lacks, parents first.

## Known limits

Work considered and set aside that bears on the costs above:

- Labels grow when ranges are marked repeatedly into one gap; only
  `compact()` resets them, and it drops history.
- Treap height is logarithmic in expectation only; an adversary who can
  shape input could deepen it.
- Each derived layer of an edit snapshots every layer, `O(d^2)` pointers
  for depth `d`.
- Replica contexts scan every item ever inserted, and replica history is
  never pruned.
- `parent` scans the sequence, `O(m)` per call; `children` is indexed.
- Grapheme counts are `O(n)` once per `Coordinates` value.
