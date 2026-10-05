# Example: overlapping structure in music

The papers stress that a sequence need not be text: the algebra works over
items of any type. `example/music/main.dart` shows this with a melody.
Its items are notes, and two interpretations of the same notes overlap,
which is the problem range algebra was made for. Run it with:

```sh
dart run example/music/main.dart
```

`test/music_test.dart` checks that it prints what this page shows.

## Notes as items

A note is a record of a pitch, or `r` for a rest, and a duration in eighth
notes:

```dart
typedef Note = ({String pitch, int eighths});
```

Records compare by value, which is all a `Sequence` asks of its items. The
tune is an `Items<Note>`, read from a short notation where `G2` is a G
lasting two eighths:

```dart
final tune = notes('r4 G2 A2 | B4 A2 G2 | A6 r2 | r4 B2 C2 | D4 C2 B2 | G8');
```

The `|` marks are for the reader; the parser drops them, and the bars are
found from the meter.

## Two constructors, two hierarchies

A melody has two structures that do not nest.

- **Bars** come from the meter. In 4/4 time a bar holds eight eighths.
- **Phrases** come from the music. Here each phrase is a run of notes
  between rests, and each starts with a pickup before the bar line.

Each is a `Constructor<Note>`: a pure function from a sequence to the
ranges it finds. `regex` only reads code points, so these are written by
hand, which is the general case.

```dart
Constructor<Note> bars(int size) => (input) {
  final found = <Range>[];
  var (start, filled) = (0, 0);
  for (final (index, note) in input.items.indexed) {
    filled += note.eighths;
    if (filled >= size || index == input.length - 1) {
      found.add(
        range(start, index + 1 - start, {
          'type': Str(Text.of('bar')),
          'number': Num(found.length + 1),
        }),
      );
      (start, filled) = (index + 1, 0);
    }
  }
  return Success(Ranges.of(found));
};
```

`union` runs both and keeps every range, in start order, as the Range
Constructors draft describes for ambiguous patterns:

```dart
final found = value(union([bars(8), phrases])(tune));
```

```text
tune: r4 G2 A2 B4 A2 G2 A6 r2 r4 B2 C2 D4 C2 B2 G8
  {0,3,number:1,type:bar}
  {1,6,type:phrase}
  {3,3,number:2,type:bar}
  {6,2,number:3,type:bar}
  {8,3,number:4,type:bar}
  {9,6,type:phrase}
  {11,3,number:5,type:bar}
  {14,1,number:6,type:bar}
```

Laid out over the notes:

```text
index   0   1   2   3   4   5   6   7   8   9   10  11  12  13  14
note    r4  G2  A2  B4  A2  G2  A6  r2  r4  B2  C2  D4  C2  B2  G8
bar     [----1-----][----2-----][--3---][----4-----][----5-----][6-]
phrase      [--------phrase--------]        [--------phrase--------]
```

The first phrase starts inside bar 1 and ends inside bar 3. In XML one of
the two would have to be broken into pieces or moved into attributes.
Here both are ranges over the same sequence.

## Marking

Each range is marked into a persistent `Document<Note>`. A left-gravity
end keeps a range from absorbing notes added right after it:

```dart
final marks = [
  for (final range in found.items.cast<ARange>())
    Mark<Note>(range, end: Gravity.left),
];
var document = value(Document.of(tune).transact(marks));
```

## Querying both hierarchies at once

A selector reads containment as the CSS element tree, and adds relations
a tree cannot express. With `type: 'type'`, a type selector such as
`bar` matches the ranges whose `type` attribute is `bar`.

```dart
final inside = value(Selector.parse('phrase bar', type: 'type'));
final crossed = value(Selector.parse('bar:crosses(phrase)', type: 'type'));
```

```text
bars inside a phrase: [2, 5, 6]
bars a phrase crosses: [1, 3, 4]
```

- `phrase bar` selects bars that lie within a phrase: bars 2, 5, and 6.
- `bar:crosses(phrase)` selects bars that a phrase starts or ends inside
  of, crossing the bar line: bars 1, 3, and 4. These are the bars where
  the phrasing and the meter disagree.

## Editing

Inserting a grace note before position 4 moves every range after it.
Nothing adjusts an offset:

```dart
document = value(document.apply(Insert(4, notes('C1'))));
```

```text
with a grace note: r4 G2 A2 B4 C1 A2 G2 A6 r2 r4 B2 C2 D4 C2 B2 G8
first phrase: {1,7,type:phrase}
at the grace note: [{1,7,type:phrase}, {3,4,number:2,type:bar}]
bar 2: {3,4,number:2,type:bar} holds 9 eighths
undo: r4 G2 A2 B4 A2 G2 A6 r2 r4 B2 C2 D4 C2 B2 G8
```

- The note falls strictly inside the first phrase and bar 2, so both
  grow by one. Every range after it shifts by one.
- `at(4)` finds the ranges holding the new note.
- Bar 2 now holds nine eighths. A marked range follows edits; it does not
  know the meter. Keeping derived structure correct is the job of a
  layered document: a `Grammar<Note>` would derive bars at layer 2 and
  report an overfull bar as a diagnostic, while phrases marked by hand
  keep their markers.
- `previous` is the version before the edit, so undo is one step back.

## Where to go next

- The XML example in `example/xml/` is a full `Grammar` with three
  layers and structural edits.
- [theory.md](theory.md) explains why overlapping ranges are the model,
  and [algorithms.md](algorithms.md) how marked ranges move with edits.
