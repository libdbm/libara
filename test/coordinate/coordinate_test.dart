import 'dart:math';

import 'package:libara/src/coordinate/coordinate.dart';
import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'model.dart';

/// Expects [result] to be a failure of [kind] whose message holds [text].
void fails(Result<Object?> result, Kind kind, String text) {
  expect(result, isA<Failure<Object?>>());
  final failure = result as Failure<Object?>;
  expect(failure.kind, kind);
  expect(failure.message, contains(text));
}

/// Expects [coordinates] to convert every position and unit of [points]
/// as the string model does, and to round-trip.
void agrees(Coordinates coordinates, List<int> points, String reason) {
  expect(coordinates.length, points.length, reason: reason);
  expect(coordinates.units, Unit(units(points, points.length)), reason: reason);
  for (var position = 0; position <= points.length; position++) {
    final unit = coordinates.unit(position).unwrap();
    expect(unit, Unit(units(points, position)), reason: reason);
    expect(coordinates.point(unit).unwrap(), position, reason: reason);
    if (position < points.length && points[position] > 0xFFFF) {
      expect(
        coordinates.point(Unit(unit.offset + 1)),
        isA<Failure<int>>(),
        reason: reason,
      );
    }
  }
}

void main() {
  test('a😀b\\r\\nc converts as the spec says', () {
    final coordinates = Coordinates.of(Text.of('a😀b\r\nc'));
    expect(coordinates.length, 6);
    expect(coordinates.units, const Unit(7));
    expect(coordinates.lines, 2);
    expect(coordinates.unit(2).unwrap(), const Unit(3));
    fails(coordinates.point(const Unit(2)), Kind.invalid, 'inside the pair');
    expect(coordinates.point(const Unit(3)).unwrap(), 2);
  });

  test('an empty text has one line and no units', () {
    final coordinates = Coordinates.of(Text.of(''));
    expect(coordinates.length, 0);
    expect(coordinates.units, const Unit(0));
    expect(coordinates.lines, 1);
    expect(coordinates.unit(0).unwrap(), const Unit(0));
    expect(coordinates.point(const Unit(0)).unwrap(), 0);
  });

  test('positions and units out of range are out of bounds', () {
    final coordinates = Coordinates.of(Text.of('ab'));
    fails(coordinates.unit(-1), Kind.bounds, 'position -1 is outside 0..2');
    fails(coordinates.unit(3), Kind.bounds, 'position 3');
    fails(coordinates.point(const Unit(-1)), Kind.bounds, 'unit -1');
    fails(coordinates.point(const Unit(3)), Kind.bounds, 'outside 0..2');
  });

  test('a document is used as it is', () {
    final document = Document.of(Text.of('x😀y'));
    expect(Coordinates.of(document).unit(2).unwrap(), const Unit(3));
  });

  test('random texts agree with the string model, over 100 seeds', () {
    for (var seed = 0; seed < 100; seed++) {
      final random = Random(seed);
      final text = points(random, random.nextInt(300));
      agrees(Coordinates.of(Items.of(text)), text, 'seed $seed');
    }
  });

  test('every version of edited documents agrees, over 50 seeds', () {
    for (var seed = 0; seed < 50; seed++) {
      for (final (index, version) in versions(Random(seed), 150, 25).indexed) {
        agrees(
          Coordinates.of(version),
          version.items.toList(),
          'seed $seed version $index',
        );
      }
    }
  });

  test('a place is equal by line and column', () {
    expect(const Place(1, 2), Place(1, 1 + 1));
    expect(const Place(1, 2).hashCode, Place(1, 1 + 1).hashCode);
    expect(const Place(1, 2), isNot(const Place(2, 1)));
    expect(const Place(1, 2).toString(), '1:2');
  });
}
