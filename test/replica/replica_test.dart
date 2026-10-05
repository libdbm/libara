import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/replica/history.dart';
import 'package:libara/src/replica/replica.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'random.dart';

/// A replica with [id] whose clock reads [time] and then counts up.
Replica<int> replica(String id, {int time = 1000}) {
  var now = time;
  return Replica.create<int>(id, clock: () => now++).unwrap();
}

/// Expects [b] to hold what [a] holds: equal items, and each of [a]'s
/// ranges under the same key in [b], with the same range and gravities.
void same(Replica<int> a, Replica<int> b, {String reason = ''}) {
  expect(b.document.items.toList(), a.document.items.toList(), reason: reason);
  final ranges = a.document.markers;
  expect(b.document.markers, hasLength(ranges.length), reason: reason);
  for (final (marker, range) in ranges) {
    final theirs = b.marker(a.key(marker)!);
    expect(theirs, isNotNull, reason: reason);
    expect(b.document.resolve(theirs!), range, reason: reason);
    expect(
      b.document.gravity(theirs),
      a.document.gravity(marker),
      reason: reason,
    );
  }
}

void main() {
  test('a replica commits as transact applies, over 50 seeds', () {
    for (var seed = 0; seed < 50; seed++) {
      final random = Random(seed);
      var a = replica('a');
      var plain = Document<int>.empty();
      for (var round = 0; round < 60; round++) {
        final commands = transaction(random, a.document);
        final (next, operation) = a.commit(commands).unwrap();
        a = next;
        plain = plain.transact(commands).unwrap();
        expect(operation.commands, commands);
        expect(a.heads, [operation.stamp]);
      }
      expect(a.document.items.toList(), plain.items.toList());
      // Committed marks keep the caller's markers.
      expect(a.document.markers, plain.markers, reason: 'seed $seed');
    }
  });

  test('a replica receiving in order reaches the same document', () {
    for (var seed = 0; seed < 50; seed++) {
      final random = Random(seed);
      var a = replica('a');
      var b = replica('b');
      for (var round = 0; round < 60; round++) {
        final (next, operation) = a
            .commit(transaction(random, a.document))
            .unwrap();
        a = next;
        final before = b.document;
        final (received, commands) = b.receive(operation).unwrap();
        b = received;
        // The returned commands turn the previous document into the new one.
        expect(
          before.transact(commands).unwrap().items.toList(),
          b.document.items.toList(),
        );
        expect(b.heads, a.heads);
      }
      same(a, b, reason: 'seed $seed');
    }
  });

  test('the history agrees with the document and its Fugue tree', () {
    for (var seed = 0; seed < 50; seed++) {
      final random = Random(seed);
      var a = replica('a');
      var history = const History.empty();
      for (var round = 0; round < 60; round++) {
        final (next, operation) = a
            .commit(transaction(random, a.document))
            .unwrap();
        a = next;
        history = history.apply(operation.stamp, operation.commands);
        expect(history.length, a.document.length);
      }
      // Reading the tree in order, left children, item, right children,
      // gives the history's order.
      final order = <Identity>[];
      void read(Identity identity) {
        final entry = history.entry(identity)!;
        entry.lefts.forEach(read);
        order.add(identity);
        entry.rights.forEach(read);
      }

      history.roots.forEach(read);
      final items = history.items.toList();
      expect(order, [for (final (identity, _) in items) identity]);
      expect(history.size, items.length);
      expect(items.where((item) => item.$2.isEmpty).length, a.document.length);
    }
  });

  group('since', () {
    late Replica<int> a;
    late List<Operation<int>> operations;

    setUp(() {
      a = replica('a');
      operations = [];
      for (var round = 0; round < 4; round++) {
        final (next, operation) = a.commit([
          Insert(0, Items.of([round])),
        ]).unwrap();
        a = next;
        operations.add(operation);
      }
    });

    test('with no heads is every operation, in order', () {
      expect(a.since(const []), operations);
    });

    test('with the replica heads is nothing', () {
      expect(a.since(a.heads), isEmpty);
    });

    test('with an earlier head is what follows it', () {
      expect(a.since([operations[1].stamp]), operations.sublist(2));
    });

    test('ignores stamps it does not hold', () {
      expect(
        a.since([operations[1].stamp, const Stamp(1, 0, 'z')]),
        operations.sublist(2),
      );
    });
  });

  test('marks, unmarks, and updates travel by key', () {
    var a = replica('a');
    var b = replica('b');
    final mark = Mark<int>(tagged(0, 2));
    for (final commands in [
      [
        Insert<int>(0, Items.of([1, 2, 3])),
        mark,
      ],
      [Update<int>(mark.marker, {})],
      [
        Insert<int>(1, Items.of([9])),
      ],
    ]) {
      final (next, operation) = a.commit(commands).unwrap();
      a = next;
      b = b.receive(operation).unwrap().$1;
    }
    final key = a.key(mark.marker)!;
    expect(key.stamp, a.since(const []).first.stamp);
    expect(key.index, 1);
    same(a, b);
    final (unmarked, operation) = a.commit([Unmark(mark.marker)]).unwrap();
    b = b.receive(operation).unwrap().$1;
    expect(b.document.markers, isEmpty);
    expect(unmarked.document.markers, isEmpty);
    // The key table outlives the range.
    expect(b.marker(key), isNotNull);
  });

  test('the system clock stamps by default', () {
    final before = DateTime.now().millisecondsSinceEpoch;
    final (_, operation) = Replica.create<int>('a').unwrap().commit([
      Insert(0, Items.of([1])),
    ]).unwrap();
    expect(operation.stamp.time, greaterThanOrEqualTo(before));
  });

  group('Operation.same', () {
    final mark = Mark<int>(tagged(0, 1));
    final stamp = const Stamp(5, 0, 'a');
    final key = Key(stamp, 3);
    Operation<int> operation(
      List<Command<int>> commands, {
      List<Stamp> parents = const [Stamp(1, 0, 'a')],
      Marker? marker,
    }) => Operation(stamp, parents, commands, {(marker ?? mark.marker): key});
    final commands = <Command<int>>[
      Insert(0, Items.of([1, 2])),
      Delete(span(0, 1)),
      Replace(span(0, 1), Items.of([3])),
      mark,
      Update(mark.marker, {'n': Num(1)}),
      Unmark(mark.marker),
    ];

    test(
      'holds for the same commands over other markers with the same keys',
      () {
        final other = Marker();
        final copy = <Command<int>>[
          Insert<int>(0, Items.of([1, 2])),
          Delete<int>(span(0, 1)),
          Replace<int>(span(0, 1), Items.of([3])),
          Mark.of(other, tagged(0, 1)),
          Update<int>(other, {'n': Num(1)}),
          Unmark<int>(other),
        ];
        expect(
          operation(commands).same(operation(copy, marker: other)),
          isTrue,
        );
      },
    );

    test('fails for any difference', () {
      final base = operation(commands);
      // Each command of the base changed in one way, in its own place.
      final changed = <(int, Command<int>)>[
        (0, Insert(1, Items.of([1, 2]))),
        (0, Insert(0, Items.of([1, 3]))),
        (1, Delete(span(0, 2))),
        (2, Replace(span(1, 1), Items.of([3]))),
        (2, Replace(span(0, 1), Items.of([4]))),
        (3, Mark.of(mark.marker, tagged(0, 2))),
        (3, Mark.of(mark.marker, tagged(0, 1), start: Gravity.left)),
        (3, Mark.of(mark.marker, tagged(0, 1), end: Gravity.left)),
        (4, Update(mark.marker, {'n': Num(2)})),
        (4, Update(mark.marker, {'n': Num(1), 'm': Num(1)})),
        (5, Delete(span(0, 1))),
      ];
      for (final (index, command) in changed) {
        final variant = [...base.commands]..[index] = command;
        expect(base.same(operation(variant)), isFalse, reason: '$command');
      }
      expect(base.same(operation(commands, parents: const [])), isFalse);
      expect(base.same(operation(commands.take(5).toList())), isFalse);
      final foreign = Operation(stamp, base.parents, commands, {
        mark.marker: Key(stamp, 4),
      });
      expect(base.same(foreign), isFalse);
    });
  });
}
