import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/range/range.dart';
import 'package:test/test.dart';

import '../support.dart';

void main() {
  group('the application layer from the attributed range algebra paper', () {
    // The P element spans lexical tokens 0 to 3, the I element tokens 1 to 2.
    final ranges = Ranges.of([span(0, 4), span(1, 2)]);

    test('P is the parent of I', () {
      expect(ranges.parent(span(1, 2)), span(0, 4));
    });

    test('I is the only child of P', () {
      expect(ranges.children(span(0, 4)), Ranges.of([span(1, 2)]));
    });

    test('P has no parent', () {
      expect(ranges.parent(span(0, 4)), isNull);
    });

    test('I has no children', () {
      expect(ranges.children(span(1, 2)), Ranges.empty());
    });
  });

  group('overlapping ranges are unrelated', () {
    final a = span(0, 4);
    final b = span(2, 4);
    final ranges = Ranges.of([a, b]);

    test('neither is an ancestor or descendant of the other', () {
      expect(ranges.ancestors(a), Ranges.empty());
      expect(ranges.ancestors(b), Ranges.empty());
      expect(ranges.descendants(a), Ranges.empty());
      expect(ranges.descendants(b), Ranges.empty());
    });

    test('neither is a parent or child of the other', () {
      expect(ranges.parent(a), isNull);
      expect(ranges.parent(b), isNull);
      expect(ranges.children(a), Ranges.empty());
      expect(ranges.children(b), Ranges.empty());
    });
  });

  group('three nested ranges', () {
    final outer = span(0, 10);
    final middle = span(2, 6);
    final inner = span(3, 2);
    final ranges = Ranges.of([inner, outer, middle]);

    test('ancestors are every containing range, in sequence order', () {
      expect(ranges.ancestors(inner), Ranges.of([outer, middle]));
    });

    test('descendants are every contained range, in sequence order', () {
      expect(ranges.descendants(outer), Ranges.of([inner, middle]));
    });

    test('parent is the innermost ancestor', () {
      expect(ranges.parent(inner), middle);
      expect(ranges.parent(middle), outer);
    });

    test('children exclude grandchildren', () {
      expect(ranges.children(outer), Ranges.of([middle]));
      expect(ranges.children(middle), Ranges.of([inner]));
    });
  });

  group('tie-breaks and identity', () {
    test('ancestors with the same start: the shorter is the parent', () {
      final ranges = Ranges.of([span(2, 6), span(2, 4)]);
      expect(ranges.parent(span(3, 1)), span(2, 4));
    });

    test('overlapping ancestors: the later start is the parent', () {
      final ranges = Ranges.of([span(0, 6), span(2, 6)]);
      expect(ranges.parent(span(3, 2)), span(2, 6));
    });

    test('a range is never its own ancestor or descendant', () {
      final ranges = Ranges.of([span(3, 2), span(3, 2), span(0, 9)]);
      expect(ranges.ancestors(span(3, 2)), Ranges.of([span(0, 9)]));
      expect(ranges.descendants(span(3, 2)), Ranges.empty());
      expect(ranges.parent(span(3, 2)), span(0, 9));
    });

    test('duplicate ranges are siblings under the same parent', () {
      final ranges = Ranges.of([span(3, 2), span(3, 2), span(0, 9)]);
      expect(ranges.children(span(0, 9)), Ranges.of([span(3, 2), span(3, 2)]));
    });

    test('of unequal ranges at one position, only the first has children', () {
      final first = tagged(0, 9, attributes: {'n': Num(1)});
      final second = tagged(0, 9, attributes: {'n': Num(2)});
      final ranges = Ranges.of([first, second, span(3, 2)]);
      expect(ranges.parent(span(3, 2)), first);
      expect(ranges.children(first), Ranges.of([span(3, 2)]));
      expect(ranges.children(second), Ranges.empty());
      // A plain range never equals an attributed one at its position.
      expect(ranges.children(span(0, 9)), Ranges.empty());
    });

    test('a zero-length range inside another is its descendant', () {
      final ranges = Ranges.of([span(4, 4), span(4, 0)]);
      expect(ranges.descendants(span(4, 4)), Ranges.of([span(4, 0)]));
      expect(ranges.parent(span(4, 0)), span(4, 4));
    });

    test('queries work for a range not in the sequence', () {
      final ranges = Ranges.of([span(0, 9), span(5, 1)]);
      expect(ranges.parent(span(4, 3)), span(0, 9));
      expect(ranges.descendants(span(4, 3)), Ranges.of([span(5, 1)]));
    });

    test('empty sequence answers every query with nothing', () {
      final ranges = Ranges.empty();
      expect(ranges.ancestors(span(0, 1)), Ranges.empty());
      expect(ranges.descendants(span(0, 1)), Ranges.empty());
      expect(ranges.parent(span(0, 1)), isNull);
      expect(ranges.children(span(0, 1)), Ranges.empty());
    });
  });

  test('parent and children agree with their definitions over 200 seeds', () {
    final random = Random(42);
    for (var round = 0; round < 200; round++) {
      // Plain and attributed ranges, so unequal ranges share positions.
      final list = List.generate(random.nextInt(12), (_) {
        final (start, length) = (random.nextInt(10), random.nextInt(8));
        return switch (random.nextInt(3)) {
          0 => span(start, length),
          final n => tagged(start, length, attributes: {'n': Num(n)}),
        };
      });
      final ranges = Ranges.of(list);
      // The innermost ancestor, straight from the paper's definition.
      Range? expected(Range range) {
        Range? best;
        for (final item in list) {
          if (!item.contains(range) || item.same(range)) {
            continue;
          }
          if (best == null ||
              item.start > best.start ||
              item.start == best.start && item.length < best.length) {
            best = item;
          }
        }
        return best;
      }

      for (final range in [...list, span(3, 2), span(0, 0), tagged(3, 2)]) {
        expect(ranges.parent(range), expected(range), reason: '$list $range');
        expect(
          ranges.children(range),
          Ranges.of([
            for (final item in list)
              if (expected(item) == range) item,
          ]),
          reason: '$list $range',
        );
      }
    }
  });
}
