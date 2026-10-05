import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/selector/selector.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// The selector in [source], which must parse.
Selector parsed(String source) => Selector.parse(source).unwrap();

/// A range of [length] items from [start] named [name].
ARange named(String name, int start, int length) =>
    tagged(start, length, attributes: {'name': Str(Text.of(name))});

/// The keys of [scope] that [source] selects.
List<int> keys(String source, List<(int, ARange)> scope) => [
  for (final (key, _) in parsed(source).select(scope)) key,
];

void main() {
  group('parse and print', () {
    const cases = {
      'p q': 'p q',
      'p>q': 'p > q',
      'p  +  q': 'p + q',
      'p~q': 'p ~ q',
      'p q > [a] ~ * + r': 'p q > [a] ~ * + r',
      'p > q, r s': 'p > q, r s',
      ':not(p q)': ':not(p q)',
      ':is(p > q, r)': ':is(p > q, r)',
    };
    for (final MapEntry(key: source, value: printed) in cases.entries) {
      test('"$source" prints as $printed and reads back', () {
        final selector = parsed(source);
        expect(selector.toString(), printed);
        expect(parsed(printed), selector);
        expect(parsed(printed).hashCode, selector.hashCode);
      });
    }

    test('a combinator with nothing after it fails', () {
      for (final (source, column) in [('p >', 4), ('p > ,q', 5), ('> p', 1)]) {
        final result = Selector.parse(source);
        expect(result, isA<Failure<Selector>>(), reason: source);
        expect(
          (result as Failure<Selector>).message,
          'selector: column $column: expected a selector',
        );
      }
    });
  });

  test('descendant is containment and child is the innermost container', () {
    // The spec's crossing example: x contains r but not p, r's parent.
    final scope = [
      (0, named('x', 0, 10)),
      (1, named('p', 2, 10)),
      (2, named('r', 3, 2)),
    ];
    expect(keys('x r', scope), [2]);
    expect(keys('x > r', scope), isEmpty);
    expect(keys('p > r', scope), [2]);
    expect(keys('x p', scope), isEmpty);
  });

  test('ranges at one position are siblings, not ancestors', () {
    final scope = [
      (0, named('a', 0, 4)),
      (1, named('b', 0, 4)),
      (2, named('c', 5, 1)),
    ];
    expect(keys('a b', scope), isEmpty);
    expect(keys('a + b', scope), [1]);
    expect(keys('a ~ c', scope), [2]);
    expect(keys('b + c', scope), [2]);
  });

  test('every combinator agrees with a model built on Ranges.parent', () {
    final random = Random(13);
    const names = ['p', 'q'];
    for (var round = 0; round < 300; round++) {
      final scope = [
        for (var index = 0; index < 1 + random.nextInt(20); index++)
          (
            index,
            named(
              names[random.nextInt(2)],
              random.nextInt(10),
              random.nextInt(5),
            ),
          ),
      ];
      final ranges = [for (final (_, range) in scope) range];
      final all = Ranges.of(ranges);
      // The parent's index: the first range at the position Ranges.parent
      // gives, as it returns the first of equal candidates.
      final parents = [
        for (final range in ranges)
          switch (all.parent(range)) {
            final parent? => ranges.indexWhere((other) => other.same(parent)),
            null => -1,
          },
      ];
      bool related(String combinator, int a, int b) => switch (combinator) {
        ' ' => ranges[a].contains(ranges[b]) && !ranges[a].same(ranges[b]),
        ' > ' => parents[b] == a,
        ' + ' =>
          parents[a] == parents[b] &&
              a < b &&
              [for (var between = a + 1; between < b; between++) between]
                  .every((between) => parents[between] != parents[b]),
        _ => parents[a] == parents[b] && a < b,
      };
      const combinators = [' ', ' > ', ' + ', ' ~ '];
      final compounds = [
        for (var count = 2 + random.nextInt(2); count > 0; count--)
          ['p', 'q', '*'][random.nextInt(3)],
      ];
      final joins = [
        for (var index = 1; index < compounds.length; index++)
          combinators[random.nextInt(4)],
      ];
      var source = compounds.first;
      bool fits(String compound, int index) =>
          compound == '*' ||
          ranges[index].get('name') == Str(Text.of(compound));
      var set = [
        for (var index = 0; index < ranges.length; index++)
          fits(compounds.first, index),
      ];
      for (var step = 1; step < compounds.length; step++) {
        source += '${joins[step - 1]}${compounds[step]}';
        final previous = set;
        set = [
          for (var index = 0; index < ranges.length; index++)
            fits(compounds[step], index) &&
                [for (var other = 0; other < ranges.length; other++) other].any(
                  (other) =>
                      previous[other] && related(joins[step - 1], other, index),
                ),
        ];
      }
      expect(keys(source, scope), [
        for (var index = 0; index < ranges.length; index++)
          if (set[index]) index,
      ], reason: '$source over $scope');
    }
  });

  test(':not and :is take complex selectors', () {
    final scope = [
      (0, named('p', 0, 10)),
      (1, named('q', 1, 2)),
      (2, named('q', 20, 2)),
    ];
    expect(keys('q:not(p q)', scope), [2]);
    expect(keys(':is(p q, p)', scope), [0, 1]);
  });
}
