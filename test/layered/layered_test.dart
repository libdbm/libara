import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart' show Document;
import 'package:libara/src/layered/layered.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'brackets.dart';

void main() {
  group('Layered.of', () {
    test('derives tokens at layer 2 and nested groups at layer 3', () {
      final document = Layered.of(Text.of('a[b[c]]d'), Brackets()).unwrap();
      expect(document.depth, 3);
      expect(document.version, 0);
      expect(document.previous, isNull);
      expect(document.layer(2).length, 8);
      expect(
        document.layer(2).item(1),
        tagged(1, 1, attributes: {'type': kind('open')}),
      );
      expect(
        document.layer(3),
        Ranges.of([
          tagged(1, 6, attributes: {'type': kind('group')}),
          tagged(3, 3, attributes: {'type': kind('group')}),
        ]),
      );
      expect(document.valid, isTrue);
      expect(check(document), const Success<void>(null));
    });

    test('extent projects a range down to the text it covers', () {
      final document = Layered.of(Text.of('a[b[c]]d'), Brackets()).unwrap();
      final groups = document.markers(3);
      expect(document.extent(3, groups[0].$1), span(1, 6));
      expect(document.extent(3, groups[1].$1), span(3, 3));
      final tokens = document.markers(2);
      expect(document.extent(2, tokens.last.$1), span(7, 1));
      expect(document.extent(3, tokens.last.$1), isNull);
    });

    test('an unmatched bracket is a diagnostic', () {
      final document = Layered.of(Text.of('a[b'), Brackets()).unwrap();
      expect(document.layer(3), Ranges.empty());
      expect(
        document.diagnostics(3),
        Ranges.of([
          tagged(1, 1, attributes: {'message': kind('unmatched [')}),
        ]),
      );
      expect(document.diagnostics(2), Ranges.empty());
      expect(document.valid, isFalse);
      expect(check(document), const Success<void>(null));
    });

    test('an empty sequence has empty layers', () {
      final document = Layered.of(Text.of(''), Brackets()).unwrap();
      expect(document.layer(2), Ranges.empty());
      expect(document.layer(3), Ranges.empty());
      expect(document.valid, isTrue);
    });
  });

  group('text edits', () {
    test('typing a closing bracket makes a group, reported by the change', () {
      final before = Layered.of(Text.of('a[b'), Brackets()).unwrap();
      final change = before.apply(Edit(1, Insert(3, Text.of(']')))).unwrap();
      final after = change.document;
      expect(String.fromCharCodes(after.items.items), 'a[b]');
      expect(after.valid, isTrue);
      expect(
        after.layer(3),
        Ranges.of([
          tagged(1, 3, attributes: {'type': kind('group')}),
        ]),
      );
      expect(change.layers.length, 3);
      expect(change.layers[0].regions, [span(3, 1)]);
      expect(change.layers[2].created, [after.markers(3).single.$1]);
      expect(after.version, 1);
      expect(identical(after.previous, before), isTrue);
      expect(after.changes.single.command, isA<Insert<Object?>>());
      expect(before.changes, isEmpty);
      expect(check(after), const Success<void>(null));
    });

    test('ranges that come out the same keep their markers', () {
      final before = Layered.of(Text.of('a[b]c'), Brackets()).unwrap();
      final open = before.markers(2)[1].$1;
      final group = before.markers(3).single.$1;
      final after = before
          .apply(Edit(1, Insert(0, Text.of('x'))))
          .unwrap()
          .document;
      expect(after.markers(2)[1].$1, open);
      expect(after.markers(3).single.$1, group);
      expect(after.extent(3, group), span(2, 3));
      expect(check(after), const Success<void>(null));
    });

    test('previous holds every layer as it was', () {
      final before = Layered.of(Text.of('a[b]c'), Brackets()).unwrap();
      final after = before
          .apply(Edit(1, Delete<int>(span(3, 1))))
          .unwrap()
          .document;
      expect(after.valid, isFalse);
      final back = after.previous!;
      expect(back.layer(2), before.layer(2));
      expect(back.layer(3), before.layer(3));
      expect(back.diagnostics(3), Ranges.empty());
    });

    test('a command that does not fit its layer is invalid', () {
      final document = Layered.of(Text.of('a[b]'), Brackets()).unwrap();
      final marker = document.markers(3).single.$1;
      expect(document.apply(Edit(2, Insert(0, Items.of([0])))), invalid);
      expect(document.apply(Edit(1, Unmark<int>(marker))), invalid);
      expect(document.apply(Edit(1, Insert(0, Items.of(['x'])))), invalid);
      expect(document.apply(Edit(0, Delete<int>(span(0, 1)))), invalid);
      expect(document.apply(Edit(4, Delete<int>(span(0, 1)))), invalid);
    });
  });
  group('affected regions', () {
    test('typing inside a group derives only that group again', () {
      final before = Layered.of(Text.of('a[bc]d[e]f'), Brackets()).unwrap();
      final tokens = before.markers(2);
      final groups = before.markers(3);
      final change = before.apply(Edit(1, Insert(3, Text.of('x')))).unwrap();
      final after = change.document;
      expect(change.layers[1].regions, [span(2, 3)]);
      expect(change.layers[2].regions, [span(1, 3)]);
      expect(after.markers(2).map((pair) => pair.$1), [
        for (final (marker, _) in tokens) marker,
      ]);
      expect(after.markers(3).last.$1, groups.last.$1);
      expect(after.extent(3, groups.last.$1), span(7, 3));
      same(after);
    });

    test('correcting an error derives it again past the named region', () {
      final before = Layered.of(
        Text.of('[a'),
        Brackets(named: (changed) => changed),
      ).unwrap();
      final change = before.apply(Edit(1, Insert(2, Text.of(']')))).unwrap();
      final after = change.document;
      expect(change.layers[2].regions, [span(0, 3)]);
      expect(after.valid, isTrue);
      same(after);
    });

    test('a chain of crossing ranges widens the region along it', () {
      final document = Layered.of(Text.of('a' * 50), Pairs()).unwrap();
      final change = document
          .apply(Edit(1, Replace(span(25, 1), Text.of('b'))))
          .unwrap();
      expect(change.layers[1].regions, [span(0, 50)]);
      expect(
        change.document.layer(2),
        Layered.of(change.document.items, Pairs()).unwrap().layer(2),
      );
      expect(check(change.document), const Success<void>(null));
    });

    test('a region cutting through a range widens to take it in', () {
      final grammar = Brackets(named: (_) => span(1, 6));
      final before = Layered.of(Text.of('[b]c[d]'), grammar).unwrap();
      final change = before.apply(Edit(1, Insert(6, Text.of('x')))).unwrap();
      expect(change.layers[2].regions, [span(0, 7)]);
      same(change.document);
    });

    test('derives what a full derivation does over seeded edits', () {
      for (var seed = 0; seed < 100; seed++) {
        final random = Random(seed);
        String text(int length) => String.fromCharCodes([
          for (var index = 0; index < length; index++)
            '[]ab'.codeUnitAt(random.nextInt(4)),
        ]);
        var document = Layered.of(
          Text.of(text(random.nextInt(12))),
          Brackets(),
        ).unwrap();
        for (var step = 0; step < 30; step++) {
          final length = document.items.length;
          final start = random.nextInt(length + 1);
          final size = random.nextInt(length - start + 1);
          final Command<int> command = switch (random.nextInt(3)) {
            0 => Insert(start, Text.of(text(1 + random.nextInt(3)))),
            1 => Delete(span(start, size)),
            _ => Replace(span(start, size), Text.of(text(random.nextInt(3)))),
          };
          document = document.apply(Edit(1, command)).unwrap().document;
          same(document, '$seed/$step: $command');
        }
      }
    });
  });
  group('structural edits', () {
    /// The text of [document].
    String text(Layered<int> document) =>
        String.fromCharCodes(document.items.items);

    test('wrapping a token inserts brackets without lexing', () {
      final grammar = Brackets();
      final before = Layered.of(Text.of('[a]b[c]'), grammar).unwrap();
      grammar.lexed = 0;
      final mark = Mark<Object?>(
        tagged(3, 1, attributes: {'type': kind('group')}),
      );
      final change = before.apply(Edit(3, mark)).unwrap();
      final after = change.document;
      expect(grammar.lexed, 0);
      expect(text(after), '[a][b][c]');
      expect(after.extent(3, mark.marker), span(3, 3));
      expect(change.layers[2].created, [mark.marker]);
      expect(change.layers[1].created.length, 2);
      expect(change.layers[0].regions, [span(5, 1), span(3, 1)]);
      expect(after.version, 1);
      expect(identical(after.previous, before), isTrue);
      same(after);
    });

    test('wrapping half a group is refused', () {
      final before = Layered.of(Text.of('[a]b'), Brackets()).unwrap();
      final mark = Mark<Object?>(
        tagged(0, 2, attributes: {'type': kind('group')}),
      );
      expect(before.apply(Edit(3, mark)), invalid);
      expect(text(before), '[a]b');
    });

    test('unwrapping a group removes its brackets and merges text', () {
      final before = Layered.of(Text.of('x[a[b]c]'), Brackets()).unwrap();
      final inner = before.markers(3).last.$1;
      final change = before.apply(Edit(3, Unmark<Object?>(inner))).unwrap();
      final after = change.document;
      expect(text(after), 'x[abc]');
      expect(change.layers[2].removed, [inner]);
      expect(after.extent(3, after.markers(3).single.$1), span(1, 5));
      same(after);
    });

    test('deleting a group removes its text and nested groups', () {
      final before = Layered.of(Text.of('a[b[c]]d[e]'), Brackets()).unwrap();
      final change = before
          .apply(Edit(3, Delete<Object?>(span(0, 1))))
          .unwrap();
      final after = change.document;
      expect(text(after), 'ad[e]');
      expect(change.layers[2].removed.length, 2);
      same(after);
    });

    test('a bracket marked at layer 2 splits text and groups at layer 3', () {
      final grammar = Brackets();
      final before = Layered.of(Text.of('ab]'), grammar).unwrap();
      grammar.lexed = 0;
      final mark = Mark<Object?>(
        tagged(1, 0, attributes: {'type': type(0x5B)}),
      );
      final change = before.apply(Edit(2, mark)).unwrap();
      final after = change.document;
      expect(grammar.lexed, 0);
      expect(text(after), 'a[b]');
      expect(after.valid, isTrue);
      expect(after.extent(2, mark.marker), span(1, 1));
      expect(change.layers[2].created, [after.markers(3).single.$1]);
      same(after);
    });

    test('an update keeps the marker and reports it', () {
      final before = Layered.of(Text.of('[a]'), Brackets()).unwrap();
      final group = before.markers(3).single.$1;
      final attributes = {'type': kind('group'), 'note': kind('x')};
      final change = before
          .apply(Edit(3, Update<Object?>(group, attributes)))
          .unwrap();
      expect(change.document.markers(3).single.$2.attributes, attributes);
      expect(change.layers[2].updated, [group]);
      expect(check(change.document), const Success<void>(null));
    });

    test('a derivation places a range it removes again under its marker', () {
      // A grammar whose edit respells a range's edges cannot carry the
      // range across, since a range only ever shrinks inward: it removes
      // the range and places it again, and the marker stays.
      final document = Layered.of(Text.of('[a]'), Placing()).unwrap();
      final group = document.markers(3).single.$1;
      final change = document
          .apply(Edit(3, Update<Object?>(group, const {})))
          .unwrap();
      final (marker, range) = change.document.markers(3).single;
      expect(marker, group);
      expect((range.start, range.length), (0, 2));
    });

    test('a derivation placing a range it removes twice is invalid', () {
      // Removing the marker frees it to be placed once, not twice: the
      // derivation is refused when checked, before anything is marked.
      final document = Layered.of(Text.of('[a]'), Doubling()).unwrap();
      final group = document.markers(3).single.$1;
      final result = document.apply(Edit(3, Update<Object?>(group, const {})));
      expect(result, invalid);
      expect(
        (result as Failure<Change<int>>).message,
        contains('creates $group, which is in use'),
      );
    });

    test('a derivation that does not fit is invalid', () {
      final before = Layered.of(Text.of('[a]'), Brackets()).unwrap();
      final group = before.markers(3).single.$1;
      Layered<int> forged(Derivation<int> derivation) =>
          Layered.of(Text.of('[a]'), Forged(derivation)).unwrap();
      final edit = Edit<int>(3, Update<Object?>(group, const {}));
      expect(
        forged((
          below: const [],
          created: [(Marker(), tagged(2, 5))],
          removed: const [],
          updated: const {},
        )).apply(edit),
        invalid,
      );
      expect(
        forged((
          below: const [],
          created: const [],
          removed: [Marker()],
          updated: const {},
        )).apply(edit),
        invalid,
      );
      expect(
        forged((
          below: [Edit(1, Insert(0, Text.of('x')))],
          created: const [],
          removed: const [],
          updated: const {},
        )).apply(edit),
        isA<Failure<Object?>>()
            .having((failure) => failure.kind, 'kind', Kind.invalid)
            .having(
              (failure) => failure.message,
              'message',
              contains('is not at layer 2'),
            ),
      );
      expect(before.apply(Edit(2, Unmark<Object?>(group))), invalid);
    });
  });
  group('order', () {
    test('Layered.of puts what the grammar returns in start order', () {
      final document = Layered.of(Text.of('abc'), Nested()).unwrap();
      expect(
        [
          for (final range in document.layer(2).items)
            (range.start, range.length),
        ],
        [(0, 1), (0, 3), (1, 1)],
      );
      expect(check(document), const Success<void>(null));
    });

    test('an edit keeps start order, as a derivation from scratch does', () {
      final document = Layered.of(Text.of('abc'), Nested()).unwrap();
      final edited = document
          .apply(Edit(1, Replace(span(1, 1), Text.of('z'))))
          .unwrap()
          .document;
      expect(
        edited.layer(2),
        Layered.of(edited.items, Nested()).unwrap().layer(2),
      );
      expect(check(edited), const Success<void>(null));
    });

    test('the bracket grammar returns its layers in start order', () {
      for (final source in ['a[b[c]]d', '[[x]y][z', ']a[', '']) {
        final document = Layered.of(Text.of(source), Brackets()).unwrap();
        for (final layer in [2, 3]) {
          final whole = span(
            0,
            layer == 2 ? source.length : document.layer(2).length,
          );
          final ranges = Ranges.of(
            Brackets().derive(document, layer, whole).ranges,
          );
          expect(ranges, ranges.startOrder(), reason: '$source at $layer');
        }
      }
    });
  });

  group('survivor order', () {
    /// The starts and lengths of layer [layer] of [document].
    List<(int, int)> spans(Layered<int> document, int layer) => [
      for (final range in document.layer(layer).items)
        (range.start, range.length),
    ];

    /// Expects [document] to pass its checks, with a layer-3 range over
    /// each layer-2 item and one over them all, as deriving would give.
    void sound(Layered<int> document, [String? reason]) {
      expect(check(document), const Success<void>(null), reason: reason);
      final count = document.layer(2).length;
      expect(spans(document, 3), [
        for (var index = 0; index < count; index++) ...[
          (index, 1),
          if (index == 0) (0, count),
        ],
      ], reason: reason);
    }

    /// Expects [document], under [Whole], to pass its checks and to hold
    /// what deriving it from scratch would.
    void fresh(Layered<int> document, [String? reason]) {
      expect(check(document), const Success<void>(null), reason: reason);
      final derived = Layered.of(document.items, Whole()).unwrap();
      for (final layer in [2, 3]) {
        expect(
          spans(document, layer),
          spans(derived, layer),
          reason: '$reason at layer $layer',
        );
      }
    }

    test('a deletion below that reorders the survivors sorts them', () {
      final before = Layered.of(
        Text.of('abcdefghij'),
        Trims([span(0, 1), span(1, 4), span(1, 9), span(5, 1)]),
      ).unwrap();
      final [(first, _), _, (whole, _), (tail, _)] = before.markers(2);
      final change = before
          .apply(Edit(2, Delete<Object?>(span(1, 1))))
          .unwrap();
      final after = change.document;
      expect(String.fromCharCodes(after.items.items), 'afghij');
      expect(spans(after, 2), [(0, 1), (1, 1), (1, 5)]);
      expect(
        [for (final (marker, _) in after.markers(2)) marker],
        [first, tail, whole],
      );
      expect(change.layers[1].removed.length, 1);
      sound(after);
    });

    test('random deletions below leave every layer in order', () {
      final random = Random(7);
      for (var round = 0; round < 300; round++) {
        final ranges = [
          for (var count = 2 + random.nextInt(5); count > 0; count--)
            switch (random.nextInt(10)) {
              final start => span(start, random.nextInt(11 - start)),
            },
        ];
        final before = Layered.of(
          Text.of('abcdefghij'),
          Trims(ranges),
        ).unwrap();
        final index = random.nextInt(before.layer(2).length);
        final reason = 'round $round: $ranges, deleting item $index';
        final after = before
            .apply(Edit(2, Delete<Object?>(span(index, 1))))
            .unwrap()
            .document;
        expect(after.layer(2).length, ranges.length - 1, reason: reason);
        sound(after, reason);
      }
    });

    test('a text deletion that reorders the layers above sorts them', () {
      final before = Layered.of(Text.of('abc'), Whole()).unwrap();
      final [_, (whole, _), (b, _), (c, _)] = before.markers(2);
      final after = before
          .apply(Edit(1, Delete<int>(span(0, 1))))
          .unwrap()
          .document;
      expect(spans(after, 2), [(0, 1), (0, 2), (1, 1)]);
      expect(
        [for (final (marker, _) in after.markers(2)) marker],
        [b, whole, c],
      );
      fresh(after);
    });

    test('random text edits leave every layer as deriving would', () {
      final random = Random(11);
      String text(int length) => String.fromCharCodes([
        for (var index = 0; index < length; index++) 0x61 + random.nextInt(3),
      ]);
      for (var round = 0; round < 300; round++) {
        final source = text(1 + random.nextInt(8));
        final start = random.nextInt(source.length + 1);
        final size = random.nextInt(source.length - start + 1);
        final command = switch (random.nextInt(3)) {
          0 => Insert(start, Text.of(text(1 + random.nextInt(3)))),
          1 => Delete<int>(span(start, size)),
          _ => Replace(span(start, size), Text.of(text(random.nextInt(3)))),
        };
        final after = Layered.of(
          Text.of(source),
          Whole(),
        ).unwrap().apply(Edit(1, command)).unwrap().document;
        fresh(after, 'round $round: $command on $source');
      }
    });

    test('a nested edit that would reorder the items below fails', () {
      final before = Layered.of(
        Text.of('abcdefghij'),
        Trims([span(0, 1), span(1, 4), span(1, 9), span(5, 1)]),
      ).unwrap();
      // Layer-3 item 2 is the one over layer-2 item 1, [1, 5).
      expect(before.apply(Edit(3, Delete<Object?>(span(2, 1)))), invalid);
      sound(before);
    });

    test('a nested edit that keeps the items below in order succeeds', () {
      final before = Layered.of(
        Text.of('abcdefghij'),
        Trims([span(0, 2), span(3, 2), span(6, 1)]),
      ).unwrap();
      final after = before
          .apply(Edit(3, Delete<Object?>(span(0, 1))))
          .unwrap()
          .document;
      expect(spans(after, 2), [(1, 2), (4, 1)]);
      expect(check(after), const Success<void>(null));
    });
  });

  group('moves', () {
    test('one whose layer-2 ranges inside it are not one run is refused', () {
      // (2,1) and (4,1) lie inside the items moved, and (3,5) between them
      // crosses its end and is clamped, so what moves at layer 2 is not
      // one run of its items.
      final document = Layered.of(
        Text.of('abcdefghij'),
        Interleaved(),
      ).unwrap();
      expect(document.apply(Edit(1, Move(span(2, 3), 10))), invalid);
      expect(String.fromCharCodes(document.items.items), 'abcdefghij');
      expect(
        document.layer(2),
        Ranges.of([tagged(2, 1), tagged(3, 5), tagged(4, 1)]),
      );
    });
  });

  group('moves at the top layer', () {
    test('one leaves the top layer to derive again when it holds nothing', () {
      // Layer 2 is the top layer, and what moves there is not one run: with
      // no annotations, deriving it again puts it in order, as before.
      final document = Layered.of(
        Text.of('abcdefghij'),
        Interleaved(depth: 2),
      ).unwrap();
      final moved = document.apply(Edit(1, Move(span(2, 3), 10)));
      expect(moved, isA<Success<Change<int>>>());
    });

    test('one is refused where an annotation there would lose units', () {
      final document = Layered.of(Text.of('abcdefghij'), Interleaved(depth: 2))
          .unwrap()
          .apply(Edit.annotation(2, Mark<Object?>(tagged(0, 3))))
          .unwrap()
          .document;
      expect(document.apply(Edit(1, Move(span(2, 3), 10))), invalid);
      expect(String.fromCharCodes(document.items.items), 'abcdefghij');
    });
  });

  group('extent', () {
    test('holds every covered item when the layer below overlaps', () {
      final document = Layered.of(Text.of('abcdefghij'), Spanning()).unwrap();
      expect(document.layer(2), Ranges.of([tagged(0, 10), tagged(5, 1)]));
      final (marker, range) = document.markers(3).first;
      expect(range, tagged(0, 2));
      expect(document.extent(3, marker), span(0, 10));
    });

    test('a zero-length range projects to where it stands', () {
      final document = Layered.of(Text.of('abcdefghij'), Spanning()).unwrap();
      final markers = {
        for (final (marker, range) in document.markers(3)) range: marker,
      };
      expect(document.extent(3, markers[tagged(1, 0)]!), span(5, 0));
      expect(document.extent(3, markers[tagged(2, 0)]!), span(6, 0));
    });
  });

  group('invariants', () {
    test('mapping a span from an unrelated version is a failure', () {
      final from = Document<Object?>.of(Text.of('ab'));
      final to = Document<Object?>.of(Text.of('ab'));
      final result = mapped(span(0, 1), from, to);
      expect(result, invalid);
      expect((result as Failure<Object?>).message, contains('invariant'));
    });

    test('mapping a span carries it through the commands between', () {
      final from = Document<Object?>.of(Text.of('ab'));
      final to = from.apply(Insert<Object?>(0, Text.of('xy'))).unwrap();
      expect(mapped(span(0, 1), from, to), Success(span(2, 1)));
      expect(
        mapped(span(0, 1), from, to, start: Gravity.left),
        Success(span(0, 3)),
      );
    });
  });

  group('faulty grammars', () {
    /// The message of every layer-2 diagnostic of [document].
    List<String> messages(Layered<int> document) => [
      for (final range in document.diagnostics(2).items.cast<ARange>())
        switch (range.get('message')) {
          Str(:final value) => String.fromCharCodes(value.items),
          final other => '$other',
        },
    ];

    test('a diagnostic outside its region becomes one over the region', () {
      final grammar = Faulty(
        flaws: (region) => [
          tagged(
            region.start,
            region.length + 5,
            attributes: {'message': kind('too long')},
          ),
        ],
      );
      final document = Layered.of(Text.of('a[b]'), grammar).unwrap();
      expect(check(document), const Success<void>(null));
      expect(document.layer(2).length, 4);
      expect(document.diagnostics(2).items, [
        isA<ARange>().having((range) => range.same(span(0, 4)), 'same', true),
      ]);
      expect(messages(document).single, contains('is outside'));
      final change = document.apply(Edit(1, Insert(0, Text.of('c'))));
      expect(change, isA<Success<Change<int>>>());
      expect(check(change.unwrap().document), const Success<void>(null));
    });

    test('a diagnostic without a message is replaced', () {
      final grammar = Faulty(flaws: (region) => [tagged(region.start, 0)]);
      final document = Layered.of(Text.of('a[b]'), grammar).unwrap();
      expect(check(document), const Success<void>(null));
      expect(messages(document).single, contains('has no message'));
    });

    test('a range outside its region becomes a diagnostic', () {
      final grammar = Faulty(
        strays: (region) => [tagged(region.start, region.length + 1)],
      );
      final document = Layered.of(Text.of('a[b]'), grammar).unwrap();
      expect(check(document), const Success<void>(null));
      expect(document.layer(2).length, 4);
      expect(messages(document).single, contains('is outside'));
    });

    test('a throw from derive in Layered.of becomes a diagnostic', () {
      final document = Layered.of(
        Text.of('a[b]'),
        Faulty(breaks: (name) => name == 'derive'),
      ).unwrap();
      expect(check(document), const Success<void>(null));
      expect(document.layer(2).length, 0);
      expect(document.diagnostics(2).items, [
        isA<ARange>().having((range) => range.same(span(0, 4)), 'same', true),
      ]);
      expect(messages(document).single, contains('derive broke'));
    });

    for (final method in ['derive', 'affected', 'edit']) {
      test('a throw from $method in an edit is invalid', () {
        var armed = false;
        final document = Layered.of(
          Text.of('a[b]'),
          Faulty(breaks: (name) => armed && name == method),
        ).unwrap();
        final group = document.markers(3).single.$1;
        armed = true;
        final edit = method == 'edit'
            ? Edit<int>(3, Unmark<Object?>(group))
            : Edit<int>(1, Insert(0, Text.of('c')));
        final result = document.apply(edit);
        expect(result, invalid);
        expect(
          (result as Failure<Object?>).message,
          allOf(contains('grammar: $method'), contains('$method broke')),
        );
        expect(document.transact([edit]), invalid);
        expect(document.version, 0);
      });
    }

    test('an affected region outside the layer is invalid', () {
      final grammar = Faulty(area: (changed) => span(0, 100));
      final document = Layered.of(Text.of('a[b]'), grammar).unwrap();
      expect(document.apply(Edit(1, Insert(0, Text.of('c')))), invalid);
    });

    test('a depth changed after construction is not seen', () {
      final grammar = Shifting(2);
      final document = Layered.of(Text.of('a[b]'), grammar).unwrap();
      grammar.depth = 3;
      expect(document.depth, 2);
      final text = document.apply(Edit(1, Insert(0, Text.of('c')))).unwrap();
      expect(text.layers.length, 2);
      expect(text.document.depth, 2);
      expect(check(text.document), const Success<void>(null));
      final group = text.document.transact([
        Edit(1, Insert(1, Text.of('d'))),
        Edit(1, Delete(span(0, 1))),
      ]);
      expect(group.unwrap().layers.length, 2);
      expect(text.document.compact().depth, 2);
    });

    test('a depth below 1 is invalid', () {
      for (final depth in [0, -1]) {
        final result = Layered.of(Text.of('a[b]'), Shifting(depth));
        expect(result, invalid, reason: 'depth $depth');
        expect((result as Failure<Object?>).message, contains('depth $depth'));
      }
    });

    test('a depth getter that throws is invalid', () {
      final result = Layered.of(Text.of('a[b]'), Bottomless());
      expect(result, invalid);
      expect(
        (result as Failure<Object?>).message,
        allOf(contains('grammar: depth'), contains('no bottom')),
      );
      expect(LayeredFormat(Bottomless()).decode(Text.of('a[b]')), invalid);
    });
  });

  group('transact', () {
    test('applies a text edit and a wrap as one version', () {
      final before = Layered.of(Text.of('[a]b'), Brackets()).unwrap();
      final mark = Mark<Object?>(
        tagged(3, 1, attributes: {'type': kind('group')}),
      );
      final edits = [Edit<int>(1, Insert(4, Text.of('c'))), Edit<int>(3, mark)];
      final change = before.transact(edits).unwrap();
      final after = change.document;
      expect(String.fromCharCodes(after.items.items), '[a][bc]');
      expect(after.version, 1);
      expect(identical(after.previous, before), isTrue);
      expect(after.changes, edits);
      expect(change.layers[0].regions, [span(5, 1), span(6, 1), span(3, 1)]);
      expect(change.layers[2].created, [mark.marker]);
      same(after);
    });

    test('a marker created and removed in one transaction is in neither', () {
      final before = Layered.of(Text.of('[a]b'), Brackets()).unwrap();
      final mark = Mark<Object?>(
        tagged(3, 1, attributes: {'type': kind('group')}),
      );
      final change = before.transact([
        Edit(3, mark),
        Edit(3, Unmark<Object?>(mark.marker)),
      ]).unwrap();
      expect(change.layers[2].created, isEmpty);
      expect(change.layers[2].removed, isEmpty);
      expect(String.fromCharCodes(change.document.items.items), '[a]b');
      same(change.document);
    });

    test('attributes set back within a transaction are not updated', () {
      final before = Layered.of(Text.of('[a]'), Brackets()).unwrap();
      final (group, range) = before.markers(3).single;
      final change = before.transact([
        Edit(
          3,
          Update<Object?>(group, {'type': kind('group'), 'n': kind('x')}),
        ),
        Edit(3, Update<Object?>(group, range.attributes)),
        Edit(3, Update<Object?>(group, range.attributes)),
      ]).unwrap();
      expect(change.layers[2].updated, isEmpty);
    });

    test('a failing edit fails the whole transaction, naming it', () {
      final before = Layered.of(Text.of('[a]b'), Brackets()).unwrap();
      final half = Mark<Object?>(
        tagged(0, 2, attributes: {'type': kind('group')}),
      );
      final result = before.transact([
        Edit(1, Insert(0, Text.of('x'))),
        Edit(3, half),
      ]);
      expect(result, invalid);
      expect(
        (result as Failure<Object?>).message,
        startsWith('transact: edit 1: '),
      );
      expect(String.fromCharCodes(before.items.items), '[a]b');
    });

    test('reports the ranges its edits create, remove, and update', () {
      final random = Random(5);
      for (var round = 0; round < 100; round++) {
        final start = Layered.of(Text.of('[a]b[c]'), Brackets()).unwrap();
        // Markers the same in every run of the edits, unlike those a
        // derivation makes, so an edit naming one replays.
        final stable = {for (final (marker, _) in start.markers(3)) marker};
        var current = start;
        final edits = <Edit<int>>[];
        while (edits.length < 30) {
          final groups = [
            for (final (marker, _) in current.markers(3))
              if (stable.contains(marker)) marker,
          ];
          final length = current.items.length;
          final Edit<int>? edit = switch (random.nextInt(5)) {
            0 => Edit(
              1,
              Insert(
                random.nextInt(length + 1),
                Text.of('[]ab'[random.nextInt(4)]),
              ),
            ),
            1 when length > 0 => Edit(
              1,
              Delete<int>(span(random.nextInt(length), 1)),
            ),
            2 when current.layer(2).length > 0 => Edit(
              3,
              Mark<Object?>(
                tagged(
                  random.nextInt(current.layer(2).length),
                  1,
                  attributes: {'type': kind('group')},
                ),
              ),
            ),
            3 when groups.isNotEmpty => Edit(
              3,
              Unmark<Object?>(groups[random.nextInt(groups.length)]),
            ),
            4 when groups.isNotEmpty => Edit(
              3,
              Update<Object?>(groups[random.nextInt(groups.length)], {
                'type': kind('group'),
                if (random.nextBool()) 'n': kind('xy'[random.nextInt(2)]),
              }),
            ),
            _ => null,
          };
          if (edit == null) {
            continue;
          }
          if (current.apply(edit) case Success(:final value)) {
            edits.add(edit);
            current = value.document;
            if (edit.command case Mark(:final marker)) {
              stable.add(marker);
            }
          }
        }
        final change = start.transact(edits).unwrap();
        for (var layer = 2; layer <= 3; layer++) {
          final before = {
            for (final (marker, range) in start.markers(layer))
              marker: range.attributes,
          };
          final after = {
            for (final (marker, range) in change.document.markers(layer))
              marker: range.attributes,
          };
          final reason = 'round $round, layer $layer';
          final delta = change.layers[layer - 1];
          expect(
            delta.created,
            unorderedEquals(after.keys.where((m) => !before.containsKey(m))),
            reason: reason,
          );
          expect(
            delta.removed,
            unorderedEquals(before.keys.where((m) => !after.containsKey(m))),
            reason: reason,
          );
          expect(
            delta.updated,
            unorderedEquals([
              for (final MapEntry(key: marker, value: attributes)
                  in before.entries)
                if (after[marker] case final later?
                    when !alike(attributes, later))
                  marker,
            ]),
            reason: reason,
          );
        }
      }
    });

    test('no edits leave the document as it is', () {
      final before = Layered.of(Text.of('[a]b'), Brackets()).unwrap();
      final change = before.transact(const []).unwrap();
      expect(identical(change.document, before), isTrue);
      expect(change.layers.length, 3);
    });
  });
}

