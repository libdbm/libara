import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart';
import 'package:libara/src/persistent/index.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// [count] random marks over a document of [length] items: shared starts
/// and ends, zero-length ranges, and every pairing of gravities.
List<Mark<int>> marks(Random random, int length, int count) => [
  for (var index = 0; index < count; index++)
    () {
      final start = random.nextInt(length + 1);
      final end = start + random.nextInt(min(4, length - start + 1));
      return Mark<int>(
        tagged(start, end - start, attributes: {'n': Num(index)}),
        start: Gravity.values[random.nextInt(2)],
        end: Gravity.values[random.nextInt(2)],
      );
    }(),
];

/// What [document] says about every one of [marks] and every position, and
/// after [edits], to compare two documents by.
List<Object?> said(Document<int> document, List<Mark<int>> marks) => [
  for (final mark in marks) document.resolve(mark.marker),
  [for (final (marker, _) in document.markers) marker.sequence],
  // Ranges sharing a start come in the order of the tree's shape, which
  // its priorities decide, so they are compared as sets.
  for (var at = 0; at <= document.length; at++)
    [for (final (marker, _) in document.crossing(at)) marker.sequence]..sort(),
];

void main() {
  group('A fresh document with many marks placed at once', () {
    for (var seed = 0; seed < 20; seed++) {
      test('is what marking them and compacting gives, seed $seed', () {
        final random = Random(seed);
        final fresh = Document.of(Items.of(List.generate(40, (at) => at)));
        final placing = marks(random, 40, 2 + random.nextInt(60));
        final direct = placed(fresh, placing).unwrap();
        final compacted = fresh.transact(placing).unwrap().compact();
        expect(direct.version, 0);
        expect(direct.previous, isNull);
        expect(check(direct), isA<Success<void>>());
        expect(said(direct, placing), said(compacted, placing));
        // And they go on alike: an insertion at every endpoint shows the
        // labels and gravities agree, not only the positions.
        var (one, other) = (direct, compacted);
        for (final mark in placing.take(10)) {
          final at = Insert<int>(mark.range.end, Items.of([0]));
          one = one.apply(at).unwrap();
          other = other.apply(at).unwrap();
          expect(said(one, placing), said(other, placing));
        }
      });
    }

    test('one mark, or none, is compacted as before', () {
      final fresh = Document.of(Items.of([1, 2, 3]));
      final one = [Mark<int>(tagged(1, 1))];
      expect(
        said(placed(fresh, one).unwrap(), one),
        said(fresh.transact(one).unwrap().compact(), one),
      );
      expect(placed(fresh, const <Mark<int>>[]).unwrap().markers, isEmpty);
    });

    test('a mark out of bounds fails as transact does', () {
      final fresh = Document.of(Items.of([1]));
      expect(
        placed(fresh, [Mark<int>(tagged(0, 1)), Mark<int>(tagged(1, 5))]),
        isA<Failure<Document<int>>>(),
      );
    });
  });

  group('An index built at once', () {
    test('holds what putting each marker gives', () {
      final random = Random(7);
      final markers = [for (var index = 0; index < 500; index++) Marker()]
        ..shuffle(random);
      var put = const Index<int>.empty();
      for (final (at, marker) in markers.indexed) {
        put = put.put(marker, at);
      }
      final built = Index<int>.of([
        for (final (at, marker) in markers.indexed) (marker, at),
      ]);
      expect(built.length, put.length);
      for (final marker in markers) {
        expect(built.get(marker), put.get(marker));
      }
      expect(built.get(Marker()), isNull);
    });
  });
}
