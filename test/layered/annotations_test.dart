import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/layered/layered.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart' show Document;
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../../example/xml/xml.dart';
import '../support.dart';
import 'brackets.dart';
import 'overlaps.dart';

/// One grammar to run the suite over: a [source], a layer-1 range [across]
/// that starts inside one unit of the grammar and ends inside another, a
/// layer-3 range [over] two units, a place [typed] to type [typing] at,
/// away from both, that derives the layers again, and a run of text [cut]
/// whose deletion removes the second of the units [over] covers, where
/// the grammar has one; and items [moved] to before [to] that cut no range
/// of the grammar, with a layer-1 range [noting] crossing an edge of them.
typedef Case = ({
  String name,
  Grammar<int> Function() grammar,
  String source,
  Range across,
  Range over,
  int typed,
  String typing,
  Range cut,
  Range moved,
  int to,
  Range noting,
});

final cases = <Case>[
  (
    name: 'XML, whose markup nests',
    grammar: XML.new,
    source: '<r><a>xy</a><b>zw</b></r>',
    across: span(7, 9),
    over: span(1, 2),
    typed: 6,
    typing: 'q',
    cut: span(12, 9),
    moved: span(12, 9),
    to: 3,
    noting: span(7, 9),
  ),
  (
    name: 'Brackets, whose markup pairs',
    grammar: Brackets.new,
    source: '[[xy][zw]]',
    across: span(3, 4),
    over: span(1, 2),
    typed: 2,
    typing: 'q',
    cut: span(5, 4),
    moved: span(5, 4),
    to: 1,
    noting: span(3, 4),
  ),
  (
    name: 'Overlaps, whose markup overlaps',
    grammar: Overlaps.new,
    source: 'ab cd ef',
    across: span(1, 6),
    over: span(1, 2),
    typed: 2,
    typing: ' ',
    cut: span(2, 3),
    moved: span(3, 3),
    to: 0,
    noting: span(4, 3),
  ),
];

