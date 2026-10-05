import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/selector/selector.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// The selector in [source], which must parse.
Selector parsed(String source) => Selector.parse(source).unwrap();

/// Random ranges over a short sequence, so that duplicates, shared starts,
/// zero-length ranges, nesting, and crossing ranges are all common.
List<(int, ARange)> scope(Random random, int count) => [
  for (var index = 0; index < count; index++)
    switch ((random.nextInt(12), random.nextInt(5))) {
      (final start, final length) => (index, tagged(start, length)),
    },
];

/// The keys of [scope] that [selector] selects.
List<int> keys(Selector selector, List<(int, ARange)> scope) => [
  for (final (key, _) in selector.select(scope)) key,
];

void main() {
  group('parse and print', () {
    const cases = {
      ':root': ':root',
      ':empty': ':empty',
      ':first-child': ':first-child',
      ':last-child': ':last-child',
      ':only-child': ':only-child',
      ':nth-child(3)': ':nth-child(3)',
      ':nth-child(+3)': ':nth-child(3)',
      ':nth-child(-3)': ':nth-child(-3)',
      ':nth-child(odd)': ':nth-child(2n+1)',
      ':nth-child(even)': ':nth-child(2n)',
      ':nth-child(n)': ':nth-child(n)',
      ':nth-child(-n+3)': ':nth-child(-n+3)',
      ':nth-child( 2n - 1 )': ':nth-child(2n-1)',
      ':nth-child(3n+0)': ':nth-child(3n)',
      ':nth-child(0n+2)': ':nth-child(2)',
      ':nth-last-child(2n+1)': ':nth-last-child(2n+1)',
      'p:first-child:not(:empty)': 'p:first-child:not(:empty)',
    };
    for (final MapEntry(key: source, value: printed) in cases.entries) {
      test('"$source" prints as $printed and reads back', () {
        final selector = parsed(source);
        expect(selector.toString(), printed);
        expect(parsed(printed), selector);
        expect(parsed(printed).hashCode, selector.hashCode);
      });
    }

    test('a malformed an+b fails with its column', () {
      for (final (source, column, problem) in [
        (':nth-child()', 12, 'expected an+b'),
        (':nth-child(x)', 12, 'expected an+b'),
        (':nth-child(2n+)', 12, 'expected an+b'),
        (':nth-child(2n+1', 16, "expected ')'"),
        (':nth-child', 11, "expected '('"),
        (':first-child(1)', 13, "expected ',' or the end"),
      ]) {
        final result = Selector.parse(source);
        expect(result, isA<Failure<Selector>>(), reason: source);
        final failure = result as Failure<Selector>;
        expect(failure.kind, Kind.syntax);
        expect(failure.message, 'selector: column $column: $problem');
      }
    });
  });

  test('structural pseudo-classes agree with a model built on '
      'Ranges.parent', () {
    final random = Random(11);
    for (var round = 0; round < 300; round++) {
      final pairs = scope(random, 1 + random.nextInt(24));
      final ranges = Ranges.of([for (final (_, range) in pairs) range]);
      final parents = [for (final (_, range) in pairs) ranges.parent(range)];
      // Siblings share a parent position, or have none.
      bool siblings(int a, int b) => switch ((parents[a], parents[b])) {
        (null, null) => true,
        (final x?, final y?) => x.same(y),
        _ => false,
      };
      final groups = [
        for (var index = 0; index < pairs.length; index++)
          [
            for (var other = 0; other < pairs.length; other++)
              if (siblings(index, other)) other,
          ],
      ];
      int place(int index) => groups[index].indexOf(index) + 1;
      int size(int index) => groups[index].length;
      final a = random.nextInt(5) - 2;
      final b = random.nextInt(7) - 2;
      bool nth(int position) => a == 0
          ? position == b
          : (position - b) % a == 0 && (position - b) ~/ a >= 0;
      final step = a == 0 ? '' : '${a}n';
      final offset = a == 0 ? '$b' : (b >= 0 ? '+$b' : '$b');
      final models = <String, bool Function(int index)>{
        ':root': (index) => parents[index] == null,
        ':empty': (index) => pairs[index].$2.length == 0,
        ':first-child': (index) => place(index) == 1,
        ':last-child': (index) => place(index) == size(index),
        ':only-child': (index) => size(index) == 1,
        ':nth-child($step$offset)': (index) => nth(place(index)),
        ':nth-last-child($step$offset)': (index) =>
            nth(size(index) - place(index) + 1),
      };
      for (final MapEntry(key: source, value: model) in models.entries) {
        expect(keys(parsed(source), pairs), [
          for (var index = 0; index < pairs.length; index++)
            if (model(index)) index,
        ], reason: '$source over $pairs');
      }
    }
  });

  test('ranges at one position share a parent and are siblings', () {
    final pairs = [
      (0, tagged(0, 10)),
      (1, tagged(2, 3)),
      (2, tagged(2, 3)),
      (3, tagged(0, 10)),
    ];
    expect(keys(parsed(':root'), pairs), [0, 3]);
    expect(keys(parsed(':first-child'), pairs), [0, 1]);
    expect(keys(parsed(':last-child'), pairs), [2, 3]);
  });

  test('matches tests one pair of the scope by its place', () {
    final pairs = [(0, tagged(0, 10)), (1, tagged(2, 3))];
    expect(parsed(':root').matches(0, pairs), const Success(true));
    expect(parsed(':root').matches(1, pairs), const Success(false));
  });
}
