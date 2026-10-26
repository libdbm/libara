import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

Document<int> text(String source) =>
    Document.of(Text.of(source), indexed: const ['label', 'other']);

Value string(String value) => Str(Text.of(value));

/// [mark] saying [attributes] over [length] items from [start].
Mark<int> marked(int start, int length, Map<String, Value> attributes) =>
    Mark<int>(tagged(start, length, attributes: attributes));

/// The ranges of [document] under [key], as their starts.
List<int> starts(Document<int> document, String key) => [
  for (final (_, range) in document.having(key)) range.start,
];

void main() {
  group('having', () {
    test('finds the ranges saying a key, in start order', () {
      final document = text('abcdef').transact([
        marked(4, 1, {'label': string('x')}),
        marked(0, 2, {'other': string('y')}),
        marked(1, 1, {'label': string('z'), 'other': string('w')}),
      ]).unwrap();
      expect(starts(document, 'label'), [1, 4]);
      expect(starts(document, 'other'), [0, 1]);
      expect(starts(document, 'none'), isEmpty);
    });

    test('follows marks, unmarks and updates, one at a time', () {
      final first = marked(0, 1, {'label': string('x')});
      final second = marked(2, 1, {'other': string('y')});
      var document = text('abc').apply(first).unwrap();
      document = document.apply(second).unwrap();
      expect(starts(document, 'label'), [0]);
      document = document
          .apply(Update<int>(second.marker, {'label': string('z')}))
          .unwrap();
      expect(starts(document, 'label'), [0, 2]);
      expect(starts(document, 'other'), isEmpty);
      document = document.apply(Unmark<int>(first.marker)).unwrap();
      expect(starts(document, 'label'), [2]);
    });

    test('finds a key it does not index by walking the ranges', () {
      final document = Document.of(Text.of('abc')).transact([
        marked(2, 1, {'label': string('x')}),
        marked(0, 1, {'label': string('y')}),
      ]).unwrap();
      expect(document.indexed, isEmpty);
      expect(starts(document, 'label'), [0, 2]);
    });

    test('leaves the versions before an edit as they were', () {
      final first = marked(0, 1, {'label': string('x')});
      final before = text('abc').apply(first).unwrap();
      final after = before.apply(Unmark<int>(first.marker)).unwrap();
      expect(starts(before, 'label'), [0]);
      expect(starts(after, 'label'), isEmpty);
    });

    test('moves with the items and survives a move and a compact', () {
      var document = text('abcdef').transact([
        marked(1, 1, {'label': string('x')}),
      ]).unwrap();
      document = document.apply(Insert(0, Text.of('zz'))).unwrap();
      expect(starts(document, 'label'), [3]);
      document = document.apply(Move<int>(span(5, 2), 0)).unwrap();
      expect(starts(document, 'label'), [5]);
      expect(starts(document.compact(), 'label'), [5]);
    });
  });
}
