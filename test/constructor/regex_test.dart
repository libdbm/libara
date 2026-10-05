import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/constructor/regex.dart';
import 'package:libara/src/persistent/document.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

final word = regex(
  RegExp('[a-z]+'),
  attributes: {'type': Value.of('word').unwrap()},
);

String extracted(Range range, Sequence<int> input) =>
    String.fromCharCodes(range.extract(input).items);

void main() {
  test('offsets are code points, not UTF-16 units', () {
    expect(
      word(Text.of('a𝄞b cat'))
          .or(Ranges.empty())
          .items
          .map((range) => '$range'),
      ['{0,1,type:word}', '{2,1,type:word}', '{4,3,type:word}'],
    );
  });

  test('every range carries the attributes', () {
    expect(
      word(Text.of('ab cd'))
          .or(Ranges.empty())
          .items
          .every(
            (range) =>
                (range as ARange).get('type') == Value.of('word').unwrap(),
          ),
      isTrue,
    );
  });

  test('no match gives no ranges', () {
    expect(word(Text.of('123 !!')), Success(Ranges.empty()));
    expect(word(Text.of('')), Success(Ranges.empty()));
  });

  test('an empty match gives a zero-length range', () {
    const source = 'baab';
    final expected = [
      for (final match in RegExp('a*').allMatches(source))
        tagged(match.start, match.end - match.start),
    ];
    final found = regex(RegExp('a*'))(Text.of(source)).or(Ranges.empty());
    expect(found, Ranges.of(expected));
    expect(found.items.where((range) => range.length == 0), isNotEmpty);
  });

  test(
    'a match boundary inside a surrogate pair covers the whole character',
    () {
      // Without unicode: true, '.' matches each half of the pair.
      expect(
        regex(RegExp('.'))(Text.of('𝄞')),
        Success(Ranges.of([tagged(0, 1), tagged(0, 1)])),
      );
      // With unicode: true, it matches the character once.
      expect(
        regex(RegExp('.', unicode: true))(Text.of('𝄞')),
        Success(Ranges.of([tagged(0, 1)])),
      );
    },
  );

  test('an empty match inside a surrogate pair is dropped', () {
    // Without unicode: true, '' also matches between the two halves.
    expect(
      regex(RegExp(''))(Text.of('𝄞')),
      Success(Ranges.of([tagged(0, 0), tagged(1, 0)])),
    );
  });

  test('empty matches fall on every code point boundary and nowhere else', () {
    expect(
      regex(RegExp(''))(Text.of('a𝄞b')),
      Success(
        Ranges.of([tagged(0, 0), tagged(1, 0), tagged(2, 0), tagged(3, 0)]),
      ),
    );
  });

  test('running twice on equal input gives equal ranges', () {
    expect(
      word(Text.of('one two 𝄞 three')),
      word(Text.of('one two 𝄞 three')),
    );
  });

  test('works on a document', () {
    final document = Document.of(Text.of('𝄞 hello'));
    expect(
      word(document).or(Ranges.empty()),
      Ranges.of([
        tagged(2, 5, attributes: {'type': Value.of('word').unwrap()}),
      ]),
    );
  });

  test(
    'ranges extract exactly the matched text over 200 seeded random texts',
    () {
      const pool = [0x61, 0x62, 0x20, 0xE9, 0x1D11E, 0x1F600];
      final patterns = [
        RegExp('[ab]+'),
        RegExp('\u{1F600}+', unicode: true),
        RegExp(r'\S+', unicode: true),
        RegExp('é[ab]*'),
      ];
      final random = Random(42);
      for (var round = 0; round < 200; round++) {
        final points = List.generate(
          random.nextInt(30),
          (_) => pool[random.nextInt(pool.length)],
        );
        final text = Text.of(String.fromCharCodes(points));
        for (final pattern in patterns) {
          final expected = [
            for (final match in pattern.allMatches(text.toString())) match[0],
          ];
          final found = [
            for (final range in regex(pattern)(text).or(Ranges.empty()).items)
              extracted(range, text),
          ];
          expect(
            found,
            expected,
            reason: 'round $round ${pattern.pattern} over $text',
          );
        }
      }
    },
  );

  test('changing the attributes map afterwards leaves results unchanged', () {
    final attributes = {'type': Value.of('word').unwrap()};
    final words = regex(RegExp('[a-z]+'), attributes: attributes);
    final before = words(Text.of('ab'));
    attributes['type'] = Value.of('other').unwrap();
    expect(words(Text.of('ab')), before);
  });

  test('an input holding an invalid code point is an invalid failure', () {
    final document = Document.of(Items.of([0x61, -1]));
    expect(
      word(document),
      isA<Failure<Ranges>>()
          .having((failure) => failure.kind, 'kind', Kind.invalid)
          .having((failure) => failure.message, 'message', contains('-1')),
    );
  });
}
