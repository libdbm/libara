import 'dart:convert';
import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/format/format.dart';
import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/replica/replica.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'model.dart';
import 'random.dart';
import 'replicas.dart' hide text;

const format = OperationFormat<int>(text);

/// The operations of a random history of [count] replicas.
List<Operation<int>> history(Random random, int count) {
  final replicas = [for (var at = 0; at < count; at++) replica('r$at')];
  final operations = <Operation<int>>[];
  for (var round = 0; round < 30; round++) {
    final at = random.nextInt(count);
    now = round + 1;
    if (random.nextInt(3) == 0) {
      final other = replicas[random.nextInt(count)];
      replicas[at] = receive(replicas[at], other.since(replicas[at].heads));
    } else {
      final (next, operation) = replicas[at]
          .commit(transaction(random, replicas[at].document))
          .unwrap();
      replicas[at] = next;
      operations.add(operation);
    }
  }
  return operations..sort((a, b) => a.stamp.compareTo(b.stamp));
}

/// [operation] through JSON text and back.
Operation<int> travelled(Operation<int> operation) => format
    .decode(jsonDecode(jsonEncode(format.encode(operation).unwrap())))
    .unwrap();

/// Expects [result] to be a failure of [kind] whose message holds [text].
void fails(Result<Object?> result, Kind kind, String text) {
  expect(result, isA<Failure<Object?>>());
  final failure = result as Failure<Object?>;
  expect(failure.kind, kind, reason: failure.message);
  expect(failure.message, contains(text));
}

