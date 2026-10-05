import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/layered/layered.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart' show Document;
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'brackets.dart';
import 'reads.dart';

/// A seeded script of random edits to a layered bracket document.
final class Script {
  Script(int seed) : random = Random(seed);

  final Random random;

  /// A random text of [length] brackets and letters.
  String text(int length) => String.fromCharCodes([
    for (var index = 0; index < length; index++)
      '[]ab'.codeUnitAt(random.nextInt(4)),
  ]);

  /// A random edit to [document], at any layer, legal or not, unmarking or
  /// updating only groups whose markers are in [known] when given.
  Edit<int> edit(Layered<int> document, [Set<Marker>? known]) {
    final items = document.items.length;
    final tokens = document.layer(2).length;
    final all = document.markers(3);
    final groups = [
      for (final group in all)
        if (known == null || known.contains(group.$1)) group,
    ];
    switch (random.nextInt(8)) {
      case 0:
        final start = random.nextInt(tokens + 1);
        return Edit(
          3,
          Mark(
            tagged(
              start,
              random.nextInt(tokens - start + 1),
              attributes: {'type': kind('group')},
            ),
          ),
        );
      case 1 when groups.isNotEmpty:
        final (marker, _) = groups[random.nextInt(groups.length)];
        return Edit(3, Unmark<Object?>(marker));
      case 2:
        final start = random.nextInt(all.length + 1);
        return Edit(
          3,
          Delete<Object?>(span(start, random.nextInt(all.length - start + 1))),
        );
      case 3 when groups.isNotEmpty:
        final (marker, _) = groups[random.nextInt(groups.length)];
        return Edit(
          3,
          Update<Object?>(marker, {
            'type': kind('group'),
            'note': Num(random.nextInt(3)),
          }),
        );
      case 4:
        final start = random.nextInt(tokens + 1);
        return Edit(
          2,
          Delete<Object?>(span(start, random.nextInt(tokens - start + 1))),
        );
      case 5:
        return Edit(
          2,
          Mark(
            tagged(
              random.nextInt(items + 1),
              0,
              attributes: {'type': type(random.nextBool() ? 0x5B : 0x5D)},
            ),
          ),
        );
      default:
        final start = random.nextInt(items + 1);
        return Edit(
          1,
          Replace(
            span(start, random.nextInt(items - start + 1)),
            Text.of(text(random.nextInt(3))),
          ),
        );
    }
  }
}

void main() {
  test('every version matches a derivation from scratch and its change', () {
    var accepted = 0;
    var transactions = 0;
    for (var seed = 0; seed < 200; seed++) {
      final script = Script(seed);
      final random = script.random;
      var document = Layered.of(
        Text.of(script.text(random.nextInt(12))),
        Brackets(),
      ).unwrap();
      for (var step = 0; step < 60; step++) {
        final reason =
            'seed $seed, step $step, ${String.fromCharCodes(document.items.items)}';
        final Result<Change<int>> result;
        if (random.nextInt(5) == 0) {
          // A transaction of edits that apply one after another. Applying
          // them again derives ranges under fresh markers, so a later edit
          // names only groups the starting version or an earlier edit's
          // Mark holds.
          final edits = <Edit<int>>[];
          final known = {for (final (marker, _) in document.markers(3)) marker};
          var current = document;
          final steps = <Change<int>>[];
          for (var count = random.nextInt(4); count > 0; count--) {
            final edit = script.edit(current, known);
            if (current.apply(edit) case Success(:final value)) {
              edits.add(edit);
              steps.add(value);
              current = value.document;
              if (edit.command case Mark(:final marker)) {
                known.add(marker);
              }
            }
          }
          result = document.transact(edits);
          expect(result, isA<Success<Change<int>>>(), reason: reason);
          if (result case Success(:final value) when steps.isNotEmpty) {
            expect(
              value.layers.first.regions,
              carried(steps, current),
              reason: '$reason: layer 1 regions',
            );
          }
          transactions++;
        } else {
          result = document.apply(script.edit(document));
        }
        switch (result) {
          case Failure(:final kind, :final message):
            expect(kind, Kind.invalid, reason: '$reason: $message');
          case Success(value: final change)
              when identical(change.document, document):
            // An empty transaction.
            expect(
              change.layers.every((delta) => delta.created.isEmpty),
              isTrue,
            );
          case Success(value: final change):
            final after = change.document;
            expect(identical(after.previous, document), isTrue, reason: reason);
            expect(after.version, document.version + 1, reason: reason);
            fresh(after, reason);
            regional(after, Random(seed * 1000 + step), reason);
            compacts(after, reason);
            changed(document, change, reason);
            document = after;
            accepted++;
        }
      }
    }
    expect(accepted, greaterThan(8000));
    expect(transactions, greaterThan(2000));
  });
}

