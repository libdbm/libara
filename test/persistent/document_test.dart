import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

Document<int> text(String source) => Document.of(Text.of(source));

String show(Sequence<int> sequence) => String.fromCharCodes(sequence.items);

void main() {
  group('a new document', () {
    test('is version 0 with no history', () {
      final document = text('abc');
      expect(document.version, 0);
      expect(document.previous, isNull);
      expect(document.commands, isEmpty);
    });

    test('an empty document accepts every command', () {
      final mark = Mark<int>(tagged(0, 1));
      var document = Document<int>.empty();
      document = document.apply(Insert(0, Text.of('ab'))).or(document);
      document = document.apply(mark).or(document);
      expect(show(document), 'ab');
      expect(document.resolve(mark.marker), tagged(0, 1));
    });

    test('answers sequence queries from its items', () {
      final document = text('abc');
      expect(document.length, 3);
      expect(show(document), 'abc');
      expect(document.item(1), 0x62);
      expect(document.first, 0x61);
      expect(document.last, 0x63);
      expect(document.contains(0x62), isTrue);
      expect(Document<int>.empty().empty, isTrue);
    });

    test('equals a sequence with the same items, in both directions', () {
      expect(text('abc'), Text.of('abc'));
      expect(Text.of('abc'), text('abc'));
    });
  });

  group('apply', () {
    test('Insert adds items and makes the next version', () {
      final document = text('ad');
      final command = Insert(1, Text.of('bc'));
      final next = document.apply(command).or(document);
      expect(show(next), 'abcd');
      expect(next.version, 1);
      expect(identical(next.previous, document), isTrue);
      expect(next.commands, [command]);
    });

    test('Delete removes the span and makes the next version', () {
      final document = text('abcd');
      final command = Delete<int>(span(1, 2));
      final next = document.apply(command).or(document);
      expect(show(next), 'ad');
      expect(next.version, 1);
      expect(next.commands, [command]);
    });

    test('an Insert outside the document fails and changes nothing', () {
      final document = text('ab');
      expect(
        document.apply(Insert(3, Text.of('x'))),
        Failure<Document<int>>.bounds('insert', 3),
      );
      expect(show(document), 'ab');
      expect(document.version, 0);
    });

    test('a Delete past the end fails and changes nothing', () {
      final document = text('ab');
      expect(
        document.apply(Delete<int>(span(1, 2))),
        Failure<Document<int>>.bounds('delete', 3),
      );
      expect(show(document), 'ab');
    });

    test('versions chain back through previous', () {
      var document = text('');
      for (final letter in ['a', 'b', 'c']) {
        document = document
            .apply(Insert(document.length, Text.of(letter)))
            .or(document);
      }
      expect(document.version, 3);
      expect(show(document.previous!), 'ab');
      expect(show(document.previous!.previous!), 'a');
      expect(document.previous!.previous!.previous!.version, 0);
    });
  });

  group('apply with flatten', () {
    test('coalesces into the current version', () {
      final start = text('');
      final first = start.apply(Insert(0, Text.of('a'))).or(start);
      final firstCommand = first.commands.single;
      final second = Insert(1, Text.of('b'));
      final both = first.apply(second, flatten: true).or(first);
      expect(show(both), 'ab');
      expect(both.version, first.version);
      expect(identical(both.previous, start), isTrue);
      expect(both.commands, [firstCommand, second]);
    });

    test('one step back undoes every coalesced command', () {
      final start = text('x');
      var document = start.apply(Insert(1, Text.of('a'))).or(start);
      document = document
          .apply(Insert(2, Text.of('b')), flatten: true)
          .or(document);
      document = document
          .apply(Insert(3, Text.of('c')), flatten: true)
          .or(document);
      expect(show(document), 'xabc');
      expect(show(document.previous!), 'x');
    });

    test('coalescing into version 0 stays version 0 with no previous', () {
      final start = text('x');
      final command = Insert(1, Text.of('a'));
      final document = start.apply(command, flatten: true).or(start);
      expect(show(document), 'xa');
      expect(document.version, 0);
      expect(document.previous, isNull);
      expect(document.commands, [command]);
    });

    test('a failed command leaves the coalesced version unchanged', () {
      final start = text('x');
      final document = start.apply(Insert(1, Text.of('a'))).or(start);
      expect(
        document.apply(Insert(9, Text.of('b')), flatten: true),
        isA<Failure<Document<int>>>(),
      );
      expect(document.commands, hasLength(1));
    });
  });

  group('sequence operations', () {
    test('insert and delete make new versions', () {
      final document = text('ac');
      final inserted = document.insert(1, 0x62).or(document);
      expect(show(inserted), 'abc');
      expect(inserted.version, 1);
      final deleted = inserted.delete(0).or(inserted);
      expect(show(deleted), 'bc');
      expect(deleted.version, 2);
    });

    test('insert and delete out of bounds are the usual failures', () {
      final document = text('ab');
      expect(
        document.insert(3, 0x78),
        Failure<Document<int>>.bounds('insert', 3),
      );
      expect(document.delete(2), Failure<Document<int>>.bounds('delete', 2));
      expect(document.delete(-1), Failure<Document<int>>.bounds('delete', -1));
    });

    test('concat appends and makes a new version', () {
      final document = text('ab');
      final joined = document.concat(Text.of('cd')).or(document);
      expect(show(joined), 'abcd');
      expect(joined.version, 1);
      expect(identical(joined.previous, document), isTrue);
    });

    test('slice, diff, union, and intersect return plain items', () {
      final document = text('abcb');
      expect(document.slice(1, 2), isA<Items<int>>());
      expect(show(document.slice(1, 2)), 'bc');
      expect(show(document.diff(Text.of('b'))), 'ac');
      expect(show(document.union(Text.of('bd')).or(Items.empty())), 'abcbd');
      expect(show(document.intersect(Text.of('cb'))), 'bcb');
      expect(document.diff(Text.of('b')), isA<Items<int>>());
      expect(document.union(Text.of('b')), isA<Success<Items<int>>>());
      expect(document.intersect(Text.of('b')), isA<Items<int>>());
    });
  });

  group('ranges under edits', () {
    /// A document of ten letters with one range marked, the marker, and the
    /// range it resolves to after [command].
    (Document<int>, Marker) marked(int start, int length) {
      final mark = Mark<int>(tagged(start, length));
      final document = text('abcdefghij');
      return (document.apply(mark).or(document), mark.marker);
    }

    ARange? after(int start, int length, Command<int> command) {
      final (document, marker) = marked(start, length);
      return document.apply(command).or(document).resolve(marker);
    }

    test('an insertion before the start shifts the range', () {
      expect(after(4, 2, Insert(1, Text.of('xyz'))), tagged(7, 2));
    });

    test('an insertion at the start shifts the range', () {
      expect(after(4, 2, Insert(4, Text.of('xyz'))), tagged(7, 2));
    });

    test('an insertion inside the range grows it', () {
      expect(after(4, 3, Insert(5, Text.of('xyz'))), tagged(4, 6));
    });

    test('an insertion at the end grows the range', () {
      expect(after(4, 2, Insert(6, Text.of('xyz'))), tagged(4, 5));
    });

    test('an insertion after the end leaves the range unchanged', () {
      expect(after(4, 2, Insert(7, Text.of('xyz'))), tagged(4, 2));
    });

    test('a zero-length range at the insertion point shifts intact', () {
      expect(after(4, 0, Insert(4, Text.of('xyz'))), tagged(7, 0));
    });

    test('a deletion covering the range collapses it to zero length', () {
      expect(after(4, 2, Delete(span(3, 5))), tagged(3, 0));
    });

    test('a deletion overlapping the start trims the range', () {
      expect(after(4, 4, Delete(span(2, 4))), tagged(2, 2));
    });

    test('a deletion before the range shifts it back', () {
      expect(after(6, 2, Delete(span(1, 3))), tagged(3, 2));
    });
  });

  group('Mark and Unmark', () {
    test('resolve returns the range with its attributes', () {
      final mark = Mark<int>(
        tagged(1, 2, attributes: {'type': Value.of('word').unwrap()}),
      );
      final document = text('abcd').apply(mark).or(text(''));
      expect(
        document.resolve(mark.marker),
        tagged(1, 2, attributes: {'type': Value.of('word').unwrap()}),
      );
      expect(document.version, 1);
    });

    test('Mark past the end is a bounds failure', () {
      expect(
        text('abc').apply(Mark<int>(tagged(2, 2))),
        Failure<Document<int>>.bounds('mark', 4),
      );
    });

    test('Mark of a marker already present is invalid', () {
      final mark = Mark<int>(tagged(0, 1));
      final document = text('abc').apply(mark).or(text(''));
      final again = document.apply(mark);
      expect(again, isA<Failure<Document<int>>>());
      expect((again as Failure).kind, Kind.invalid);
    });

    test('Unmark removes the range', () {
      final mark = Mark<int>(tagged(0, 1));
      final document = text('abc').apply(mark).or(text(''));
      final removed = document.apply(Unmark(mark.marker)).or(document);
      expect(removed.resolve(mark.marker), isNull);
      expect(removed.ranges, Ranges.empty());
      expect(document.resolve(mark.marker), tagged(0, 1));
    });

    test('Unmark of an absent marker is missing', () {
      final result = text('abc').apply(Unmark(Marker()));
      expect(result, isA<Failure<Document<int>>>());
      expect((result as Failure).kind, Kind.missing);
    });

    test('resolve is null for a marker not in this version', () {
      final mark = Mark<int>(tagged(0, 1));
      final start = text('abc');
      final document = start.apply(mark).or(start);
      expect(start.resolve(mark.marker), isNull);
      expect(document.previous!.resolve(mark.marker), isNull);
      expect(document.resolve(Marker()), isNull);
    });

    test('one Mark applied to two versions resolves independently', () {
      final mark = Mark<int>(tagged(1, 1));
      final start = text('abc');
      final shorter = start.apply(Delete(span(0, 1))).or(start);
      final left = start.apply(mark).or(start);
      final right = shorter.apply(mark).or(shorter);
      final edited = left.apply(Insert(0, Text.of('xy'))).or(left);
      expect(edited.resolve(mark.marker), tagged(3, 1));
      expect(right.resolve(mark.marker), tagged(1, 1));
    });

    test('ranges lists every range in startOrder with attributes', () {
      final word = {'type': Value.of('word').unwrap()};
      var document = text('abcdefgh');
      for (final range in [
        tagged(4, 2, attributes: word),
        tagged(0, 8),
        tagged(4, 1),
        tagged(1, 3),
      ]) {
        document = document.apply(Mark<int>(range)).or(document);
      }
      expect(
        document.ranges,
        Ranges.of([
          tagged(0, 8),
          tagged(1, 3),
          tagged(4, 1),
          tagged(4, 2, attributes: word),
        ]),
      );
    });

    test('concat keeps the ranges of the receiver', () {
      final inner = Mark<int>(tagged(0, 1));
      final tail = Mark<int>(tagged(1, 2));
      var document = text('abc');
      document = document.apply(inner).or(document);
      document = document.apply(tail).or(document);
      final joined = document.concat(Text.of('def')).or(document);
      expect(joined.resolve(inner.marker), tagged(0, 1));
      // concat inserts at the end, and a range ending there has right
      // gravity at its end, so it grows over the appended items.
      expect(joined.resolve(tail.marker), tagged(1, 5));
      expect(joined.ranges.length, 2);
    });

    test('undo through previous drops a range marked later', () {
      final mark = Mark<int>(tagged(0, 2));
      var document = text('abc');
      document = document.apply(Insert(0, Text.of('x'))).or(document);
      document = document.apply(mark, flatten: true).or(document);
      expect(document.resolve(mark.marker), tagged(0, 2));
      expect(document.previous!.ranges, Ranges.empty());
    });
  });

  group('at', () {
    Document<int> nested() {
      var document = text('abcdefghij');
      for (final range in [
        tagged(0, 10),
        tagged(2, 5),
        tagged(3, 1),
        tagged(6, 0),
        tagged(8, 2),
      ]) {
        document = document.apply(Mark<int>(range)).or(document);
      }
      return document;
    }

    test('returns every range containing the position, in start order', () {
      expect(
        nested().at(3),
        Ranges.of([tagged(0, 10), tagged(2, 5), tagged(3, 1)]),
      );
      expect(nested().at(8), Ranges.of([tagged(0, 10), tagged(8, 2)]));
    });

    test('the end of a range is not inside it', () {
      expect(nested().at(7), Ranges.of([tagged(0, 10)]));
    });

    test('a zero-length range is never returned', () {
      expect(nested().at(6), Ranges.of([tagged(0, 10), tagged(2, 5)]));
    });

    test('positions outside the document return nothing', () {
      expect(nested().at(10), Ranges.empty());
      expect(nested().at(-1), Ranges.empty());
    });

    test('follows ranges through edits', () {
      final document = nested();
      final edited = document.apply(Insert(0, Text.of('xyz'))).or(document);
      expect(
        edited.at(6),
        Ranges.of([tagged(3, 10), tagged(5, 5), tagged(6, 1)]),
      );
      expect(edited.at(2), Ranges.empty());
    });
  });

  group('gravity', () {
    ARange? after(
      ARange range,
      Gravity start,
      Gravity end,
      Command<int> command,
    ) {
      final mark = Mark<int>(range, start: start, end: end);
      var document = text('abcdefghij');
      document = document.apply(mark).or(document);
      return document.apply(command).or(document).resolve(mark.marker);
    }

    final insert4 = Insert(4, Text.of('xyz'));
    final insert6 = Insert(6, Text.of('xyz'));
    const right = Gravity.right;
    const left = Gravity.left;

    test(
      'an insertion at the start moves a right start and keeps a left one',
      () {
        expect(after(tagged(4, 2), right, right, insert4), tagged(7, 2));
        expect(after(tagged(4, 2), right, left, insert4), tagged(7, 2));
        expect(after(tagged(4, 2), left, right, insert4), tagged(4, 5));
        expect(after(tagged(4, 2), left, left, insert4), tagged(4, 5));
      },
    );

    test('an insertion at the end moves a right end and keeps a left one', () {
      expect(after(tagged(4, 2), right, right, insert6), tagged(4, 5));
      expect(after(tagged(4, 2), left, right, insert6), tagged(4, 5));
      expect(after(tagged(4, 2), right, left, insert6), tagged(4, 2));
      expect(after(tagged(4, 2), left, left, insert6), tagged(4, 2));
    });

    test(
      'a zero-length range at the insertion point, for every combination',
      () {
        expect(after(tagged(4, 0), right, right, insert4), tagged(7, 0));
        expect(after(tagged(4, 0), left, left, insert4), tagged(4, 0));
        expect(after(tagged(4, 0), left, right, insert4), tagged(4, 3));
        // The end is left before the start, so it reads as zero-length at the
        // start.
        expect(after(tagged(4, 0), right, left, insert4), tagged(7, 0));
      },
    );

    test('deletions ignore gravity', () {
      for (final start in Gravity.values) {
        for (final end in Gravity.values) {
          expect(
            after(tagged(4, 4), start, end, Delete(span(2, 4))),
            tagged(2, 2),
          );
          expect(
            after(tagged(4, 2), start, end, Delete(span(3, 5))),
            tagged(3, 0),
          );
        }
      }
    });

    test('an inverted range reads as zero-length through later edits', () {
      final mark = Mark<int>(tagged(4, 0), start: right, end: left);
      var document = text('abcdefghij');
      document = document.apply(mark).or(document);
      document = document.apply(insert4).or(document);
      expect(document.resolve(mark.marker), tagged(7, 0));
      document = document.apply(Insert(5, Text.of('uv'))).or(document);
      expect(document.resolve(mark.marker), tagged(9, 0));
      document = document.apply(Delete(span(0, 2))).or(document);
      expect(document.resolve(mark.marker), tagged(7, 0));
      expect(document.ranges, Ranges.of([tagged(7, 0)]));
    });

    test('Unmark removes a range whose endpoints have different gravities', () {
      final mark = Mark<int>(tagged(2, 3), start: left, end: right);
      var document = text('abcdefghij');
      document = document.apply(mark).or(document);
      document = document.apply(Unmark(mark.marker)).or(document);
      expect(document.resolve(mark.marker), isNull);
      expect(document.ranges, Ranges.empty());
    });

    test('concat does not grow a range whose end has left gravity', () {
      final mark = Mark<int>(tagged(1, 2), end: left);
      var document = text('abc');
      document = document.apply(mark).or(document);
      final joined = document.concat(Text.of('def')).or(document);
      expect(joined.resolve(mark.marker), tagged(1, 2));
    });

    test('ranges lists ranges of every gravity in start order', () {
      var document = text('abcdefghij');
      document = document
          .apply(Mark<int>(tagged(5, 2), start: left))
          .or(document);
      document = document
          .apply(Mark<int>(tagged(1, 3), end: left))
          .or(document);
      document = document.apply(Mark<int>(tagged(0, 9))).or(document);
      expect(
        document.ranges,
        Ranges.of([tagged(0, 9), tagged(1, 3), tagged(5, 2)]),
      );
    });

    test('undo and flatten keep each marker gravity', () {
      final mark = Mark<int>(tagged(4, 2), start: left, end: left);
      var document = text('abcdefghij');
      document = document.apply(mark).or(document);
      document = document.apply(insert4).or(document);
      document = document.apply(insert6, flatten: true).or(document);
      // First [4,6) to [4,9), then the end moves again: [4,12).
      expect(document.resolve(mark.marker), tagged(4, 8));
      expect(document.previous!.resolve(mark.marker), tagged(4, 2));
    });
  });

  group('compact', () {
    /// A document with three ranges, one of each endpoint gravity mix, after
    /// a few edits.
    (Document<int>, List<Marker>) edited() {
      final marks = [
        Mark<int>(tagged(0, 3, attributes: {'n': const Num(1)})),
        Mark<int>(tagged(2, 4), start: Gravity.left),
        Mark<int>(tagged(5, 0), end: Gravity.left),
      ];
      var document = text('abcdefghij');
      for (final mark in marks) {
        document = document.apply(mark).unwrap();
      }
      document = document.apply(Insert(3, Text.of('xy'))).unwrap();
      document = document.apply(Delete<int>(span(1, 2))).unwrap();
      return (document, [for (final mark in marks) mark.marker]);
    }

    test('keeps items, ranges, and every marker', () {
      final (document, markers) = edited();
      final compacted = document.compact();
      expect(show(compacted), show(document));
      expect(compacted.ranges, document.ranges);
      for (final marker in markers) {
        expect(compacted.resolve(marker), document.resolve(marker));
      }
      for (var position = 0; position <= document.length; position++) {
        expect(compacted.at(position), document.at(position));
      }
      expect(check(compacted), const Success<void>(null));
    });

    test('is version 0 with no history', () {
      final (document, _) = edited();
      final compacted = document.compact();
      expect(compacted.version, 0);
      expect(compacted.previous, isNull);
      expect(compacted.commands, isEmpty);
    });

    test('edits after compacting move the ranges as before', () {
      final (document, markers) = edited();
      final compacted = document.compact();
      final command = Insert(2, Text.of('zz'));
      final expected = document.apply(command).unwrap();
      final actual = compacted.apply(command).unwrap();
      for (final marker in markers) {
        expect(actual.resolve(marker), expected.resolve(marker));
      }
      final unmarked = actual.apply(Unmark(markers.first)).unwrap();
      expect(unmarked.resolve(markers.first), isNull);
      expect(check(unmarked), const Success<void>(null));
    });
  });

  group('transact', () {
    test('applies every command as one new version', () {
      final document = text('abc');
      final mark = Mark<int>(tagged(0, 1));
      final commands = <Command<int>>[
        Insert(3, Text.of('de')),
        mark,
        Delete<int>(span(0, 1)),
      ];
      final result = document.transact(commands).unwrap();
      expect(show(result), 'bcde');
      expect(result.version, document.version + 1);
      expect(identical(result.previous, document), isTrue);
      expect(result.commands, commands);
      expect(result.resolve(mark.marker), tagged(0, 0));
      expect(check(result), const Success<void>(null));
    });

    test('each command sees the result of the one before', () {
      final result = text('ab')
          .transact([Insert(2, Text.of('c')), Delete<int>(span(2, 1))])
          .unwrap();
      expect(show(result), 'ab');
    });

    test('a failing command fails the whole transaction', () {
      final document = text('abc');
      final result = document.transact([
        Insert(0, Text.of('x')),
        Delete<int>(span(2, 5)),
      ]);
      expect(
        result,
        const Failure<Document<int>>(
          Kind.bounds,
          'transact: command 1: delete: position 7 is out of bounds',
        ),
      );
      expect(show(document), 'abc');
      expect(document.version, 0);
    });

    test('an empty transaction returns the document unchanged', () {
      final document = text('abc');
      expect(identical(document.transact([]).unwrap(), document), isTrue);
    });
  });

  group('Replace', () {
    test('is a delete then an insert at the span start', () {
      final document = text('the cat sat');
      final word = Mark<int>(tagged(4, 3));
      final covering = Mark<int>(tagged(4, 3), start: Gravity.left);
      final around = Mark<int>(tagged(0, 11));
      final marked = document.transact([word, covering, around]).unwrap();
      final replaced = marked
          .apply(Replace(span(4, 3), Text.of('dogs')))
          .unwrap();
      expect(show(replaced), 'the dogs sat');
      // Default gravities: both endpoints collapse to 4, then move past.
      expect(replaced.resolve(word.marker), tagged(8, 0));
      // A left start stays before the new items, so the range covers them.
      expect(replaced.resolve(covering.marker), tagged(4, 4));
      expect(replaced.resolve(around.marker), tagged(0, 12));
      expect(replaced.version, marked.version + 1);
      expect(check(replaced), const Success<void>(null));
    });

    test('a span ending past the end is a bounds failure', () {
      expect(
        text('abc').apply(Replace(span(2, 2), Text.of('x'))),
        Failure<Document<int>>.bounds('replace', 4),
      );
    });
  });

  group('Update', () {
    test('replaces the attributes and keeps the position and marker', () {
      final mark = Mark<int>(
        tagged(1, 2, attributes: {'type': const Num(1)}),
        start: Gravity.left,
      );
      final marked = text('abcdef').apply(mark).unwrap();
      final updated = marked
          .apply(Update(mark.marker, {'kind': const Bool(true)}))
          .unwrap();
      expect(
        updated.resolve(mark.marker),
        tagged(1, 2, attributes: {'kind': const Bool(true)}),
      );
      expect(updated.version, marked.version + 1);
      // The earlier version keeps its attributes.
      expect(
        marked.resolve(mark.marker),
        tagged(1, 2, attributes: {'type': const Num(1)}),
      );
      // Gravity is kept: an insert at the start is absorbed.
      final grown = updated.apply(Insert(1, Text.of('x'))).unwrap();
      expect(grown.resolve(mark.marker)!.length, 3);
      expect(check(updated), const Success<void>(null));
    });

    test('copies the map it is given', () {
      final mark = Mark<int>(tagged(0, 1));
      final attributes = <String, Value>{'n': const Num(1)};
      final command = Update<int>(mark.marker, attributes);
      attributes['n'] = const Num(2);
      final updated = text('ab').apply(mark).unwrap().apply(command).unwrap();
      expect(
        updated.resolve(mark.marker),
        tagged(0, 1, attributes: {'n': const Num(1)}),
      );
    });

    test('an absent marker is a missing failure', () {
      final marker = Mark<int>(tagged(0, 1)).marker;
      expect(
        text('ab').apply(Update(marker, const {})),
        isA<Failure<Document<int>>>().having(
          (failure) => failure.kind,
          'kind',
          Kind.missing,
        ),
      );
    });
  });

  group('markers', () {
    test('pairs every marker with its range, in the order of ranges', () {
      final late = Mark<int>(tagged(3, 1));
      final early = Mark<int>(tagged(0, 2), end: Gravity.left);
      final empty = Mark<int>(tagged(3, 0));
      final document = text('abcdef').transact([late, early, empty]).unwrap();
      final pairs = document.markers;
      expect(
        [for (final (marker, _) in pairs) marker],
        [early.marker, empty.marker, late.marker],
      );
      expect(
        Ranges.of([for (final (_, range) in pairs) range]),
        document.ranges,
      );
      for (final (marker, range) in pairs) {
        expect(document.resolve(marker), range);
      }
    });

    test('of a document with no ranges is empty', () {
      expect(text('abc').markers, isEmpty);
    });
  });

  group('overlapping', () {
    // 0123456789
    final marks = [
      Mark<int>(tagged(0, 10)), // encloses the query
      Mark<int>(tagged(1, 3)), // ends inside
      Mark<int>(tagged(5, 3)), // starts inside
      Mark<int>(tagged(3, 0)), // zero-length at the query start
      Mark<int>(tagged(6, 0)), // zero-length at the query end
      Mark<int>(tagged(4, 0)), // zero-length strictly inside
      Mark<int>(tagged(0, 3)), // ends at the query start
      Mark<int>(tagged(6, 2)), // starts at the query end
    ];
    final document = text('abcdefghij').transact(marks).unwrap();

    test('follows Range.overlaps, in start order', () {
      expect(
        document.overlapping(span(3, 3)),
        Ranges.of([tagged(0, 10), tagged(1, 3), tagged(4, 0), tagged(5, 3)]),
      );
    });

    test('a zero-length query finds ranges strictly around it', () {
      // {1,3} ends at 4, so a query at 4 is outside it.
      expect(document.overlapping(span(4, 0)), Ranges.of([tagged(0, 10)]));
      expect(
        document.overlapping(span(3, 0)),
        Ranges.of([tagged(0, 10), tagged(1, 3)]),
      );
    });

    test('a query past the end finds nothing new', () {
      expect(document.overlapping(span(20, 5)), Ranges.empty());
    });
  });

  group('bulk marking', () {
    /// Marks overlapping, nested, zero-length, shared-position, and
    /// mixed-gravity ranges.
    List<Mark<int>> marks() => [
      Mark<int>(tagged(0, 10, attributes: {'n': const Num(0)})),
      Mark<int>(tagged(2, 3), end: Gravity.left),
      Mark<int>(tagged(2, 3), start: Gravity.left),
      Mark<int>(tagged(5, 0)),
      Mark<int>(tagged(5, 0), start: Gravity.left, end: Gravity.left),
      Mark<int>(tagged(4, 4)),
      Mark<int>(tagged(10, 0), end: Gravity.left),
    ];

    test('a leading run of marks gives the same result as one by one', () {
      final list = marks();
      final base = text('abcdefghij');
      final bulk = base.transact([...list, Insert(5, Text.of('xy'))]).unwrap();
      var single = base;
      for (final command in [...list, Insert(5, Text.of('xy'))]) {
        single = single.apply(command).unwrap();
      }
      expect(bulk.ranges, single.ranges);
      for (final mark in list) {
        expect(bulk.resolve(mark.marker), single.resolve(mark.marker));
      }
      for (var position = 0; position <= single.length; position++) {
        expect(bulk.at(position), single.at(position));
      }
      expect(bulk.version, 1);
      expect(bulk.commands.length, list.length + 1);
      expect(check(bulk), const Success<void>(null));
      // Later edits behave the same too.
      final edited = bulk.apply(Delete<int>(span(3, 4))).unwrap();
      final expected = single.apply(Delete<int>(span(3, 4))).unwrap();
      expect(edited.ranges, expected.ranges);
      expect(check(edited), const Success<void>(null));
    });

    test('a mark past the end fails with its index', () {
      final list = marks();
      final result = text('abcdefghij')
          .transact([list[0], list[1], Mark<int>(tagged(8, 5))]);
      expect(
        result,
        const Failure<Document<int>>(
          Kind.bounds,
          'transact: command 2: mark: position 13 is out of bounds',
        ),
      );
    });

    test('the same marker twice fails as it does one by one', () {
      final mark = Mark<int>(tagged(0, 1));
      final result = text('ab').transact([mark, Mark<int>(tagged(0, 2)), mark]);
      expect(
        result,
        isA<Failure<Document<int>>>()
            .having((failure) => failure.kind, 'kind', Kind.invalid)
            .having(
              (failure) => failure.message,
              'message',
              startsWith('transact: command 2: mark:'),
            ),
      );
    });
  });

  test('gravity reports each endpoint gravity of a marker', () {
    final mark = Mark<int>(tagged(0, 1), start: Gravity.left);
    final document = text('ab').apply(mark).unwrap();
    expect(document.gravity(mark.marker), (
      start: Gravity.left,
      end: Gravity.right,
    ));
    expect(document.gravity(Mark<int>(tagged(0, 1)).marker), isNull);
  });

  group('map', () {
    test('agrees with a marker placed at the position with the gravity', () {
      for (var seed = 0; seed < 50; seed++) {
        final random = Random(seed);
        final origin = text('abcdefgh');
        // A zero-length probe at every position, with each gravity at both
        // ends, moves exactly as a mapped position does.
        final probes = [
          for (var position = 0; position <= origin.length; position++)
            for (final gravity in Gravity.values)
              (
                position,
                gravity,
                Mark<int>(tagged(position, 0), start: gravity, end: gravity),
              ),
        ];
        var document = origin.transact([
          for (final (_, _, mark) in probes) mark,
        ]).unwrap();
        final marked = document;
        for (var step = 0; step < 30; step++) {
          final length = document.length;
          final start = random.nextInt(length + 1);
          final cut = span(start, random.nextInt(min(3, length - start) + 1));
          final Command<int> command = switch (random.nextInt(3)) {
            0 => Insert(start, Text.of('xy'.substring(random.nextInt(2)))),
            1 => Delete(cut),
            _ => Replace(cut, Text.of('z')),
          };
          document = switch (random.nextInt(3)) {
            // Coalescing into the probes' own version would replace it.
            0 when step > 0 => document.apply(command, flatten: true),
            1 => document.transact([command, Insert(0, Text.of('w'))]),
            _ => document.apply(command),
          }.unwrap();
          for (final (position, gravity, mark) in probes) {
            expect(
              document.map(marked, position, gravity),
              Success(document.resolve(mark.marker)!.start),
              reason: 'seed $seed, step $step, $position $gravity',
            );
          }
        }
      }
    });

    test('a version maps its own positions to themselves', () {
      final document = text('abc');
      expect(document.map(document, 2, Gravity.left), const Success(2));
    });

    test('a version outside the history, or a position outside it, fails', () {
      final origin = text('abc');
      final edited = origin.apply(Insert(0, Text.of('x'))).unwrap();
      expect(edited.map(text('abc'), 0, Gravity.right), invalid);
      expect(edited.compact().map(origin, 0, Gravity.right), invalid);
      expect(origin.map(edited, 0, Gravity.right), invalid);
      expect(edited.map(origin, 4, Gravity.right), invalid);
      expect(edited.map(origin, -1, Gravity.right), invalid);
      expect(edited.map(origin, 3, Gravity.right), const Success(4));
    });
  });

  group('a range subclass that breaks the invariant', () {
    test('a negative start is a bounds failure for every edit', () {
      final document = text('abc');
      const negative = Negative();
      expect(document.apply(Delete<int>(negative)), isA<Failure<Object?>>());
      expect(
        document.apply(Replace(negative, Text.of('x'))),
        isA<Failure<Object?>>(),
      );
      expect(
        document.apply(Mark<int>(ARange.from(negative, const {}))),
        isA<Failure<Object?>>(),
      );
      expect(
        document.transact([
          Mark<int>(tagged(0, 1)),
          Mark<int>(ARange.from(negative, const {})),
        ]),
        isA<Failure<Object?>>(),
      );
    });
  });
}

/// A range with a negative start, which only a subclass can hold.
final class Negative extends Range {
  const Negative();

  @override
  int get start => -1;

  @override
  int get length => 2;
}
