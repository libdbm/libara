import 'dart:math';

import 'package:libara/src/coordinate/coordinate.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'model.dart';

/// Each line of [points] as `(start, end)`, its end excluded, splitting on
/// the six line ends `Coordinates` recognizes.
List<(int, int)> split(List<int> points) {
  final lines = <(int, int)>[];
  var start = 0;
  var index = 0;
  while (index < points.length) {
    final point = points[index];
    if (point == 0x0D &&
        index + 1 < points.length &&
        points[index + 1] == 0x0A) {
      lines.add((start, index));
      index += 2;
      start = index;
    } else if (const [0x0A, 0x0D, 0x85, 0x2028, 0x2029].contains(point)) {
      lines.add((start, index));
      index++;
      start = index;
    } else {
      index++;
    }
  }
  return [...lines, (start, points.length)];
}

/// Expects every position and line of [points] to convert as the model
/// splits them, in both column units, and to round-trip.
void agrees(Coordinates coordinates, List<int> points, String reason) {
  final lines = split(points);
  expect(coordinates.lines, lines.length, reason: reason);
  for (final (index, (start, end)) in lines.indexed) {
    final range = coordinates.line(index).unwrap();
    expect((range.start, range.end), (start, end), reason: reason);
    for (var position = start; position <= end; position++) {
      final inPoints = Place(index, position - start);
      final inUnits = Place(
        index,
        units(points, position) - units(points, start),
      );
      expect(
        coordinates.place(position, columns: Columns.points).unwrap(),
        inPoints,
        reason: '$reason $position',
      );
      expect(coordinates.place(position).unwrap(), inUnits, reason: reason);
      expect(
        coordinates.locate(inPoints, columns: Columns.points).unwrap(),
        position,
        reason: reason,
      );
      expect(coordinates.locate(inUnits).unwrap(), position, reason: reason);
    }
  }
  for (var position = 1; position < points.length; position++) {
    if (points[position - 1] == 0x0D && points[position] == 0x0A) {
      expect(
        coordinates.place(position),
        isA<Failure<Place>>(),
        reason: reason,
      );
    }
  }
}

/// Expects [result] to be a failure of [kind] whose message holds [text].
void fails(Result<Object?> result, Kind kind, String text) {
  expect(result, isA<Failure<Object?>>());
  final failure = result as Failure<Object?>;
  expect(failure.kind, kind);
  expect(failure.message, contains(text));
}

void main() {
  test('a😀b\\r\\nc has lines and columns as the spec says', () {
    final coordinates = Coordinates.of(Text.of('a😀b\r\nc'));
    expect(coordinates.place(5).unwrap(), const Place(1, 0));
    expect(
      coordinates.place(5, columns: Columns.points).unwrap(),
      const Place(1, 0),
    );
    fails(coordinates.place(4), Kind.invalid, 'inside a line end');
    expect(coordinates.place(2).unwrap(), const Place(0, 3));
    expect(
      coordinates.place(2, columns: Columns.points).unwrap(),
      const Place(0, 2),
    );
    fails(
      coordinates.locate(const Place(0, 2)),
      Kind.invalid,
      'inside the pair at position 1',
    );
  });

  test('x\\u2028y puts y on line 1', () {
    final coordinates = Coordinates.of(Text.of('x y'));
    expect(coordinates.lines, 2);
    expect(coordinates.place(2).unwrap(), const Place(1, 0));
  });

  test('every line end ends a line', () {
    final coordinates = Coordinates.of(Text.of('a\nb\rc\r\nd\u0085e f g'));
    expect(coordinates.lines, 7);
    expect(
      [
        for (var line = 0; line < 7; line++)
          coordinates.line(line).unwrap().start,
      ],
      [0, 2, 4, 7, 9, 11, 13],
    );
  });

  test('lines and columns out of range are out of bounds', () {
    final coordinates = Coordinates.of(Text.of('ab\ncd'));
    fails(coordinates.place(6), Kind.bounds, 'position 6');
    fails(coordinates.place(-1), Kind.bounds, 'position -1');
    fails(coordinates.line(2), Kind.bounds, 'line 2 is outside 0..1');
    fails(coordinates.line(-1), Kind.bounds, 'line -1');
    fails(
      coordinates.locate(const Place(0, 3)),
      Kind.bounds,
      'column 3 is outside 0..2 of line 0',
    );
    fails(
      coordinates.locate(const Place(1, -1), columns: Columns.points),
      Kind.bounds,
      'column -1',
    );
    fails(coordinates.locate(const Place(5, 0)), Kind.bounds, 'line 5');
  });

  test('random texts agree with the model, over 200 seeds', () {
    for (var seed = 0; seed < 200; seed++) {
      final random = Random(seed);
      final text = points(random, random.nextInt(200));
      agrees(Coordinates.of(Items.of(text)), text, 'seed $seed');
    }
  });

  test('every version of edited documents agrees, over 50 seeds', () {
    for (var seed = 0; seed < 50; seed++) {
      for (final (index, version) in versions(Random(seed), 120, 20).indexed) {
        agrees(
          Coordinates.of(version),
          version.items.toList(),
          'seed $seed version $index',
        );
      }
    }
  });
}