void main() {
  for (final example in cases) {
    group(example.name, () {
      /// The document of [example], its grammar wrapped in [spy] if given.
      Layered<int> document([Spy? spy]) => Layered.of(
        Text.of(example.source),
        spy ?? example.grammar(),
      ).unwrap();

      /// [document] after [edit].
      Layered<int> after(Layered<int> document, Edit<int> edit) =>
          document.apply(edit).unwrap().document;

      test('an annotation across units is added, read, changed, removed', () {
        final mark = Mark<Object?>(
          tagged(example.across.start, example.across.length),
        );
        final noted = after(document(), Edit.annotation(1, mark));
        expect(noted.annotations(1), [(mark.marker, mark.range)]);
        expect(check(noted), const Success<void>(null));
        final changed = after(
          noted,
          Edit.annotation(1, Update<Object?>(mark.marker, {'n': string('1')})),
        );
        expect(changed.annotations(1).single.$2.get('n'), string('1'));
        final removed = after(
          changed,
          Edit.annotation(1, Unmark<Object?>(mark.marker)),
        );
        expect(removed.annotations(1), isEmpty);
        expect(check(removed), const Success<void>(null));
      });

      test('an annotation over two units of layer 3 is added and read', () {
        final base = document();
        expect(base.layer(3).length, greaterThanOrEqualTo(3));
        final mark = Mark<Object?>(
          tagged(example.over.start, example.over.length),
        );
        final noted = after(base, Edit.annotation(3, mark));
        expect(noted.annotations(3), [(mark.marker, mark.range)]);
        expect(noted.annotations(1), isEmpty);
        expect(check(noted), const Success<void>(null));
      });

      test('adding one leaves every layer as it was', () {
        final base = document();
        final noted = after(
          base,
          Edit.annotation(1, Mark<Object?>(tagged(0, 1))),
        );
        for (var layer = 2; layer <= base.depth; layer++) {
          expect(noted.layer(layer), base.layer(layer), reason: '$layer');
          expect(noted.markers(layer), base.markers(layer), reason: '$layer');
          expect(
            noted.diagnostics(layer),
            base.diagnostics(layer),
            reason: '$layer',
          );
        }
      });

      test('an edit that is not an annotation of the layer is invalid', () {
        final base = document();
        final token = base.markers(2).first.$1;
        for (final edit in [
          Edit<int>.annotation(1, Insert(0, Text.of('x'))),
          Edit<int>.annotation(1, Unmark<Object?>(token)),
          Edit<int>.annotation(1, Update<Object?>(token, const {})),
          Edit<int>.annotation(0, Mark<Object?>(tagged(0, 1))),
          Edit<int>.annotation(base.depth + 1, Mark<Object?>(tagged(0, 0))),
        ]) {
          expect(base.apply(edit), invalid, reason: '$edit');
        }
      });

      test('a change reports what it did to annotations, by layer', () {
        final base = document();
        final mark = Mark<Object?>(tagged(0, 1));
        final marked = base.apply(Edit.annotation(2, mark)).unwrap();
        expect(marked.annotations, hasLength(base.depth));
        expect(marked.annotations[1].created, [mark.marker]);
        expect(marked.annotations[0].created, isEmpty);
        final updated = marked.document
            .apply(Edit.annotation(2, Update<Object?>(mark.marker, const {})))
            .unwrap();
        expect(updated.annotations[1].updated, [mark.marker]);
        final removed = updated.document
            .apply(Edit.annotation(2, Unmark<Object?>(mark.marker)))
            .unwrap();
        expect(removed.annotations[1].removed, [mark.marker]);
        for (final delta in [
          ...marked.annotations,
          ...updated.annotations,
          ...removed.annotations,
        ]) {
          expect(delta.regions, isEmpty);
        }
        // A text edit does nothing to annotations.
        final typed = removed.document
            .apply(Edit(1, Insert(example.typed, Text.of(example.typing))))
            .unwrap();
        for (final delta in typed.annotations) {
          expect([
            ...delta.created,
            ...delta.removed,
            ...delta.updated,
          ], isEmpty);
        }
      });

      test('a transaction merges what it did to annotations', () {
        final base = document();
        final gone = Mark<Object?>(tagged(0, 1));
        final kept = Mark<Object?>(tagged(1, 1));
        final change = base.transact([
          Edit.annotation(1, gone),
          Edit.annotation(1, kept),
          Edit(1, Insert(example.typed, Text.of(example.typing))),
          Edit.annotation(1, Unmark<Object?>(gone.marker)),
          Edit.annotation(1, Update<Object?>(kept.marker, const {})),
        ]).unwrap();
        // Created then removed is in neither list; created then updated is
        // only created.
        expect(change.annotations[0].created, [kept.marker]);
        expect(change.annotations[0].removed, isEmpty);
        expect(change.annotations[0].updated, isEmpty);
        expect(change.document.annotations(1).single.$1, kept.marker);
        final empty = base.transact([]).unwrap();
        expect(empty.annotations, hasLength(base.depth));
      });

      test('one over the text moves as a range on the text would', () {
        final mark = Mark<Object?>(
          tagged(example.across.start, example.across.length),
        );
        var layered = after(document(), Edit.annotation(1, mark));
        var plain = Document.of(Text.of(example.source))
            .apply(Mark<int>.of(mark.marker, mark.range))
            .unwrap();
        final (start, end) = (example.across.start, example.across.end);
        for (final command in <Command<int>>[
          Insert(0, Text.of('q')),
          Insert(start + 2, Text.of('q')),
          Insert(end + 2, Text.of('q')),
          Delete(span(end + 2, 1)),
          // Over its start, through markup where the grammar has it there.
          Replace(span(start, 2), Text.of('zz')),
          Delete(span(start + 2, 2)),
        ]) {
          layered = after(layered, Edit(1, command));
          plain = plain.apply(command).unwrap();
          expect(
            layered.annotations(1).single.$2,
            plain.resolve(mark.marker),
            reason: '$command',
          );
          expect(check(layered), const Success<void>(null), reason: '$command');
        }
      });

      test('one over units keeps those of them that stay', () {
        final base = document();
        final mark = Mark<Object?>(
          tagged(example.over.start, example.over.length),
        );
        final noted = after(base, Edit.annotation(3, mark));
        final covered = [
          for (final (marker, _)
              in noted.markers(3).sublist(example.over.start, example.over.end))
            marker,
        ];

        /// The units of [document]'s layer 3 the annotation covers.
        List<Marker> under(Layered<int> document) {
          final range = document.annotations(3).single.$2;
          return [
            for (final (marker, _)
                in document.markers(3).sublist(range.start, range.end))
              marker,
          ];
        }

        final typed = after(
          noted,
          Edit(1, Insert(example.typed, Text.of(example.typing))),
        );
        expect(under(typed), covered, reason: 'typing elsewhere');
        final cut = after(noted, Edit(1, Delete(example.cut)));
        final kept = {for (final (marker, _) in cut.markers(3)) marker};
        expect(under(cut), [
          for (final marker in covered)
            if (kept.contains(marker)) marker,
        ], reason: 'cutting a unit');
        expect(check(cut), const Success<void>(null));
      });

      test('none widens the region derived again', () {
        final base = document();
        final noted = after(
          after(
            base,
            Edit.annotation(1, Mark<Object?>(tagged(1, base.items.length - 2))),
          ),
          Edit.annotation(
            2,
            Mark<Object?>(tagged(1, base.layer(2).length - 2)),
          ),
        );
        final edit = Edit<int>(
          1,
          Insert(example.typed, Text.of(example.typing)),
        );
        final plain = base.apply(edit).unwrap();
        final annotated = noted.apply(edit).unwrap();
        for (var layer = 1; layer <= base.depth; layer++) {
          expect(
            annotated.layers[layer - 1].regions,
            plain.layers[layer - 1].regions,
            reason: 'layer $layer',
          );
        }
      });

      test('a move cutting one clamps it, unless the move says otherwise', () {
        for (final (policy, given) in [
          (Crossing.clamp, null),
          (Crossing.clamp, Crossing.clamp),
          (Crossing.follow, Crossing.follow),
        ]) {
          final mark = Mark<Object?>(
            tagged(example.noting.start, example.noting.length),
          );
          final noted = after(document(), Edit.annotation(1, mark));
          final move = Edit<int>(
            1,
            Move<Object?>(example.moved, example.to, {mark.marker: ?given}),
          );
          final plain = Document.of(Text.of(example.source))
              .apply(Mark<int>.of(mark.marker, mark.range))
              .unwrap()
              .apply(Move(example.moved, example.to), crossing: (_) => policy);
          switch ((noted.apply(move), plain)) {
            case (Success(:final value), Success(value: final expected)):
              expect(
                value.document.annotations(1).single.$2,
                expected.resolve(mark.marker),
                reason: '$policy',
              );
              expect(check(value.document), const Success<void>(null));
            case (Failure(), Failure()):
              // Following the items would end it before it starts, both
              // ways.
              break;
            case (final layered, final document):
              fail('$policy: $layered, but the plain document $document');
          }
        }
      });

      test('one inside what moves goes with it, at layers 1 and 2', () {
        final base = document();
        final inner = Mark<Object?>(tagged(example.moved.start + 1, 1));
        final tokens = [
          for (final (index, (marker, range)) in base.markers(2).indexed)
            if (example.moved.start <= range.start &&
                range.end <= example.moved.end)
              (index, marker),
        ];
        // Its end stays put where the layer gains an item exactly there, as
        // rederiving may place one, so it holds these tokens alone.
        final over = Mark<Object?>(
          tagged(tokens.first.$1, tokens.length),
          end: Gravity.left,
        );
        final noted = after(
          after(base, Edit.annotation(1, inner)),
          Edit.annotation(2, over),
        );
        final moved = after(
          noted,
          Edit(1, Move<Object?>(example.moved, example.to)),
        );
        final plain = Document.of(Text.of(example.source))
            .apply(Mark<int>.of(inner.marker, inner.range))
            .unwrap()
            .apply(Move(example.moved, example.to))
            .unwrap();
        expect(moved.annotations(1).single.$2, plain.resolve(inner.marker));
        final range = moved.annotations(2).single.$2;
        expect(
          [
            for (final (marker, _)
                in moved.markers(2).sublist(range.start, range.end))
              marker,
          ],
          [for (final (_, marker) in tokens) marker],
        );
      });

      test('one over the top layer keeps the units a move takes', () {
        final base = document();
        final top = base.depth;
        final taken = [
          for (final (index, (marker, _)) in base.markers(top).indexed)
            if (base.extent(top, marker) case final extent?
                when example.moved.start <= extent.start &&
                    extent.end <= example.moved.end)
              (index, marker),
        ];
        expect(taken, isNotEmpty);
        // Its end stays put where the layer gains an item exactly there, so
        // it holds the units taken alone.
        final mark = Mark<Object?>(
          tagged(taken.first.$1, taken.length),
          end: Gravity.left,
        );
        final moved = after(
          after(base, Edit.annotation(top, mark)),
          Edit(1, Move<Object?>(example.moved, example.to)),
        );
        final range = moved.annotations(top).single.$2;
        // A unit the grammar derives afresh after the move is a new range,
        // so the annotation keeps those of the units taken that stay.
        final kept = {for (final (marker, _) in moved.markers(top)) marker};
        expect(
          [
            for (final (marker, _)
                in moved.markers(top).sublist(range.start, range.end))
              marker,
          ],
          [
            for (final (_, marker) in taken)
              if (kept.contains(marker)) marker,
          ],
        );
        expect(range.length, greaterThan(0), reason: 'a unit stays');
        expect(check(moved), const Success<void>(null));
      });

      test('the grammar is never asked what a move does with one', () {
        final spy = Spy(example.grammar());
        final mark = Mark<Object?>(
          tagged(
            example.noting.start,
            example.noting.length,
            attributes: {'note': string('n')},
          ),
        );
        final noted = after(document(spy), Edit.annotation(1, mark));
        after(noted, Edit(1, Move<Object?>(example.moved, example.to)));
        expect(spy.asked.where((range) => range.has('note')), isEmpty);
      });

      test('valid decides as it would with no annotations', () {
        final base = document();
        final noted = after(
          after(
            base,
            Edit.annotation(
              1,
              Mark<Object?>(
                tagged(example.across.start, example.across.length),
              ),
            ),
          ),
          Edit.annotation(
            3,
            Mark<Object?>(tagged(example.over.start, example.over.length)),
          ),
        );
        final (start, end) = (example.across.start, example.across.end);
        for (final command in <Command<int>>[
          Insert(example.typed, Text.of(example.typing)),
          // Inside the annotation, and inside a unit of the grammar.
          Insert(end - 1, Text.of('q')),
          Insert(start, Text.of('q')),
          Delete(span(start, 2)),
          Replace(span(0, 1), Text.of('<')),
          Insert(0, Text.of('[')),
          Insert(0, Text.of(' ')),
        ]) {
          final edit = Edit<int>(1, command);
          switch ((
            base.grammar.valid(base, edit),
            noted.grammar.valid(noted, edit),
          )) {
            case (Success(value: final plain), Success(value: final kept)):
              expect(kept.document.items, plain.document.items);
              for (var layer = 2; layer <= base.depth; layer++) {
                expect(
                  kept.document.layer(layer),
                  plain.document.layer(layer),
                  reason: '$command layer $layer',
                );
              }
            case (Failure(message: final plain), Failure(:final message)):
              expect(message, plain, reason: '$command');
            case (final plain, final kept):
              fail('$command: $plain without annotations, $kept with');
          }
        }
      });

      test('undo, a transaction, and compacting keep them', () {
        final base = document();
        final mark = Mark<Object?>(
          tagged(example.across.start, example.across.length),
        );
        final noted = after(base, Edit.annotation(1, mark));
        final typed = after(
          noted,
          Edit(1, Insert(example.typed, Text.of(example.typing))),
        );
        expect(identical(typed.previous, noted), isTrue);
        expect(typed.previous!.annotations(1), noted.annotations(1));
        expect(noted.previous!.annotations(1), isEmpty);
        final compacted = typed.compact();
        expect(compacted.previous, isNull);
        expect(compacted.annotations(1), typed.annotations(1));
        expect(check(compacted), const Success<void>(null));
        final change = base.transact([
          Edit.annotation(1, mark),
          Edit(1, Insert(example.typed, Text.of(example.typing))),
        ]).unwrap();
        expect(identical(change.document.previous, base), isTrue);
        expect(change.document.annotations(1), typed.annotations(1));
      });

      test('the grammar never sees an annotation', () {
        final spy = Spy(example.grammar());
        final across = Mark<Object?>(
          tagged(example.across.start, example.across.length),
        );
        final over = Mark<Object?>(
          tagged(example.over.start, example.over.length),
        );
        var noted = after(document(spy), Edit.annotation(1, across));
        noted = after(noted, Edit.annotation(2, Mark<Object?>(tagged(0, 2))));
        noted = after(noted, Edit.annotation(3, over));
        spy.seen.clear();
        noted = after(
          noted,
          Edit(1, Insert(example.typed, Text.of(example.typing))),
        );
        expect(spy.seen, isNotEmpty, reason: 'the layers were derived again');
        final annotations = {
          for (var layer = 1; layer <= noted.depth; layer++)
            for (final (marker, _) in noted.annotations(layer)) marker,
        };
        expect(annotations, hasLength(3));
        expect(spy.seen.intersection(annotations), isEmpty);
      });
    });
  }
}

