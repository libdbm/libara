import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/layered/layered.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart' show Document;
import 'package:libara/src/range/range.dart';
import 'package:libara/src/selector/selector.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../../example/xml/xml.dart';
import '../support.dart';

/// The selector in [source], which must parse.
Selector parsed(String source, {String type = 'name'}) =>
    Selector.parse(source, type: type).unwrap();

/// A text attribute value.
Str string(String value) => Str(Text.of(value));

/// A layered XML document over [source].
Layered<int> xml(String source) =>
    Layered.of(Text.of(source), const XML()).unwrap();

void main() {
  group('a document', () {
    final section = Mark<int>(
      tagged(0, 20, attributes: {'name': string('section')}),
    );
    final paragraph = Mark<int>(
      tagged(2, 10, attributes: {'name': string('p'), 'lang': string('en')}),
    );
    final empty = Mark<int>(
      tagged(5, 0, attributes: {'name': string('p'), 'lang': string('en')}),
    );
    final document = Document.of(Text.of('a' * 20))
        .transact([section, paragraph, empty])
        .unwrap();

    test('selects among its markers', () {
      final selector = parsed('section > p[lang=en]:not(:empty)');
      expect(document.select(selector), [
        (paragraph.marker, document.resolve(paragraph.marker)),
      ]);
      expect(document.select(selector), selector.select(document.markers));
    });

    test('matches one marker, and an unmarked one is missing', () {
      final selector = parsed('p:empty');
      expect(document.matches(selector, empty.marker), const Success(true));
      expect(document.matches(selector, section.marker), const Success(false));
      final missing = document.matches(selector, Marker());
      expect((missing as Failure<bool>).kind, Kind.missing);
    });

    test('selects within a region through Document.within', () {
      final region = document.within(span(1, 15));
      expect(parsed('p').select(region), [
        (paragraph.marker, document.resolve(paragraph.marker)),
        (empty.marker, document.resolve(empty.marker)),
      ]);
      // The section is outside the region, so the paragraph is a root, and
      // the empty paragraph inside it is its child.
      expect(parsed('p:root').select(region), [
        (paragraph.marker, document.resolve(paragraph.marker)),
      ]);
    });
  });

  group('a layered XML document', () {
    test('selects elements by their names and nesting', () {
      final document = xml('<a><p><b/>x</p><b/><p>y</p></a>');
      List<String> names(List<(Marker, ARange)> pairs) => [
        for (final (_, range) in pairs) '${range.get('name')}',
      ];
      expect(names(document.select(parsed('p > b'), 3)), ['b']);
      expect(names(document.select(parsed('a > b'), 3)), ['b']);
      expect(names(document.select(parsed('p:has(> b)'), 3)), ['p']);
      expect(names(document.select(parsed('a b'), 3)), ['b', 'b']);
      final (first, _) = document.select(parsed('p'), 3).first;
      expect(document.matches(parsed('a > p'), 3, first), const Success(true));
      final missing = document.matches(parsed('p'), 2, first);
      expect((missing as Failure<bool>).kind, Kind.missing);
    });

    test('selects tokens by their XML attributes at layer 2', () {
      final document = xml(
        '<r><p class="a note">x</p><p class="notes">y</p></r>',
      );
      final found = document.select(parsed('[@class~=note]'), 2);
      expect(found.length, 1);
      expect(found.single.$2.get('@class'), string('a note'));
    });

    test('never selects diagnostics', () {
      final document = xml('<a><b></a>');
      expect(document.diagnostics(3).length, greaterThan(0));
      expect(document.select(parsed('*'), 3), document.markers(3));
      expect(document.select(parsed('*'), 9), isEmpty);
    });

    test('child and descendant selections agree with a model', () {
      for (var seed = 0; seed < 100; seed++) {
        final random = Random(seed);
        String tree(int depth) {
          if (depth == 0 || random.nextInt(3) == 0) {
            return const ['x', '<b/>', '<a/>'][random.nextInt(3)];
          }
          final name = random.nextBool() ? 'a' : 'b';
          final children = [
            for (var count = 1 + random.nextInt(3); count > 0; count--)
              tree(depth - 1),
          ];
          return '<$name>${children.join()}</$name>';
        }

        final document = xml('<r>${tree(4)}</r>');
        final pairs = document.markers(3);
        final ranges = Ranges.of([for (final (_, range) in pairs) range]);
        bool named(ARange range, String name) =>
            range.get('name') == string(name);
        expect(document.select(parsed('a > b'), 3), [
          for (final pair in pairs)
            if (named(pair.$2, 'b') &&
                switch (ranges.parent(pair.$2)) {
                  final parent? => named(parent as ARange, 'a'),
                  null => false,
                })
              pair,
        ], reason: 'seed $seed');
        expect(document.select(parsed('a b'), 3), [
          for (final pair in pairs)
            if (named(pair.$2, 'b') &&
                ranges
                    .ancestors(pair.$2)
                    .items
                    .any((range) => named(range as ARange, 'a')))
              pair,
        ], reason: 'seed $seed');
      }
    });
  });

  group('across layers', () {
    final document = xml('<a><p>hi <b>there</b></p><b>x</b><p>y</p></a>');

    test('projects every range as extent does, in start order', () {
      final expected = [
        for (final layer in [2, 3])
          for (final (marker, range) in document.markers(layer))
            (
              (layer, marker),
              ARange.from(document.extent(layer, marker)!, range.attributes),
            ),
      ];
      final across = document.across([3, 2, 3]);
      expect(across.toSet(), expected.toSet());
      expect(across, hasLength(expected.length));
      for (var index = 1; index < across.length; index++) {
        final ((_, before), (_, after)) = (across[index - 1], across[index]);
        expect(
          before.start < after.start ||
              before.start == after.start && before.length >= after.length,
          isTrue,
        );
      }
    });

    test('p [type=text] selects the text tokens inside p elements', () {
      final selected = parsed('p [type=text]').select(document.across([2, 3]));
      final texts = [
        for (final ((layer, _), range) in selected)
          (
            layer,
            String.fromCharCodes(
              range
                  .extract(
                    Text.of('<a><p>hi <b>there</b></p><b>x</b><p>y</p></a>'),
                  )
                  .items,
            ),
          ),
      ];
      // The text in the first p, inside it and inside its b, and in the
      // last p; not the x of the b outside every p.
      expect(texts, [(2, 'hi '), (2, 'there'), (2, 'y')]);
    });

    test('layers outside 2..depth give nothing', () {
      expect(document.across([0, 1, 4]), isEmpty);
    });

    test('a layer scope selects as the layer does', () {
      for (final source in ['p', 'b', 'p > b', ':root']) {
        expect(
          document.scope(3).select(parsed(source)),
          document.select(parsed(source), 3),
        );
      }
    });
  });
}