void main() {
  setUp(() => now = 1);

  test('every operation of random histories round-trips, over 50 seeds', () {
    for (var seed = 0; seed < 50; seed++) {
      for (final operation in history(Random(seed), 3)) {
        final back = travelled(operation);
        expect(back.same(operation), isTrue, reason: '$operation');
      }
    }
  });

  test('a replica restored from its operations equals the original', () {
    for (var seed = 0; seed < 20; seed++) {
      final operations = history(Random(seed), 3);
      var original = replica('x');
      original = receive(original, operations);
      final restored = receive(replica('x'), [
        for (final operation in original.since(const [])) travelled(operation),
      ]);
      agrees(restored, Model.of(operations), reason: 'seed $seed');
      expect(restored.heads, original.heads);
    }
  });

  test('markers are written as keys', () {
    final mark = Mark<int>(tagged(0, 1, attributes: {'n': Num(1)}));
    final operation = Operation<int>(
      const Stamp(5, 1, 'a'),
      const [Stamp(4, 0, 'b')],
      [Insert(0, Text.of('x')), mark, Unmark(mark.marker)],
      {mark.marker: const Key(Stamp(5, 1, 'a'), 1)},
    );
    expect(format.encode(operation).unwrap(), {
      'libara': 1,
      'stamp': [5, 1, 'a'],
      'parents': [
        [4, 0, 'b'],
      ],
      'commands': [
        {'command': 'insert', 'position': 0, 'items': 'x'},
        {
          'command': 'mark',
          'id': [5, 1, 'a', 1],
          'range': [0, 1],
          'start': 'right',
          'end': 'right',
          'attributes': {'n': 1},
        },
        {
          'command': 'unmark',
          'id': [5, 1, 'a', 1],
        },
      ],
    });
    final back = travelled(operation);
    // One key, one marker, named by both commands.
    expect(back.keys, hasLength(1));
    expect(
      (back.commands[2] as Unmark<int>).marker,
      same((back.commands[1] as Mark<int>).marker),
    );
  });

  group('malformed operations', () {
    Map<String, Object?> valid() => {
      'libara': 1,
      'stamp': [5, 0, 'a'],
      'parents': <Object?>[],
      'commands': [
        {
          'command': 'unmark',
          'id': [1, 0, 'b', 0],
        },
      ],
    };

    final cases = <(String, Object? Function(), Kind, String)>[
      ('not an object', () => [1], Kind.syntax, 'replica: expected an object'),
      ('no version', () => valid()..remove('libara'), Kind.syntax, 'libara'),
      ('another version', () => valid()..['libara'] = 2, Kind.invalid, '2'),
      ('stamp shape', () => valid()..['stamp'] = [1, 0], Kind.syntax, 'stamp'),
      (
        'negative stamp',
        () => valid()..['stamp'] = [-1, 0, 'a'],
        Kind.invalid,
        'is not a stamp',
      ),
      (
        'empty replica',
        () => valid()..['stamp'] = [1, 0, ''],
        Kind.invalid,
        'is not a stamp',
      ),
      ('parents', () => valid()..['parents'] = 3, Kind.syntax, 'parents'),
      (
        'a parent',
        () => valid()..['parents'] = ['x'],
        Kind.syntax,
        'parents[0]',
      ),
      ('commands', () => valid()..['commands'] = {}, Kind.syntax, 'commands'),
      (
        'a command',
        () => valid()
          ..['commands'] = [
            {'command': 'shuffle'},
          ],
        Kind.syntax,
        'commands[0].command',
      ),
      (
        'key shape',
        () => valid()
          ..['commands'] = [
            {'command': 'unmark', 'id': 0},
          ],
        Kind.syntax,
        'commands[0].id: expected [time, count, replica, index]',
      ),
      (
        'negative index',
        () => valid()
          ..['commands'] = [
            {
              'command': 'unmark',
              'id': [1, 0, 'b', -1],
            },
          ],
        Kind.invalid,
        'index -1 is negative',
      ),
      (
        'key stamp',
        () => valid()
          ..['commands'] = [
            {
              'command': 'unmark',
              'id': [1, -1, 'b', 0],
            },
          ],
        Kind.invalid,
        'commands[0].id: [1, -1, "b"] is not a stamp',
      ),
    ];
    for (final (name, json, kind, text) in cases) {
      test(name, () => fails(format.decode(json()), kind, text));
    }
  });

  group('limits', () {
    final mark = Mark<int>(
      tagged(0, 1, attributes: {'a': Num(1), 'b': Num(2)}),
    );
    final stamp = const Stamp(5, 0, 'a');
    final operation = Operation<int>(
      stamp,
      const [],
      [Insert(0, Text.of('abc')), mark, Mark<int>.of(Marker(), tagged(0, 0))],
      {mark.marker: Key(stamp, 1)},
    );
    final json = format
        .encode(
          Operation<int>(stamp, const [], operation.commands, {
            mark.marker: Key(stamp, 1),
            (operation.commands[2] as Mark<int>).marker: Key(stamp, 2),
          }),
        )
        .unwrap();

    test('bound commands, markers, attributes, and payload both ways', () {
      for (final (limits, name) in [
        (const Limits(commands: 2), 'commands: 3 exceeds 2'),
        (const Limits(markers: 1), 'markers: 2 exceeds 1'),
        (const Limits(attributes: 1), 'attributes: 2 exceeds 1'),
        (const Limits(payload: 2), 'payload: 3 exceeds 2'),
      ]) {
        final bounded = OperationFormat<int>(text, limits: limits);
        fails(bounded.decode(json), Kind.invalid, name);
        fails(bounded.encode(format.decode(json).unwrap()), Kind.invalid, name);
      }
    });

    test('bound the nesting of item JSON on encoding', () {
      final nested = OperationFormat(_Nested(), limits: const Limits(depth: 1));
      fails(
        nested.encode(
          Operation<int>(stamp, const [], [Insert(0, Text.of('a'))], const {}),
        ),
        Kind.invalid,
        'replica: commands[0].items',
      );
    });
  });

  test(
    'decoding mangled operations always gives a result, over 2000 seeds',
    () {
      final random = Random(11);
      final operations = history(Random(1), 3);
      Object? noise(int depth) => switch (random.nextInt(depth > 2 ? 4 : 6)) {
        0 => random.nextInt(20) - 5,
        1 => ['', 'a', 'mark', 'insert', 'left'][random.nextInt(5)],
        2 => null,
        3 => random.nextBool(),
        4 => [for (var at = 0; at < random.nextInt(5); at++) noise(depth + 1)],
        _ => {
          for (final key in ['command', 'id', 'range', 'items', 'stamp'])
            if (random.nextBool()) key: noise(depth + 1),
        },
      };
      Object? mangled(Object? json) {
        if (random.nextInt(6) == 0) {
          return noise(0);
        }
        return switch (json) {
          final List<Object?> list => [for (final item in list) mangled(item)],
          final Map<String, Object?> map => {
            for (final MapEntry(:key, :value) in map.entries)
              if (random.nextInt(8) != 0) key: mangled(value),
          },
          _ => json,
        };
      }

      for (var round = 0; round < 2000; round++) {
        final operation = operations[round % operations.length];
        final json = jsonDecode(jsonEncode(format.encode(operation).unwrap()));
        expect(format.decode(mangled(json)), isA<Result<Operation<int>>>());
      }
    },
  );
}

/// An item format that writes every item two lists deep.
final class _Nested implements Format<Sequence<int>, Object?> {
  @override
  Result<Object?> encode(Sequence<int> value) => Success([
    [value.items.toList()],
  ]);

  @override
  Result<Sequence<int>> decode(Object? form) =>
      const Failure(Kind.invalid, 'unused');
}
