import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/layered/layered.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'brackets.dart';
import 'layered_test.dart' show Placing, Spanning;
import 'overlaps.dart';

void main() {
  /// A bracket document over [source].
  Layered<int> brackets(String source) =>
      Layered.of(Text.of(source), Brackets()).unwrap();

  /// Whether [range] is a run of text between brackets.
  bool text(ARange range) => range.get('type') == kind('text');

  /// [document]'s items.
  String shown(Layered<int> document) =>
      String.fromCharCodes(document.items.items);

  group('kept', () {
    test('takes every range for markup unless told which are text', () {
      final document = brackets('[ab]');
      final typed = Edit<int>(1, Insert(2, Text.of('x')));
      expect(kept(document, typed), isA<Failure<Change<int>>>());
      final change = kept(document, typed, text: text).unwrap();
      expect(shown(change.document), '[axb]');
    });

    test('refuses an edit that is not to the text', () {
      final document = brackets('[ab]');
      expect(
        kept(document, Edit<int>(2, Delete(span(1, 1))), text: text),
        isA<Failure<Change<int>>>(),
      );
      expect(
        kept(document, Edit<int>(1, Mark(tagged(0, 1))), text: text),
        isA<Failure<Change<int>>>(),
      );
    });

    test('refuses an edit reaching into markup, writing or removing it', () {
      final document = brackets('[ab][c]');
      // Over the first ] and into the text after it.
      expect(
        kept(document, Edit<int>(1, Delete(span(3, 2))), text: text),
        isA<Failure<Change<int>>>(),
      );
      expect(
        kept(document, Edit<int>(1, Insert(2, Text.of('['))), text: text),
        isA<Failure<Change<int>>>(),
      );
    });

    test('keeps a diagnostic standing beside an edit, and is valid', () {
      // The [ never closes: a layer-3 diagnostic over it.
      final document = brackets('[ab');
      expect(document.diagnostics(3).items, hasLength(1));
      final change = kept(
        document,
        Edit<int>(1, Insert(3, Text.of('c'))),
        text: text,
      ).unwrap();
      expect(shown(change.document), '[abc');
      expect(change.document.diagnostics(3).items, hasLength(1));
    });
  });

  group('Brackets.valid', () {
    /// What the bracket grammar makes of [command] to [source].
    Result<Change<int>> valid(String source, Command<int> command) {
      final document = brackets(source);
      return document.grammar.valid(document, Edit(1, command));
    }

    test('accepts typing inside a run of text between brackets', () {
      expect(
        shown(valid('[ab]', Insert(2, Text.of('x'))).unwrap().document),
        '[axb]',
      );
      expect(valid('[ab]', Delete(span(1, 1))), isA<Success<Change<int>>>());
    });

    test('refuses writing, removing, or reaching into a bracket', () {
      expect(
        valid('[ab]', Insert(2, Text.of(']'))),
        isA<Failure<Change<int>>>(),
      );
      expect(valid('[ab]', Delete(span(0, 1))), isA<Failure<Change<int>>>());
      expect(valid('[ab][c]', Delete(span(2, 3))), isA<Failure<Change<int>>>());
    });

    test('refuses an edit changing which brackets do not pair', () {
      // The unmatched [ before 'a' would pair once the text holds a ], but
      // a ] is markup, so any such edit writes markup too.
      expect(
        valid('[ab', Insert(3, Text.of(']'))),
        isA<Failure<Change<int>>>(),
      );
    });
  });

  group('every grammar', () {
    /// What [document]'s grammar makes of [command] to it.
    Result<Change<int>> valid(Layered<int> document, Command<int> command) =>
        document.grammar.valid(document, Edit(1, command));

    test('Overlaps, whose every range is markup, refuses every edit', () {
      // Its `all` range covers the whole layer, so every edit changes it.
      final document = Layered.of(Text.of('ab cd'), const Overlaps()).unwrap();
      expect(
        valid(document, Insert(1, Text.of('x'))),
        isA<Failure<Change<int>>>(),
      );
      expect(
        valid(document, Insert(2, Text.of(' '))),
        isA<Failure<Change<int>>>(),
      );
    });

    test('a grammar of fixed ranges refuses an edit changing one', () {
      final document = Layered.of(Text.of('abcdefghij'), Spanning()).unwrap();
      expect(
        valid(document, Insert(5, Text.of('x'))),
        isA<Failure<Change<int>>>(),
      );
    });

    test('a grammar wrapping another answers as the one it wraps', () {
      final document = Layered.of(Text.of('[ab]'), Placing()).unwrap();
      expect(
        valid(document, Insert(2, Text.of(']'))),
        isA<Failure<Change<int>>>(),
      );
      expect(
        valid(document, Insert(2, Text.of('x'))),
        isA<Success<Change<int>>>(),
      );
    });
  });
}
