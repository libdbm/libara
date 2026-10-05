import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/replica/replica.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'model.dart';
import 'random.dart';
import 'replicas.dart';

void main() {
  setUp(() => now = 1);

  test('a mark over hello keeps lo after a concurrent deletion of hel', () {
    for (final (markTime, cutTime) in [(2, 3), (3, 2)]) {
      final (a, base) = commit(replica('a'), 1, [Insert(0, Text.of('hello'))]);
      final b = receive(replica('b'), [base]);
      final mark = Mark<int>(
        tagged(0, 5, attributes: {'name': Str(Text.of('b'))}),
      );
      final (marked, marking) = commit(a, markTime, [mark]);
      final (cut, cutting) = commit(b, cutTime, [Delete(span(0, 3))]);
      final key = marked.key(mark.marker)!;
      final ordered = [marking, cutting]
        ..sort((x, y) => x.stamp.compareTo(y.stamp));
      // The writer of the earlier operation receives the later one.
      final later = markTime < cutTime
          ? receive(marked, [cutting])
          : receive(cut, [marking]);
      final observed = receive(replica('o'), [base, ...ordered]);
      for (final held in [later, observed]) {
        expect(text(held), 'lo');
        final range = held.document.resolve(held.marker(key)!)!;
        expect(range.same(span(0, 2)), isTrue);
        expect(range.attributes, {'name': Str(Text.of('b'))});
      }
      agrees(observed, Model.of([base, ...ordered]));
    }
  });

  group('with a marked base', () {
    late Operation<int> base;
    late Replica<int> a;
    late Replica<int> b;
    late Key key;
    final mark = Mark<int>(tagged(0, 1));

    setUp(() {
      (a, base) = commit(replica('a'), 1, [Insert(0, Text.of('ab')), mark]);
      b = receive(replica('b'), [base]);
      key = a.key(mark.marker)!;
    });

    Marker theirs(Replica<int> replica) => replica.marker(key)!;

    test('concurrent updates end with the later stamp, either order', () {
      final (_, one) = commit(a, 2, [
        Update(mark.marker, {'x': Num(1)}),
      ]);
      final (_, two) = commit(b, 3, [
        Update(theirs(b), {'x': Num(2)}),
      ]);
      final observed = receive(replica('o'), [base, one, two]);
      final range = observed.document.resolve(observed.marker(key)!)!;
      expect(range.attributes, {'x': Num(2)});
      agrees(observed, Model.of([base, one, two]));
    });

    test('an unmark wins over a concurrent update, either order', () {
      for (final (unmarkTime, updateTime) in [(2, 3), (3, 2)]) {
        final (_, unmark) = commit(a, unmarkTime, [Unmark(mark.marker)]);
        final (_, update) = commit(b, updateTime, [
          Update(theirs(b), {'x': Num(1)}),
        ]);
        final ordered = [unmark, update]
          ..sort((x, y) => x.stamp.compareTo(y.stamp));
        final observed = receive(replica('o'), [base, ...ordered]);
        expect(observed.document.markers, isEmpty);
        expect(observed.document.resolve(observed.marker(key)!), isNull);
        agrees(observed, Model.of([base, ...ordered]));
      }
    });

    test('concurrent unmarks remove the range once', () {
      final (_, one) = commit(a, 2, [Unmark(mark.marker)]);
      final (_, two) = commit(b, 3, [Unmark(theirs(b))]);
      final observed = receive(replica('o'), [base, one, two]);
      expect(observed.document.markers, isEmpty);
    });

    test('each gravity at a concurrent insertion matches the model', () {
      for (final start in Gravity.values) {
        for (final end in Gravity.values) {
          for (final (markTime, putTime) in [(2, 3), (3, 2)]) {
            for (final at in [0, 1, 2]) {
              final mark = Mark<int>(
                tagged(at == 2 ? 1 : at, at == 2 ? 1 : 0),
                start: start,
                end: end,
              );
              final (_, marking) = commit(a, markTime, [mark]);
              final (_, putting) = commit(b, putTime, [
                Insert(at, Text.of('x')),
              ]);
              final ordered = [marking, putting]
                ..sort((x, y) => x.stamp.compareTo(y.stamp));
              agrees(
                receive(replica('o'), [base, ...ordered]),
                Model.of([base, ...ordered]),
                reason: '$start $end at $at, mark at $markTime',
              );
            }
          }
        }
      }
    });

    test('a range over concurrently deleted items matches the model', () {
      for (final start in Gravity.values) {
        for (final end in Gravity.values) {
          final mark = Mark<int>(tagged(0, 2), start: start, end: end);
          final (_, cutting) = commit(a, 2, [Delete(span(0, 2))]);
          final (_, marking) = commit(b, 3, [mark]);
          agrees(
            receive(replica('o'), [base, cutting, marking]),
            Model.of([base, cutting, marking]),
            reason: '$start $end',
          );
        }
      }
    });

    test('a transaction uses its earlier positions and markers', () {
      final (_, put) = commit(a, 2, [Insert(0, Text.of('pq'))]);
      final mark = Mark<int>(tagged(1, 2));
      final (_, transaction) = commit(b, 3, [
        Insert(2, Text.of('xyz')),
        mark,
        Update(mark.marker, {'n': Num(7)}),
        Delete(span(0, 1)),
      ]);
      final observed = receive(replica('o'), [base, put, transaction]);
      agrees(observed, Model.of([base, put, transaction]));
      final mine = observed.marker(Key(transaction.stamp, 1))!;
      expect(observed.document.resolve(mine)!.attributes, {'n': Num(7)});
    });

    test('an unmark of a key unmarked in its context is invalid', () {
      final (_, unmark) = commit(a, 2, [Unmark(mark.marker)]);
      final (_, put) = commit(b, 3, [Insert(0, Text.of('x'))]);
      final held = receive(replica('o'), [base, put]);
      final stranger = Marker();
      final forged = Operation<int>(
        const Stamp(4, 0, 'c'),
        [base.stamp, unmark.stamp]..sort(),
        [Unmark(stranger)],
        {stranger: key},
      );
      final withUnmark = receive(replica('p'), [base, unmark, put]);
      final failure = withUnmark.receive(forged) as Failure<Object?>;
      expect(failure.kind, Kind.invalid);
      expect(failure.message, contains('$key is not marked'));
      expect(held.heads, isNotEmpty);
    });

    test('an update of a key marked concurrently is invalid', () {
      final concurrent = Mark<int>(tagged(0, 0));
      final (marked, marking) = commit(a, 2, [concurrent]);
      final (_, put) = commit(b, 3, [Insert(0, Text.of('x'))]);
      final held = receive(replica('o'), [base, marking, put]);
      final stranger = Marker();
      final forged = Operation<int>(
        const Stamp(4, 0, 'c'),
        [put.stamp],
        [Update(stranger, const {})],
        {stranger: marked.key(concurrent.marker)!},
      );
      final failure = held.receive(forged) as Failure<Object?>;
      expect(failure.kind, Kind.invalid);
      expect(failure.message, contains('is not marked'));
    });

    test('a concurrent mark past its context is out of bounds', () {
      final (_, put) = commit(a, 2, [Insert(0, Text.of('x'))]);
      final held = receive(replica('o'), [base, put]);
      final wide = Mark<int>(tagged(0, 3));
      final stamp = const Stamp(4, 0, 'c');
      final failure = held.receive(
        Operation(stamp, [base.stamp], [wide], {wide.marker: Key(stamp, 0)}),
      ) as Failure<Object?>;
      expect(failure.kind, Kind.bounds);
    });
  });

  test('replicas branching from earlier states converge on the model with '
      'all six commands, over 100 seeds', () {
    for (var seed = 0; seed < 100; seed++) {
      final random = Random(seed);
      final operations = <Operation<int>>[];
      for (var round = 0; round < 30; round++) {
        final prefix = operations.sublist(
          0,
          random.nextInt(operations.length + 1),
        );
        final writer = receive(replica('w$round'), prefix);
        now = round + 1;
        final (_, operation) = writer
            .commit(transaction(random, writer.document))
            .unwrap();
        operations.add(operation);
      }
      agrees(
        receive(replica('o'), operations),
        Model.of(operations),
        reason: 'seed $seed',
      );
    }
  });
}