/// Expects [document] to have the layers of one derived from scratch from
/// its items, and to keep its invariants.
void same(Layered<int> document, [String? reason]) {
  final fresh = Layered.of(Items.of(document.items.items), Brackets()).unwrap();
  for (var layer = 2; layer <= 3; layer++) {
    expect(document.layer(layer), fresh.layer(layer), reason: reason);
    expect(
      document.diagnostics(layer),
      fresh.diagnostics(layer),
      reason: reason,
    );
  }
  expect(check(document), const Success<void>(null), reason: reason);
}

/// A bracket grammar whose every structural edit is [derivation].
final class Forged implements Grammar<int> {
  /// A grammar returning [derivation] for every structural edit.
  Forged(this.derivation);

  /// What every structural edit derives.
  final Derivation<int> derivation;

  final Brackets _brackets = Brackets();

  @override
  int get depth => _brackets.depth;

  @override
  Derived derive(Layered<int> document, int layer, Range region) =>
      _brackets.derive(document, layer, region);

  @override
  Range affected(Layered<int> document, int layer, Range changed) =>
      _brackets.affected(document, layer, changed);

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) =>
      Success(derivation);

  /// As the bracket grammar decides.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      _brackets.valid(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}

/// The bracket grammar, whose every structural edit removes the first
/// range of layer 3 and places it again over the first two items below.
final class Placing implements Grammar<int> {
  final Brackets _brackets = Brackets();

