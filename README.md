# libara

Attributed Range Algebra for Dart: markup as ranges over a sequence rather
than as a tree inside it.

A document is a persistent sequence, such as the code points of a text. Its
markup is a set of ranges over that sequence, each with scalar attributes.
Ranges may overlap freely and are held by markers that move with every edit,
so inserting or deleting text never requires adjusting an offset. Every edit
returns a new version, and the previous one stays valid, which gives undo
for free.

The library implements the Core Range Algebra and Attributed Range Algebra
papers, and the Range Constructors draft, and adds the persistent, editable
document and layered documents, whose layers of ranges over ranges a
caller's grammar derives. It is pure Dart, with one runtime dependency,
`package:characters`, for grapheme clusters, and runs on the VM and the
web.

## Example

```dart
import 'dart:convert';

import 'package:libara/libara.dart';

/// The value of [result]; an application would handle the failure instead.
T value<T>(Result<T> result) => switch (result) {
  Success(:final value) => value,
  Failure(:final message) => throw StateError(message),
};

void main() {
  // A document holds a sequence, here the code points of a text, and every
  // edit returns a new version.
  final source = Text.of('The cat sat on the mat.');
  var document = Document.of(source);

  // A constructor finds ranges. Each word becomes an attributed range.
  final words = regex(
    RegExp('[a-z]+', caseSensitive: false),
    attributes: {'type': Str(Text.of('word'))},
  );
  final found = value(words(source)).items.cast<ARange>().toList();
  print('words: ${found.length}');

  // Marking stores each range under a marker. A left-gravity end keeps a
  // word from absorbing text typed right after it.
  final marks = [
    for (final range in found) Mark<int>(range, end: Gravity.left),
  ];
  document = value(document.transact(marks));

  // Edits move every range; the caller never adjusts an offset.
  document = value(document.apply(Insert(4, Text.of('black '))));
  print(String.fromCharCodes(document.items));
  print('cat is now at ${document.resolve(marks[1].marker)}');

  // Queries find the ranges at a position or across a span.
  final view = value(Range.create(4, 9));
  print('over "black cat": ${document.overlapping(view)}');

  // Undo is a step back to the previous version.
  print('undo: ${String.fromCharCodes(document.previous!.items)}');

  // A document saves to JSON and loads back with fresh markers, in the
  // order of document.markers.
  final format = JSONFormat(text, history: true);
  final json = jsonEncode(value(format.encode(document)));
  final (loaded, markers) = value(format.restore(jsonDecode(json)));
  print('loaded ${loaded.ranges.length} ranges, version ${loaded.version}');
  print('first word: ${loaded.resolve(markers.first)}');

  // A selector finds ranges by their attributes and by how they nest.
  // Here a type selector reads the `type` attribute, and `phrase > word`
  // selects the words whose innermost container is the phrase.
  final phrase = Mark<int>(
    value(ARange.create(4, 13, attributes: {'type': Str(Text.of('phrase'))})),
  );
  final selector = value(Selector.parse('phrase > word', type: 'type'));
  final inside = value(loaded.apply(phrase)).select(selector);
  print('in the phrase: ${[for (final (_, range) in inside) range]}');

  // Replicas edit one document with no server. Each commit is an
  // operation to send to the others, and concurrent edits converge.
  var alice = value(Replica.create<int>('alice'));
  var bob = value(Replica.create<int>('bob'));
  final Operation<int> hello;
  (alice, hello) = value(alice.commit([Insert(0, Text.of('hello'))]));
  (bob, _) = value(bob.receive(hello));
  final Operation<int> world;
  (alice, world) = value(alice.commit([Insert(5, Text.of(' world'))]));
  final Operation<int> oh;
  (bob, oh) = value(bob.commit([Insert(0, Text.of('Oh, '))]));
  // Operations travel as JSON, here bob's to alice.
  final wire = OperationFormat(text);
  final sent = jsonEncode(value(wire.encode(oh)));
  (alice, _) = value(alice.receive(value(wire.decode(jsonDecode(sent)))));
  (bob, _) = value(bob.receive(world));
  print('alice: ${String.fromCharCodes(alice.document.items)}');
  print('bob: ${String.fromCharCodes(bob.document.items)}');
}
```

