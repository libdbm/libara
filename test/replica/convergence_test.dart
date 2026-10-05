import 'dart:math';

import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/replica/replica.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'model.dart';
import 'random.dart';
import 'replicas.dart';

/// [to] after receiving, in canonical order, everything [from] holds that
/// it lacks.
Replica<int> sync(Replica<int> to, Replica<int> from) =>
    receive(to, from.since(to.heads));

/// Every order of [operations] in which each comes after its parents.
Iterable<List<Operation<int>>> orders(List<Operation<int>> operations) sync* {
  if (operations.isEmpty) {
    yield const [];
    return;
  }
  final stamps = {for (final operation in operations) operation.stamp};
  for (final operation in operations) {
    if (operation.parents.any(stamps.contains)) {
      continue;
    }
    final rest = [
      for (final other in operations)
        if (other != operation) other,
    ];
    for (final order in orders(rest)) {
      yield [operation, ...order];
    }
  }
}

void main() {
  setUp(() => now = 1);

  test('Oh, hello world, both ways', () {
    var (a, base) = commit(replica('a'), 1, [Insert(0, Text.of('hello'))]);
    var b = receive(replica('b'), [base]);
    final Operation<int> world;
    (a, world) = commit(a, 2, [Insert(5, Text.of(' world'))]);
    final Operation<int> oh;
    (b, oh) = commit(b, 3, [Insert(0, Text.of('Oh, '))]);
    a = receive(a, [oh]);
    // b's own operation is later than a's: a replay.
    b = receive(b, [world]);
    expect(text(a), 'Oh, hello world');
    expect(text(b), 'Oh, hello world');
  });

  test('a caller marker resolves after an arrival out of order', () {
    var (a, base) = commit(replica('a'), 1, [Insert(0, Text.of('hello'))]);
    var b = receive(replica('b'), [base]);
    final Operation<int> put;
    (b, put) = commit(b, 2, [Insert(0, Text.of('oh '))]);
    final mark = Mark<int>(tagged(1, 3));
    (a, _) = commit(a, 3, [mark]);
    a = receive(a, [put]);
    expect(a.marker(a.key(mark.marker)!), same(mark.marker));
    expect(a.document.resolve(mark.marker)!.same(span(4, 3)), isTrue);
    expect(text(a), 'oh hello');
  });

  test('a late operation that does not fit its context fails, unchanged', () {
    var (a, base) = commit(replica('a'), 1, [Insert(0, Text.of('ab'))]);
    (a, _) = commit(a, 3, [Insert(0, Text.of('x'))]);
    final late = Operation<int>(
      const Stamp(2, 0, 'b'),
      [base.stamp],
      [Delete(span(0, 3))],
      const {},
    );
    final failure = a.receive(late) as Failure<Object?>;
    expect(failure.kind, Kind.bounds);
    expect(failure.message, contains('replica: 2.0@b'));
    expect(text(a), 'xab');
  });

  test('replicas converge on the model through random partial syncs, '
      'over 200 seeds', () {
    for (var seed = 0; seed < 200; seed++) {
      final random = Random(seed);
      final count = 3 + random.nextInt(3);
      final replicas = [for (var at = 0; at < count; at++) replica('r$at')];
      final operations = <Operation<int>>[];
      for (var round = 0; round < 40; round++) {
        final at = random.nextInt(count);
        now = round + 1;
        if (random.nextInt(3) == 0) {
          final other = random.nextInt(count);
          replicas[at] = sync(replicas[at], replicas[other]);
        } else {
          final (next, operation) = replicas[at]
              .commit(transaction(random, replicas[at].document))
              .unwrap();
          replicas[at] = next;
          operations.add(operation);
        }
      }
      // A full sync: each takes everything from the first, which first
      // takes everything from all.
      for (var at = 1; at < count; at++) {
        replicas[0] = sync(replicas[0], replicas[at]);
      }
      for (var at = 1; at < count; at++) {
        replicas[at] = sync(replicas[at], replicas[0]);
      }
      final model = Model.of(operations);
      for (final held in replicas) {
        agrees(held, model, reason: 'seed $seed ${held.id}');
        expect(held.heads, replicas[0].heads);
      }
    }
  });

  test('every causal delivery order gives the same replica', () {
    for (var seed = 0; seed < 20; seed++) {
      final random = Random(seed);
      now = 1;
      final (start, base) = commit(replica('a'), 1, [
        Insert(0, Items.of([1, 2, 3, 4])),
        Mark(tagged(1, 2)),
      ]);
      // Three writers, each committing twice from the base.
      final operations = <Operation<int>>[];
      for (final id in ['x', 'y', 'z']) {
        var writer = receive(replica(id), [base]);
        for (var round = 0; round < 2; round++) {
          now = 2 + random.nextInt(6);
          final (next, operation) = writer
              .commit(transaction(random, writer.document))
              .unwrap();
          writer = next;
          operations.add(operation);
        }
      }
      final model = Model.of([base, ...operations]);
      var count = 0;
      for (final order in orders(operations)) {
        agrees(
          receive(replica('o'), [base, ...order]),
          model,
          reason: 'seed $seed $order',
        );
        count++;
      }
      expect(count, 90);
      expect(start.heads, [base.stamp]);
    }
  });
}
