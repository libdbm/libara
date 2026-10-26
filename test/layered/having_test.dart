import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/layered/layered.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../../example/xml/xml.dart';
import '../support.dart';

void main() {
  group('A layer having a key', () {
    final document = Layered.of(
      Text.of('<r>a & b</r>'),
      const XML(),
      indexed: const ['type', 'message'],
    ).unwrap();

    test('holds the ranges of the layer that say the key', () {
      expect(
        [for (final (_, range) in document.having(2, 'type')) range],
        [for (final (_, range) in document.markers(2)) range],
      );
      expect(document.having(3, 'type'), hasLength(document.layer(3).length));
    });

    test('and no diagnostic, though one says the key', () {
      expect(document.diagnostics(2).items, isNotEmpty);
      expect(document.having(2, 'message'), isEmpty);
    });

    test('and no annotation over the layer below', () {
      final mark = Mark<Object?>(
        tagged(0, 1, attributes: {'type': Str(Text.of('note'))}),
      );
      final noted = document.apply(Edit.annotation(1, mark)).unwrap().document;
      expect(noted.having(2, 'type'), hasLength(document.layer(2).length));
    });

    test('and the same where it does not index the key', () {
      final plain = Layered.of(Text.of('<r>a & b</r>'), const XML()).unwrap();
      expect(
        [for (final (_, range) in plain.having(2, 'type')) range],
        [for (final (_, range) in document.having(2, 'type')) range],
      );
      expect(plain.having(2, 'message'), isEmpty);
    });

    test('and nothing outside the layers', () {
      expect(document.having(1, 'type'), isEmpty);
      expect(document.having(4, 'type'), isEmpty);
    });
  });
}