It prints:

```text
words: 6
The black cat sat on the mat.
cat is now at {10,3,type:word}
over "black cat": [{10,3,type:word}]
undo: The cat sat on the mat.
loaded 6 ranges, version 2
first word: {0,3,type:word}
in the phrase: [{10,3,type:word}, {14,3,type:word}]
alice: Oh, hello world
bob: Oh, hello world
```

## Concepts

- **Sequences.** `Sequence<T>` is an immutable sequence with the algebra's
  operations. `Items<T>` is backed by a list; `Text` holds Unicode code
  points, so a position counts characters, not UTF-16 units.
- **Ranges.** A `Range` is a start and a length; `ARange` adds attributes,
  whose values are `Str`, `Num`, `Bool`, or `Nil`. `Ranges` adds ordering
  and the containment structure: ancestors, descendants, parent, children.
- **Constructors.** A `Constructor<T>` finds ranges in a sequence. `regex`
  matches a pattern; `union`, `concat`, and `layer` compose constructors,
  so overlapping interpretations can stand side by side.
- **Documents.** `Document<T>` is a persistent sequence carrying marked
  ranges. Commands (`Insert`, `Delete`, `Replace`, `Mark`, `Unmark`,
  `Update`) are applied with `apply`, or several at once with `transact`,
  and each makes a new version linked through `previous`. Query a version
  with `resolve`, `at`, `overlapping`, `ranges`, and `markers`, or, with
  each range's marker, `within` a region and `crossing` a position; `map`
  carries a position from an earlier version into a later one.
- **Gravity.** Each endpoint of a marked range is left or right gravity,
  which decides only what happens when items are inserted exactly at it: a
  right endpoint moves past them, a left one stays before them. The default,
  right at both ends, grows a range at its end; a left end keeps a token
  from absorbing text typed after it.
- **History.** Every version keeps its predecessor alive. `compact()`
  returns a fresh version 0 with the same ranges and markers, releasing the
  history and shortening internal labels.
- **Saving.** A `Format<D, S>` maps values to a serialized form and back.
  `JSONFormat` turns a document into a JSON value and back, optionally with
  its history, through an item format for its items; `text` is the item
  format for code points.
- **Layered documents.** `Layered<T>` holds layers 1 to n over one
  sequence: layer 1 is the sequence, and each layer above is a sequence of
  ranges over the items of the layer below, such as tokens over text and
  elements over tokens. Every layer is a persistent `Document`, so an edit
  at one layer moves the ranges above it. A caller's `Grammar<T>` says what
  the layers mean: `derive` gives a layer's ranges and diagnostics over a
  region of the one below, `affected` names the region an edit touches,
  and `edit` carries out structural edits. A grammar reads one region
  through `slice`, `within`, `crossing`, and `span`, so a keystroke costs
  time that follows nesting depth and the region, not the size of the
  document. `compact()` releases a layered document's history.
- **Layered edits.** An `Edit(layer, command)` reuses the document
  commands. At layer 1, `Insert`, `Delete`, and `Replace` edit the items
  and are always accepted; the layers above are derived again over the
  affected region, and what does not parse becomes diagnostics. Above
  layer 1, `Mark`, `Unmark`, `Update`, and `Delete` go to the grammar,
  which refuses them or describes the edits one layer down that carry them
  out, so a structural edit never lexes text. `apply` and `transact` return
  a `Change`: the new version and, per layer, the ranges created, removed,
  and updated. A grammar's `valid` says whether a text edit leaves the
  markup and its diagnostics as they stand, through the library's `kept`,
  so an editor changing only the words can ask first; `escaped` writes text
  so the grammar reads it as text. A `Move` at layer 1 carries the ranges
  wholly inside the moved items, at every layer, under their markers; the
  grammar's `crossing` decides a range cut by the move. `LayeredFormat`
  reads and writes a layered document as its layer-1 sequence, so with
  `text` it travels as its markup.