  @override
  int get depth => _brackets.depth;

  @override
  Derived derive(Layered<int> document, int layer, Range region) =>
      _brackets.derive(document, layer, region);

  @override
  Range affected(Layered<int> document, int layer, Range changed) =>
      _brackets.affected(document, layer, changed);

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) {
    final (marker, range) = document.markers(3).first;
    return Success((
      below: const [],
      created: [(marker, tagged(0, 2, attributes: range.attributes))],
      removed: [marker],
      updated: const {},
    ));
  }

  /// As the bracket grammar decides.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      _brackets.valid(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}

/// The bracket grammar, whose every structural edit removes the first
/// range of layer 3 and places it again twice, under the same marker.
final class Doubling implements Grammar<int> {
  final Brackets _brackets = Brackets();

  @override
  int get depth => _brackets.depth;

  @override
  Derived derive(Layered<int> document, int layer, Range region) =>
      _brackets.derive(document, layer, region);

  @override
  Range affected(Layered<int> document, int layer, Range changed) =>
      _brackets.affected(document, layer, changed);

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) {
    final (marker, range) = document.markers(3).first;
    return Success((
      below: const [],
      created: [(marker, range), (marker, range)],
      removed: [marker],
      updated: const {},
    ));
  }

  /// As the bracket grammar decides.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      _brackets.valid(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}

