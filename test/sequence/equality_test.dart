import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// A document holding [points], built through edits so its content tree has more
/// than one node.
Document<int> edited(List<int> points) {
  var document = Document<int>.empty();
  for (final (index, point) in points.indexed) {
    document = document.apply(Insert(index, Items.of([point]))).unwrap();
  }
  return document;
}

/// Every sequence implementation holding [points].
List<Sequence<int>> every(List<int> points) => [
  Items.of(points),
  Text.of(String.fromCharCodes(points)),
  Document.of(Items.of(points)),
  edited(points),
];

void main() {
  const samples = [
    <int>[],
    [0x61],
    [0x61, 0x62, 0x63],
    [0x61, 0x62, 0x64],
    [0x61, 0x62],
    [0x62, 0x61, 0x63],
  ];

  test('every implementation agrees on equality with every other', () {
    for (final left in samples) {
      for (final right in samples) {
        final expected =
            left.length == right.length &&
            List.generate(
              left.length,
              (index) => index,
            ).every((index) => left[index] == right[index]);
        for (final a in every(left)) {
          for (final b in every(right)) {
            expect(
              a == b,
              expected,
              reason: '${a.runtimeType}$left == ${b.runtimeType}$right',
            );
          }
        }
      }
    }
  });

  test('ranges equal items holding the same ranges', () {
    final list = [span(0, 1), span(2, 3)];
    final Sequence<Range> ranges = Ranges.of(list);
    final Sequence<Range> items = Items.of(list);
    final Sequence<Range> reversed = Items.of(list.reversed);
    final Sequence<Range> shorter = Items.of([span(0, 1)]);
    expect(ranges == items, isTrue);
    expect(items == ranges, isTrue);
    expect(ranges == reversed, isFalse);
    expect(ranges == shorter, isFalse);
  });

  group('get', () {
    test('tells a stored null from a missing position', () {
      final items = Items<int?>.of([null, 1]);
      expect(items.get(0), const Success<int?>(null));
      expect(items.get(1), const Success<int?>(1));
      expect(items.get(2), Failure<int?>.bounds('get', 2));
      expect(items.get(-1), Failure<int?>.bounds('get', -1));
      expect(items.item(0), items.item(2));
    });

    test('works on every implementation', () {
      for (final sequence in every([0x61, 0x62])) {
        expect(sequence.get(1), const Success<int>(0x62), reason: '$sequence');
        expect(
          sequence.get(2),
          Failure<int>.bounds('get', 2),
          reason: '$sequence',
        );
      }
    });
  });
}
