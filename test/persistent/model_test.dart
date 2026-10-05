import 'dart:convert';
import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/format/format.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// The naive model: a plain list of items, and each marker's range as two
/// integers adjusted directly by the edit rules `Document.apply` documents.
final class Model {
  Model(this.items, this.ranges);

  final List<int> items;

  /// Each marker's raw start and end, attributes, and endpoint gravities.
  final Map<Marker, (int, int, Map<String, Value>, Gravity, Gravity)> ranges;

  Model copy() => Model([...items], {...ranges});

  void insert(int at, List<int> added) {
    items.insertAll(at, added);
    int moved(int position, Gravity gravity) =>
        position > at || position == at && gravity == Gravity.right
        ? position + added.length
        : position;
    ranges.updateAll(
      (_, range) => (
        moved(range.$1, range.$4),
        moved(range.$2, range.$5),
        range.$3,
        range.$4,
        range.$5,
      ),
    );
  }

  void delete(int from, int to) {
    items.removeRange(from, to);
    int moved(int position) => position < from
        ? position
        : position < to
        ? from
        : position - (to - from);
    ranges.updateAll(
      (_, range) =>
          (moved(range.$1), moved(range.$2), range.$3, range.$4, range.$5),
    );
  }

  /// A marker's range as read: an end before the start reads as zero-length
  /// at the start.
  ARange? read(Marker marker) {
    final range = ranges[marker];
    if (range == null) {
      return null;
    }
    final (start, end, attributes, _, _) = range;
    return tagged(start, max(start, end) - start, attributes: attributes);
  }

  List<ARange> get expected => [
    for (final marker in ranges.keys) read(marker)!,
  ];
}

/// Whether [ranges] is in start order: by start, then by length.
void ordered(List<ARange> ranges, String reason) {
  for (var index = 1; index < ranges.length; index++) {
    final previous = ranges[index - 1];
    final current = ranges[index];
    expect(
      previous.start < current.start ||
          previous.start == current.start && previous.length <= current.length,
      isTrue,
      reason: '$reason out of start order at $index',
    );
  }
}

/// The document matches the model: items, every range, and every marker.
void matches(
  Document<int> document,
  Model model,
  Iterable<Marker> known,
  String reason,
) {
  expect(document.items, model.items, reason: '$reason items');
  final ranges = document.ranges.items.cast<ARange>().toList();
  expect(ranges, unorderedEquals(model.expected), reason: '$reason ranges');
  ordered(ranges, '$reason ranges');
  final pairs = document.markers;
  expect(
    [for (final (_, range) in pairs) range],
    ranges,
    reason: '$reason markers in the order of ranges',
  );
  for (final (marker, range) in pairs) {
    expect(model.read(marker), range, reason: '$reason markers $marker');
  }
  for (final marker in known) {
    expect(
      document.resolve(marker),
      model.read(marker),
      reason: '$reason resolve $marker',
    );
  }
}

/// `at(x)` matches the model's ranges with `start <= x < end`, for every
/// position from before the start to past the end.
/// [document] survives a save, a trip through a JSON string, and a load:
/// the same items and ranges, and each saved marker's range and gravities
/// on its loaded counterpart.
void survives(Document<int> document, String reason) {
  final saved = jsonDecode(
    jsonEncode(JSONFormat(text).encode(document).unwrap()),
  );
  final (loaded, markers) = JSONFormat(text).restore(saved).unwrap();
  expect(loaded.items, document.items, reason: '$reason format items');
  expect(loaded.ranges, document.ranges, reason: '$reason format ranges');
  for (final (index, (marker, range)) in document.markers.indexed) {
    expect(loaded.resolve(markers[index]), range, reason: '$reason format');
    expect(loaded.gravity(markers[index]), document.gravity(marker));
  }
  expect(check(loaded), const Success<void>(null), reason: reason);
}

/// `overlapping` matches the model's ranges that overlap each of a spread
/// of query ranges, zero-length ones included.
void overlaps(Document<int> document, Model model, String reason) {
  final random = Random(reason.hashCode);
  for (var round = 0; round < 12; round++) {
    final start = random.nextInt(model.items.length + 2);
    final query = span(start, random.nextInt(4) * random.nextInt(8));
    final found = document.overlapping(query).items.cast<ARange>().toList();
    final expected = [
      for (final range in model.expected)
        if (range.overlaps(query)) range,
    ];
    expect(found, unorderedEquals(expected), reason: '$reason $query');
    ordered(found, '$reason $query');
  }
}

