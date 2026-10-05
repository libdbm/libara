/// Timing tests for the replica module, run on demand with
/// `dart test --tags benchmark --run-skipped test/replica`.
@Tags(['benchmark'])
library;

import 'dart:math';

import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/replica/replica.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'random.dart';
import 'replicas.dart';

/// Microseconds, the median of seven runs of [run].
int time(void Function() run) {
  final times = <int>[];
  for (var round = 0; round < 7; round++) {
    final watch = Stopwatch()..start();
    run();
    times.add(watch.elapsedMicroseconds);
  }
  return (times..sort())[times.length ~/ 2];
}

/// [time] microseconds as milliseconds.
String ms(int time) => '${(time / 1000).toStringAsFixed(1)}ms';

/// A replica holding [count] items from `a`, one later operation from `a`,
/// and a concurrent operation from `b`, each inserting in the middle: the
/// replica before the last arrives, `b`'s operation, and `a`'s.
(Replica<int>, Operation<int>, Operation<int>) scene(int count) {
  now = 1;
  final (a, base) = commit(replica('a'), 1, [
    Insert(0, Items.of(List.generate(count, (index) => index % 10))),
  ]);
  final b = receive(replica('b'), [base]);
  final (_, theirs) = commit(b, 3, [
    Insert(count ~/ 2, Items.of([1])),
  ]);
  final (_, ours) = commit(a, 2, [
    Insert(count ~/ 3, Items.of([2])),
  ]);
  return (receive(replica('o'), [base]), theirs, ours);
}

void main() {
  test('sequential commits cost about what transact costs', () {
    final random = Random(5);
    var plain = Document<int>.empty();
    final transactions = <List<Command<int>>>[];
    for (var round = 0; round < 2000; round++) {
      final commands = transaction(random, plain);
      plain = plain.transact(commands).unwrap();
      transactions.add(commands);
    }
    final replicated = time(() {
      var held = replica('a');
      for (final commands in transactions) {
        held = held.commit(commands).unwrap().$1;
      }
    });
    final applied = time(() {
      var document = Document<int>.empty();
      for (final commands in transactions) {
        document = document.transact(commands).unwrap();
      }
    });
    print('2,000 commits: ${ms(replicated)}, transact: ${ms(applied)}');
    // The history and key tables add a constant factor.
    expect(replicated, lessThan(10 * max(1000, applied)));
  });

  test('a concurrent operation takes time near linear in the items', () {
    int run(int count) {
      final (held, theirs, ours) = scene(count);
      final before = receive(held, [ours]);
      return time(() => before.receive(theirs));
    }

    run(4000);
    final (small, large) = (run(4000), run(32000));
    print('concurrent, 4,000 items: ${ms(small)}, 32,000: ${ms(large)}');
    // Linear is 8 times; a quadratic scan would be 64.
    expect(large, lessThan(16 * max(200, small)));
  });

  test('an operation out of order takes time near linear in the items', () {
    int run(int count) {
      final (held, theirs, ours) = scene(count);
      final before = receive(held, [theirs]);
      return time(() => before.receive(ours));
    }

    run(4000);
    final (small, large) = (run(4000), run(32000));
    print('out of order, 4,000 items: ${ms(small)}, 32,000: ${ms(large)}');
    expect(large, lessThan(16 * max(200, small)));
  });
}