/// The bracket grammar with faulty answers added at layer 2: [strays] are
/// added to its ranges, [flaws] to its diagnostics, and [area], when
/// given, replaces its affected region. A method for which [breaks] holds
/// throws.
final class Faulty implements Grammar<int> {
  /// The bracket grammar with the given faults.
  Faulty({
    this.strays = _none,
    this.flaws = _none,
    this.area,
    this.breaks = _never,
  });

  /// Ranges added to layer 2's over a region.
  final List<ARange> Function(Range region) strays;

  /// Diagnostics added to layer 2's over a region.
  final List<ARange> Function(Range region) flaws;

  /// The affected region at every layer, when given.
  final Range Function(Range changed)? area;

  /// Whether the grammar method named [method] throws.
  final bool Function(String method) breaks;

  final Brackets _brackets = Brackets();

  static List<ARange> _none(Range region) => const [];

  static bool _never(String method) => false;

  /// Throws when [method] breaks.
  void _check(String method) {
    if (breaks(method)) {
      throw StateError('$method broke');
    }
  }

  @override
  int get depth => _brackets.depth;

  @override
  Derived derive(Layered<int> document, int layer, Range region) {
    _check('derive');
    final (:ranges, :diagnostics) = _brackets.derive(document, layer, region);
    return (
      ranges: [...ranges, if (layer == 2) ...strays(region)],
      diagnostics: [...diagnostics, if (layer == 2) ...flaws(region)],
    );
  }