/// [grammar], recording every marker the layer queries return while a
/// layer is derived.
final class Spy implements Grammar<int> {
  Spy(this.grammar);

  /// The grammar watched.
  final Grammar<int> grammar;

  /// Every marker a query has returned.
  final Set<Marker> seen = {};

  /// Every range the grammar was asked what a move does with.
  final List<ARange> asked = [];

  @override
  int get depth => grammar.depth;

  @override
  Derived derive(Layered<int> document, int layer, Range region) {
    for (var below = 2; below <= layer; below++) {
      final length = below == 2
          ? document.items.length
          : document.layer(below - 1).length;
      seen.addAll([
        for (final (marker, _) in document.markers(below)) marker,
        for (final (marker, _) in document.within(below, span(0, length)))
          marker,
        for (var at = 0; at <= length; at++)
          for (final (marker, _) in document.crossing(below, at)) marker,
      ]);
    }
    return grammar.derive(document, layer, region);
  }

  @override
  Range affected(Layered<int> document, int layer, Range changed) =>
      grammar.affected(document, layer, changed);

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) =>
      grammar.edit(document, change);

  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      grammar.valid(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) =>
      grammar.escaped(text, raw: raw);

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) {
    asked.add(range);
    return grammar.crossing(document, layer, range);
  }
}