- **Annotations.** `Edit.annotation(layer, command)` marks, updates, or
  unmarks a range of the caller's own over a layer's items: a comment or a
  highlight over the text, or a note over tokens or elements. It may start
  inside one element and end inside another. No query a grammar makes
  returns one, so it works with any grammar, and no grammar derives,
  removes, or decides anything about it. An annotation moves with its
  layer's items by its endpoint gravities, as a marked range does; one
  meant to hold exactly some units ends with left gravity, so units placed
  at its end stay outside it. A move that cuts one clamps it, unless the
  move's own `crossings` say otherwise. `annotations(layer)` reads them, a
  `Change` reports those created, removed, and updated, and `previous`,
  `transact`, and `compact` keep them, and `gravity(layer, marker)` gives
  an annotation's gravities. `LayeredFormat` saves only the markup;
  `AnnotationsFormat` saves the annotations beside it as JSON, and its
  `restore` marks them again on the document decoded from that markup,
  giving one fresh marker per saved id.
- **Selectors.** `Selector.parse` reads a CSS-like selector, and `select`
  and `matches` apply it to a document's ranges, one layer of a layered
  document, or any list of keyed ranges. Containment plays the part of the
  element tree: `section p` is a `p` inside a `section`, and `section > p`
  one whose innermost container is the `section`. Type, attribute, and
  structural selectors, `:not`, `:is`, and `:has` work as in CSS;
  `:overlaps` and `:crosses` select ranges by overlap, which a tree cannot
  express. A query costs `O(m log m)` per term over `m` ranges. A `Scope`,
  from `Scope(pairs)`, `document.scope()`, or `layered.scope(layer)`,
  indexes its ranges once for many selections, and `layered.across(layers)`
  projects several layers' ranges to base positions, so one selector
  relates them: `p [type=text]` over the XML example's layers 2 and 3
  selects the text inside `p` elements.
- **Replicas.** `Replica<T>` lets several copies of one document edit
  concurrently with no server. Each `commit` returns an `Operation`,
  stamped by a hybrid logical clock and naming the operations it had seen;
  `receive` merges operations from any replica in any causal order, and
  `since` gives what a peer lacks. Replicas holding the same operations
  hold equal documents, with each range under the same `Key`: concurrent
  insertions do not interleave, updates are last writer wins by stamp, and
  an unmark wins over a concurrent update. `OperationFormat` carries
  operations as JSON.
- **Coordinates.** `Coordinates.of(text)` converts code-point positions to
  what editors and language servers count: UTF-16 offsets (`Unit`), and
  lines and columns (`Place`), with columns in UTF-16 units, code points, or
  grapheme clusters. Over a `Document<int>` every conversion is `O(log n)`
  in any version, from measures its tree caches when first asked. It also
  works in user-perceived characters: `next`, `previous`, `boundary`, and
  `cluster` move by grapheme cluster, `graphemes` counts them, `snap`
  widens a range so it never splits one, and `snapped` does the same for
  every range a constructor gives.

The repository's `example/xml/` holds a grammar for a small subset of XML,
with tokens, elements, well-formedness diagnostics, and wrapping,
unwrapping, renaming, and deleting elements; `dart run example/xml/main.dart`
shows it at work. It reads tokens with `package:petitparser`, a development
dependency only. It is an example, not part of the library.

`example/music/` treats a melody as a sequence of notes, not characters:
bars from the meter and phrases from the rests are two hierarchies that
overlap, queried together with selectors; `dart run
example/music/main.dart` runs it.

## Documentation

`doc/` explains the library in depth: [the theory](doc/theory.md) from
the reference papers, [the architecture](doc/architecture.md), [the
algorithms](doc/algorithms.md), and [the music example](doc/example.md).

## Things to know

