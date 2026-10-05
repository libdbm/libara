import 'dart:math';

import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// Code points that exercise every measure: ASCII, a two-unit character,
/// lone surrogates, and every line end.
const alphabet = [
  0x61,
  0xE9,
  0x1F600,
  0xD800,
  0xDC00,
  0x0A,
  0x0D,
  0x0D,
  0x85,
  0x2028,
  0x2029,
];

/// Random code points from [alphabet], [count] of them.
List<int> points(Random random, int count) => [
  for (var index = 0; index < count; index++)
    alphabet[random.nextInt(alphabet.length)],
];

/// The UTF-16 units of [points] before [position].
int units(List<int> points, int position) => points
    .take(position)
    .fold(0, (sum, point) => sum + (point > 0xFFFF ? 2 : 1));

/// Whether a line end completes at [index] of [points].
bool completes(List<int> points, int index) => switch (points[index]) {
  0x0A => index == 0 || points[index - 1] != 0x0D,
  0x0D || 0x85 || 0x2028 || 0x2029 => true,
  _ => false,
};

/// The line ends of [points] before [position].
int ends(List<int> points, int position) => [
  for (var index = 0; index < position; index++)
    if (completes(points, index)) index,
].length;

/// Expects every measure of [document] to agree with counting [points].
void agrees(Document<int> document, List<int> points, String reason) {
  final total = document.measure;
  expect(total?.units ?? 0, units(points, points.length), reason: reason);
  expect(total?.ends ?? 0, ends(points, points.length), reason: reason);
  for (var position = 0; position <= points.length; position++) {
    final prefix = document.prefix(position);
    expect(prefix?.units ?? 0, units(points, position), reason: reason);
    expect(prefix?.ends ?? 0, ends(points, position), reason: reason);
    if (position > 0) {
      expect(prefix!.last, points[position - 1], reason: reason);
    }
  }
  // Every unit lands on a position, or inside a two-unit item.
  var position = 0;
  var unit = 0;
  for (final point in points) {
    expect(document.located(unit), (position, true), reason: reason);
    if (point > 0xFFFF) {
      expect(document.located(unit + 1), (position, false), reason: reason);
    }
    unit += point > 0xFFFF ? 2 : 1;
    position++;
  }
  expect(document.located(unit), (points.length, true), reason: reason);
  var count = 0;
  for (var index = 0; index < points.length; index++) {
    if (completes(points, index)) {
      expect(document.ending(++count), index, reason: reason);
    }
  }
}

void main() {
  test('a carriage return and line feed across chunks are one end', () {
    final points = [...List.filled(63, 0x61), 0x0D, 0x0A, 0x62];
    final document = Document.of(Items.of(points));
    expect(document.measure!.ends, 1);
    expect(document.prefix(64)!.ends, 1);
    expect(document.prefix(65)!.ends, 1);
    expect(document.ending(1), 63);
    agrees(document, points, 'across chunks');
  });

  test('an empty document measures nothing', () {
    final document = Document<int>.empty();
    expect(document.measure, isNull);
    expect(document.prefix(0), isNull);
    expect(document.located(0), (0, true));
  });

  test('measures agree with counting over random texts, over 100 seeds', () {
    for (var seed = 0; seed < 100; seed++) {
      final random = Random(seed);
      final text = points(random, random.nextInt(300));
      agrees(Document.of(Items.of(text)), text, 'seed $seed');
    }
  });

  test('every version of edited documents measures right, over 50 seeds', () {
    for (var seed = 0; seed < 50; seed++) {
      final random = Random(seed);
      var text = points(random, random.nextInt(200));
      var document = Document.of(Items.of(text));
      final versions = [(document, text)];
      for (var round = 0; round < 30; round++) {
        final start = random.nextInt(text.length + 1);
        final length = random.nextInt(text.length - start + 1);
        final added = points(random, random.nextInt(80));
        final Command<int> command = switch (random.nextInt(3)) {
          0 => Insert(start, Items.of(added)),
          1 => Delete(span(start, length)),
          _ => Replace(span(start, length), Items.of(added)),
        };
        document = document.apply(command).unwrap();
        text = document.items.toList();
        versions.add((document, text));
        // Query some versions as they are made, so later edits share
        // measured nodes with them.
        if (random.nextBool()) {
          agrees(document, text, 'seed $seed round $round');
        }
      }
      for (final (index, (version, items)) in versions.indexed) {
        agrees(version, items, 'seed $seed version $index');
      }
    }
  });
}