  @override
  Range affected(Layered<int> document, int layer, Range changed) {
    _check('affected');
    return area?.call(changed) ?? _brackets.affected(document, layer, changed);
  }

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) {
    _check('edit');
    return _brackets.edit(document, change);
  }

  /// As the bracket grammar decides.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      _brackets.valid(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}

/// A grammar of depth 2 whose layer 2 has ranges sharing a start, returned
/// longest first: over three items or more, the whole sequence, its first
/// item, and its second item, each naming the item it holds. A change
/// within the second item derives the first two again.
final class Nested implements Grammar<int> {
  @override
  int get depth => 2;

  @override
  Derived derive(Layered<int> document, int layer, Range region) =>
      (ranges: _ranges(document, region), diagnostics: const []);

  /// Layer 2's ranges over [region].
  List<ARange> _ranges(Layered<int> document, Range region) {
    final items = document.items.items.toList();
    if (items.length < 3) {
      return const [];
    }
    return [
      if (region.start == 0 && region.end == items.length)
        tagged(0, items.length, attributes: {'type': kind('all')}),
      if (region.start == 0) tagged(0, 1, attributes: {'first': Num(items[0])}),
      if (region.start <= 1 && region.end >= 2)
        tagged(1, 1, attributes: {'second': Num(items[1])}),
    ];
  }

