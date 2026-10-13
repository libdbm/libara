import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

Document<int> text(String source) => Document.of(Text.of(source));

String show(Sequence<int> sequence) => String.fromCharCodes(sequence.items);

/// [document] with a range marked over [start] to [end], and its marker.
(Document<int>, Marker) marked(Document<int> document, int start, int end) {
  final mark = Mark<int>(tagged(start, end - start));
  return (document.apply(mark).unwrap(), mark.marker);
}

/// Where [marker]'s range stands in [document], as start and end.
(int, int) where(Document<int> document, Marker marker) {
  final range = document.resolve(marker)!;
  return (range.start, range.end);
}

void main() {
  group('Move', () {
    test('takes the items forward, to before a later position', () {
      final moved = text('abcdef').apply(Move(span(1, 2), 5)).unwrap();
      expect(show(moved), 'adebcf');
    });

    test('and back, to before an earlier one', () {
      final moved = text('abcdef').apply(Move(span(3, 2), 1)).unwrap();
      expect(show(moved), 'adebcf');
    });

    test('carries a range wholly inside with the items, marker and all', () {
      final (document, marker) = marked(text('abcdef'), 1, 3);
      final moved = document.apply(Move(span(1, 2), 5)).unwrap();
      expect(where(moved, marker), (3, 5));
      expect(show(moved.slice(3, 2)), 'bc');
    });

    test('shifts a range outside as the items leave and arrive', () {
      final (other, before) = marked(text('abcdef'), 0, 1);
      final back = other.apply(Move(span(3, 2), 2)).unwrap();
      expect(where(back, before), (0, 1));
      final (after, past) = marked(text('abcdef'), 3, 4);
      final forward = after.apply(Move(span(1, 2), 5)).unwrap();
      expect(where(forward, past), (1, 2));
    });

    test('and its gravity decides an end at the place they arrive', () {
      // 'de' ends where 'bc' arrives: an end with right gravity takes them
      // in, as an insertion there would, and one with left gravity does not.
      final document = text('abcdef');
      final right = Mark<int>(tagged(3, 2));
      final left = Mark<int>(tagged(3, 2), end: Gravity.left);
      final moved = document
          .transact([right, left])
          .unwrap()
          .apply(Move(span(1, 2), 5))
          .unwrap();
      expect(where(moved, right.marker), (1, 5));
      expect(where(moved, left.marker), (1, 3));
    });

    test('keeps a range around the span and the place, holding them both', () {
      final (document, marker) = marked(text('abcdef'), 0, 6);
      final moved = document.apply(Move(span(1, 2), 5)).unwrap();
      expect(where(moved, marker), (0, 6));
    });

    group('a range crossing an edge of the span', () {
      // 'cde' crosses the span 'bc' at its end.
      (Document<int>, Marker) crossed() => marked(text('abcdef'), 2, 5);

      test(
        'takes in one sharing an edge with the span and running past it',
        () {
          // 'bcd' starts with 'bc', and 'abc' ends with it: each holds some
          // of what moves and not all.
          final (starting, _) = marked(text('abcdef'), 1, 4);
          expect(starting.apply(Move(span(1, 2), 6)), invalid);
          final (ending, _) = marked(text('abcdef'), 0, 3);
          expect(ending.apply(Move(span(1, 2), 6)), invalid);
        },
      );

      test('is refused by default, nothing changed', () {
        final (document, _) = crossed();
        expect(document.apply(Move(span(1, 2), 6)), invalid);
      });

      test('is clamped to the part outside the span', () {
        final (document, marker) = crossed();
        final moved = document
            .apply(Move(span(1, 2), 6), crossing: (_) => Crossing.clamp)
            .unwrap();
        expect(show(moved), 'adefbc');
        expect(where(moved, marker), (1, 3));
        expect(show(moved.slice(1, 2)), 'de');
      });

      test('or follows the items with its inside end', () {
        final (document, marker) = crossed();
        final moved = document
            .apply(Move(span(1, 2), 0), crossing: (_) => Crossing.follow)
            .unwrap();
        // 'bc' to the front: 'cde' starts where 'c' went and ends where it
        // did.
        expect(show(moved), 'bcadef');
        expect(where(moved, marker), (1, 5));
      });

      test('and fails where following would end it before it starts', () {
        final (document, _) = crossed();
        expect(
          document.apply(Move(span(0, 3), 6), crossing: (_) => Crossing.follow),
          invalid,
        );
      });

      test('and the policy is asked of that range alone', () {
        final (document, _) = crossed();
        final (both, inside) = marked(document, 1, 3);
        final asked = <ARange>[];
        both
            .apply(
              Move(span(1, 2), 6),
              crossing: (range) {
                asked.add(range);
                return Crossing.clamp;
              },
            )
            .unwrap();
        expect(asked, hasLength(1));
        expect((asked.single.start, asked.single.end), (2, 5));
        expect(inside, isNotNull);
      });
    });

    test('opens an empty range at the place as an insertion there does', () {
      // Its start goes past the items arriving at it, and its end stays:
      // as a deletion then an insertion leave it, reading as empty at
      // its start, and no failure.
      final mark = Mark<int>(tagged(2, 0), end: Gravity.left);
      final document = text('abcdef').apply(mark).unwrap();
      final moved = document.apply(Move(span(3, 2), 2)).unwrap();
      final inserted = document
          .apply(Delete(span(3, 2)))
          .unwrap()
          .apply(Insert(2, Text.of('de')))
          .unwrap();
      expect(show(moved), show(inserted));
      expect(where(moved, mark.marker), where(inserted, mark.marker));
    });

    test('to a place inside the span, or outside the document, fails', () {
      final document = text('abcdef');
      expect(document.apply(Move(span(1, 3), 2)), invalid);
      expect(
        document.apply(Move(span(1, 2), 9)),
        isA<Failure<Document<int>>>(),
      );
      expect(
        document.apply(Move(span(5, 3), 0)),
        isA<Failure<Document<int>>>(),
      );
    });

    test('to either edge of the span leaves the items where they are', () {
      final document = text('abcdef');
      expect(show(document.apply(Move(span(1, 2), 1)).unwrap()), 'abcdef');
      expect(show(document.apply(Move(span(1, 2), 3)).unwrap()), 'abcdef');
    });

    test('is undone by stepping back, and logged as itself', () {
      final document = text('abcdef');
      final moved = document.apply(Move(span(1, 2), 5)).unwrap();
      expect(identical(moved.previous, document), isTrue);
      expect(moved.commands.single, isA<Move<int>>());
      expect(
        show(
          document.transact([
            Move(span(1, 2), 5),
            Move(span(3, 2), 1),
          ]).unwrap(),
        ),
        'abcdef',
      );
    });

    test('is logged with what it decided, and replays the same', () {
      final crossing = Mark<int>(tagged(2, 3));
      final document = text('abcdef').apply(crossing).unwrap();
      final moved = document
          .apply(Move(span(1, 2), 6), crossing: (_) => Crossing.clamp)
          .unwrap();
      final logged = moved.commands.single as Move<int>;
      expect(logged.crossings, {crossing.marker: Crossing.clamp});
      // With no say of its own, a replay decides as the move did.
      final again = document.apply(logged).unwrap();
      expect(again.resolve(crossing.marker), moved.resolve(crossing.marker));
    });

    test('in a transaction is logged with what it decided', () {
      final crossing = Mark<int>(tagged(2, 3));
      final document = text('abcdef');
      final moved = document.transact([
        crossing,
        Move(span(1, 2), 6),
      ], crossing: (_) => Crossing.clamp).unwrap();
      final logged = moved.commands.last as Move<int>;
      expect(logged.crossings, {crossing.marker: Crossing.clamp});
    });

    test('carries a position mapped through it', () {
      final document = text('abcdef');
      final moved = document.apply(Move(span(1, 2), 5)).unwrap();
      // 'c', inside, goes with the items; 'e', after, moves back.
      expect(moved.map(document, 2, Gravity.right).unwrap(), 4);
      expect(moved.map(document, 4, Gravity.right).unwrap(), 2);
      expect(moved.map(document, 0, Gravity.right).unwrap(), 0);
      expect(moved.map(document, 6, Gravity.right).unwrap(), 6);
    });

    test('to either edge of the span maps every position to itself', () {
      final document = text('abcdef');
      for (final to in [1, 4]) {
        final moved = document.apply(Move(span(1, 3), to)).unwrap();
        for (var position = 0; position <= document.length; position++) {
          for (final gravity in Gravity.values) {
            expect(
              moved.map(document, position, gravity).unwrap(),
              position,
              reason: 'to $to, $position $gravity',
            );
          }
        }
      }
    });
  });
}
