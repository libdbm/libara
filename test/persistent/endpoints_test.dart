import 'dart:math';

import 'package:libara/src/persistent/endpoints.dart';
import 'package:libara/src/persistent/label.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// A range as the naive model sees it.
final class Entry {
  Entry(this.owner, this.start, this.end, this.first, this.last);

  final Object owner;
  int start;
  int end;
  final Label first;
  final Label last;
}

int shifted(int position, int at, int count) =>
    position >= at ? position + count : position;

int collapsed(int position, int from, int to) => position < from
    ? position
    : position < to
    ? from
    : position - (to - from);

/// Positions never decrease in tree order, and labels strictly increase.
void ordered(Endpoints<Object> tree) {
  final entries = tree.entries.toList();
  for (var index = 1; index < entries.length; index++) {
    expect(
      entries[index - 1].position,
      lessThanOrEqualTo(entries[index].position),
    );
    expect(
      entries[index - 1].label.compareTo(entries[index].label),
      lessThan(0),
    );
  }
}

void agrees(Endpoints<Object> tree, List<Entry> model, String reason) {
  for (final entry in model) {
    expect(
      tree.position(entry.first, entry.owner),
      entry.start,
      reason: '$reason start',
    );
    expect(
      tree.position(entry.last, entry.owner),
      entry.end,
      reason: '$reason end',
    );
  }
  expect(tree.entries.length, model.length * 2, reason: reason);
  ordered(tree);
}