  @override
  Range affected(Layered<int> document, int layer, Range changed) =>
      changed.start >= 1 && changed.end <= 2
      ? span(0, 2)
      : span(0, document.items.length);

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) =>
      Failure(Kind.invalid, 'nested: no structural edits');

  /// Every range is markup, so only an edit changing none is valid.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      kept(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}

/// A grammar of depth 3 over ten items or more whose layer 2 overlaps:
/// the whole sequence and its sixth item. Layer 3 covers both, and has
/// zero-length ranges before the second and after the last.
final class Spanning implements Grammar<int> {
  @override
  int get depth => 3;

  @override
  Derived derive(Layered<int> document, int layer, Range region) => (
    ranges: switch (layer) {
      2 when region.length >= 10 => [tagged(0, region.length), tagged(5, 1)],
      3 when region.length == 2 => [tagged(0, 2), tagged(1, 0), tagged(2, 0)],
      _ => const [],
    },
    diagnostics: const [],
  );

  @override
  Range affected(Layered<int> document, int layer, Range changed) =>
      span(0, layer == 2 ? document.items.length : document.layer(2).length);

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) =>
      Failure(Kind.invalid, 'spanning: no structural edits');

  /// Every range is markup, so only an edit changing none is valid.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      kept(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}

/// A grammar of depth 2 whose layer 2 is a chain of crossing ranges: one
/// over each pair of neighbouring items, naming both. A change derives
/// again the pairs that start or end at it.
final class Pairs implements Grammar<int> {
  @override
  int get depth => 2;