/// `within` and `crossing` match the model's markers whose ranges, as
/// read, lie within each of a spread of regions, zero-length ones
/// included, and span each of a spread of positions, from before the start
/// to past the end.
void regions(Document<int> document, Model model, String reason) {
  List<(Marker, ARange)> expected(bool Function(ARange range) wanted) => [
    for (final marker in model.ranges.keys)
      if (wanted(model.read(marker)!)) (marker, model.read(marker)!),
  ];
  final random = Random(reason.hashCode + 1);
  for (var round = 0; round < 12; round++) {
    final start = random.nextInt(model.items.length + 2);
    final region = span(start, random.nextInt(4) * random.nextInt(8));
    final found = document.within(region);
    expect(
      found,
      unorderedEquals(
        expected(
          (range) => region.start <= range.start && range.end <= region.end,
        ),
      ),
      reason: '$reason within $region',
    );
    ordered([for (final (_, range) in found) range], '$reason within');
  }
  for (var round = 0; round < 12; round++) {
    final position = random.nextInt(model.items.length + 3) - 1;
    final found = document.crossing(position);
    expect(
      found,
      unorderedEquals(
        expected((range) => range.start < position && position < range.end),
      ),
      reason: '$reason crossing($position)',
    );
    ordered([for (final (_, range) in found) range], '$reason crossing');
  }
}

void contains(Document<int> document, Model model, String reason) {
  for (var position = -1; position <= model.items.length + 1; position++) {
    final found = document.at(position).items.cast<ARange>().toList();
    final expected = [
      for (final range in model.expected)
        if (range.start <= position && position < range.end) range,
    ];
    expect(found, unorderedEquals(expected), reason: '$reason at($position)');
    ordered(found, '$reason at($position)');
  }
}

