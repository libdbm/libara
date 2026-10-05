import 'package:libara/src/range/range.dart';
import 'package:test/test.dart';

import '../support.dart';

/// Every fixture is compared as the receiver against [base], which spans
/// positions 4 to 8, end exclusive.
final base = span(4, 4);

final fixtures = {
  'disjoint before': span(0, 2),
  'touching before': span(2, 2),
  'overlapping before': span(2, 4),
  'nested inside': span(5, 2),
  'same': span(4, 4),
  'containing': span(2, 8),
  'same start, longer': span(4, 6),
  'overlapping after': span(6, 4),
  'touching after': span(8, 2),
  'disjoint after': span(10, 2),
  'zero-length at start': span(4, 0),
  'zero-length inside': span(6, 0),
  'zero-length at end': span(8, 0),
};

/// Expected results, written by hand from the formulas `Range` documents.
/// Columns follow [fixtures] order.
const expected = {
  //                     dB     tB     oB     in     same   cont   ssL    oA     tA     dA     z@s    zIn    z@e
  'startsBefore': [
    true,
    true,
    true,
    false,
    false,
    true,
    false,
    false,
    false,
    false,
    false,
    false,
    false,
  ],
  'startsAfter': [
    false,
    false,
    false,
    true,
    false,
    false,
    false,
    true,
    true,
    true,
    false,
    true,
    true,
  ],
  'startsWithin': [
    false,
    false,
    false,
    true,
    true,
    false,
    true,
    true,
    false,
    false,
    true,
    true,
    false,
  ],
  'endsBefore': [
    true,
    true,
    false,
    false,
    false,
    false,
    false,
    false,
    false,
    false,
    true,
    false,
    false,
  ],
  'endsAfter': [
    false,
    false,
    false,
    false,
    false,
    true,
    true,
    true,
    true,
    true,
    false,
    false,
    false,
  ],
  'endsWithin': [
    false,
    false,
    true,
    true,
    true,
    false,
    false,
    false,
    false,
    false,
    false,
    true,
    true,
  ],
  'within': [
    false,
    false,
    false,
    true,
    true,
    false,
    false,
    false,
    false,
    false,
    true,
    true,
    true,
  ],
  'contains': [
    false,
    false,
    false,
    false,
    true,
    true,
    true,
    false,
    false,
    false,
    false,
    false,
    false,
  ],
  'overlaps': [
    false,
    false,
    true,
    true,
    true,
    true,
    true,
    true,
    false,
    false,
    false,
    true,
    false,
  ],
  'same': [
    false,
    false,
    false,
    false,
    true,
    false,
    false,
    false,
    false,
    false,
    false,
    false,
    false,
  ],
};

final predicates = <String, bool Function(Range, Range)>{
  'startsBefore': (a, b) => a.startsBefore(b),
  'startsAfter': (a, b) => a.startsAfter(b),
  'startsWithin': (a, b) => a.startsWithin(b),
  'endsBefore': (a, b) => a.endsBefore(b),
  'endsAfter': (a, b) => a.endsAfter(b),
  'endsWithin': (a, b) => a.endsWithin(b),
  'within': (a, b) => a.within(b),
  'contains': (a, b) => a.contains(b),
  'overlaps': (a, b) => a.overlaps(b),
  'same': (a, b) => a.same(b),
};

void main() {
  group('truth table against {4,4}', () {
    for (final MapEntry(key: name, value: predicate) in predicates.entries) {
      test(name, () {
        final actual = [
          for (final fixture in fixtures.values) predicate(fixture, base),
        ];
        final mismatches = [
          for (final (index, label) in fixtures.keys.indexed)
            if (actual[index] != expected[name]![index])
              '$label ${fixtures[label]}: expected ${expected[name]![index]}',
        ];
        expect(mismatches, isEmpty);
      });
    }
  });

  final all = [base, ...fixtures.values];

  test('within and contains are converses on every pair', () {
    for (final a in all) {
      for (final b in all) {
        expect(a.within(b), b.contains(a), reason: '$a $b');
      }
    }
  });

  test('overlaps is symmetric on every pair', () {
    for (final a in all) {
      for (final b in all) {
        expect(a.overlaps(b), b.overlaps(a), reason: '$a $b');
      }
    }
  });

  test('same agrees with equality on every pair', () {
    for (final a in all) {
      for (final b in all) {
        expect(a.same(b), a == b, reason: '$a $b');
      }
    }
  });
}
