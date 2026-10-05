import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/constructor/constructor.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// A range over every run of [item] in the input, tagged with [name].
Constructor<int> runs(int item, String name) => (input) {
  final found = <ARange>[];
  int? start;
  final list = input.items.toList();
  for (var position = 0; position <= list.length; position++) {
    final inside = position < list.length && list[position] == item;
    if (inside && start == null) {
      start = position;
    } else if (!inside && start != null) {
      found.add(
        tagged(
          start,
          position - start,
          attributes: {'run': Value.of(name).unwrap()},
        ),
      );
      start = null;
    }
  }
  return Success(Ranges.of(found));
};

/// The whole input as one range.
Result<Ranges> whole(Sequence<int> input) =>
    Success(Ranges.of([tagged(0, input.length)]));

/// A constructor that always fails.
Result<Ranges> broken(Sequence<int> input) =>
    const Failure(Kind.invalid, 'broken');

void main() {
  final input = Items.of([1, 1, 2, 1, 2, 2]);

  group('union', () {
    test('runs every part and returns start order', () {
      final result = union([runs(2, 'two'), runs(1, 'one')])(input);
      expect(result.or(Ranges.empty()).items.map((range) => range.toString()), [
        '{0,2,run:one}',
        '{2,1,run:two}',
        '{3,1,run:one}',
        '{4,2,run:two}',
      ]);
    });

    test(
      'drops exact duplicates and keeps ranges with different attributes',
      () {
        final result = union([runs(1, 'one'), runs(1, 'one'), runs(1, 'uno')])(
          input,
        );
        expect(result.or(Ranges.empty()).length, 4);
      },
    );

    test('of nothing is empty', () {
      expect(union<int>([])(input), Success(Ranges.empty()));
    });
  });

  group('concat', () {
    test('keeps every range, in part order, with duplicates', () {
      final result = concat([runs(2, 'two'), runs(1, 'one'), runs(1, 'one')])(
        input,
      );
      expect(result.or(Ranges.empty()).items.map((range) => range.toString()), [
        '{2,1,run:two}',
        '{4,2,run:two}',
        '{0,2,run:one}',
        '{3,1,run:one}',
        '{0,2,run:one}',
        '{3,1,run:one}',
      ]);
    });

    test('of nothing is empty', () {
      expect(concat<int>([])(input), Success(Ranges.empty()));
    });
  });

  group('layer', () {
    test('gives the upper function the lower layer, and indexes into it', () {
      // Above: one range over every lower range, by position in the lower
      // layer.
      Ranges above(Ranges lower) => Ranges.of([span(0, lower.length)]);
      final result = layer(runs(2, 'two'), above)(input);
      expect(result, Success(Ranges.of([span(0, 2)])));
    });

    test('composes with union below', () {
      Ranges count(Ranges lower) => Ranges.of([span(0, lower.length)]);
      final result = layer(union([runs(1, 'one'), runs(2, 'two')]), count)(
        input,
      );
      expect(result, Success(Ranges.of([span(0, 4)])));
    });
  });

  test('clearing the parts afterwards leaves results unchanged', () {
    final parts = [runs(1, 'one')];
    final united = union(parts);
    final joined = concat(parts);
    final (first, second) = (united(input), joined(input));
    parts.clear();
    expect(united(input), first);
    expect(joined(input), second);
  });

  test('a failing part fails the whole composition', () {
    const failure = Failure<Ranges>(Kind.invalid, 'broken');
    expect(union([whole, broken])(input), failure);
    expect(concat([broken, whole])(input), failure);
    expect(layer(broken, (lower) => lower)(input), failure);
  });

  test('composing never changes the input', () {
    final before = Items.of([1, 1, 2, 1, 2, 2]);
    union([runs(1, 'one'), whole])(input);
    concat([whole, whole])(input);
    layer(whole, (lower) => lower)(input);
    expect(input, before);
  });
}
