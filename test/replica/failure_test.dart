import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/replica/replica.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// A replica with [id] whose clock reads [time] and then counts up.
Replica<int> replica(String id, {int time = 1000}) {
  var now = time;
  return Replica.create<int>(id, clock: () => now++).unwrap();
}

/// Expects [result] to be a failure of [kind] whose message holds [text].
void fails(Result<Object?> result, Kind kind, String text) {
  expect(result, isA<Failure<Object?>>());
  final failure = result as Failure<Object?>;
  expect(failure.kind, kind);
  expect(failure.message, contains(text));
}

void main() {
  group('create', () {
    test('an empty id is invalid', () {
      fails(Replica.create<int>(''), Kind.invalid, 'id is empty');
    });

    test('a negative skew is invalid', () {
      fails(Replica.create<int>('a', skew: -1), Kind.invalid, 'negative');
    });
  });

  group('commit', () {
    test('a move is not replicated', () {
      final a = replica('a').commit([Insert(0, Text.of('abc'))]).unwrap().$1;
      fails(
        a.commit([Move(span(0, 1), 3)]),
        Kind.invalid,
        'a move is not replicated',
      );
    });

    test('an empty list is invalid', () {
      fails(replica('a').commit(const []), Kind.invalid, 'nothing to commit');
    });

    test('a mark of a marker the replica knows is invalid', () {
      final mark = Mark<int>(tagged(0, 0));
      final a = replica('a').commit([mark]).unwrap().$1;
      fails(
        a.commit([Mark.of(mark.marker, tagged(0, 0))]),
        Kind.invalid,
        'command 0: ${mark.marker} is already known',
      );
      // Unmarked, it is still known.
      final unmarked = a.commit([Unmark(mark.marker)]).unwrap().$1;
      fails(
        unmarked.commit([Mark.of(mark.marker, tagged(0, 0))]),
        Kind.invalid,
        'already known',
      );
    });

    test('a marker marked twice in one list is invalid', () {
      final mark = Mark<int>(tagged(0, 0));
      fails(
        replica('a').commit([mark, Mark.of(mark.marker, tagged(0, 0))]),
        Kind.invalid,
        'command 1',
      );
    });

    test('an unmark or update of an unknown marker is invalid', () {
      fails(
        replica('a').commit([Unmark(Marker())]),
        Kind.invalid,
        'is not known',
      );
      fails(
        replica('a').commit([Update(Marker(), {})]),
        Kind.invalid,
        'is not known',
      );
    });

    test('a command that does not fit fails as transact does', () {
      final commands = [
        Insert<int>(3, Items.of([1])),
      ];
      final expected =
          Document<int>.empty().transact(commands) as Failure<Document<int>>;
      final failure = replica('a').commit(commands) as Failure<Object?>;
      expect(failure.kind, expected.kind);
      expect(failure.message, expected.message);
    });
  });

  group('receive', () {
    late Replica<int> a;
    late Operation<int> first;
    late Operation<int> second;
    final mark = Mark<int>(tagged(0, 1));

    setUp(() {
      a = replica('a');
      (a, first) = a.commit([
        Insert(0, Items.of([1, 2])),
        mark,
      ]).unwrap();
      (a, second) = a.commit([
        Insert(2, Items.of([3])),
      ]).unwrap();
    });

    test('a held operation changes nothing', () {
      final b = replica('b').receive(first).unwrap().$1;
      final (again, commands) = b.receive(first).unwrap();
      expect(again, same(b));
      expect(commands, isEmpty);
    });

    test('a different operation under a held stamp is invalid', () {
      final b = replica('b').receive(first).unwrap().$1;
      final forged = Operation<int>(first.stamp, first.parents, [
        Insert(0, Items.of([7])),
      ], const {});
      fails(b.receive(forged), Kind.invalid, 'differs');
    });

    test('a missing parent is missing, naming it', () {
      fails(
        replica('b').receive(second),
        Kind.missing,
        'parent ${first.stamp} is not held',
      );
    });

    test('parents not sorted and distinct are invalid', () {
      final b = replica('b')
          .receive(first)
          .unwrap()
          .$1
          .receive(second)
          .unwrap()
          .$1;
      final stamp = Stamp(second.stamp.time + 1, 0, 'c');
      fails(
        b.receive(
          Operation(stamp, [second.stamp, first.stamp], const [], const {}),
        ),
        Kind.invalid,
        'not sorted',
      );
      fails(
        b.receive(
          Operation(stamp, [first.stamp, first.stamp], const [], const {}),
        ),
        Kind.invalid,
        'not sorted',
      );
    });

    test('a stamp past the skew fails until the clock catches up', () {
      var now = 1000;
      var b = Replica.create<int>('b', clock: () => now).unwrap();
      final ahead = Operation<int>(const Stamp(2001, 0, 'c'), const [], [
        Insert(0, Items.of([1])),
      ], const {});
      fails(b.receive(ahead), Kind.invalid, '1001ms ahead');
      now = 1001;
      b = b.receive(ahead).unwrap().$1;
      expect(b.document.items.toList(), [1]);
    });

    test('a stamp not after its parent is invalid', () {
      final b = replica('b').receive(first).unwrap().$1;
      final early = Stamp(first.stamp.time - 1, 0, 'c');
      fails(
        b.receive(Operation(early, [first.stamp], const [], const {})),
        Kind.invalid,
        'is not after its parent',
      );
    });

    test('a mark keyed other than its stamp and place is invalid', () {
      final stamp = Stamp(first.stamp.time - 1, 0, 'c');
      final mark = Mark<int>(tagged(0, 0));
      fails(
        replica('b').receive(
          Operation(stamp, const [], [mark], {mark.marker: Key(stamp, 1)}),
        ),
        Kind.invalid,
        'is not $stamp#0',
      );
    });

    test('a marker with no key is invalid', () {
      final mark = Mark<int>(tagged(0, 0));
      fails(
        replica('b').receive(
          Operation(const Stamp(1, 0, 'c'), const [], [mark], const {}),
        ),
        Kind.invalid,
        'has no key',
      );
    });

    test('an unmark or update of a key not marked in context is invalid', () {
      final b = replica('b')
          .receive(first)
          .unwrap()
          .$1
          .receive(second)
          .unwrap()
          .$1;
      final key = a.key(mark.marker)!;
      final stamp = Stamp(second.stamp.time + 1, 0, 'a');
      final stranger = Marker();
      final unknown = Key(const Stamp(1, 0, 'z'), 0);
      fails(
        b.receive(
          Operation(stamp, b.heads, [Unmark(stranger)], {stranger: unknown}),
        ),
        Kind.invalid,
        '$unknown is not marked',
      );
      // Unmarked earlier in the same operation.
      fails(
        b.receive(
          Operation(
            stamp,
            b.heads,
            [Unmark(mark.marker), Update(mark.marker, {})],
            {mark.marker: key},
          ),
        ),
        Kind.invalid,
        'command 1: $key is not marked',
      );
    });

    test('a command that does not fit its context fails with its kind', () {
      fails(
        replica('b').receive(
          Operation(const Stamp(1, 0, 'c'), const [], [
            Delete(span(0, 1)),
          ], const {}),
        ),
        Kind.bounds,
        'replica: 1.0@c: transact: command 0',
      );
    });

    test('a failed receive leaves the replica unchanged', () {
      final b = replica('b').receive(first).unwrap().$1;
      final before = b.document;
      expect(
        b.receive(
          Operation(
            Stamp(first.stamp.time + 1, 0, 'c'),
            [first.stamp],
            [Delete(span(0, 9))],
            const {},
          ),
        ),
        isA<Failure<Object?>>(),
      );
      expect(b.document, same(before));
      expect(b.heads, [first.stamp]);
    });
  });
}
