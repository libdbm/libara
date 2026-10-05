import 'dart:math';

import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// Between 40 and 80 ranges over a small key space, so that equal sort keys
/// are common and the list is long enough for Dart's sort to leave its
/// stable insertion-sort path.
List<Range> sample(Random random) => List.generate(
  40 + random.nextInt(41),
  (_) => span(random.nextInt(5), random.nextInt(4)),
);

/// Whether every group of equal ranges in [sorted] appears in the same
/// relative order, by identity, as in [source].
bool stable(List<Range> source, Iterable<Range> sorted) {
  for (final range in source.toSet()) {
    final before = source.where((item) => item == range).toList();
    final after = sorted.where((item) => item == range).toList();
    for (var index = 0; index < before.length; index++) {
      if (!identical(before[index], after[index])) {
        return false;
      }
    }
  }
  return true;
}

void main() {
  group('Ranges as a sequence', () {
    test('of and empty', () {
      expect(Ranges.of([span(0, 1)]).length, 1);
      expect(Ranges.empty().empty, isTrue);
    });

    test('equals items with the same ranges', () {
      expect(Ranges.of([span(0, 1)]), Items.of([span(0, 1)]));
    });

    test('every sequence operation returns Ranges', () {
      final ranges = Ranges.of([span(0, 1), span(2, 1)]);
      final other = Ranges.of([span(2, 1), span(5, 1)]);
      expect(ranges.slice(0, 1), isA<Ranges>());
      expect(ranges.concat(other).or(Ranges.empty()), isA<Ranges>());
      expect(ranges.diff(other), isA<Ranges>());
      expect(ranges.union(other).or(Ranges.empty()), isA<Ranges>());
      expect(ranges.intersect(other), isA<Ranges>());
      expect(ranges.insert(0, span(9, 1)).or(Ranges.empty()), isA<Ranges>());
      expect(ranges.delete(0).or(Ranges.empty()), isA<Ranges>());
    });

    test('a slice cannot be changed through its items', () {
      final slice = Ranges.of([span(0, 1), span(2, 1)]).slice(0, 1);
      expect(
        () => (slice.items as List<Range>)[0] = span(5, 5),
        throwsUnsupportedError,
      );
      expect(slice, Ranges.of([span(0, 1)]));
    });

    test('edits and set operations delegate correctly', () {
      final ranges = Ranges.of([span(0, 1), span(2, 1)]);
      final other = Ranges.of([span(2, 1), span(5, 1)]);
      expect(ranges.concat(other).or(Ranges.empty()).length, 4);
      expect(ranges.diff(other), Ranges.of([span(0, 1)]));
      expect(
        ranges.union(other),
        Success(Ranges.of([span(0, 1), span(2, 1), span(5, 1)])),
      );
      expect(ranges.intersect(other), Ranges.of([span(2, 1)]));
      expect(ranges.item(1), span(2, 1));
      expect(ranges.insert(3, span(9, 1)), Failure<Ranges>.bounds('insert', 3));
      expect(ranges.delete(0), Success(Ranges.of([span(2, 1)])));
    });
  });

  group('startOrder', () {
    test('sorts by start, then by length', () {
      final ranges = Ranges.of([
        span(4, 2),
        span(1, 5),
        span(4, 1),
        span(0, 9),
      ]);
      expect(
        ranges.startOrder(),
        Ranges.of([span(0, 9), span(1, 5), span(4, 1), span(4, 2)]),
      );
    });

    test('empty stays empty', () {
      expect(Ranges.empty().startOrder(), Ranges.empty());
    });
  });

  group('endOrder', () {
    test('sorts by end, then by length', () {
      final ranges = Ranges.of([
        span(0, 5),
        span(4, 1),
        span(3, 2),
        span(1, 2),
      ]);
      // Ends: 5, 5, 5, 3. Among end 5, lengths 1, 2, 5.
      expect(
        ranges.endOrder(),
        Ranges.of([span(1, 2), span(4, 1), span(3, 2), span(0, 5)]),
      );
    });

    test('empty stays empty', () {
      expect(Ranges.empty().endOrder(), Ranges.empty());
    });
  });

  group('unique', () {
    test('keeps the first occurrence of each range, in order', () {
      final first = span(2, 1);
      final ranges = Ranges.of([first, span(0, 1), span(2, 1), span(0, 1)]);
      final unique = ranges.unique();
      expect(unique, Ranges.of([span(2, 1), span(0, 1)]));
      expect(identical(unique.item(0), first), isTrue);
    });

    test('empty stays empty', () {
      expect(Ranges.empty().unique(), Ranges.empty());
    });
  });

  group('ordering laws over 200 seeded samples', () {
    test('startOrder is sorted, stable, and idempotent', () {
      final random = Random(42);
      for (var round = 0; round < 200; round++) {
        final source = sample(random);
        final sorted = Ranges.of(source).startOrder();
        final list = sorted.items.toList();
        for (var index = 1; index < list.length; index++) {
          final previous = list[index - 1];
          final current = list[index];
          expect(
            previous.start < current.start ||
                previous.start == current.start &&
                    previous.length <= current.length,
            isTrue,
            reason: 'round $round at $index: $previous then $current',
          );
        }
        expect(stable(source, list), isTrue, reason: 'round $round');
        expect(sorted.startOrder(), sorted, reason: 'round $round');
        expect(stable(list, sorted.startOrder().items), isTrue);
      }
    });

    test('endOrder is sorted, stable, and idempotent', () {
      final random = Random(7);
      for (var round = 0; round < 200; round++) {
        final source = sample(random);
        final sorted = Ranges.of(source).endOrder();
        final list = sorted.items.toList();
        for (var index = 1; index < list.length; index++) {
          final previous = list[index - 1];
          final current = list[index];
          expect(
            previous.end < current.end ||
                previous.end == current.end &&
                    previous.length <= current.length,
            isTrue,
            reason: 'round $round at $index: $previous then $current',
          );
        }
        expect(stable(source, list), isTrue, reason: 'round $round');
        expect(sorted.endOrder(), sorted, reason: 'round $round');
        expect(stable(list, sorted.endOrder().items), isTrue);
      }
    });
  });
}
