/// Timing tests for the selector module, run on demand with
/// `dart test --tags benchmark --run-skipped test/selector`.
@Tags(['benchmark'])
library;

import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/selector/selector.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// [time] microseconds as milliseconds.
String ms(int time) => '${(time / 1000).toStringAsFixed(1)}ms';

/// Microseconds, the median of seven runs, to select with [source] from
/// [count] nested and crossing ranges.
int time(String source, int count) {
  final random = Random(count);
  final scope = <(int, ARange)>[
    for (var index = 0; index < count; index++)
      (index, tagged(random.nextInt(count), 1 + random.nextInt(64))),
  ];
  final selector = Selector.parse(source).unwrap();
  final times = <int>[];
  for (var round = 0; round < 7; round++) {
    final watch = Stopwatch()..start();
    selector.select(scope);
    times.add(watch.elapsedMicroseconds);
  }
  return (times..sort())[times.length ~/ 2];
}

void main() {
  test('the hierarchy is indexed in time near linear in the ranges', () {
    time(':first-child', 8000);
    final (small, large) = (
      time(':first-child', 8000),
      time(':first-child', 64000),
    );
    print('hierarchy, 8,000: ${ms(small)}, 64,000: ${ms(large)}');
    // n log n is about 10 times; a scan for each parent was about 64.
    expect(large, lessThan(16 * max(200, small)));
  });

  test('a three-term selector takes time near linear in the ranges', () {
    time('* * > *', 8000);
    final (small, large) = (time('* * > *', 8000), time('* * > *', 64000));
    print('three terms, 8,000: ${ms(small)}, 64,000: ${ms(large)}');
    // n log n is about 10 times; scanning ancestors for each range was
    // quadratic.
    expect(large, lessThan(16 * max(200, small)));
  });

  test(':overlaps and :crosses take time near linear in the ranges', () {
    for (final source in [':overlaps(*)', ':crosses(*)']) {
      time(source, 8000);
      final (small, large) = (time(source, 8000), time(source, 64000));
      print('$source, 8,000: ${ms(small)}, 64,000: ${ms(large)}');
      // n log n is about 10 times; testing every pair was quadratic.
      expect(large, lessThan(16 * max(200, small)));
    }
  });

  test('*= takes time linear in the text, whatever the value', () {
    // Microseconds, the median of seven runs, to select with `*=` a value
    // of [part] code points, a run of `a` then `b`, from 200 ranges whose
    // text is [length] code points of `a`: the worst case for a naive
    // search, which backs up at every start.
    int search(int length, int part) {
      final scope = [
        for (var index = 0; index < 200; index++)
          (index, tagged(0, 0, attributes: {'v': Str(Text.of('a' * length))})),
      ];
      final selector = Selector.parse('[v*="${'a' * (part - 1)}b"]').unwrap();
      final times = <int>[];
      for (var round = 0; round < 7; round++) {
        final watch = Stopwatch()..start();
        selector.select(scope);
        times.add(watch.elapsedMicroseconds);
      }
      return (times..sort())[times.length ~/ 2];
    }

    search(1000, 50);
    final base = search(1000, 50);
    final (longer, wider) = (search(8000, 50), search(1000, 400));
    print('*=: base ${ms(base)}, 8x text ${ms(longer)}, 8x value ${ms(wider)}');
    expect(longer, lessThan(16 * max(200, base)));
    // A naive search would take about 8 times as long for 8 times the value.
    expect(wider, lessThan(3 * max(200, base)));
  });

  test(
    'selecting many times over a prepared scope beats building it again',
    () {
      final random = Random(3);
      final keyed = <(int, ARange)>[
        for (var index = 0; index < 8000; index++)
          (index, tagged(random.nextInt(8000), 1 + random.nextInt(64))),
      ];
      final selector = Selector.parse(':first-child').unwrap();
      int run(void Function() select) {
        final times = <int>[];
        for (var round = 0; round < 7; round++) {
          final watch = Stopwatch()..start();
          for (var count = 0; count < 100; count++) {
            select();
          }
          times.add(watch.elapsedMicroseconds);
        }
        return (times..sort())[times.length ~/ 2];
      }

      final scope = Scope(keyed);
      run(() => scope.select(selector));
      final prepared = run(() => scope.select(selector));
      final fresh = run(() => selector.select(keyed));
      print('100 selections: prepared ${ms(prepared)}, fresh ${ms(fresh)}');
      expect(prepared, lessThan(fresh ~/ 2));
    },
  );
}
