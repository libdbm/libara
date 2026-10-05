@Tags(['benchmark'])
library;

import 'dart:math';

import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart';
import 'package:libara/src/persistent/edits.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

void main() {
  test('one insert at the front of 100,000 items and 10,000 ranges', () {
    var document = Document.of(
      Items.of(List.generate(100000, (index) => index)),
    );
    for (var index = 0; index < 10000; index++) {
      final start = index * 10;
      document = document
          .apply(Mark<int>(tagged(start, 5 + index % 20)))
          .or(document);
    }
    final base = document;
    final command = Insert(0, Items.of([-1]));

    // Warm up, then time each insert from the same base version.
    for (var round = 0; round < 200; round++) {
      base.apply(command);
    }
    final watch = Stopwatch();
    final times = <int>[];
    for (var round = 0; round < 200; round++) {
      watch
        ..reset()
        ..start();
      base.apply(command);
      watch.stop();
      times.add(watch.elapsedMicroseconds);
    }
    times.sort();
    final median = times[times.length ~/ 2];
    // Printed so the measurement is visible when the benchmark is run.
    print(
      'median ${median}us, slowest ${times.last}us over ${times.length} inserts',
    );
    expect(median, lessThan(1000));

    // The ranges really did move.
    final moved = base.apply(command).or(base);
    expect(moved.ranges.items.first.start, 1);
  });

  test('coalescing edits costs about the same per edit at any group size', () {
    /// Milliseconds to coalesce [count] single-item inserts into one version.
    int time(int count) {
      var document = Document<int>.empty();
      final watch = Stopwatch()..start();
      for (var index = 0; index < count; index++) {
        document = document
            .apply(Insert(index, Items.of([index])), flatten: true)
            .unwrap();
      }
      watch.stop();
      expect(document.commands.length, count);
      return watch.elapsedMilliseconds;
    }

    // Warm up, then compare a group four times as large.
    time(4000);
    final small = time(4000);
    final large = time(16000);
    print('coalesced 4,000 inserts in ${small}ms, 16,000 in ${large}ms');
    // Copying the command list on every edit makes this about 16 times.
    expect(large, lessThan(8 * max(1, small)));
  });

  test('queries with no hits skip endpoints that are not starts', () {
    // Zero-length ranges at 1 with a left end: an insertion at 1 moves the
    // starts to 11 and leaves the ends at 1, so they read as empty at 11
    // while their ends sit inside a query over [0, 2).
    Document<int> inverted(int count) {
      final document = Document.of(Items.of(List.filled(20, 0))).transact([
        for (var index = 0; index < count; index++)
          Mark<int>(tagged(1, 0), end: Gravity.left),
      ]).unwrap();
      return document.apply(Insert(1, Items.of(List.filled(10, 1)))).unwrap();
    }

    /// Microseconds per call of [query], over 50 calls after 10 of warm-up.
    double time(void Function() query) {
      for (var round = 0; round < 10; round++) {
        query();
      }
      final watch = Stopwatch()..start();
      for (var round = 0; round < 50; round++) {
        query();
      }
      return watch.elapsedMicroseconds / 50;
    }

    final region = span(0, 2);
    final (small, large) = (inverted(1000), inverted(100000));
    expect(large.overlapping(region).items, isEmpty);
    expect(large.within(region), isEmpty);
    final overlapping = (
      time(() => small.overlapping(region)),
      time(() => large.overlapping(region)),
    );
    final within = (
      time(() => small.within(region)),
      time(() => large.within(region)),
    );
    // Printed to record the cost.
    print(
      'no hits, 1,000 and 100,000 markers: overlapping '
      '${overlapping.$1}us and ${overlapping.$2}us, within '
      '${within.$1}us and ${within.$2}us',
    );
    // Visiting every end inside the query made it about 100 times.
    expect(overlapping.$2, lessThan(10 * max(1, overlapping.$1)));
    expect(within.$2, lessThan(10 * max(1, within.$1)));
  });

  test('edits of a few changes take time linear in the items', () {
    // Microseconds, the median of seven runs, for edits between [count]
    // items and a copy with three items changed far from either end.
    int time(int count) {
      final from = List.generate(count, (index) => index % 1000);
      final to = [...from];
      for (final at in [count ~/ 4, count ~/ 2, 3 * count ~/ 4]) {
        to[at] = -1;
      }
      final (a, b) = (Items.of(from), Items.of(to));
      final times = <int>[];
      for (var round = 0; round < 7; round++) {
        final watch = Stopwatch()..start();
        edits(a, b);
        times.add(watch.elapsedMicroseconds);
      }
      return (times..sort())[times.length ~/ 2];
    }

    time(100000);
    final (small, large) = (time(100000), time(800000));
    print('edits, 100,000 items: ${small}us, 800,000: ${large}us');
    // Linear is 8 times; a quadratic comparison would be 64.
    expect(large, lessThan(12 * max(200, small)));
  });
}
