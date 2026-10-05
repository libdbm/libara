/// Timing tests for the coordinate module, run on demand with
/// `dart test --tags benchmark --run-skipped test/coordinate`.
@Tags(['benchmark'])
library;

import 'dart:math';

import 'package:libara/src/coordinate/coordinate.dart';
import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import 'model.dart';

/// Microseconds, the median of seven runs of [run].
int time(void Function() run) {
  final times = <int>[];
  for (var round = 0; round < 7; round++) {
    final watch = Stopwatch()..start();
    run();
    times.add(watch.elapsedMicroseconds);
  }
  return (times..sort())[times.length ~/ 2];
}

/// A document of [count] random code points with every line end.
Document<int> document(int count) =>
    Document.of(Items.of(points(Random(count), count)));

void main() {
  test('queries grow with the items no faster than item lookups do', () {
    // Microseconds for 10,000 conversions and for 10,000 item lookups at
    // the same positions of one document of [count] items.
    (int, int) queries(int count) {
      final text = document(count);
      final coordinates = Coordinates.of(text);
      final random = Random(1);
      final positions = [
        for (var index = 0; index < 10000; index++) random.nextInt(count + 1),
      ];
      coordinates.unit(0);
      return (
        time(() {
          for (final position in positions) {
            coordinates.place(position, columns: Columns.points);
          }
        }),
        time(() {
          for (final position in positions) {
            text.item(position);
          }
        }),
      );
    }

    queries(100000);
    final (small, smallItems) = queries(100000);
    final (large, largeItems) = queries(800000);
    print(
      '10,000 places, 100,000 items: ${small}us, 800,000: ${large}us; '
      'item lookups ${smallItems}us and ${largeItems}us',
    );
    // A descent of a tree 8 times larger costs a few more levels and more
    // cache misses; conversions are a few descents, so they grow as an
    // item lookup does. Linear growth would be 8 times.
    final growth = large / max(1000, small);
    final items = largeItems / max(100, smallItems);
    expect(growth, lessThan(1.5 * max(1, items)));
  });

  test("a fresh document's first query takes time linear in the items", () {
    int first(int count) {
      final documents = [
        for (var round = 0; round < 7; round++) document(count),
      ];
      var round = 0;
      return time(() => Coordinates.of(documents[round++]).unit(count));
    }

    first(100000);
    final (small, large) = (first(100000), first(800000));
    print('first query, 100,000 items: ${small}us, 800,000: ${large}us');
    // Linear is 8 times.
    expect(large, lessThan(16 * max(200, small)));
  });
}
