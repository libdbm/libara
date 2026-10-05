import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

void main() {
  group('Range construction', () {
    test('end is start plus length', () {
      final range = span(4, 5);
      expect(range.start, 4);
      expect(range.length, 5);
      expect(range.end, 9);
    });

    test('a zero-length range is allowed', () {
      expect(span(3, 0).end, 3);
    });

    test('create returns the range for valid input', () {
      expect(Range.create(4, 5), Success(span(4, 5)));
    });

    test('create reports a negative start as invalid', () {
      expect(
        Range.create(-1, 2),
        Failure<Range>(Kind.invalid, 'range: start -1 is negative'),
      );
    });

    test('create reports a negative length as invalid', () {
      expect(
        Range.create(0, -1),
        Failure<Range>(Kind.invalid, 'range: length -1 is negative'),
      );
    });
  });

  group('Range equality', () {
    test('equal start and length are equal', () {
      expect(span(4, 5), span(4, 5));
      expect(span(4, 5).hashCode, span(4, 5).hashCode);
    });

    test('different start or length are not equal', () {
      expect(span(4, 5), isNot(span(4, 6)));
      expect(span(4, 5), isNot(span(3, 5)));
    });

    test('toString uses the paper notation', () {
      expect(span(4, 5).toString(), '{4,5}');
    });
  });

  group('Range move', () {
    test('moves forward', () {
      expect(span(4, 5).move(2), Success(span(6, 5)));
    });

    test('moves back to zero', () {
      expect(span(4, 5).move(-4), Success(span(0, 5)));
    });

    test('a negative resulting start is a bounds failure', () {
      expect(span(4, 5).move(-5), Failure<Range>.bounds('move', -1));
    });
  });

  group('Range resize', () {
    test('grows', () {
      expect(span(4, 5).resize(2), Success(span(4, 7)));
    });

    test('shrinks to zero length', () {
      expect(span(4, 5).resize(-5), Success(span(4, 0)));
    });

    test('a negative resulting length is a bounds failure', () {
      expect(span(4, 5).resize(-6), Failure<Range>.bounds('resize', -1));
    });
  });

  group('Range extract', () {
    test('returns the spanned items', () {
      expect(span(1, 3).extract(Text.of('abcde')), Text.of('bcd'));
    });

    test('keeps the type of the source sequence', () {
      expect(span(1, 3).extract(Text.of('abcde')), isA<Text>());
    });

    test('is clamped at the end of the sequence', () {
      expect(span(3, 5).extract(Items.of([0, 1, 2, 3, 4])), Items.of([3, 4]));
    });

    test('past the end is empty', () {
      expect(span(9, 2).extract(Items.of([0, 1])), Items<int>.empty());
    });
  });
}