/// Expects [document] to keep its invariants and to have the layers of one
/// derived from scratch from its items, with attributes the grammar does
/// not derive left out.
void fresh(Layered<int> document, String reason) {
  expect(check(document), const Success<void>(null), reason: reason);
  final scratch = Layered.of(
    Items.of(document.items.items),
    Brackets(),
  ).unwrap();
  for (var layer = 2; layer <= 3; layer++) {
    expect(
      derived(document.layer(layer)),
      scratch.layer(layer),
      reason: '$reason: layer $layer',
    );
    expect(
      document.diagnostics(layer),
      scratch.diagnostics(layer),
      reason: '$reason: layer $layer diagnostics',
    );
  }
}

/// [ranges] with only the attributes the bracket grammar derives.
Ranges derived(Ranges ranges) => Ranges.of([
  for (final range in ranges.items.cast<ARange>())
    tagged(range.start, range.length, attributes: {'type': range.get('type')!}),
]);

/// Expects [change]'s markers, for each layer above 1, to be exactly what
/// differs between [before] and the version it made: the ranges only in
/// the new version, those only in the old, and those in both with new
/// attributes.
void changed(Layered<int> before, Change<int> change, String reason) {
  final after = change.document;
  expect(change.layers.length, after.depth, reason: reason);
  for (var layer = 2; layer <= after.depth; layer++) {
    final old = {
      for (final (marker, range) in before.markers(layer))
        marker: range.attributes,
    };
    final now = {
      for (final (marker, range) in after.markers(layer))
        marker: range.attributes,
    };
    final delta = change.layers[layer - 1];
    final why = '$reason: layer $layer';
    expect(delta.created.toSet(), {
      for (final marker in now.keys)
        if (!old.containsKey(marker)) marker,
    }, reason: why);
    expect(delta.removed.toSet(), {
      for (final marker in old.keys)
        if (!now.containsKey(marker)) marker,
    }, reason: why);
    expect(delta.updated.toSet(), {
      for (final MapEntry(key: marker, value: attributes) in now.entries)
        if (old[marker] case final was? when !same(was, attributes)) marker,
    }, reason: why);
  }
}

/// Whether [a] and [b] hold the same attributes.
bool same(Map<String, Value> a, Map<String, Value> b) =>
    a.length == b.length &&
    a.entries.every((entry) => b[entry.key] == entry.value);

/// Expects [document] compacted to be version 0 with no history and the
/// same layers, markers, diagnostics, and extents, and an edit to it to
/// give the layers the same edit gives [document].
void compacts(Layered<int> document, String reason) {
  final compacted = document.compact();
  expect(compacted.version, 0, reason: reason);
  expect(compacted.previous, isNull, reason: reason);
  expect(compacted.changes, isEmpty, reason: reason);
  expect((compacted.items as Document<int>).previous, isNull, reason: reason);
  expect(check(compacted), const Success<void>(null), reason: reason);
  for (var layer = 2; layer <= document.depth; layer++) {
    final why = '$reason: compacted layer $layer';
    expect(compacted.markers(layer), document.markers(layer), reason: why);
    expect(
      compacted.diagnostics(layer),
      document.diagnostics(layer),
      reason: why,
    );
    for (final (marker, _) in document.markers(layer)) {
      expect(
        compacted.extent(layer, marker),
        document.extent(layer, marker),
        reason: why,
      );
    }
  }
  final edit = Edit<int>(1, Insert(document.items.length ~/ 2, Text.of('[')));
  final (mine, theirs) = (
    compacted.apply(edit).unwrap().document,
    document.apply(edit).unwrap().document,
  );
  for (var layer = 2; layer <= document.depth; layer++) {
    expect(mine.layer(layer), theirs.layer(layer), reason: '$reason: edited');
  }
}

/// The layer-1 regions of [steps], applied one after another to reach
/// [last], each carried into [last]'s positions by [Document.map]: its
/// start follows items inserted at it, and its end does not.
List<Range> carried(List<Change<int>> steps, Layered<int> last) {
  final to = last.items as Document<int>;
  return [
    for (final step in steps)
      for (final region in step.layers.first.regions)
        switch ((
          to
              .map(
                step.document.items as Document<int>,
                region.start,
                Gravity.right,
              )
              .unwrap(),
          to
              .map(
                step.document.items as Document<int>,
                region.end,
                Gravity.left,
              )
              .unwrap(),
        )) {
          (final start, final end) => span(
            start,
            end < start ? 0 : end - start,
          ),
        },
  ];
}