void main() {
  group('Endpoints basics', () {
    test('add places both endpoints, the start before the end', () {
      final owner = Object();
      final (tree, first, last) = Endpoints<Object>.empty()
          .add(owner, 3, 7)
          .unwrap();
      expect(tree.position(first, owner), 3);
      expect(tree.position(last, owner), 7);
      expect(first.compareTo(last), lessThan(0));
    });

    test('a zero-length range keeps its start before its end', () {
      final owner = Object();
      final (tree, first, last) = Endpoints<Object>.empty()
          .add(owner, 4, 4)
          .unwrap();
      expect(tree.position(first, owner), 4);
      expect(tree.position(last, owner), 4);
      expect(first.compareTo(last), lessThan(0));
    });

    test('a start after its end or a negative start is invalid', () {
      expect(Endpoints<Object>.empty().add(Object(), 5, 4), invalid);
      expect(Endpoints<Object>.empty().add(Object(), -1, 4), invalid);
    });

    test('put places one endpoint and drop removes it', () {
      final owner = Object();
      final (tree, label) = Endpoints<Object>.empty()
          .put(owner, 5, true)
          .unwrap();
      expect(tree.position(label, owner), 5);
      expect(tree.drop(Object(), label).entries.length, 1);
      expect(tree.drop(owner, label).entries, isEmpty);
    });

    test('put at a negative position is invalid', () {
      expect(Endpoints<Object>.empty().put(Object(), -1, true), invalid);
    });

    test('position is null for another owner', () {
      final owner = Object();
      final (tree, first, _) = Endpoints<Object>.empty()
          .add(owner, 3, 7)
          .unwrap();
      expect(tree.position(first, Object()), isNull);
    });

    test('remove drops both endpoints and ignores an absent owner', () {
      final owner = Object();
      final (tree, first, last) = Endpoints<Object>.empty()
          .add(owner, 3, 7)
          .unwrap();
      final removed = tree.remove(owner, first, last);
      expect(removed.entries, isEmpty);
      expect(tree.remove(Object(), first, last).entries.length, 2);
    });

    test('shift moves every endpoint at or after the position', () {
      final a = Object();
      final b = Object();
      var (tree, a1, a2) = Endpoints<Object>.empty().add(a, 2, 5).unwrap();
      final (next, b1, b2) = tree.add(b, 5, 9).unwrap();
      tree = next.shift(5, 10);
      expect(tree.position(a1, a), 2);
      expect(tree.position(a2, a), 15);
      expect(tree.position(b1, b), 15);
      expect(tree.position(b2, b), 19);
    });

    test('collapse sends endpoints inside the span to its start', () {
      final a = Object();
      final (tree, a1, a2) = Endpoints<Object>.empty().add(a, 4, 12).unwrap();
      final after = tree.collapse(2, 8);
      expect(after.position(a1, a), 2);
      expect(after.position(a2, a), 6);
    });
  });

  group('Endpoints after a collapse', () {
    test('a shift after a collapse', () {
      final a = Object();
      final (tree, a1, a2) = Endpoints<Object>.empty().add(a, 3, 5).unwrap();
      final after = tree.collapse(2, 8).shift(2, 4);
      expect(after.position(a1, a), 6);
      expect(after.position(a2, a), 6);
    });

    test('a range added inside a collapsed run', () {
      final a = Object();
      final b = Object();
      final (tree, a1, a2) = Endpoints<Object>.empty().add(a, 3, 5).unwrap();
      final (after, b1, b2) = tree.collapse(2, 8).add(b, 2, 4).unwrap();
      expect(after.position(a1, a), 2);
      expect(after.position(a2, a), 2);
      expect(after.position(b1, b), 2);
      expect(after.position(b2, b), 4);
      ordered(after);
    });

    test('two overlapping collapses', () {
      final a = Object();
      final (tree, a1, a2) = Endpoints<Object>.empty().add(a, 5, 20).unwrap();
      final after = tree.collapse(4, 10).collapse(2, 6);
      // First: 5 -> 4, 20 -> 14. Second: 4 -> 2, 14 -> 10.
      expect(after.position(a1, a), 2);
      expect(after.position(a2, a), 10);
    });
  });

  test('an earlier tree is unchanged by later operations', () {
    final a = Object();
    final (tree, a1, a2) = Endpoints<Object>.empty().add(a, 4, 12).unwrap();
    tree.shift(0, 5).collapse(1, 9).add(Object(), 0, 3);
    expect(tree.position(a1, a), 4);
    expect(tree.position(a2, a), 12);
  });

  test('4,000 ranges marked in order keep labels to two digits', () {
    var tree = const Endpoints<Object>.empty();
    for (var index = 0; index < 4000; index++) {
      (tree, _, _) = tree.add(Object(), 2 * index, 2 * index + 1).unwrap();
    }
    final longest = tree.entries
        .map((endpoint) => endpoint.label.digits.length)
        .reduce(max);
    expect(longest, lessThanOrEqualTo(2));
  });

  test('4,000 ranges marked last to first keep labels to two digits', () {
    var tree = const Endpoints<Object>.empty();
    for (var index = 3999; index >= 0; index--) {
      (tree, _, _) = tree.add(Object(), 2 * index, 2 * index + 1).unwrap();
    }
    final longest = tree.entries
        .map((endpoint) => endpoint.label.digits.length)
        .reduce(max);
    expect(longest, lessThanOrEqualTo(2));
  });

  test('relabel spaces labels evenly and keeps every endpoint', () {
    // One gap filled 4,000 times grows labels a digit every 16 ranges.
    var tree = const Endpoints<Object>.empty();
    (tree, _, _) = tree.add(Object(), 1000, 1001).unwrap();
    for (var index = 0; index < 4000; index++) {
      (tree, _, _) = tree.add(Object(), 500, 501).unwrap();
    }
    final labels = tree.spacing();
    final relabelled = tree.relabel(labels, const {});
    final before = tree.entries.toList();
    final after = relabelled.entries.toList();
    expect(after.length, before.length);
    for (var index = 0; index < before.length; index++) {
      expect(after[index].position, before[index].position);
      expect(identical(after[index].owner, before[index].owner), isTrue);
      expect(after[index].label, labels[before[index].label]);
      expect(after[index].partner, labels[before[index].partner]);
    }
    final longest = after
        .map((endpoint) => endpoint.label.digits.length)
        .reduce(max);
    expect(longest, 1);
    expect(relabelled.check(), const Success<void>(null));
  });

  test('of builds a tree from endpoints in tree order', () {
    final a = Object();
    final b = Object();
    final labels = Label.spread(4);
    final tree = Endpoints<Object>.of([
      (
        (
          position: 1,
          label: labels[0],
          owner: a,
          start: true,
          partner: labels[2],
        ),
        false,
      ),
      (
        (
          position: 2,
          label: labels[1],
          owner: b,
          start: true,
          partner: labels[3],
        ),
        false,
      ),
      (
        (position: 5, label: labels[2], owner: a, start: false, partner: null),
        false,
      ),
      (
        (position: 9, label: labels[3], owner: b, start: false, partner: null),
        false,
      ),
    ]);
    expect(tree.position(labels[0], a), 1);
    expect(tree.position(labels[3], b), 9);
    expect(tree.containing(3, null).toSet(), {a, b});
    expect(tree.check(), const Success<void>(null));
  });

  test('agrees with a naive list over 200 seeded random scripts', () {
    final random = Random(42);
    for (var script = 0; script < 200; script++) {
      var tree = Endpoints<Object>.empty();
      final model = <Entry>[];
      for (var step = 0; step < 60; step++) {
        final reason = 'script $script step $step';
        final choice = random.nextInt(10);
        if (choice < 4 || model.isEmpty) {
          final start = random.nextInt(60);
          final end = start + random.nextInt(4) * random.nextInt(15);
          final owner = Object();
          final (next, first, last) = tree.add(owner, start, end).unwrap();
          tree = next;
          model.add(Entry(owner, start, end, first, last));
        } else if (choice < 5) {
          final entry = model.removeAt(random.nextInt(model.length));
          tree = tree.remove(entry.owner, entry.first, entry.last);
        } else if (choice < 8) {
          final at = random.nextInt(70);
          final count = 1 + random.nextInt(10);
          tree = tree.shift(at, count);
          for (final entry in model) {
            entry.start = shifted(entry.start, at, count);
            entry.end = shifted(entry.end, at, count);
          }
        } else {
          final from = random.nextInt(60);
          final to = from + random.nextInt(20);
          tree = tree.collapse(from, to);
          for (final entry in model) {
            entry.start = collapsed(entry.start, from, to);
            entry.end = collapsed(entry.end, from, to);
          }
        }
        agrees(tree, model, reason);
        expect(tree.check(), const Success<void>(null), reason: reason);
      }
    }
  });
}
