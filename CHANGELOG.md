## 0.2.2

- `Document.having(key)` and `Layered.having(layer, key)` find the ranges
  whose attributes say a key, in start order. A document made with
  `Document.of(items, indexed: ...)` or `Layered.of(items, grammar, indexed:
  ...)` indexes those keys in every version, so finding one costs what the
  ranges found do; any other key is found by walking the ranges. A layer's
  diagnostics and the annotations over the layer below are not among a
  layer's ranges.

## 0.2.1

- Improve annotation performance by not scanning everything, every time.

## 0.2.0

- `Move(span, to)` moves items, and the ranges wholly inside them, under
  their markers. A range crossing an edge of the span is decided by the
  `crossing` policy `Document.apply` and `transact` take: `Crossing.clamp`,
  `follow`, or `refuse`, the default. The document logs the move with the
  decisions it made, so a replay and a JSON history make it the same way.
  `Grammar.crossing` is the policy a layered document passes; a layer-1
  move moves the items of each layer above that lie wholly inside it. A
  replica refuses a move. `transact` logs each move with its decisions, as
  `apply` does.
- Mapping a position through a move, by `Document.map` or anchors, takes a
  position strictly inside the moved items along with them; a move to
  either edge of its items maps every position to itself. An empty range
  at the place a move puts items, its start right and its end left, reads
  as empty at its start, as an insertion leaves it; a move fails for a
  range turned inside out only where `follow` turns it.
- `Grammar` has `valid`, the change a text edit makes where it leaves the
  markup and its diagnostics as they stand, and `escaped`, how text is
  written as text alone. Both are new members, so every grammar must
  answer them. The library's `kept` carries out the check: a grammar's
  `valid` calls it, naming which of its ranges are text, and every range
  is markup by default. Markup and diagnostics are compared in order, by
  what each is and what lies under it, not counted.
- The XML example reports a bare `&` in text, one starting no reference,
  as a diagnostic, and its structural edits refuse to make or unmake one.
- `Edit.annotation(layer, command)` marks, updates, and unmarks
  annotations: ranges of the caller's own over a layer's items, which may
  cross elements, and which no grammar derives or sees. They move with
  their layer's items, a move that cuts one clamps it unless the move says
  otherwise, `Layered.annotations` reads them, in time following how many
  there are rather than the layer's size, and `Layered.gravity` gives
  their gravities.
- `AnnotationsFormat` saves a layered document's annotations as JSON, to
  keep beside the markup `LayeredFormat` saves, and `restore` marks them
  again on the document decoded from that markup. An annotation over a
  layer above 1 is saved as indices into that layer.
- `Change` has a third field, `annotations`, the annotations each layer
  created, removed, and updated. Code that destructures a `Change` with a
  record pattern must name it.
- `ARange` is a `base` class and `ARange.from` a generative constructor, so
  a caller can extend it to say by a range's class what kind of thing it
  is. Equality is unchanged, and a document stores every range as a plain
  `ARange`.

## 0.1.0

First release.

- Sequences: `Sequence`, `Items`, and `Text` over Unicode code points, with
  the Core Range Algebra operations, and `Result` for every operation that
  can fail. Slices hold unmodifiable copies.
- Ranges: `Range`, `Ranges`, the predicates, ordering, and containment
  structure, with `Ranges.children` answering from a hierarchy indexed
  once; `ARange` with scalar attribute values.
- Constructors: `regex`, `union`, `concat`, and `layer`.
- Documents: `Document`, a persistent sequence whose marked ranges move
  with every edit, with endpoint gravity, `Insert`, `Delete`, `Replace`,
  `Mark`, `Unmark`, and `Update` commands, `transact`, coalesced edits,
  `resolve`, `at`, `overlapping`, `within`, `crossing`, `map`, `markers`,
  and `compact`. `edits` gives the commands that turn one sequence into
  another, from a shortest edit script.
- Formats: the `Format` interface; `JSONFormat` to and from JSON, with
  optional history, `restore` returning the loaded markers, and `Limits`
  bounding what a decode may allocate; and `text`, the item format for
  code points.
- Layered documents: `Layered`, layers 1 to n of ranges over ranges, each a
  persistent `Document`, with a caller's `Grammar` deriving them. Text
  edits derive the layers again over the affected region, reporting what
  does not parse as diagnostics; structural edits are carried out through
  the grammar's `Derivation`; `apply` and `transact` return a `Change`;
  and `slice`, `within`, `crossing`, `span`, and `extent` read one region.
  `LayeredFormat` reads and writes a layered document as its text. An XML
  grammar in `example/xml/` shows one at work.
- Selectors: `Selector`, CSS-like queries over attributed ranges, with
  type, attribute, and structural selectors, the four combinators, `:not`,
  `:is`, `:has`, `:overlaps`, and `:crosses`, over any list of keyed
  ranges, a `Document`, or one layer of a `Layered`. A `Scope` indexes its
  ranges once for many selections, and `Layered.across` projects several
  layers' ranges to base positions so one selector relates them.
- Replicas: `Replica`, peer-to-peer replication of a `Document` with no
  server. Each `commit` is an `Operation` stamped by a hybrid logical clock
  and naming its parents; `receive` merges operations from any replica in
  any causal order, and replicas holding the same operations hold equal
  documents. Concurrent insertions do not interleave, updates are last
  writer wins by stamp, an unmark wins over a concurrent update, and stamps
  too far ahead of the local clock wait. `since` gives what a peer lacks,
  `Key` names a range on every replica, and `OperationFormat` carries
  operations as JSON.
- Coordinates: `Coordinates` converts code-point positions to UTF-16
  offsets (`Unit`) and to lines and columns (`Place`), columns in UTF-16
  units, code points, or grapheme clusters, in `O(log n)` over any
  `Document<int>` version. Through `package:characters` it also finds
  grapheme cluster boundaries, counts clusters, and snaps ranges to them,
  and `snapped` makes a constructor's ranges whole clusters.