- **Failures are values.** Operations that can fail return a `Result`, a
  `Success` or a `Failure` with a `Kind` and a message. The library does
  not throw for an expected failure. Two things can still throw: writing
  an item of the wrong runtime type into a covariant sequence, which is a
  `TypeError`, and a callback passed to `Result.map` or `flatMap`, whose
  exception is not caught. Code a caller plugs in is caught at its
  boundary: `JSONFormat` turns anything an item format throws into a
  failure, and a layered document does the same for its grammar, or
  records a diagnostic in `Layered.of`, which fails only for a grammar
  whose depth is below 1 or whose `depth` getter throws.
- **Some sequence operations drop markup.** On a `Document`, `slice`,
  `diff`, `union`, and `intersect` return plain `Items` without ranges or
  history; `concat` keeps the receiver's ranges and not the argument's.
- **Equality.** Sequences compare their items, so a `Document` equals an
  `Items` with the same items regardless of ranges. Two `ARange`s are equal
  only with equal attributes; `same` compares position alone.
- **Unicode.** Positions are code points. A `RegExp` without
  `unicode: true` can match half of a character outside the Basic
  Multilingual Plane; such a match is widened to the whole character. The
  `text` format refuses to save a high surrogate followed by a low one,
  which would read back as one character.
- **Line ends.** `Coordinates` ends lines at `\n`, `\r\n`, `\r`, NEL,
  LINE SEPARATOR, and PARAGRAPH SEPARATOR. The LSP counts only the first
  three, so a server whose texts can hold the others numbers lines
  differently from its clients after them.
- **Graphemes follow `package:characters`.** Clusters are Unicode's
  extended grapheme clusters as that package finds them, so they change
  with its Unicode version. Segmentation starts at the start of a line,
  since clusters never cross a line end, so a grapheme query costs time in
  the width of its line.
- **The web.** Integers beyond 2^53 are not exact in JavaScript, so very
  large positions do not survive saving and loading there.
- **Layered ranges grow inward.** A range in a layered document grows only
  for items inserted strictly inside it; items inserted at either end lie
  outside it until its layer is derived again. So a grammar's `affected`
  must take in every range that starts or ends where the changed items do.
  The layered document itself widens the region over diagnostics that
  touch it and ranges that cross its ends.
- **A region may start inside what a grammar builds.** The layered
  document widens the region a grammar is asked to derive over the
  diagnostics that touch it, so a region need not start where a unit of the
  grammar starts. A grammar that pairs or nests reads what stands open at
  the region's start from the layer as it is, rather than assuming nothing
  does.
- **A structural edit cannot move a diagnostic.** A `Derivation` creates,
  removes and updates ranges of the edited layer, but not diagnostics, so a
  grammar refuses a structural edit that would change what is in error
  there. A text edit at layer 1, which derives the layers above again,
  repairs it.
- **Ties come in the tree's order.** Queries return ranges in start order,
  and ranges that share a start come in an order the shape of the internal
  trees decides. The same ranges may tie differently in another version, so
  a caller orders ties itself where it needs an order.
- **Grammars must be pure.** A layered document reads its grammar's
  `depth` once, but calls its other methods again whenever a version is
  edited, however old. A grammar whose answers depend on anything but its
  arguments, or whose configuration changes during a session, can derive
  an old version differently from how it was built.
- **History keeps what was deleted.** Every version holds its
  `previous`, and commands hold the items they inserted, so deleted
  items stay reachable, and `JSONFormat` with `history: true` saves them.
  `compact()` drops the history of the version it returns, but any older
  version still held keeps its own; it is not erasure.
- **Extension points are trusted.** Sequence values are immutable only
  as deeply as their items: a mutable item can change an old version and
  its hash. A `Range` subclass is read through `start` and `length`, which
  must not change or fail, and a custom `Sequence` must not throw from its
  getters. `JSONFormat` limits what it reads with `Limits`; nothing bounds
  what such code does.
- **Regular expressions run synchronously.** A backtracking pattern over
  untrusted text can take a long time, and nothing can interrupt it on the
  same isolate.


## License

BSD 3-Clause; see [LICENSE](LICENSE).
