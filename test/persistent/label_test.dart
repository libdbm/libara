import 'dart:math';

import 'package:libara/src/persistent/label.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// The label with [digits], which must be valid.
Label label(List<int> digits) => Label.of(digits).unwrap();

/// A random label of one to four digits that does not end in zero.
Label sample(Random random) {
  final digits = List.generate(
    1 + random.nextInt(4),
    (_) => random.nextInt(Label.base),
  );
  if (digits.last == 0) {
    digits.last = 1;
  }
  return label(digits);
}

void main() {
  group('comparison', () {
    test('is lexicographic, a proper prefix first', () {
      expect(label([1]).compareTo(label([1, 5])), lessThan(0));
      expect(label([1, 5]).compareTo(label([2])), lessThan(0));
      expect(label([2]).compareTo(label([1, 65535])), greaterThan(0));
      expect(label([3, 4]).compareTo(label([3, 4])), 0);
    });

    test('equality and hashCode are by digits', () {
      expect(label([3, 4]), label([3, 4]));
      expect(label([3, 4]).hashCode, label([3, 4]).hashCode);
      expect(label([3, 4]), isNot(label([3])));
    });
  });

  group('between', () {
    test('with both bounds open', () {
      expect(Label.between(null, null), isA<Success<Label>>());
    });

    test('is strictly between for 1,000 seeded random bound pairs', () {
      final random = Random(42);
      var checked = 0;
      while (checked < 1000) {
        final a = sample(random);
        final b = sample(random);
        if (a == b) {
          continue;
        }
        final (lower, upper) = a.compareTo(b) < 0 ? (a, b) : (b, a);
        final label = Label.between(lower, upper).unwrap();
        expect(
          lower.compareTo(label),
          lessThan(0),
          reason: '$lower $label $upper',
        );
        expect(
          label.compareTo(upper),
          lessThan(0),
          reason: '$lower $label $upper',
        );
        expect(label.digits.last, isNot(0));
        checked++;
      }
    });

    test('with one bound open', () {
      final random = Random(7);
      for (var round = 0; round < 1000; round++) {
        final bound = sample(random);
        expect(
          Label.between(bound, null).unwrap().compareTo(bound),
          greaterThan(0),
        );
        expect(
          Label.between(null, bound).unwrap().compareTo(bound),
          lessThan(0),
        );
      }
    });

    test('rejects bounds out of order', () {
      expect(Label.between(label([5]), label([3])), invalid);
      expect(Label.between(label([5]), label([5])), invalid);
    });

    test('rejects empty digits and a trailing zero digit', () {
      expect(Label.of([1, 0]), invalid);
      expect(Label.of([]), invalid);
    });

    test('rejects a digit outside the base', () {
      expect(Label.of([-1, 1]), invalid);
      expect(Label.of([Label.base]), invalid);
    });
  });

  group('1,000 labels inserted next to each other stay ordered and short', () {
    void check(List<Label> labels) {
      for (var index = 1; index < labels.length; index++) {
        expect(
          labels[index - 1].compareTo(labels[index]),
          lessThan(0),
          reason: '$index',
        );
      }
      final longest = labels.map((label) => label.digits.length).reduce(max);
      expect(longest, lessThan(100));
    }

    test('each just after the previous, below a fixed upper bound', () {
      final upper = label([40000]);
      var previous = label([20000]);
      final labels = [previous];
      for (var round = 0; round < 1000; round++) {
        previous = Label.between(previous, upper).unwrap();
        labels.add(previous);
      }
      check([...labels, upper]);
    });

    test('each just before the previous, above a fixed lower bound', () {
      final lower = label([20000]);
      var previous = label([40000]);
      final labels = [previous];
      for (var round = 0; round < 1000; round++) {
        previous = Label.between(lower, previous).unwrap();
        labels.add(previous);
      }
      check([lower, ...labels.reversed]);
    });
  });

  group('labels made at an open bound do not grow', () {
    /// The labels made by [count] rounds of [next] from a first label with
    /// both bounds open.
    List<Label> made(int count, Label Function(Label previous) next) {
      final labels = [Label.between(null, null).unwrap()];
      for (var round = 0; round < count; round++) {
        labels.add(next(labels.last));
      }
      return labels;
    }

    int longest(List<Label> labels) =>
        labels.map((label) => label.digits.length).reduce(max);

    void ordered(List<Label> labels) {
      for (var index = 1; index < labels.length; index++) {
        expect(labels[index - 1].compareTo(labels[index]), lessThan(0));
      }
    }

    test('appended, from 1,000 to 4,000', () {
      Label next(Label previous) => Label.between(previous, null).unwrap();
      final small = made(1000, next);
      final large = made(4000, next);
      ordered(large);
      expect(longest(large), longest(small));
      expect(longest(large), lessThanOrEqualTo(2));
    });

    test('prepended, from 1,000 to 4,000', () {
      Label next(Label previous) => Label.between(null, previous).unwrap();
      final small = made(1000, next);
      final large = made(4000, next);
      ordered(large.reversed.toList());
      expect(longest(large), longest(small));
      expect(longest(large), lessThanOrEqualTo(2));
    });
  });

  group('spread', () {
    test('gives count strictly ordered labels', () {
      final labels = Label.spread(1000);
      expect(labels.length, 1000);
      for (var index = 1; index < labels.length; index++) {
        expect(labels[index - 1].compareTo(labels[index]), lessThan(0));
      }
    });

    test('uses one digit below the base and two above it', () {
      int longest(List<Label> labels) =>
          labels.map((label) => label.digits.length).reduce(max);
      expect(longest(Label.spread(Label.base - 1)), 1);
      expect(longest(Label.spread(100000)), 2);
    });

    test('of nothing is empty', () {
      expect(Label.spread(0), isEmpty);
    });
  });
}
