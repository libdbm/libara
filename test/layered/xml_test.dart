import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/format/format.dart';
import 'package:libara/src/layered/layered.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../../example/xml/xml.dart';
import '../support.dart';

void main() {
  /// A layered XML document over [source].
  Layered<int> xml(String source) =>
      Layered.of(Text.of(source), const XML()).unwrap();

  /// The value of [name] for each range of [ranges].
  List<Value?> each(Ranges ranges, String name) => [
    for (final range in ranges.items.cast<ARange>()) range.get(name),
  ];

  test('derives tokens and elements', () {
    final document = xml('<a x="1"><b/>hi<!-- c --></a>');
    final tokens = document.layer(2);
    expect(each(tokens, 'type'), [
      string('start'),
      string('empty'),
      string('text'),
      string('comment'),
      string('end'),
    ]);
    expect(
      tokens.item(0),
      tagged(
        0,
        9,
        attributes: {
          'type': string('start'),
          'name': string('a'),
          '@x': string('1'),
        },
      ),
    );
    expect(
      document.layer(3),
      Ranges.of([
        tagged(
          0,
          5,
          attributes: {'type': string('element'), 'name': string('a')},
        ),
        tagged(
          1,
          1,
          attributes: {'type': string('element'), 'name': string('b')},
        ),
      ]),
    );
    expect(document.extent(3, document.markers(3).first.$1), span(0, 29));
    expect(document.valid, isTrue);
    expect(check(document), const Success<void>(null));
  });

  test('the grammar returns its layers in start order', () {
    for (final source in [
      '<a x="1"><b/>hi<!-- c --></a>',
      '<a><a><a></a></a></a><b/>',
      '</x><y>text<',
      '',
    ]) {
      final document = xml(source);
      for (final layer in [2, 3]) {
        final below = layer == 2 ? source.length : document.layer(2).length;
        final ranges = Ranges.of(
          const XML().derive(document, layer, span(0, below)).ranges,
        );
        expect(ranges, ranges.startOrder(), reason: '$source at $layer');
      }
    }
  });

  test('a text edit derives each layer once', () {
    final grammar = Counted();
    final document = Layered.of(Text.of('<a><b>hi</b></a>'), grammar).unwrap();
    grammar.derived.clear();
    document.apply(Edit(1, Insert(7, Text.of('x')))).unwrap();
    expect(grammar.derived, {2: 1, 3: 1});
  });

  test('markup that does not parse is a layer-2 diagnostic', () {
    final document = xml('a<b c>d<!-- e');
    expect(each(document.layer(2), 'type'), [
      string('text'),
      string('error'),
      string('comment'),
    ]);
    expect(each(document.diagnostics(2), 'message'), [
      string('malformed markup'),
      string('unterminated comment'),
    ]);
  });

  test('a mismatched end tag is a diagnostic, and fixing it clears it', () {
    final before = xml('<a><b></c></a>');
    expect(
      each(before.diagnostics(3), 'message'),
      contains(string('unexpected </c>')),
    );
    expect(before.valid, isFalse);
    final after = before
        .apply(Edit(1, Replace(span(8, 1), Text.of('b'))))
        .unwrap()
        .document;
    expect(after.valid, isTrue);
    expect(each(after.layer(3), 'name'), [string('a'), string('b')]);
    same(after);
  });

  test('typing inside an element derives only that element again', () {
    final before = xml('<r><a>xy</a><b>y</b></r>');
    final elements = before.markers(3);
    final change = before.apply(Edit(1, Insert(7, Text.of('z')))).unwrap();
    expect(change.layers[1].regions, [span(6, 3)]);
    expect(change.layers[2].regions, [span(1, 3)]);
    expect(
      change.document.markers(3).map((pair) => pair.$1),
      elements.map((pair) => pair.$1),
    );
    same(change.document);
  });

  test('derives what a full derivation does over seeded edits', () {
    const markup = [
      '<a>',
      '</a>',
      '<b/>',
      '<b x="1">',
      '</b>',
      '<!--',
      '-->',
      '<',
      '>',
      '/',
      '"',
    ];
    for (var seed = 0; seed < 200; seed++) {
      final random = Random(seed);
      // Mostly text, so that edits fall inside well-formed elements.
      String fragment() => [
        for (var count = random.nextInt(3); count > 0; count--)
          random.nextInt(4) == 0
              ? markup[random.nextInt(markup.length)]
              : 'xy '[random.nextInt(3)],
      ].join();
      String tree(int depth) {
        if (depth == 0 || random.nextInt(3) == 0) {
          return random.nextBool() ? 'x' : '<b/>';
        }
        final name = random.nextBool() ? 'a' : 'b';
        final children = [
          for (var count = 1 + random.nextInt(3); count > 0; count--)
            tree(depth - 1),
        ].join();
        return '<$name>$children</$name>';
      }

      var document = xml(tree(4));
      for (var step = 0; step < 30; step++) {
        final length = document.items.length;
        final start = random.nextInt(length + 1);
        final size = random.nextInt(min(3, length - start) + 1);
        final command = Replace(span(start, size), Text.of(fragment()));
        document = document.apply(Edit(1, command)).unwrap().document;
        same(
          document,
          'seed $seed, step $step: $command on '
          '${String.fromCharCodes(document.previous!.items.items)}',
        );
      }
    }
  });

  group('structural edits', () {
    /// The text of [document], through the layered and text formats.
    String serialized(Layered<int> document) =>
        text
                .encode(const LayeredFormat(XML()).encode(document).unwrap())
                .unwrap()
            as String;

    /// [document] after [edit].
    Layered<int> after(Layered<int> document, Edit<int> edit) =>
        document.apply(edit).unwrap().document;

    /// An element named [name] over [length] tokens from [start].
    Mark<Object?> element(int start, int length, String name) => Mark(
      tagged(
        start,
        length,
        attributes: {'type': string('element'), 'name': string(name)},
      ),
    );

    test('wrapping tokens inserts the tags', () {
      final before = xml('<r> x <!-- c --> <b/></r>');
      final wrap = element(1, 3, 'p');
      final edited = after(before, Edit(3, wrap));
      expect(serialized(edited), '<r><p> x <!-- c --> </p><b/></r>');
      expect(edited.extent(3, wrap.marker), span(3, 21));
      same(edited);
    });

    test('unwrapping an element removes its tags and joins text', () {
      final before = xml('<r>a<p>b</p>c</r>');
      final edited = after(
        before,
        Edit(3, Unmark<Object?>(before.markers(3).last.$1)),
      );
      expect(serialized(edited), '<r>abc</r>');
      same(edited);
    });

    test('renaming an element rewrites both tags and keeps markers', () {
      final before = xml('<r><a x="1">t</a></r>');
      final (inner, _) = before.markers(3).last;
      final tokens = before.markers(2).map((pair) => pair.$1).toList();
      final change = before
          .apply(
            Edit(
              3,
              Update<Object?>(inner, {
                'type': string('element'),
                'name': string('item'),
              }),
            ),
          )
          .unwrap();
      final edited = change.document;
      expect(serialized(edited), '<r><item x="1">t</item></r>');
      expect(edited.markers(2).map((pair) => pair.$1), tokens);
      expect(change.layers[2].updated, [inner]);
      expect(change.layers[1].updated.length, 2);
      same(edited);
    });

    test('deleting an element removes it and its content', () {
      final before = xml('<r>a<p>b<q/></p>c</r>');
      final edited = after(before, Edit(3, Delete<Object?>(span(1, 1))));
      expect(serialized(edited), '<r>ac</r>');
      same(edited);
    });

    test('an empty wrap makes an empty element', () {
      final edited = after(xml('<r></r>'), Edit(3, element(1, 0, 'e')));
      expect(serialized(edited), '<r><e></e></r>');
      same(edited);
    });

    test('edits that would break the markup are refused', () {
      final before = xml('<r><a>x</a><b>y</b></r>');
      final document = xml('<r><a>x</a><b>y</b></r>');
      expect(before.apply(Edit(3, element(2, 3, 'p'))), invalid);
      expect(before.apply(Edit(3, element(1, 2, 'bad name'))), invalid);
      expect(before.apply(Edit(3, Unmark<Object?>(Marker()))), invalid);
      final empty = xml('<r><e/></r>');
      expect(
        empty.apply(Edit(3, Unmark<Object?>(empty.markers(3).last.$1))),
        invalid,
      );
      // The example reads entities as plain text, so a value holding `&`
      // or `<` could not be read back as written.
      for (final value in ['a&b', 'a<b']) {
        final tag = tagged(
          3,
          0,
          attributes: {
            'type': string('empty'),
            'name': string('c'),
            '@v': string(value),
          },
        );
        expect(before.apply(Edit(2, Mark<Object?>(tag))), invalid);
      }
      final flawed = xml('<r><a b>x</r>');
      expect(flawed.apply(Edit(2, Delete<Object?>(span(1, 1)))), invalid);
      expect(serialized(before), serialized(document));
    });

    test('a tag with a character outside the BMP is measured in code '
        'points', () {
      // An empty p tag with an attribute holding one emoji, which is two
      // UTF-16 code units but one code point.
      ARange tag(int at) => tagged(
        at,
        0,
        attributes: {
          'type': string('empty'),
          'name': string('p'),
          '@a': string('😀'),
        },
      );
      final cases = [
        (xml(''), 0, '<p a="😀"/>'),
        (xml('<r>abc</r>'), 4, '<r>a<p a="😀"/>bc</r>'),
        (xml('<r>abc</r>'), 10, '<r>abc</r><p a="😀"/>'),
      ];
      for (final (before, at, expected) in cases) {
        final edited = after(before, Edit(2, Mark<Object?>(tag(at))));
        expect(serialized(edited), expected);
        same(edited, 'at $at');
      }
    });

    test('mixed edits match a derivation from scratch', () {
      var accepted = 0;
      for (var seed = 0; seed < 200; seed++) {
        final random = Random(seed);
        String tree(int depth) {
          if (depth == 0 || random.nextInt(3) == 0) {
            return const ['x', ' ', '<b/>', '<!--c-->'][random.nextInt(4)];
          }
          final name = random.nextBool() ? 'a' : 'b';
          return '<$name>${[for (var count = 1 + random.nextInt(3); count > 0; count--) tree(depth - 1)].join()}</$name>';
        }

        var document = xml(tree(4));
        for (var step = 0; step < 30; step++) {
          final tokens = document.layer(2).length;
          final elements = document.markers(3);
          int at(int limit) => random.nextInt(limit + 1);
          final Edit<int> edit;
          switch (random.nextInt(7)) {
            case 0:
              final start = at(tokens);
              edit = Edit(
                3,
                element(
                  start,
                  at(tokens - start),
                  random.nextBool() ? 'p' : 'a',
                ),
              );
            case 1 when elements.isNotEmpty:
              edit = Edit(
                3,
                Unmark<Object?>(elements[random.nextInt(elements.length)].$1),
              );
            case 2 when elements.isNotEmpty:
              edit = Edit(
                3,
                Update<Object?>(elements[random.nextInt(elements.length)].$1, {
                  'type': string('element'),
                  'name': string(random.nextBool() ? 'q' : 'b'),
                }),
              );
            case 3:
              final start = at(elements.length);
              edit = Edit(
                3,
                Delete<Object?>(span(start, at(elements.length - start))),
              );
            case 4:
              final start = at(tokens);
              edit = Edit(
                2,
                Delete<Object?>(span(start, at(min(2, tokens - start)))),
              );
            case 5:
              edit = Edit(
                2,
                Mark(
                  tagged(
                    at(document.items.length),
                    0,
                    attributes: {
                      'type': string(random.nextBool() ? 'start' : 'end'),
                      'name': string('a'),
                    },
                  ),
                ),
              );
            default:
              final length = document.items.length;
              final start = at(length);
              edit = Edit(
                1,
                Replace(
                  span(start, at(min(2, length - start))),
                  Text.of(
                    const ['x', '<', '>', '<a>', '</a>'][random.nextInt(5)],
                  ),
                ),
              );
          }
          switch (document.apply(edit)) {
            case Failure(:final kind, :final message):
              expect(kind, Kind.invalid, reason: message);
            case Success(:final value):
              same(
                value.document,
                'seed $seed, step $step: $edit on ${String.fromCharCodes(document.items.items)}',
              );
              document = value.document;
              accepted++;
          }
        }
      }
      expect(accepted, greaterThan(3000));
    });

    test('text the edits do not touch serializes back unchanged', () {
      const source =
          '<doc>\n  <!-- keep -->\n  <a k=\'v\'>one</a>\n'
          '  <b>two</b>\n</doc>\n';
      var document = xml(source);
      final (a, _) = document.markers(3)[1];
      document = after(
        document,
        Edit(
          3,
          Update<Object?>(a, {'type': string('element'), 'name': string('x')}),
        ),
      );
      document = after(document, Edit(3, element(1, 3, 'w')));
      expect(
        serialized(document),
        "<doc><w>\n  <!-- keep -->\n  </w><x k='v'>one</x>\n"
        '  <b>two</b>\n</doc>\n',
      );
      same(document);
    });
  });

  group('change lists', () {
    /// Expects every list of every layer of [change] to refuse changes.
    void frozen(Change<int> change) {
      for (final (index, delta) in change.layers.indexed) {
        for (final list in <List<Object>>[
          delta.created,
          delta.removed,
          delta.updated,
          delta.regions,
        ]) {
          expect(
            list.clear,
            throwsUnsupportedError,
            reason: 'layer ${index + 1}',
          );
        }
      }
    }

    test('a text edit returns unmodifiable lists', () {
      final before = xml('<a x="1"><b/>hi</a>');
      frozen(before.apply(Edit(1, Insert(13, Text.of('yo')))).unwrap());
    });

    test('a structural edit returns unmodifiable lists', () {
      // Deleting a layer-2 token derives layer 3 again.
      final before = xml('<r>a<b/>c</r>');
      frozen(before.apply(Edit(2, Delete<Object?>(span(2, 1)))).unwrap());
    });

    test('a transaction returns unmodifiable lists', () {
      final before = xml('<a x="1"><b/>hi</a>');
      frozen(
        before.transact([
          Edit(1, Insert(13, Text.of('yo'))),
          Edit(1, Delete(span(0, 1))),
        ]).unwrap(),
      );
    });

    test('an empty transaction returns unmodifiable lists', () {
      frozen(xml('<a/>').transact([]).unwrap());
    });
  });
}

/// Expects [document] to keep its invariants and to have the layers of one
/// derived from scratch from its items.
void same(Layered<int> document, [String? reason]) {
  expect(check(document), const Success<void>(null), reason: reason);
  final scratch = Layered.of(
    Items.of(document.items.items),
    const XML(),
  ).unwrap();
  for (var layer = 2; layer <= 3; layer++) {
    expect(document.layer(layer), scratch.layer(layer), reason: reason);
    expect(
      document.diagnostics(layer),
      scratch.diagnostics(layer),
      reason: reason,
    );
  }
}

/// The XML grammar, counting how many times it derives each layer.
final class Counted implements Grammar<int> {
  /// For each layer, how many times it has been derived.
  final Map<int, int> derived = {};

  static const _xml = XML();

  @override
  int get depth => _xml.depth;

  @override
  Derived derive(Layered<int> document, int layer, Range region) {
    derived.update(layer, (count) => count + 1, ifAbsent: () => 1);
    return _xml.derive(document, layer, region);
  }

  @override
  Range affected(Layered<int> document, int layer, Range changed) =>
      _xml.affected(document, layer, changed);

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) =>
      _xml.edit(document, change);
}