/// Runs 200 seeded random command scripts against a document and the model.
/// With [gravities], each mark gets random endpoint gravities. With
/// [containing], `at` is checked at every position after every step.
void scripts({
  required int seed,
  required bool gravities,
  required bool containing,
}) {
  final random = Random(seed);
  for (var script = 0; script < 200; script++) {
    final start = List.generate(random.nextInt(40), (_) => random.nextInt(100));
    var document = Document.of(Items.of(start));
    final model = Model([...start], {});
    final known = <Marker>[];
    // One model snapshot per version, replaced when a command coalesces.
    final history = [model.copy()];

    for (var step = 0; step < 60; step++) {
      final reason = 'script $script step $step';

      /// A random command that fits the model, applied to the model.
      Command<int> next() {
        final length = model.items.length;
        final live = model.ranges.keys.toList();
        final choice = random.nextInt(12);
        if (choice < 3) {
          final at = random.nextInt(length + 1);
          final added = List.generate(
            1 + random.nextInt(8),
            (_) => random.nextInt(100),
          );
          model.insert(at, added);
          return Insert(at, Items.of(added));
        } else if (choice == 9 && length > 0) {
          final from = random.nextInt(length);
          final to = from + random.nextInt(min(10, length - from) + 1);
          final added = List.generate(
            random.nextInt(6),
            (_) => random.nextInt(100),
          );
          model
            ..delete(from, to)
            ..insert(from, added);
          return Replace(span(from, to - from), Items.of(added));
        } else if (choice < 5 && length > 0) {
          final from = random.nextInt(length);
          final to = from + random.nextInt(min(10, length - from) + 1);
          model.delete(from, to);
          return Delete(span(from, to - from));
        } else if (choice <= 9 || live.isEmpty) {
          final from = random.nextInt(length + 1);
          final to = from + random.nextInt(length - from + 1);
          final attributes = random.nextBool()
              ? {'step': Value.of(step).unwrap()}
              : <String, Value>{};
          final first = gravities
              ? Gravity.values[random.nextInt(2)]
              : Gravity.right;
          final last = gravities
              ? Gravity.values[random.nextInt(2)]
              : Gravity.right;
          final mark = Mark<int>(
            tagged(from, to - from, attributes: attributes),
            start: first,
            end: last,
          );
          known.add(mark.marker);
          model.ranges[mark.marker] = (from, to, attributes, first, last);
          return mark;
        } else if (choice == 11) {
          final marker = live[random.nextInt(live.length)];
          final (start, end, _, first, last) = model.ranges[marker]!;
          final attributes = {'updated': Value.of(step).unwrap()};
          model.ranges[marker] = (start, end, attributes, first, last);
          return Update(marker, attributes);
        } else {
          final marker = live[random.nextInt(live.length)];
          model.ranges.remove(marker);
          return Unmark(marker);
        }
      }

      // Now and then, apply a few commands as one transaction.
      if (random.nextInt(6) == 0) {
        final count = 1 + random.nextInt(4);
        final commands = [for (var index = 0; index < count; index++) next()];
        final result = document.transact(commands);
        expect(
          result,
          isA<Success<Document<int>>>(),
          reason: '$reason $commands',
        );
        document = result.or(document);
        expect(document.commands, commands, reason: reason);
        history.add(model.copy());
      } else {
        final command = next();
        final flatten = random.nextInt(4) == 0;
        final result = document.apply(command, flatten: flatten);
        expect(
          result,
          isA<Success<Document<int>>>(),
          reason: '$reason $command',
        );
        document = result.or(document);
        if (flatten) {
          history.last = model.copy();
        } else {
          history.add(model.copy());
        }
      }
      // Now and then, compact and keep editing the compacted document.
      if (random.nextInt(15) == 0) {
        document = document.compact();
        expect(document.previous, isNull, reason: reason);
        expect(document.commands, isEmpty, reason: reason);
        history
          ..clear()
          ..add(model.copy());
      }
      expect(document.version, history.length - 1, reason: reason);
      matches(document, model, known, reason);
      expect(check(document), const Success<void>(null), reason: reason);
      survives(document, reason);
      if (containing) {
        contains(document, model, reason);
        overlaps(document, model, reason);
        regions(document, model, reason);
      }
    }

    // The whole history survives a save and load with every version.
    final saved = jsonDecode(
      jsonEncode(JSONFormat(text, history: true).encode(document).unwrap()),
    );
    Document<int>? original = document;
    Document<int>? copy = JSONFormat(text).decode(saved).unwrap();
    while (original != null) {
      final reason = 'script $script history version ${original.version}';
      expect(copy, isNotNull, reason: reason);
      expect(copy!.items, original.items, reason: reason);
      // The order among ranges with equal start and length is not kept.
      final ranges = copy.ranges.items.cast<ARange>().toList();
      expect(ranges, unorderedEquals(original.ranges.items), reason: reason);
      ordered(ranges, reason);
      original = original.previous;
      copy = copy.previous;
    }
    expect(copy, isNull, reason: 'script $script history length');

    // Walking back through previous reproduces every earlier version.
    Document<int>? version = document;
    for (final snapshot in history.reversed) {
      matches(
        version!,
        snapshot,
        known,
        'script $script version ${version.version}',
      );
      version = version.previous;
    }
    expect(version, isNull);
  }
}

void main() {
  test('agrees with a naive model over 200 seeded random scripts', () {
    scripts(seed: 42, gravities: false, containing: true);
  });

  test('agrees with a naive model with random gravities', () {
    scripts(seed: 7, gravities: true, containing: true);
  });

  test('a document held before ten further edits is unchanged', () {
    final mark = Mark<int>(
      tagged(2, 3, attributes: {'type': Value.of('word').unwrap()}),
    );
    final start = Document.of(Text.of('abcdefgh'));
    final held = start.apply(mark).or(start);
    var document = held;
    for (var round = 0; round < 10; round++) {
      document = document.apply(Insert(round % 4, Text.of('xy'))).or(document);
      document = document.apply(Delete<int>(span(round % 3, 1))).or(document);
    }
    expect(String.fromCharCodes(held.items), 'abcdefgh');
    expect(
      held.ranges,
      Ranges.of([
        tagged(2, 3, attributes: {'type': Value.of('word').unwrap()}),
      ]),
    );
    expect(
      held.resolve(mark.marker),
      tagged(2, 3, attributes: {'type': Value.of('word').unwrap()}),
    );
    expect(document.items, isNot(held.items));
  });
}
