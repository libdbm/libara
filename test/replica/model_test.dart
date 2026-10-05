import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/replica/replica.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'model.dart';
import 'random.dart';

/// The operation stamped `time.0@replica` after [parents].
Operation<int> operation(
  int time,
  String replica,
  List<Operation<int>> parents,
  List<Command<int>> commands, [
  Map<Marker, Key> keys = const {},
]) => Operation(
  Stamp(time, 0, replica),
  [for (final parent in parents) parent.stamp]..sort(),
  commands,
  keys,
);

/// The model's document as text.
String text(Model<int> model) => String.fromCharCodes(model.document.items);

void main() {
  test('on sequential histories it equals transact and the replica', () {
    for (var seed = 0; seed < 30; seed++) {
      final random = Random(seed);
      var now = 1000;
      var replica = Replica.create<int>('a', clock: () => now++).unwrap();
      var plain = Document<int>.empty();
      final operations = <Operation<int>>[];
      for (var round = 0; round < 40; round++) {
        final commands = transaction(random, replica.document);
        final (next, operation) = replica.commit(commands).unwrap();
        replica = next;
        plain = plain.transact(commands).unwrap();
        operations.add(operation);
      }
      final model = Model.of(operations);
      expect(model.document.items.toList(), plain.items.toList());
      expect(
        model.markers,
        hasLength(
          operations.expand((o) => o.commands).whereType<Mark<int>>().length,
        ),
      );
      for (final (marker, range) in replica.document.markers) {
        final mine = model.markers[replica.key(marker)!]!;
        expect(model.document.resolve(mine), range, reason: 'seed $seed');
        expect(model.document.gravity(mine), replica.document.gravity(marker));
      }
      expect(
        model.document.markers,
        hasLength(replica.document.markers.length),
      );
    }
  });

  group('concurrent', () {
    final base = operation(1, 'a', const [], [Insert(0, Text.of('abcd'))]);

    test('insertions at one position order earlier stamp first', () {
      // Both land between a and b: left children of b, by identity.
      final x = operation(2, 'a', [base], [Insert(1, Text.of('x'))]);
      final y = operation(3, 'b', [base], [Insert(1, Text.of('y'))]);
      expect(text(Model.of([base, x, y])), 'axybcd');
      final early = operation(2, 'b', [base], [Insert(1, Text.of('y'))]);
      final late = operation(3, 'a', [base], [Insert(1, Text.of('x'))]);
      expect(text(Model.of([base, early, late])), 'ayxbcd');
    });

    test('an insertion inside a concurrently deleted span survives', () {
      final cut = operation(2, 'a', [base], [Delete(span(1, 2))]);
      final put = operation(3, 'b', [base], [Insert(2, Text.of('x'))]);
      expect(text(Model.of([base, cut, put])), 'axd');
      final putFirst = operation(2, 'b', [base], [Insert(2, Text.of('x'))]);
      final cutLater = operation(3, 'a', [base], [Delete(span(1, 2))]);
      expect(text(Model.of([base, putFirst, cutLater])), 'axd');
    });

    test('overlapping deletions delete the union once', () {
      final one = operation(2, 'a', [base], [Delete(span(1, 2))]);
      final two = operation(3, 'b', [base], [Delete(span(2, 2))]);
      expect(text(Model.of([base, one, two])), 'a');
    });

    test('a deletion split by a concurrent insertion becomes two', () {
      final put = operation(2, 'b', [base], [Insert(2, Text.of('x'))]);
      final cut = operation(3, 'a', [base], [Delete(span(0, 4))]);
      final model = Model.of([base, put, cut]);
      expect(text(model), 'x');
      expect(model.document.commands, hasLength(2));
    });

    test('a replacement and a concurrent insertion both land', () {
      final small = operation(1, 'a', const [], [Insert(0, Text.of('abc'))]);
      final swap = operation(
        2,
        'a',
        [small],
        [Replace(span(1, 1), Text.of('X'))],
      );
      final put = operation(3, 'b', [small], [Insert(2, Text.of('y'))]);
      expect(text(Model.of([small, swap, put])), 'aXyc');
    });

    test('a mark over concurrently deleted items collapses, either order', () {
      final hello = operation(1, 'a', const [], [Insert(0, Text.of('hello'))]);
      final mark = Mark<int>(
        tagged(0, 5, attributes: {'name': Str(Text.of('b'))}),
      );
      for (final (markTime, cutTime) in [(2, 3), (3, 2)]) {
        final key = Key(Stamp(markTime, 0, 'a'), 0);
        final marked = operation(markTime, 'a', [hello], [mark], {
          mark.marker: key,
        });
        final cut = operation(cutTime, 'b', [hello], [Delete(span(0, 3))]);
        final model = Model.of([hello, marked, cut]);
        expect(text(model), 'lo');
        expect(
          model.document.resolve(model.markers[key]!)!.same(span(0, 2)),
          isTrue,
        );
      }
    });

    test(
      'an end at a concurrent insertion follows its gravity, either order',
      () {
        final ab = operation(1, 'a', const [], [Insert(0, Text.of('ab'))]);
        for (final gravity in Gravity.values) {
          for (final (markTime, putTime) in [(2, 3), (3, 2)]) {
            final mark = Mark<int>(tagged(0, 1), end: gravity);
            final key = Key(Stamp(markTime, 0, 'a'), 0);
            final marked = operation(markTime, 'a', [ab], [mark], {
              mark.marker: key,
            });
            final put = operation(
              putTime,
              'b',
              [ab],
              [Insert(1, Text.of('x'))],
            );
            final model = Model.of([ab, marked, put]);
            expect(text(model), 'axb');
            expect(
              model.document.resolve(model.markers[key]!)!.length,
              gravity == Gravity.right ? 2 : 1,
              reason: '$gravity $markTime',
            );
          }
        }
      },
    );

    test('an unmark wins over a concurrent update, either order', () {
      final mark = Mark<int>(tagged(0, 1));
      final key = Key(const Stamp(1, 0, 'a'), 1);
      final marked = operation(
        1,
        'a',
        const [],
        [Insert(0, Text.of('ab')), mark],
        {mark.marker: key},
      );
      for (final (unmarkTime, updateTime) in [(2, 3), (3, 2)]) {
        final unmark = operation(
          unmarkTime,
          'a',
          [marked],
          [Unmark(mark.marker)],
          {mark.marker: key},
        );
        final update = operation(
          updateTime,
          'b',
          [marked],
          [
            Update(mark.marker, {'n': Num(1)}),
          ],
          {mark.marker: key},
        );
        expect(Model.of([marked, unmark, update]).document.markers, isEmpty);
      }
    });

    test('concurrent updates resolve to the later stamp', () {
      final mark = Mark<int>(tagged(0, 1));
      final key = Key(const Stamp(1, 0, 'a'), 1);
      final marked = operation(
        1,
        'a',
        const [],
        [Insert(0, Text.of('ab')), mark],
        {mark.marker: key},
      );
      final one = operation(
        2,
        'b',
        [marked],
        [
          Update(mark.marker, {'x': Num(2)}),
        ],
        {mark.marker: key},
      );
      final two = operation(
        2,
        'a',
        [marked],
        [
          Update(mark.marker, {'x': Num(1)}),
        ],
        {mark.marker: key},
      );
      // 2.0@b is after 2.0@a, so its attributes win.
      final model = Model.of([marked, one, two]);
      expect(model.document.resolve(model.markers[key]!)!.attributes, {
        'x': Num(2),
      });
    });

    test('two words typed at one position do not interleave', () {
      final xy = operation(1, 'a', const [], [Insert(0, Text.of('xy'))]);
      // a types "abc" forwards, each letter after the last.
      final forwards = <Operation<int>>[];
      var parent = xy;
      for (final (index, letter) in 'abc'.split('').indexed) {
        parent = operation(
          10 + index,
          'a',
          [parent],
          [Insert(1 + index, Text.of(letter))],
        );
        forwards.add(parent);
      }
      // b types "def" backwards, each letter before the first.
      final backwards = <Operation<int>>[];
      parent = xy;
      for (final (index, letter) in 'fed'.split('').indexed) {
        parent = operation(
          10 + index,
          'b',
          [parent],
          [Insert(1, Text.of(letter))],
        );
        backwards.add(parent);
      }
      expect(text(Model.of([xy, ...forwards, ...backwards])), 'xabcdefy');
    });
  });
}
