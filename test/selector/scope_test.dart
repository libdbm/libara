import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/selector/selector.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// Random keyed ranges over a short sequence, so nesting, shared starts,
/// zero-length ranges, and crossings are common, with `name`, `kind`, and
/// `n` attributes.
List<(int, ARange)> pairs(Random random, int count) => [
  for (var index = 0; index < count; index++)
    (
      index,
      tagged(
        random.nextInt(12),
        random.nextInt(5),
        attributes: {
          'name': Str(Text.of(['p', 'q', 'pq'][random.nextInt(3)])),
          'kind': Str(Text.of(['p', 'q'][random.nextInt(2)])),
          if (random.nextBool()) 'n': Num(random.nextInt(3)),
        },
      ),
    ),
];

/// Selectors over every kind of term, two with another type attribute.
final selectors = [
  for (final source in [
    'p',
    '*',
    '[n]',
    '[n=1]',
    '[name*="q"]',
    '[name~="pq"]',
    'p q',
    'p > q',
    'p + q',
    'p ~ q',
    ':root',
    ':first-child',
    ':nth-child(2n+1)',
    ':not(p)',
    ':is(p, q)',
    ':has(> q)',
    ':overlaps(p)',
    ':crosses(q)',
    'q:empty',
  ])
    Selector.parse(source).unwrap(),
  Selector.parse('p', type: 'kind').unwrap(),
  Selector.parse('p > q', type: 'kind').unwrap(),
];

void main() {
  test('one scope serves many selections as fresh ones do, over 100 seeds', () {
    for (var seed = 0; seed < 100; seed++) {
      final random = Random(seed);
      final keyed = pairs(random, random.nextInt(30));
      final scope = Scope(keyed);
      // Each selector twice, in a random order, through one scope.
      final order = [...selectors, ...selectors]..shuffle(random);
      for (final selector in order) {
        expect(
          scope.select(selector),
          selector.select(keyed),
          reason: 'seed $seed $selector ${selector.type}',
        );
        for (final (key, _) in keyed) {
          expect(
            scope.matches(selector, key),
            selector.matches(key, keyed),
            reason: 'seed $seed $selector $key',
          );
        }
      }
    }
  });

  test('a scope keeps a copy of its pairs, in order', () {
    final keyed = [(1, tagged(0, 1)), (2, tagged(1, 1))];
    final scope = Scope(keyed);
    keyed.clear();
    expect([for (final (key, _) in scope.pairs) key], [1, 2]);
  });

  test('matches finds the first pair under a key, or fails', () {
    final scope = Scope([
      (1, tagged(0, 1, attributes: {'a': const Num(1)})),
      (1, tagged(0, 1)),
      (2, tagged(0, 1)),
    ]);
    final selector = Selector.parse('[a]').unwrap();
    expect(scope.matches(selector, 1), const Success(true));
    expect(scope.matches(selector, 2), const Success(false));
    final missing = scope.matches(selector, 3) as Failure<bool>;
    expect(missing.kind, Kind.missing);
    expect(missing.message, 'selector: 3 is not in the scope');
  });

  test('a document scope selects as the document does', () {
    var document = Document.of(Text.of('abcdefgh'));
    document = document.transact([
      Mark(tagged(0, 8, attributes: {'name': Str(Text.of('p'))})),
      Mark(tagged(1, 2, attributes: {'name': Str(Text.of('q'))})),
      Mark(tagged(4, 3, attributes: {'name': Str(Text.of('q'))})),
    ]).unwrap();
    final scope = document.scope();
    for (final selector in selectors) {
      expect(scope.select(selector), document.select(selector));
    }
  });
}
