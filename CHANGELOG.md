## Unreleased

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
