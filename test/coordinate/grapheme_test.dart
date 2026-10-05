import 'dart:math';

import 'package:characters/characters.dart';
import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/constructor/constructor.dart';
import 'package:libara/src/coordinate/coordinate.dart';
import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// Code points that build interesting clusters: letters, a combining
/// mark, emoji with a joiner and a skin tone, regional indicators, Hangul
/// jamo, lone surrogates, and line ends.
const alphabet = [
  0x61,
  0x20,
  0x0301,
  0x1F468,
  0x200D,
  0x1F469,
  0x1F3FD,
  0x1F1EB,
  0x1F1F7,
  0x1100,
  0x1161,
  0x11A8,
  0xD800,
  0xDC00,
  0x0A,
  0x0D,
  0x2028,
];

/// The cluster boundaries of [points], segmenting the whole text at once
/// rather than line by line: the model that segmenting by line must agree
/// with.
List<int> boundaries(List<int> points) {
  final boundaries = [0];
  var index = 0;
  for (final cluster in String.fromCharCodes(points).characters) {
    var units = cluster.length;
    while (units > 0) {
      units -= points[index] > 0xFFFF ? 2 : 1;
      index++;
    }
    boundaries.add(index);
  }
  return boundaries;
}

/// Expects every position of [coordinates] over [points] to agree with
/// the model.
void agrees(Coordinates coordinates, List<int> points, String reason) {
  final expected = boundaries(points);
  for (var position = 0; position <= points.length; position++) {
    expect(
      coordinates.boundary(position).unwrap(),
      expected.contains(position),
      reason: '$reason $position',
    );
    if (position < points.length) {
      final next = expected.firstWhere((at) => at > position);
      final start = expected.lastWhere((at) => at <= position);
      expect(coordinates.next(position).unwrap(), next, reason: reason);
      final cluster = coordinates.cluster(position).unwrap();
      expect((cluster.start, cluster.end), (start, next), reason: reason);
    }
    if (position > 0) {
      expect(
        coordinates.previous(position).unwrap(),
        expected.lastWhere((at) => at < position),
        reason: reason,
      );
    }
  }
}

