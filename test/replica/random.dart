import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';

import '../support.dart';

/// A random transaction of one to four commands of all six kinds, or of
/// insertions, deletions, and replacements only when [marks] is false,
/// each fitting [document] after the ones before it, naming only markers
/// that [document] holds or that the transaction marks.
List<Command<int>> transaction(
  Random random,
  Document<int> document, {
  bool marks = true,
}) {
  var current = document;
  final commands = <Command<int>>[];
  final count = 1 + random.nextInt(4);
  for (var round = 0; round < count; round++) {
    final command = _command(random, current, marks);
    current = current.apply(command).unwrap();
    commands.add(command);
  }
  return commands;
}

Command<int> _command(Random random, Document<int> document, bool marks) {
  final length = document.length;
  final marked = document.markers;
  int position() => random.nextInt(length + 1);
  Items<int> items() =>
      Items.of(List.generate(1 + random.nextInt(3), (_) => random.nextInt(10)));
  Range region() {
    final start = position();
    return span(start, random.nextInt(length - start + 1));
  }

  Map<String, Value> attributes() => {'n': Num(random.nextInt(5))};
  Gravity gravity() => Gravity.values[random.nextInt(2)];
  return switch (random.nextInt(marks ? 6 : 3)) {
    1 when length > 0 => Delete(region()),
    2 when length > 0 => Replace(region(), items()),
    3 => Mark(
      ARange.from(region(), attributes()),
      start: gravity(),
      end: gravity(),
    ),
    4 when marked.isNotEmpty => Unmark(
      marked[random.nextInt(marked.length)].$1,
    ),
    5 when marked.isNotEmpty => Update(
      marked[random.nextInt(marked.length)].$1,
      attributes(),
    ),
    _ => Insert(position(), items()),
  };
}
