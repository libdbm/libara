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
      ':has(b)': ':has(b)',
      ':has(>b)': ':has(> b)',
      ':has( + b , ~ c )': ':has(+ b, ~ c)',
      'a:has(> b c)': 'a:has(> b c)',
      ':has(:has(b))': ':has(:has(b))',
      ':not(:has(b))': ':not(:has(b))',
    };
    for (final MapEntry(key: source, value: printed) in cases.entries) {
      test('"$source" prints as $printed and reads back', () {
        final selector = parsed(source);
        expect(selector.toString(), printed);
        expect(parsed(printed), selector);
        expect(parsed(printed).hashCode, selector.hashCode);
      });
    }

    test('a dangling or doubled combinator fails with its column', () {
      for (final (source, column) in [
        (':has()', 6),
        (':has(>)', 7),
        (':has(> > b)', 8),
        (':has(b,)', 8),
      ]) {
        final result = Selector.parse(source);
        expect(result, isA<Failure<Selector>>(), reason: source);
        expect(
          (result as Failure<Selector>).message,
          'selector: column $column: expected a selector',
        );
      }
    });
  });

  test('a range with a child, a descendant, or a later sibling', () {
    final scope = [
      (0, named('a', 0, 10)),
      (1, named('b', 1, 4)),
      (2, named('c', 2, 1)),
      (3, named('a', 20, 2)),
      (4, named('b', 30, 1)),
    ];
    expect(keys('a:has(> b)', scope), [0]);
    expect(keys('a:has(c)', scope), [0]);
    expect(keys('a:has(> c)', scope), isEmpty);
    expect(keys('a:has(> b > c)', scope), [0]);
    expect(keys(':has(+ b)', scope), [3]);
    expect(keys(':has(~ b)', scope), [0, 3]);
  });

  test(':has agrees with a model built on Ranges.parent', () {
    final random = Random(17);
    const combinators = [' ', '> ', '+ ', '~ '];
    for (var round = 0; round < 300; round++) {
      final scope = [
        for (var index = 0; index < 1 + random.nextInt(20); index++)
          (
            index,
            named(
              ['p', 'q'][random.nextInt(2)],
              random.nextInt(10),
              random.nextInt(5),
            ),
          ),
      ];
      final ranges = [for (final (_, range) in scope) range];
      final all = Ranges.of(ranges);
      final parents = [
        for (final range in ranges)
          switch (all.parent(range)) {
            final parent? => ranges.indexWhere((other) => other.same(parent)),
            null => -1,
          },
      ];
      // Whether [combinator] relates [b] to the anchor [a].
      bool related(String combinator, int a, int b) => switch (combinator) {
        ' ' => ranges[a].contains(ranges[b]) && !ranges[a].same(ranges[b]),
        '> ' => parents[b] == a,
        '+ ' =>
          parents[a] == parents[b] &&
              a < b &&
              [for (var between = a + 1; between < b; between++) between]
                  .every((between) => parents[between] != parents[b]),
        _ => parents[a] == parents[b] && a < b,
      };
      bool fits(String compound, int index) =>
          compound == '*' ||
          ranges[index].get('name') == Str(Text.of(compound));
      final steps = [
        for (var count = 1 + random.nextInt(2); count > 0; count--)
          (combinators[random.nextInt(4)], ['p', 'q', '*'][random.nextInt(3)]),
      ];
      // Whether a chain of [steps] from [from] on runs out of [anchor].
      bool chain(int anchor, int from) =>
          from == steps.length ||
          [for (var index = 0; index < ranges.length; index++) index].any(
            (next) =>
                related(steps[from].$1, anchor, next) &&
                fits(steps[from].$2, next) &&
                chain(next, from + 1),
          );
      final inside = [
        for (final (index, (combinator, compound)) in steps.indexed)
          '${index == 0 ? combinator : ' ${combinator.trim()} '}$compound'
              .replaceAll('  ', ' '),
      ].join();
      final source = ':has(${inside.trim()})';
      expect(keys(source, scope), [
        for (var index = 0; index < ranges.length; index++)
          if (chain(index, 0)) index,
      ], reason: '$source over $scope');
    }
  });
}