void main() {
  test('e and a combining acute are one cluster', () {
    final coordinates = Coordinates.of(Text.of('éx'));
    expect(
      [for (var at = 0; at <= 3; at++) coordinates.boundary(at).unwrap()],
      [true, false, true, true],
    );
    expect(coordinates.next(0).unwrap(), 2);
    final cluster = coordinates.cluster(1).unwrap();
    expect((cluster.start, cluster.end), (0, 2));
  });

  test('a family emoji is one cluster of five code points', () {
    final coordinates = Coordinates.of(Text.of('👨‍👩‍👧!'));
    expect(coordinates.length, 6);
    expect(coordinates.next(0).unwrap(), 5);
    expect(coordinates.previous(6).unwrap(), 5);
    expect(coordinates.previous(5).unwrap(), 0);
  });

  test('a carriage return and line feed are one cluster', () {
    final coordinates = Coordinates.of(Text.of('a\r\nb'));
    expect(coordinates.boundary(2).unwrap(), isFalse);
    expect(coordinates.next(1).unwrap(), 3);
    final cluster = coordinates.cluster(2).unwrap();
    expect((cluster.start, cluster.end), (1, 3));
    expect(coordinates.previous(3).unwrap(), 1);
  });

  test('a lone high and low surrogate fall in one cluster', () {
    final coordinates = Coordinates.of(Items.of([0x61, 0xD800, 0xDC00, 0x62]));
    expect(coordinates.boundary(2).unwrap(), isFalse);
    expect(coordinates.next(1).unwrap(), 3);
  });

  test('positions out of range are out of bounds', () {
    final coordinates = Coordinates.of(Text.of('ab'));
    for (final result in [
      coordinates.boundary(-1),
      coordinates.boundary(3),
      coordinates.next(2),
      coordinates.next(-1),
      coordinates.previous(0),
      coordinates.previous(3),
      coordinates.cluster(2),
    ]) {
      expect(result, isA<Failure<Object>>());
      expect((result as Failure<Object>).kind, Kind.bounds);
    }
    expect(Coordinates.of(Text.of('')).boundary(0).unwrap(), isTrue);
  });

  test('random texts agree with segmenting them whole, over 300 seeds', () {
    for (var seed = 0; seed < 300; seed++) {
      final random = Random(seed);
      final points = [
        for (var index = 0; index < random.nextInt(60); index++)
          alphabet[random.nextInt(alphabet.length)],
      ];
      agrees(Coordinates.of(Items.of(points)), points, 'seed $seed');
    }
  });

  test('every version of edited documents agrees, over 50 seeds', () {
    for (var seed = 0; seed < 50; seed++) {
      final random = Random(seed);
      List<int> points(int count) => [
        for (var index = 0; index < count; index++)
          alphabet[random.nextInt(alphabet.length)],
      ];
      var document = Document.of(Items.of(points(random.nextInt(80))));
      for (var round = 0; round < 15; round++) {
        final start = random.nextInt(document.length + 1);
        final size = random.nextInt(document.length - start + 1);
        document = document
            .apply(
              Replace(span(start, size), Items.of(points(random.nextInt(8)))),
            )
            .unwrap();
        agrees(
          Coordinates.of(document),
          document.items.toList(),
          'seed $seed round $round',
        );
      }
    }
  });

  group('grapheme columns, count, and snapping', () {
    test('the family emoji is one column', () {
      final coordinates = Coordinates.of(Text.of('👨‍👩‍👧!'));
      expect(
        coordinates.place(5, columns: Columns.graphemes).unwrap(),
        const Place(0, 1),
      );
      final inside = coordinates.place(2, columns: Columns.graphemes);
      expect((inside as Failure<Place>).kind, Kind.invalid);
      expect(
        coordinates
            .locate(const Place(0, 1), columns: Columns.graphemes)
            .unwrap(),
        5,
      );
      final past = coordinates.locate(
        const Place(0, 3),
        columns: Columns.graphemes,
      );
      expect((past as Failure<int>).kind, Kind.bounds);
      expect(coordinates.graphemes, 2);
    });

    test('snapping widens to clusters and keeps attributes', () {
      final coordinates = Coordinates.of(Text.of('🇫🇷🇩🇪'));
      final range = coordinates.snap(span(1, 2)).unwrap();
      expect((range.start, range.end), (0, 4));
      final half = coordinates.snap(span(1, 1)).unwrap();
      expect((half.start, half.end), (0, 2));
      final attributed = coordinates
          .snap(tagged(1, 2, attributes: {'n': const Num(1)}))
          .unwrap();
      expect(attributed.attributes, {'n': const Num(1)});
      expect((attributed.start, attributed.end), (0, 4));
      final empty = coordinates.snap(span(1, 0)).unwrap();
      expect((empty.start, empty.length), (0, 0));
      final past = coordinates.snap(span(3, 2));
      expect((past as Failure<Range>).kind, Kind.bounds);
      final other = coordinates.snap(_Other());
      expect((other as Failure<Range>).kind, Kind.invalid);
    });

    test('random texts snap, count, and place as the model says, '
        'over 300 seeds', () {
      for (var seed = 0; seed < 300; seed++) {
        final random = Random(seed);
        final points = [
          for (var index = 0; index < random.nextInt(50); index++)
            alphabet[random.nextInt(alphabet.length)],
        ];
        final expected = boundaries(points);
        final coordinates = Coordinates.of(Items.of(points));
        expect(coordinates.graphemes, expected.length - 1, reason: '$seed');
        for (var round = 0; round < 10; round++) {
          final start = random.nextInt(points.length + 1);
          final size = random.nextInt(points.length - start + 1);
          final range = coordinates.snap(span(start, size)).unwrap();
          final from = expected.lastWhere((at) => at <= start);
          final to = size == 0
              ? from
              : expected.firstWhere((at) => at >= start + size);
          expect((range.start, range.end), (from, to), reason: '$seed');
        }
        for (final position in expected) {
          final place = coordinates.place(position, columns: Columns.graphemes);
          if (place case Success(:final value)) {
            expect(
              coordinates.locate(value, columns: Columns.graphemes).unwrap(),
              position,
              reason: '$seed $position',
            );
          }
        }
      }
    });

    test('snapped regex matches never split a cluster', () {
      final constructor = snapped(regex(RegExp('.', unicode: true)));
      for (var seed = 0; seed < 100; seed++) {
        final random = Random(seed);
        final points = [
          for (var index = 0; index < random.nextInt(50); index++)
            alphabet[random.nextInt(alphabet.length)],
        ];
        final expected = boundaries(points).toSet();
        for (final range in constructor(Items.of(points)).unwrap().items) {
          expect(expected.contains(range.start), isTrue, reason: '$seed');
          expect(expected.contains(range.end), isTrue, reason: '$seed');
        }
      }
      // An inner constructor that accepts anything: snapped still checks.
      final invalid = snapped((input) => Success(Ranges.of([span(0, 1)])))(
        Items.of([0x110000]),
      );
      expect((invalid as Failure<Ranges>).kind, Kind.invalid);
      // A range past the input cannot be snapped.
      final past = snapped((input) => Success(Ranges.of([span(0, 5)])))(
        Text.of('ab'),
      );
      expect((past as Failure<Ranges>).kind, Kind.bounds);
    });
  });
}

/// A range of a type the module cannot build again.
final class _Other extends Range {
  @override
  int get start => 0;

  @override
  int get length => 1;
}
