/// Timing tests for the range module, run on demand with
/// `dart test --tags benchmark --run-skipped test/range`.
@Tags(['benchmark'])
library;

import 'dart:math';

import 'package:libara/src/range/range.dart';
import 'package:test/test.dart';

import '../support.dart';

/// [time] microseconds as milliseconds.
String ms(int time) => '${(time / 1000).toStringAsFixed(1)}ms';

/// Microseconds, the median of seven runs, to ask a new sequence of
/// [count] nested and crossing ranges for the children of each of them.
int time(int count) {
  final random = Random(count);
  final list = [
    for (var index = 0; index < count; index++)
      span(random.nextInt(count), 1 + random.nextInt(64)),
  ];
  final times = <int>[];
  for (var round = 0; round < 7; round++) {
    final watch = Stopwatch()..start();
    final ranges = Ranges.of(list);
    for (final range in list) {
      ranges.children(range);
    }
    times.add(watch.elapsedMicroseconds);
  }
  return (times..sort())[times.length ~/ 2];
}

void main() {
  test('walking a whole tree takes time near linear in the ranges', () {
    time(8000);
    final (small, large) = (time(8000), time(64000));
    print('children of every range, 8,000: ${ms(small)}, 64,000: ${ms(large)}');
    // n log n is about 10 times; a parent scan for each descendant was
    // quadratic per call.
    expect(large, lessThan(16 * max(200, small)));
  });
}
