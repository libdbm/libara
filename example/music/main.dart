import 'package:libara/libara.dart';

/// A note: a pitch, or `r` for a rest, and a duration in eighth notes.
typedef Note = ({String pitch, int eighths});

/// The value of [result]; an application would handle the failure instead.
T value<T>(Result<T> result) => switch (result) {
  Success(:final value) => value,
  Failure(:final message) => throw StateError(message),
};

/// An attributed range of [length] items from [start].
ARange range(int start, int length, Map<String, Value> attributes) =>
    value(ARange.create(start, length, attributes: attributes));

/// A constructor of bars of [size] eighths: each bar is the run of notes
/// that fills it, numbered from 1, and a last bar holds what is left.
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

/// A constructor of phrases: each maximal run of notes between rests.
Result<Ranges> phrases(Sequence<Note> input) {
  final found = <Range>[];
  int? start;
  for (final (index, note) in [
    ...input.items,
    (pitch: 'r', eighths: 0),
  ].indexed) {
    if (note.pitch != 'r') {
      start ??= index;
    } else if (start != null) {
      found.add(range(start, index - start, {'type': Str(Text.of('phrase'))}));
      start = null;
    }
  }
  return Success(Ranges.of(found));
}

/// The notes written in [source] as [score] writes them, with `|` for
/// bar lines, which are left for the meter to find.
Items<Note> notes(String source) => Items.of([
  for (final word in source.split(' '))
    if (word != '|')
      (pitch: word.substring(0, 1), eighths: int.parse(word.substring(1))),
]);

/// [notes] written one note after another, such as `G2` for a G lasting
/// two eighths.
String score(Iterable<Note> notes) =>
    notes.map((note) => '${note.pitch}${note.eighths}').join(' ');

/// The bar numbers of [pairs].
List<Value?> numbers(List<(Marker, ARange)> pairs) => [
  for (final (_, range) in pairs) range.get('number'),
];

void main() {
  // The sequence holds notes, not characters. Two phrases each begin with
  // a pickup before the bar line, so phrases and bars overlap.
  final tune = notes('r4 G2 A2 | B4 A2 G2 | A6 r2 | r4 B2 C2 | D4 C2 B2 | G8');
  print('tune: ${score(tune.items)}');

  // Two constructors read the same notes: one by the meter, one by the
  // rests. Their union keeps both interpretations side by side.
  final found = value(union([bars(8), phrases])(tune));
  for (final range in found.items) {
    print('  $range');
  }

  // Marking puts each range in a persistent document under a marker.
  final marks = [
    for (final range in found.items.cast<ARange>())
      Mark<Note>(range, end: Gravity.left),
  ];
  var document = value(Document.of(tune).transact(marks));

  // A selector relates the two hierarchies. Containment answers which
  // bars lie inside a phrase; crossing answers where a phrase begins or
  // ends in the middle of a bar, which no single tree can express.
  final inside = value(Selector.parse('phrase bar', type: 'type'));
  print('bars inside a phrase: ${numbers(document.select(inside))}');
  final crossed = value(Selector.parse('bar:crosses(phrase)', type: 'type'));
  print('bars a phrase crosses: ${numbers(document.select(crossed))}');

  // A grace note inserted inside the first phrase moves every range after
  // it, and the phrase and its bar grow to hold it.
  document = value(document.apply(Insert(4, notes('C1'))));
  print('with a grace note: ${score(document.items)}');
  final first = marks.firstWhere(
    (mark) => mark.range.get('type') == Str(Text.of('phrase')),
  );
  print('first phrase: ${document.resolve(first.marker)}');
  print('at the grace note: ${document.at(4)}');

  // A marked range follows the edit; it does not know the meter. The
  // second bar now holds nine eighths, which a grammar over a layered
  // document would report as a diagnostic.
  final second = marks.firstWhere(
    (mark) => mark.range.get('number') == const Num(2),
  );
  final bar = document.resolve(second.marker)!;
  final eighths = bar
      .extract(document)
      .items
      .fold(0, (sum, note) => sum + note.eighths);
  print('bar ${bar.get('number')}: $bar holds $eighths eighths');

  // Undo is a step back to the previous version.
  print('undo: ${score(document.previous!.items)}');
}
