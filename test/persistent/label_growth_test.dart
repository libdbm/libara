@Tags(['benchmark'])
library;

import 'dart:math';

import 'package:libara/src/persistent/endpoints.dart';
import 'package:libara/src/persistent/label.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// A workload: builds a tree from [count] ranges, passing every label it
/// creates to [note].
typedef Workload = Endpoints<Object> Function(
  int count,
  void Function(Label) note,
);

/// [tree] with a range from [start] to [end] added, its labels noted.
Endpoints<Object> add(
  Endpoints<Object> tree,
  int start,
  int end,
  void Function(Label) note,
) {
  final (next, first, last) = tree.add(Object(), start, end).unwrap();
  note(first);
  note(last);
  return next;
}

final workloads = <String, Workload>{
  // Disjoint ranges marked in order, as a tokenizer produces them.
  'ascending': (count, note) {
    var tree = const Endpoints<Object>.empty();
    for (var index = 0; index < count; index++) {
      tree = add(tree, 2 * index, 2 * index + 1, note);
    }
    return tree;
  },
  // The same ranges marked last to first.
  'prepended': (count, note) {
    var tree = const Endpoints<Object>.empty();
    for (var index = count - 1; index >= 0; index--) {
      tree = add(tree, 2 * index, 2 * index + 1, note);
    }
    return tree;
  },
  // Zero-length ranges at one position, each placed after the others.
  'same position': (count, note) {
    var tree = const Endpoints<Object>.empty();
    for (var index = 0; index < count; index++) {
      tree = add(tree, 5, 5, note);
    }
    return tree;
  },
  // Ranges inserted into one gap below a fixed later range.
  'between neighbours': (count, note) {
    var tree = add(const Endpoints<Object>.empty(), 1000, 1001, note);
    for (var index = 0; index < count; index++) {
      tree = add(tree, 500, 501, note);
    }
    return tree;
  },
  // A hundred live ranges, each round unmarking one and marking another at
  // a random position.
  'churn': (count, note) {
    final random = Random(42);
    var tree = const Endpoints<Object>.empty();
    final live = <(Object, Label, Label)>[];
    void mark() {
      final start = random.nextInt(1000);
      final owner = Object();
      final (next, first, last) = tree
          .add(owner, start, start + random.nextInt(50))
          .unwrap();
      note(first);
      note(last);
      tree = next;
      live.add((owner, first, last));
    }

    for (var index = 0; index < 100; index++) {
      mark();
    }
    for (var round = 0; round < count; round++) {
      final (owner, first, last) = live.removeAt(random.nextInt(live.length));
      tree = tree.remove(owner, first, last);
      mark();
    }
    return tree;
  },
};

void main() {
  final report = <String>[];

  tearDownAll(() {
    // Printed so the measurements are visible when the benchmark is run.
    print(report.join('\n'));
  });

  for (final MapEntry(key: name, value: workload) in workloads.entries) {
    test('label growth: $name', () {
      for (final count in [1000, 2000, 4000]) {
        var longest = 0;
        final watch = Stopwatch()..start();
        final tree = workload(
          count,
          (label) => longest = max(longest, label.digits.length),
        );
        watch.stop();
        final total = tree.entries.fold(
          0,
          (sum, endpoint) => sum + endpoint.label.digits.length,
        );
        report.add(
          '$name $count: longest $longest digits, '
          '$total digits held, ${watch.elapsedMilliseconds}ms',
        );
        expect(tree.check(), const Success<void>(null), reason: '$count');
      }
    });
  }
}
