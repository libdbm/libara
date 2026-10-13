import 'dart:convert';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/format/format.dart';
import 'package:libara/src/layered/layered.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../../example/xml/xml.dart';
import '../layered/brackets.dart';
import '../layered/overlaps.dart';
import '../support.dart';

/// A grammar, a source in it, and a layer-1 range [across] two of its units.
typedef Case = ({
  String name,
  Grammar<int> Function() grammar,
  String source,
  Range across,
});

final cases = <Case>[
  (
    name: 'XML',
    grammar: XML.new,
    source: '<r><a>xy</a><b>zw</b></r>',
    across: span(7, 9),
  ),
  (
    name: 'Brackets',
    grammar: Brackets.new,
    source: '[[xy][zw]]',
    across: span(3, 4),
  ),
  (
    name: 'Overlaps',
    grammar: Overlaps.new,
    source: 'ab cd ef',
    across: span(1, 6),
  ),
];

void main() {
  for (final example in cases) {
    group(example.name, () {
      final markup = LayeredFormat(example.grammar());

      test('annotations over the text come back as they were', () {
        final document = markup.decode(Text.of(example.source)).unwrap();
        final wide = Mark<Object?>(
          tagged(
            example.across.start,
            example.across.length,
            attributes: {'note': string('cross'), 'weight': const Num(2)},
          ),
          end: Gravity.left,
        );
        final point = Mark<Object?>(tagged(0, 0), start: Gravity.left);
        final noted = document
            .transact([Edit.annotation(1, wide), Edit.annotation(1, point)])
            .unwrap()
            .document;
        final saved = jsonDecode(
          jsonEncode(const AnnotationsFormat().encode(noted).unwrap()),
        );
        final loaded = markup
            .decode(Text.of(String.fromCharCodes(noted.items.items)))
            .unwrap();
        final (restored, markers) = const AnnotationsFormat()
            .restore(loaded, saved)
            .unwrap();
        expect(restored.version, 0);
        expect(restored.previous, isNull);
        expect(markers, hasLength(2));
        // Ids go in start order: the empty one at 0 first.
        final ids = {point.marker: markers[0], wide.marker: markers[1]};
        for (final (marker, range) in noted.annotations(1)) {
          final again = ids[marker]!;
          expect(
            restored.annotations(1).firstWhere((pair) => pair.$1 == again).$2,
            range,
          );
          expect(restored.gravity(1, again), noted.gravity(1, marker));
        }
        expect(check(restored), const Success<void>(null));
      });

      test('annotations over tokens and units come back over the same', () {
        final document = markup.decode(Text.of(example.source)).unwrap();
        final tokens = Mark<Object?>(tagged(0, 2), end: Gravity.left);
        final units = Mark<Object?>(
          tagged(1, 2, attributes: {'note': string('pair')}),
        );
        final noted = document
            .transact([Edit.annotation(3, units), Edit.annotation(2, tokens)])
            .unwrap()
            .document;
        final saved = jsonDecode(
          jsonEncode(const AnnotationsFormat().encode(noted).unwrap()),
        );
        final loaded = markup.decode(Text.of(example.source)).unwrap();
        final (restored, markers) = const AnnotationsFormat()
            .restore(loaded, saved)
            .unwrap();
        // Ids go layer by layer: layer 2's, then layer 3's.
        for (final (layer, marker, again) in [
          (2, tokens.marker, markers[0]),
          (3, units.marker, markers[1]),
        ]) {
          expect(restored.annotations(layer).single, (
            again,
            noted.annotations(layer).single.$2,
          ));
          expect(restored.gravity(layer, again), noted.gravity(layer, marker));
        }
      });

      test('a form it cannot use fails, naming the entry', () {
        final document = markup.decode(Text.of(example.source)).unwrap();

        /// An entry, with [changes] made to it.
        Map<String, Object?> entry([Map<String, Object?> changes = const {}]) =>
            {
              'layer': 1,
              'id': 0,
              'range': [0, 1],
              'start': 'right',
              'end': 'right',
              'attributes': <String, Object?>{},
              ...changes,
            };
        for (final (form, path) in [
          ('annotations', 'annotations'),
          (<String, Object?>{'annotations': 1}, 'annotations'),
          (
            <String, Object?>{
              'annotations': [1],
            },
            'annotations[0]',
          ),
          (
            {
              'annotations': [
                entry({'layer': 0}),
              ],
            },
            'annotations[0].layer',
          ),
          (
            {
              'annotations': [
                entry({'layer': document.depth + 1}),
              ],
            },
            'annotations[0].layer',
          ),
          (
            {
              'annotations': [
                entry({'id': 'x'}),
              ],
            },
            'annotations[0].id',
          ),
          (
            {
              'annotations': [
                entry({'start': 'up'}),
              ],
            },
            'annotations[0].start',
          ),
          (
            {
              'annotations': [
                entry({'end': null}),
              ],
            },
            'annotations[0].end',
          ),
          (
            {
              'annotations': [
                entry({'range': 3}),
              ],
            },
            'annotations[0].range',
          ),
          (
            {
              'annotations': [
                entry({
                  'range': [0, document.items.length + 1],
                }),
              ],
            },
            'annotations[0].range',
          ),
          (
            {
              'annotations': [
                entry({
                  'layer': 2,
                  'range': [0, document.layer(2).length + 1],
                }),
              ],
            },
            'annotations[0].range',
          ),
          (
            {
              'annotations': [entry(), entry()],
            },
            'annotations',
          ),
          (
            {
              'annotations': [
                entry({'attributes': 1}),
              ],
            },
            'annotations[0].attributes',
          ),
        ]) {
          final result = const AnnotationsFormat().restore(document, form);
          expect(result, isA<Failure<Object?>>(), reason: '$form');
          final failure = result as Failure<(Layered<int>, List<Marker>)>;
          expect(failure.kind, Kind.syntax, reason: '$form');
          expect(failure.message, startsWith(path), reason: '$form');
        }
      });

      test('attributes past the limits fail, as JSONFormat\'s do', () {
        const format = AnnotationsFormat(limits: Limits(attributes: 1));
        final document = markup.decode(Text.of(example.source)).unwrap();
        final noted = document
            .apply(
              Edit.annotation(
                1,
                Mark<Object?>(
                  tagged(
                    0,
                    1,
                    attributes: {'a': string('1'), 'b': string('2')},
                  ),
                ),
              ),
            )
            .unwrap()
            .document;
        final saving = format.encode(noted);
        expect(saving, isA<Failure<Object?>>());
        expect((saving as Failure<Object?>).kind, Kind.invalid);
        expect(saving.message, startsWith('annotations[0].attributes'));
        final saved = const AnnotationsFormat().encode(noted).unwrap();
        final loading = format.restore(document, saved);
        expect(
          (loading as Failure<(Layered<int>, List<Marker>)>).kind,
          Kind.invalid,
        );
        expect(loading.message, startsWith('annotations[0].attributes'));
      });

      test('more annotations than the markers limit fail, at it succeed', () {
        final document = markup.decode(Text.of(example.source)).unwrap();
        final noted = document
            .transact([
              Edit.annotation(1, Mark<Object?>(tagged(0, 1))),
              Edit.annotation(1, Mark<Object?>(tagged(1, 1))),
            ])
            .unwrap()
            .document;
        final saved = const AnnotationsFormat().encode(noted).unwrap();
        for (final (limit, fits) in [(0, false), (1, false), (2, true)]) {
          final format = AnnotationsFormat(limits: Limits(markers: limit));
          for (final result in <Result<Object?>>[
            format.encode(noted),
            format.restore(document, saved),
          ]) {
            if (fits) {
              expect(result, isA<Success<Object?>>(), reason: '$limit');
            } else {
              final failure = result as Failure<Object?>;
              expect(failure.kind, Kind.invalid, reason: '$limit');
              expect(failure.message, startsWith('annotations'));
              expect(failure.message, contains('markers'));
            }
          }
        }
      });

      test('no annotations save as none and restore as the markup', () {
        final document = markup.decode(Text.of(example.source)).unwrap();
        final saved = const AnnotationsFormat().encode(document).unwrap();
        expect(saved, {'annotations': <Object?>[]});
        final (restored, markers) = const AnnotationsFormat()
            .restore(document, saved)
            .unwrap();
        expect(markers, isEmpty);
        expect(restored.items, document.items);
        for (var layer = 1; layer <= document.depth; layer++) {
          expect(restored.annotations(layer), isEmpty);
        }
      });
    });
  }
}