  @override
  Derived derive(Layered<int> document, int layer, Range region) {
    final items = document.slice(region).items.toList();
    return (
      ranges: [
        for (var index = 0; index + 1 < items.length; index++)
          tagged(
            region.start + index,
            2,
            attributes: {
              'first': Num(items[index]),
              'second': Num(items[index + 1]),
            },
          ),
      ],
      diagnostics: const [],
    );
  }

  @override
  Range affected(Layered<int> document, int layer, Range changed) {
    final start = max(0, changed.start - 1);
    return span(start, min(document.items.length, changed.end + 1) - start);
  }

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) =>
      Failure(Kind.invalid, 'pairs: no structural edits');

  /// Every range is markup, so only an edit changing none is valid.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      kept(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}

/// A grammar of fixed layer-2 [ranges] over the text, a layer-3 range over
/// each layer-2 item and one over them all, and structural deletes of one
/// item that delete what it covers below. The range over them all does not
/// depend on their order, so reordering them does not affect it.
final class Trims implements Grammar<int> {
  /// Layer 2 holds [ranges].
  Trims(this.ranges);

  /// The ranges of layer 2.
  final List<Range> ranges;

  @override
  int get depth => 3;

  @override
  Derived derive(Layered<int> document, int layer, Range region) => (
    ranges: layer == 2
        ? [
            for (final range in ranges)
              if (range.within(region)) tagged(range.start, range.length),
          ]
        : [
            for (final (index, _) in document.span(2, region).indexed)
              tagged(region.start + index, 1),
            if (region.start == 0 &&
                region.length > 0 &&
                region.end == document.layer(2).length)
              tagged(0, region.length),
          ],
    diagnostics: const [],
  );

