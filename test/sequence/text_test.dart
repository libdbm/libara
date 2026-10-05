import 'package:libara/src/sequence/items.dart';
import 'package:libara/src/sequence/result.dart';
import 'package:libara/src/sequence/text.dart';
import 'package:test/test.dart';

void main() {
  group('Text code points', () {
    test('a character outside the basic plane is one item', () {
      final text = Text.of('a𝄞b');
      expect(text.length, 3);
      expect(text.item(1), 0x1D11E);
    });

    test('toString round-trips', () {
      expect(Text.of('a𝄞b').toString(), 'a𝄞b');
      expect(Text.of('').toString(), '');
    });

    test('a lone surrogate is preserved and round-trips', () {
      const source = 'a\uD800b';
      final text = Text.of(source);
      expect(text.length, 3);
      expect(text.item(1), 0xD800);
      expect(text.toString(), source);
    });

    test('empty text is empty', () {
      expect(Text.of('').empty, isTrue);
    });
  });

  group('Text operations return Text', () {
    test('slice', () {
      final slice = Text.of('a𝄞bc').slice(1, 2);
      expect(slice, isA<Text>());
      expect(slice.toString(), '𝄞b');
    });

    test('a slice cannot be changed through its items', () {
      final slice = Text.of('abc').slice(0, 2);
      expect(
        () => (slice.items as List<int>)[0] = 0x58,
        throwsUnsupportedError,
      );
      expect(slice.toString(), 'ab');
    });

    test('concat', () {
      final joined = Text.of('ab').concat(Text.of('𝄞'));
      expect(joined, Success(Text.of('ab𝄞')));
      expect(joined.or(Text.of('')), isA<Text>());
    });

    test('insert', () {
      final result = Text.of('ac').insert(1, 0x62);
      expect(result, Success(Text.of('abc')));
      expect(result.or(Text.of('')), isA<Text>());
    });

    test('insert out of bounds is a bounds failure', () {
      expect(Text.of('a').insert(2, 0x62), Failure<Text>.bounds('insert', 2));
    });

    test('insert of an invalid code point is an invalid failure', () {
      final invalid = isA<Failure<Text>>().having(
        (failure) => failure.kind,
        'kind',
        Kind.invalid,
      );
      expect(Text.of('a').insert(0, -1), invalid);
      expect(Text.of('a').insert(0, 0x110000), invalid);
    });

    test('concat and union with an invalid code point are failures', () {
      final invalid = isA<Failure<Text>>().having(
        (failure) => failure.kind,
        'kind',
        Kind.invalid,
      );
      expect(Text.of('a').concat(Items.of([0x62, -1])), invalid);
      expect(Text.of('a').union(Items.of([0x110000])), invalid);
    });

    test('insert of a lone surrogate succeeds and round-trips', () {
      final result = Text.of('ab').insert(1, 0xD800);
      expect(result.or(Text.of('')).toString(), 'a\u{D800}b');
    });

    test('delete', () {
      expect(Text.of('a𝄞b').delete(1), Success(Text.of('ab')));
    });

    test('delete out of bounds is a bounds failure', () {
      expect(Text.of('a').delete(1), Failure<Text>.bounds('delete', 1));
    });

    test('diff, union, and intersect', () {
      expect(Text.of('abc').diff(Text.of('b')), Text.of('ac'));
      expect(Text.of('ab').union(Text.of('bc')), Success(Text.of('abc')));
      expect(Text.of('cab').intersect(Text.of('bc')), Text.of('cb'));
      expect(Text.of('abc').diff(Text.of('b')), isA<Text>());
    });
  });

  group('Text compare', () {
    test('a proper prefix sorts first', () {
      expect(Text.of('ab').compare(Text.of('abc')), -1);
      expect(Text.of('abc').compare(Text.of('ab')), 1);
    });

    test('equal text compares as zero', () {
      expect(Text.of('a').compare(Text.of('a')), 0);
      expect(Text.of('').compare(Text.of('')), 0);
    });

    test('the first differing code point decides', () {
      expect(Text.of('abd').compare(Text.of('abc')), 1);
      expect(Text.of('abc').compare(Text.of('abd')), -1);
    });

    test('order is by code point, not UTF-16 unit', () {
      // U+FF61 is one UTF-16 unit above the surrogate range; U+1D11E is
      // encoded with a lead surrogate 0xD834, which is lower as a unit.
      expect(Text.of('｡').compare(Text.of('𝄞')), -1);
    });

    test('sort orders a list by code point', () {
      final list = [Text.of('b'), Text.of('𝄞'), Text.of('ab'), Text.of('a')]
        ..sort();
      expect(list.map((text) => text.toString()), ['a', 'ab', 'b', '𝄞']);
    });
  });

  group('Text equality', () {
    test('text equals items with the same code points, both ways', () {
      expect(Text.of('ab'), Items.of([0x61, 0x62]));
      expect(Items.of([0x61, 0x62]), Text.of('ab'));
    });

    test('hashCode agrees with items', () {
      expect(Text.of('ab').hashCode, Items.of([0x61, 0x62]).hashCode);
    });
  });
}
