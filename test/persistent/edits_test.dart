import 'dart:math';

import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart';
import 'package:libara/src/persistent/edits.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// [from] with [commands] applied by `transact`, as a list.
List<T> applied<T>(Sequence<T> from, List<Command<T>> commands) =>
    Document.of(from).transact(commands).unwrap().items.toList();

/// The items [commands] delete plus the items they insert.
int cost<T>(List<Command<T>> commands) => [
  for (final command in commands)
    switch (command) {
      Insert(:final items) => items.length,
      Delete(:final span) => span.length,
      Replace(:final span, :final items) => span.length + items.length,
      _ => throw StateError('edits gave $command'),
    },
].fold(0, (sum, each) => sum + each);

/// The length of a longest common subsequence, by dynamic programming.
int common(List<int> a, List<int> b) {
  var row = List.filled(b.length + 1, 0);
  for (final x in a) {
    final next = List.filled(b.length + 1, 0);
    for (var j = 0; j < b.length; j++) {
      next[j + 1] = x == b[j] ? row[j] + 1 : max(next[j], row[j + 1]);
    }
    row = next;
  }
  return row[b.length];
}

void main() {
  group('edge cases', () {
    test('equal sequences need no commands', () {
      expect(edits(Items.of([1, 2, 3]), Items.of([1, 2, 3])), isEmpty);
      expect(edits(Items.of(<int>[]), Items.of(<int>[])), isEmpty);
    });

    test('from nothing is one insert', () {
      final commands = edits(Items.of(<int>[]), Items.of([1, 2]));
      expect(commands, hasLength(1));
      expect(commands.single, isA<Insert<int>>());
      expect(applied(Items.of(<int>[]), commands), [1, 2]);
    });

    test('to nothing is one delete', () {
      final commands = edits(Items.of([1, 2]), Items.of(<int>[]));
      expect(commands, hasLength(1));
      expect(commands.single, isA<Delete<int>>());
      expect(applied(Items.of([1, 2]), commands), isEmpty);
    });

    test('a changed run is one replace', () {
      final commands = edits(Items.of([1, 2, 3]), Items.of([1, 9, 3]));
      expect(commands, hasLength(1));
      expect(commands.single, isA<Replace<int>>());
    });

    test('runs come last first, in the positions of from', () {
      final from = Text.of('abcdef');
      final commands = edits(from, Text.of('aXcdeYf'));
      expect(commands, hasLength(2));
      expect((commands.first as Insert<int>).position, 5);
      expect((commands.last as Replace<int>).span.start, 1);
      expect(String.fromCharCodes(applied(from, commands)), 'aXcdeYf');
    });

    test('text compares code points, keeping a pair whole', () {
      final from = Text.of('a😀b');
      final commands = edits(from, Text.of('a😁b'));
      expect(commands.single, isA<Replace<int>>());
      expect((commands.single as Replace<int>).span.length, 1);
      expect(String.fromCharCodes(applied(from, commands)), 'a😁b');
    });

    test('inserted items keep the type of to', () {
      final commands = edits(Text.of('ab'), Text.of('axb'));
      expect((commands.single as Insert<int>).items, isA<Text>());
    });
  });

  test('turns from into to by a shortest script over 500 seeds', () {
    final random = Random(7);
    for (var round = 0; round < 500; round++) {
      // A small alphabet, so the sequences share much and differ often.
      List<int> sequence() => List.generate(
        random.nextInt(24),
        (_) => random.nextInt(1 + random.nextInt(4)),
      );
      final (a, b) = (sequence(), sequence());
      final commands = edits(Items.of(a), Items.of(b));
      expect(applied(Items.of(a), commands), b, reason: '$a -> $b');
      expect(
        cost(commands),
        a.length + b.length - 2 * common(a, b),
        reason: '$a -> $b: $commands',
      );
    }
  });

  test('works on items of any type', () {
    final from = Items.of(['x', 'y', 'z']);
    final to = Items.of(['x', 'q', 'z', 'w']);
    expect(applied(from, edits(from, to)), ['x', 'q', 'z', 'w']);
  });
}
