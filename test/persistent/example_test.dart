import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

Mark<int> mark(int start, int length, String type, String label) => Mark(
  tagged(
    start,
    length,
    attributes: {
      'type': Value.of(type).unwrap(),
      'label': Value.of(label).unwrap(),
    },
  ),
);

void main() {
  // The mixed-syntax example from the attributed range algebra paper.
  final source = Text.of('<P>THE @I{CAT} UNDER THE HAT.{/P]');

  // The lexical layer: the four markup tokens.
  final openP = mark(0, 3, 'stag', 'P');
  final openI = mark(7, 3, 'stag', 'I');
  final closeI = mark(13, 1, 'etag', 'I');
  final closeP = mark(29, 4, 'etag', 'P');

  // The application layer. The paper indexes these into the lexical layer;
  // a document holds ranges over its own items, so here each element spans
  // the text from its start tag to the end of its end tag.
  final elementP = mark(0, 33, 'elem', 'P');
  final elementI = mark(7, 7, 'elem', 'I');

  final marks = [openP, openI, closeI, closeP, elementP, elementI];

  Document<int> marked() {
    var document = Document.of(source);
    for (final command in marks) {
      document = document.apply(command).or(document);
    }
    return document;
  }

  String spanned(Document<int> document, Mark<int> command) =>
      String.fromCharCodes(
        document.resolve(command.marker)!.extract(document).items,
      );

  test('every range spans its markup before the edit', () {
    final document = marked();
    expect(spanned(document, openP), '<P>');
    expect(spanned(document, openI), '@I{');
    expect(spanned(document, closeI), '}');
    expect(spanned(document, closeP), '{/P]');
    expect(spanned(document, elementI), '@I{CAT}');
    expect(document.ranges.length, 6);
  });

  test('inserting BIG before CAT moves every range', () {
    final before = marked();
    final after = before.apply(Insert(10, Text.of('BIG '))).or(before);
    expect(
      String.fromCharCodes(after.items),
      '<P>THE @I{BIG CAT} UNDER THE HAT.{/P]',
    );

    // Before the insertion point: unchanged.
    expect(
      after.resolve(openP.marker)!.same(before.resolve(openP.marker)!),
      isTrue,
    );
    // Ending exactly at the insertion point: grown, by right gravity.
    expect(spanned(after, openI), '@I{BIG ');
    // Starting after the insertion point: shifted by four.
    expect(after.resolve(closeI.marker)!.start, 17);
    expect(spanned(after, closeI), '}');
    expect(after.resolve(closeP.marker)!.start, 33);
    expect(spanned(after, closeP), '{/P]');
    // Containing the insertion point: grown.
    expect(spanned(after, elementI), '@I{BIG CAT}');
    expect(after.resolve(elementP.marker)!.length, 37);

    // Attributes travel with the ranges.
    expect(
      after.resolve(closeI.marker)!.get('type'),
      Value.of('etag').unwrap(),
    );
    // Undo restores every range.
    expect(spanned(after.previous!, openI), '@I{');
  });

  test('tokens marked right start, left end never absorb the insertion', () {
    Mark<int> token(int start, int length, String type, String label) => Mark(
      tagged(
        start,
        length,
        attributes: {
          'type': Value.of(type).unwrap(),
          'label': Value.of(label).unwrap(),
        },
      ),
      end: Gravity.left,
    );
    final tokens = [
      token(0, 3, 'stag', 'P'),
      token(7, 3, 'stag', 'I'),
      token(13, 1, 'etag', 'I'),
      token(29, 4, 'etag', 'P'),
    ];
    var before = Document.of(source);
    for (final command in [...tokens, elementP, elementI]) {
      before = before.apply(command).or(before);
    }
    final after = before.apply(Insert(10, Text.of('BIG '))).or(before);

    expect(
      [for (final command in tokens) spanned(after, command)],
      ['<P>', '@I{', '}', '{/P]'],
    );
    expect(spanned(after, elementI), '@I{BIG CAT}');
    expect(after.resolve(elementP.marker)!.length, 37);
    // Inside the inserted text, only the two elements contain the position.
    expect(after.at(11).length, 2);
  });
}
