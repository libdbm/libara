import 'dart:math';

import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

Items<int> sample(Random random) =>
    Items.of(List.generate(random.nextInt(6), (_) => random.nextInt(10)));

void main() {
  test('concat is associative over 200 seeded triples', () {
    final random = Random(42);
    for (var round = 0; round < 200; round++) {
      final a = sample(random);
      final b = sample(random);
      final c = sample(random);
      expect(
        a.concat(b).flatMap((ab) => ab.concat(c)),
        b.concat(c).flatMap(a.concat),
        reason: '$a $b $c',
      );
    }
  });

  test('empty is the identity for concat over 200 seeded samples', () {
    final random = Random(42);
    final empty = Items<int>.empty();
    for (var round = 0; round < 200; round++) {
      final a = sample(random);
      expect(empty.concat(a), Success(a), reason: '$a');
      expect(a.concat(empty), Success(a), reason: '$a');
    }
  });
}
