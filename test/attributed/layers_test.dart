import 'package:libara/src/attributed/arange.dart';
import 'package:libara/src/attributed/value.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

ARange token(int start, int length, String type, String label) => tagged(
  start,
  length,
  attributes: {
    'type': Value.of(type).unwrap(),
    'label': Value.of(label).unwrap(),
  },
);

void main() {
  // The mixed-syntax example from the attributed range algebra paper.
  final text = Text.of('<P>THE @I{CAT} UNDER THE HAT.{/P]');

  // The paper's two figures disagree on the closing I tag, printing {13,4}
  // in one and {13,1} in the other. Counting the characters above gives
  // {13,1}: a single closing brace.
  final lexical = Ranges.of([
    token(0, 3, 'stag', 'P'),
    token(7, 3, 'stag', 'I'),
    token(13, 1, 'etag', 'I'),
    token(29, 4, 'etag', 'P'),
  ]);

  // The application layer indexes into the lexical layer: P spans tokens 0
  // to 3, I spans tokens 1 to 2.
  final elementP = token(0, 4, 'elem', 'P');
  final elementI = token(1, 2, 'elem', 'I');
  final application = Ranges.of([elementP, elementI]);

  group('the lexical layer', () {
    test('each token extracts its markup from the text', () {
      expect(lexical.items.map((range) => range.extract(text).toString()), [
        '<P>',
        '@I{',
        '}',
        '{/P]',
      ]);
    });

    test('no token nests inside another', () {
      for (final range in lexical.items) {
        expect(lexical.parent(range), isNull, reason: '$range');
        expect(lexical.children(range), Ranges.empty(), reason: '$range');
      }
    });
  });

  group('the application layer', () {
    test('P is the parent of I', () {
      expect(application.parent(elementI), elementP);
    });

    test('I is the only child of P', () {
      expect(application.children(elementP), Ranges.of([elementI]));
    });

    test('each element extracts its tokens from the lexical layer', () {
      expect(elementP.extract(lexical), lexical);
      expect(
        elementI.extract(lexical),
        Ranges.of([token(7, 3, 'stag', 'I'), token(13, 1, 'etag', 'I')]),
      );
    });

    test('children needs an attributed query, since a plain Range never '
        'equals an ARange', () {
      expect(application.children(span(0, 4)), Ranges.empty());
    });
  });

  group('attributed ranges in Ranges', () {
    test('unique keeps different attributes at one position and drops an '
        'exact duplicate', () {
      final ranges = Ranges.of([
        token(0, 3, 'stag', 'P'),
        token(0, 3, 'elem', 'P'),
        token(0, 3, 'stag', 'P'),
      ]);
      // Compared through the notation, which prints attributes, so the
      // assertion does not rely on the equality that unique itself uses.
      expect(ranges.unique().items.map((range) => range.toString()), [
        '{0,3,label:P,type:stag}',
        '{0,3,label:P,type:elem}',
      ]);
    });

    test('startOrder keeps ranges at one position in their original order', () {
      // More than 32 items, so that Dart's sort leaves its stable
      // insertion-sort path.
      final source = [
        for (var index = 0; index < 40; index++)
          tagged(
            index.isEven ? 5 : 2,
            3,
            attributes: {'index': Value.of(index).unwrap()},
          ),
      ];
      final sorted = Ranges.of(source).startOrder().items.toList();
      final expected = [
        ...source.where((range) => range.start == 2),
        ...source.where((range) => range.start == 5),
      ];
      expect(sorted, expected);
    });
  });

  group('attributed ranges held as plain ranges', () {
    final Sequence<Range> tokens = Items<ARange>.of(
      lexical.items.cast<ARange>(),
    );

    test('contains a plain range without throwing', () {
      expect(tokens.contains(span(0, 3)), isFalse);
      expect(tokens.contains(token(0, 3, 'stag', 'P')), isTrue);
    });

    test('diff and intersect against Ranges without throwing', () {
      final other = Ranges.of([token(0, 3, 'stag', 'P'), span(7, 3)]);
      expect(tokens.intersect(other).length, 1);
      expect(tokens.diff(other).length, 3);
    });

    test('equals Ranges holding the same attributed ranges, both ways', () {
      expect(tokens == lexical, isTrue);
      expect(lexical == tokens, isTrue);
    });
  });
}
