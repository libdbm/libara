import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
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
      ':overlaps(line)': ':overlaps(line)',
      ':crosses( line , p > q )': ':crosses(line, p > q)',
      'sentence:crosses(line):not(:overlaps(p))':
          'sentence:crosses(line):not(:overlaps(p))',
    };
    for (final MapEntry(key: source, value: printed) in cases.entries) {
      test('"$source" prints as $printed and reads back', () {
        final selector = parsed(source);
        expect(selector.toString(), printed);
        expect(parsed(printed), selector);
        expect(parsed(printed).hashCode, selector.hashCode);
      });
    }
  });

  test('a sentence two lines cross, and one inside a line', () {
    final scope = [
      (0, named('line', 0, 10)),
      (1, named('line', 10, 10)),
      (2, named('sentence', 6, 8)),
      (3, named('sentence', 12, 3)),
    ];
    expect(keys('sentence:crosses(line)', scope), [2]);
    expect(keys('sentence:overlaps(line)', scope), [2, 3]);
    expect(keys('line:crosses(sentence)', scope), [0, 1]);
  });

  test('a range never overlaps itself, but does a copy of itself', () {
    final scope = [(0, named('a', 0, 4)), (1, named('b', 0, 4))];
    expect(keys('a:overlaps(a)', scope), isEmpty);
    expect(keys('a:overlaps(b)', scope), [0]);
    expect(keys('a:crosses(b)', scope), isEmpty);
  });

  test('both agree with a model built on the range predicates', () {
    final random = Random(19);
    for (var round = 0; round < 400; round++) {
      final scope = [
        for (var index = 0; index < 1 + random.nextInt(24); index++)
          (
            index,
            named(
              ['p', 'q'][random.nextInt(2)],
              random.nextInt(12),
              random.nextInt(6),
            ),
          ),
      ];
      final ranges = [for (final (_, range) in scope) range];
      final name = ['p', 'q', '*'][random.nextInt(3)];
      bool fits(int index) =>
          name == '*' || ranges[index].get('name') == Str(Text.of(name));
      final indices = [
        for (var index = 0; index < ranges.length; index++) index,
      ];
      bool overlaps(int index) => indices.any(
        (other) =>
            other != index &&
            fits(other) &&
            ranges[other].overlaps(ranges[index]),
      );
      bool crosses(int index) => indices.any(
        (other) =>
            fits(other) &&
            ranges[other].overlaps(ranges[index]) &&
            !ranges[other].contains(ranges[index]) &&
            !ranges[index].contains(ranges[other]),
      );
      expect(keys(':overlaps($name)', scope), [
        for (final index in indices)
          if (overlaps(index)) index,
      ], reason: ':overlaps($name) over $scope');
      expect(keys(':crosses($name)', scope), [
        for (final index in indices)
          if (crosses(index)) index,
      ], reason: ':crosses($name) over $scope');
    }
  });
}
