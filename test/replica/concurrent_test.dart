import 'dart:math';

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

  test('Oh, hello world', () {
    var (a, base) = commit(replica('a'), 1, [Insert(0, Text.of('hello'))]);
    var b = receive(replica('b'), [base]);
    final Operation<int> world;
    (a, world) = commit(a, 2, [Insert(5, Text.of(' world'))]);
    final Operation<int> oh;
    (b, oh) = commit(b, 3, [Insert(0, Text.of('Oh, '))]);
    a = receive(a, [oh]);
    expect(text(a), 'Oh, hello world');
    expect(text(receive(replica('o'), [base, world, oh])), 'Oh, hello world');
  });

  group('with a shared base', () {
    late Operation<int> base;
    late Replica<int> a;
    late Replica<int> b;

    setUp(() {
      (a, base) = commit(replica('a'), 1, [Insert(0, Text.of('abcd'))]);
      b = receive(replica('b'), [base]);
    });

    String merged(List<Command<int>> first, List<Command<int>> second) {
      final (_, one) = commit(a, 2, first);
      final (_, two) = commit(b, 3, second);
      final observed = receive(replica('o'), [base, one, two]);
      expect(
        observed.document.items.toList(),
        Model.of([base, one, two]).document.items.toList(),
      );
      return text(observed);
    }

    test('insertions at one position order earlier stamp first', () {
      expect(
        merged([Insert(1, Text.of('x'))], [Insert(1, Text.of('y'))]),
        'axybcd',
      );
      expect(
        merged([Insert(1, Text.of('y'))], [Insert(1, Text.of('x'))]),
        'ayxbcd',
      );
    });

    test('an insertion inside a concurrently deleted span survives', () {
      expect(merged([Delete(span(1, 2))], [Insert(2, Text.of('x'))]), 'axd');
      expect(merged([Insert(2, Text.of('x'))], [Delete(span(1, 2))]), 'axd');
    });

    test('overlapping deletions delete the union once', () {
      expect(merged([Delete(span(1, 2))], [Delete(span(2, 2))]), 'a');
    });

    test('a deletion split by a concurrent insertion becomes two', () {
      final (_, put) = commit(a, 2, [Insert(2, Text.of('x'))]);
      final (_, cut) = commit(b, 3, [Delete(span(0, 4))]);
      final held = receive(replica('o'), [base, put]);
      final (_, commands) = held.receive(cut).unwrap();
      expect(commands, hasLength(2));
      expect(text(receive(held, [cut])), 'x');
    });

    test('a replacement and a concurrent insertion both land', () {
      expect(
        merged([Replace(span(1, 1), Text.of('X'))], [Insert(2, Text.of('y'))]),
        'aXycd',
      );
    });

    test('a command past its context is out of bounds', () {
      final (_, one) = commit(a, 2, [Insert(0, Text.of('x'))]);
      final held = receive(replica('o'), [base, one]);
      final forged = Operation<int>(
        const Stamp(3, 0, 'b'),
        [base.stamp],
        [Delete(span(0, 5))],
        const {},
      );
      final failure = held.receive(forged) as Failure<Object?>;
      expect(failure.kind, Kind.bounds);
      expect(failure.message, contains('of its context of 4 items'));
    });

    test('an insertion past its context is out of bounds', () {
      final (_, one) = commit(a, 2, [Insert(0, Text.of('x'))]);
      final held = receive(replica('o'), [base, one]);
      final forged = Operation<int>(
        const Stamp(3, 0, 'b'),
        [base.stamp],
        [Insert(5, Text.of('y'))],
        const {},
      );
      final failure = held.receive(forged) as Failure<Object?>;
      expect(failure.kind, Kind.bounds);
      expect(failure.message, contains('position 5 is out of bounds'));
    });

    test('an empty concurrent insertion changes nothing', () {
      expect(
        merged([Insert(0, Text.of('x'))], [Insert(2, Text.of(''))]),
        'xabcd',
      );
    });
  });

  test('two words typed at one position do not interleave', () {
    var (a, base) = commit(replica('a'), 1, [Insert(0, Text.of('xy'))]);
    var b = receive(replica('b'), [base]);
    final operations = [base];
    // a types "abc" forwards, b types "def" backwards, at times that
    // alternate between them.
    for (final (index, letter) in 'abc'.split('').indexed) {
      final Operation<int> operation;
      (a, operation) = commit(a, 10 + 2 * index, [
        Insert(1 + index, Text.of(letter)),
      ]);
      operations.add(operation);
    }
    for (final (index, letter) in 'fed'.split('').indexed) {
      final Operation<int> operation;
      (b, operation) = commit(b, 11 + 2 * index, [Insert(1, Text.of(letter))]);
      operations.add(operation);
    }
    operations.sort((x, y) => x.stamp.compareTo(y.stamp));
    expect(text(receive(replica('o'), operations)), 'xabcdefy');
  });

  test('replicas branching from earlier states converge on the model, '
      'over 100 seeds', () {
    for (var seed = 0; seed < 100; seed++) {
      final random = Random(seed);
      final operations = <Operation<int>>[];
      for (var round = 0; round < 30; round++) {
        // A writer that has received a random prefix of the history in
        // canonical order commits one transaction, concurrent with every
        // operation after that prefix.
        final prefix = operations.sublist(
          0,
          random.nextInt(operations.length + 1),
        );
        final writer = receive(replica('w$round'), prefix);
        now = round + 1;
        final (_, operation) = writer
            .commit(transaction(random, writer.document, marks: false))
            .unwrap();
        operations.add(operation);
      }
      final observed = receive(replica('o'), operations);
      expect(
        observed.document.items.toList(),
        Model.of(operations).document.items.toList(),
        reason: 'seed $seed',
      );
    }
  });
}