  @override
  Range affected(Layered<int> document, int layer, Range changed) => changed;

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) {
    final Edit(:layer, :command) = change;
    if (command is! Delete<Object?> || command.span.length != 1) {
      return Failure(Kind.invalid, 'trims: only one item is deleted');
    }
    final (marker, range) = document.span(layer, command.span).single;
    return Success((
      below: [
        layer == 2
            ? Edit<int>(1, Delete<int>(range))
            : Edit<int>(2, Delete<Object?>(range)),
      ],
      created: const [],
      removed: [marker],
      updated: const {},
    ));
  }

  /// Every range is markup, so only an edit changing none is valid.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      kept(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}

/// A grammar of three layers whose layers above the first each hold a range
/// over every item of the layer below and one over them all. Neither kind
/// depends on the items' order, so a change affects only itself, except
/// that items inserted at either end lie outside the range over them all.
final class Whole implements Grammar<int> {
  @override
  int get depth => 3;

  /// The number of items in the layer below [layer].
  static int _count(Layered<int> document, int layer) =>
      layer == 2 ? document.items.length : document.layer(layer - 1).length;

  @override
  Derived derive(Layered<int> document, int layer, Range region) {
    final count = _count(document, layer);
    return (
      ranges: [
        for (var index = region.start; index < min(region.end, count); index++)
          tagged(index, 1),
        if (region.start == 0 && region.end == count && count > 0)
          tagged(0, count),
      ],
      diagnostics: const [],
    );
  }

  @override
  Range affected(Layered<int> document, int layer, Range changed) {
    final count = _count(document, layer);
    return changed.length > 0 && (changed.start == 0 || changed.end == count)
        ? span(0, count)
        : changed;
  }

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) =>
      Failure(Kind.invalid, 'whole: no structural edits');

  /// Every range is markup, so only an edit changing none is valid.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      kept(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}

/// A grammar of [depth] 2 or 3 over ten items or more whose layer 2
/// interleaves: (2,1) and (4,1) with (3,5) between them, which clamps where
/// a move cuts it. Layer 3, if any, is empty.
final class Interleaved implements Grammar<int> {
  /// The grammar, of [depth] layers.
  Interleaved({this.depth = 3});

  @override
  final int depth;

  @override
  Derived derive(Layered<int> document, int layer, Range region) => (
    ranges: layer == 2 && region.length >= 10
        ? [tagged(2, 1), tagged(3, 5), tagged(4, 1)]
        : const [],
    diagnostics: const [],
  );

  @override
  Range affected(Layered<int> document, int layer, Range changed) =>
      span(0, layer == 2 ? document.items.length : document.layer(2).length);

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) =>
      Failure(Kind.invalid, 'interleaved: no structural edits');

  /// Every range is markup, so only an edit changing none is valid.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      kept(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.clamp;
}

/// The bracket grammar with a [depth] that can be changed, which a grammar
/// must not do.
final class Shifting implements Grammar<int> {
  /// The bracket grammar reporting [depth] layers.
  Shifting(this.depth);

  @override
  int depth;

  final Brackets _brackets = Brackets();

  @override
  Derived derive(Layered<int> document, int layer, Range region) =>
      _brackets.derive(document, layer, region);

  @override
  Range affected(Layered<int> document, int layer, Range changed) =>
      _brackets.affected(document, layer, changed);

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) =>
      _brackets.edit(document, change);

  /// As the bracket grammar decides.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      _brackets.valid(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}

/// The bracket grammar with a [depth] getter that throws.
final class Bottomless extends Shifting {
  /// The bracket grammar, without a depth.
  Bottomless() : super(3);

  @override
  int get depth => throw StateError('no bottom');
}
