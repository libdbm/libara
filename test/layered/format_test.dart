import 'package:libara/src/format/format.dart';
import 'package:libara/src/layered/layered.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'brackets.dart';
import 'model_test.dart' show Script, derived, fresh;

void main() {
  final format = LayeredFormat(Brackets());

  test('encodes layer 1 and decodes by deriving every layer', () {
    final document = Layered.of(Text.of('a[b]c'), Brackets()).unwrap();
    final items = format.encode(document).unwrap();
    expect(String.fromCharCodes(items.items), 'a[b]c');
    final decoded = format.decode(items).unwrap();
    expect(decoded.version, 0);
    expect(decoded.layer(3), document.layer(3));
  });

  test('travels as text when composed with the text format', () {
    final document = Layered.of(Text.of('[a]]'), Brackets()).unwrap();
    final form = text.encode(format.encode(document).unwrap()).unwrap();
    expect(form, '[a]]');
    final decoded = format.decode(text.decode(form).unwrap()).unwrap();
    expect(decoded.diagnostics(3), document.diagnostics(3));
    expect(decoded.valid, isFalse);
  });

  test('decoding any model version derives it from scratch', () {
    for (var seed = 0; seed < 20; seed++) {
      final script = Script(seed);
      var document = Layered.of(Text.of(script.text(8)), Brackets()).unwrap();
      for (var step = 0; step < 60; step++) {
        final reason = 'seed $seed, step $step';
        final decoded = format
            .decode(format.encode(document).unwrap())
            .unwrap();
        expect(decoded.items.items, document.items.items, reason: reason);
        fresh(decoded, reason);
        for (var layer = 2; layer <= 3; layer++) {
          expect(
            decoded.layer(layer),
            derived(document.layer(layer)),
            reason: reason,
          );
        }
        if (document.apply(script.edit(document)) case Success(:final value)) {
          document = value.document;
        }
      }
    }
  });
}
