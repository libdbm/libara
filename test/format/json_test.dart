import 'dart:convert';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/format/format.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// A marked, edited text document.
Document<int> sample() => Document.of(Text.of('the cat sat 𝄞')).transact([
  Mark<int>(
    tagged(
      4,
      3,
      attributes: {
        'type': Value.of('word').unwrap(),
        'count': const Num(2),
        'open': const Bool(true),
        'note': const Nil(),
      },
    ),
  ),
  Mark<int>(tagged(0, 3), start: Gravity.left, end: Gravity.left),
  Mark<int>(tagged(8, 0), end: Gravity.left),
  Insert(0, Text.of('> ')),
]).unwrap();

/// [document] through [JSONFormat], as a map.
Result<Map<String, Object?>> encode(
  Document<int> document,
  Format<Sequence<int>, Object?> items, {
  bool history = false,
}) => JSONFormat(
  items,
  history: history,
).encode(document).map((json) => json! as Map<String, Object?>);

/// The document and markers [json] holds, through [JSONFormat].
Result<(Document<int>, List<Marker>)> restore(
  Object? json,
  Format<Sequence<int>, Object?> items,
) => JSONFormat(items).restore(json);

/// An item format from two functions, for faulty formats in tests.
final class Custom implements Format<Sequence<int>, Object?> {
  Custom(this._encode, this._decode);

  final Result<Object?> Function(Sequence<int> items) _encode;
  final Result<Sequence<int>> Function(Object? json) _decode;

  @override
  Result<Object?> encode(Sequence<int> value) => _encode(value);

  @override
  Result<Sequence<int>> decode(Object? form) => _decode(form);
}

/// [json] through a JSON string and back.
Object? wire(Object? json) => jsonDecode(jsonEncode(json));

/// Expects [failure] to be a failure of [kind] whose message starts with
/// [prefix].
void fails(Object? failure, Kind kind, String prefix) => expect(
  failure,
  isA<Failure<Object?>>()
      .having((failure) => failure.kind, 'kind', kind)
      .having((failure) => failure.message, 'message', startsWith(prefix)),
);

void main() {
  test('save and load round-trip items, ranges, and markers', () {
    final document = sample();
    final saved = encode(document, text).unwrap();
    final (loaded, markers) = restore(wire(saved), text).unwrap();
    expect(loaded.items, document.items);
    expect(loaded.ranges, document.ranges);
    expect(loaded.version, 0);
    expect(markers.length, document.markers.length);
    for (final (index, (marker, range)) in document.markers.indexed) {
      expect(loaded.resolve(markers[index]), range);
      expect(loaded.gravity(markers[index]), document.gravity(marker));
    }
    expect(check(loaded), const Success<void>(null));
  });

  test('the saved value uses only JSON types and survives jsonEncode', () {
    final saved = encode(sample(), text).unwrap();
    expect(wire(saved), saved);
    expect(saved['libara'], 1);
    expect((saved['markers']! as List).first, {
      'id': 0,
      'range': [0, 5],
      'start': 'left',
      'end': 'left',
      'attributes': <String, Object?>{},
    });
  });

  test('a document with no ranges round-trips', () {
    final document = Document.of(Text.of('plain'));
    final (loaded, markers) = restore(
      wire(encode(document, text).unwrap()),
      text,
    ).unwrap();
    expect(loaded.items, document.items);
    expect(markers, isEmpty);
  });

  test('saving items the item format cannot write is a failure', () {
    final document = Document.of(Items.of([0x61, -1]));
    fails(encode(document, text), Kind.invalid, 'format: items: ');
  });

  group('load of malformed input fails and never throws', () {
    Map<String, Object?> valid() =>
        wire(encode(sample(), text).unwrap())! as Map<String, Object?>;

    test('a value that is not an object', () {
      fails(restore('text', text), Kind.syntax, 'format: expected an object');
    });

    test('an unsupported version', () {
      fails(restore(valid()..['libara'] = 2, text), Kind.invalid, 'format: ');
      fails(restore(valid()..remove('libara'), text), Kind.syntax, 'format: ');
    });

    test('items the item format cannot read', () {
      fails(
        restore(valid()..['items'] = 3, text),
        Kind.syntax,
        'format: items',
      );
    });

    test('markers that are not a list of objects', () {
      fails(restore(valid()..['markers'] = {}, text), Kind.syntax, 'format: ');
      fails(
        restore(valid()..['markers'] = [3], text),
        Kind.syntax,
        'format: markers[0]',
      );
    });

    Map<String, Object?> with0(String key, Object? value) {
      final json = valid();
      final markers = [...json['markers']! as List];
      markers[0] = {...markers[0] as Map<String, Object?>, key: value};
      return json..['markers'] = markers;
    }

    test('a malformed range, gravity, or attribute', () {
      fails(
        restore(with0('range', [1]), text),
        Kind.syntax,
        'format: markers[0].range',
      );
      fails(
        restore(with0('range', [-1, 2]), text),
        Kind.invalid,
        'format: markers[0].range',
      );
      fails(
        restore(with0('range', [0, 999]), text),
        Kind.invalid,
        'format: markers[0].range',
      );
      fails(
        restore(with0('start', 'up'), text),
        Kind.syntax,
        'format: markers[0].start',
      );
      fails(
        restore(with0('attributes', {'x': 1.5}), text),
        Kind.syntax,
        'format: markers[0].attributes.x',
      );
    });

    test('an unknown or repeated marker id', () {
      fails(
        restore(with0('id', 7), text),
        Kind.invalid,
        'format: markers[0].id',
      );
      fails(restore(with0('id', 1), text), Kind.invalid, 'format: markers[');
      fails(
        restore(with0('id', 'a'), text),
        Kind.syntax,
        'format: markers[0].id',
      );
    });
  });

  group('history', () {
    /// A document with coalesced edits, an unmark, a re-mark of the same
    /// marker, an update, and a replace across its versions.
    (Document<int>, Mark<int>) edited() {
      final word = Mark<int>(tagged(4, 3));
      var document = Document.of(Text.of('the cat sat')).apply(word).unwrap();
      document = document.apply(Insert(0, Text.of('a'))).unwrap();
      document = document
          .apply(Insert(1, Text.of('b')), flatten: true)
          .unwrap();
      document = document.apply(Unmark(word.marker)).unwrap();
      document = document.apply(word).unwrap();
      document = document.transact([
        Update(word.marker, {'n': const Num(1)}),
        Replace(span(0, 2), Text.of('xyz')),
        Mark<int>(tagged(0, 1), start: Gravity.left),
      ]).unwrap();
      return (document, word);
    }

    test('round-trips every version, so undo works after loading', () {
      final (document, word) = edited();
      final saved = encode(document, text, history: true).unwrap();
      final (loaded, markers) = restore(wire(saved), text).unwrap();
      Document<int>? original = document;
      Document<int>? copy = loaded;
      while (original != null) {
        expect(copy, isNotNull);
        expect(copy!.version, original.version);
        expect(copy.items, original.items, reason: '${original.version}');
        // The order among ranges with equal start and length is not kept.
        expect(
          copy.ranges.items,
          unorderedEquals(original.ranges.items),
          reason: '${original.version}',
        );
        expect(check(copy), const Success<void>(null));
        original = original.previous;
        copy = copy.previous;
      }
      expect(copy, isNull);
      for (final (index, (_, range)) in document.markers.indexed) {
        expect(loaded.resolve(markers[index]), range);
      }
      // The re-marked word is one marker throughout.
      final id = document.markers.indexWhere((pair) => pair.$1 == word.marker);
      expect(loaded.previous!.previous!.resolve(markers[id]), isNull);
    });

    test('round-trips an inserted slice, which cannot change after', () {
      final payload = Text.of('ab').slice(0, 2);
      final document = Document.of(Text.of(''))
          .apply(Insert(0, payload))
          .unwrap();
      expect(
        () => (payload.items as List<int>)[0] = 0x58,
        throwsUnsupportedError,
      );
      final saved = encode(document, text, history: true).unwrap();
      final (loaded, _) = restore(wire(saved), text).unwrap();
      expect(loaded.items, document.items);
      expect(loaded.previous!.items, document.previous!.items);
    });

    test('is left out unless asked for', () {
      final (document, _) = edited();
      expect(encode(document, text).unwrap().containsKey('history'), isFalse);
      final (loaded, _) = restore(
        wire(encode(document, text).unwrap()),
        text,
      ).unwrap();
      expect(loaded.version, 0);
      expect(loaded.ranges, document.ranges);
    });

    Map<String, Object?> saved() =>
        wire(encode(edited().$1, text, history: true).unwrap())!
            as Map<String, Object?>;

    test('a malformed history fails and never throws', () {
      fails(
        restore(saved()..['history'] = 3, text),
        Kind.syntax,
        'format: history',
      );
      fails(
        restore(saved()..['history'] = [<Object?>[]], text),
        Kind.syntax,
        'format: history[0]',
      );
      fails(
        restore(
          saved()
            ..['history'] = [
              [
                {'command': 'jump'},
              ],
            ],
          text,
        ),
        Kind.syntax,
        'format: history[0][0].command',
      );
      fails(
        restore(
          saved()
            ..['history'] = [
              [
                {'command': 'unmark', 'id': 99},
              ],
            ],
          text,
        ),
        Kind.invalid,
        'format: history[0][0].id',
      );
    });

    test('a command that does not apply fails with its path', () {
      fails(
        restore(
          saved()
            ..['history'] = [
              [
                {
                  'command': 'delete',
                  'range': [0, 999],
                },
              ],
            ],
          text,
        ),
        Kind.bounds,
        'format: history[0]: ',
      );
    });
  });

  group('surrogates', () {
    /// A high and a low surrogate as separate items, which a string would
    /// merge into one character.
    final pair = Text.of('\uD800').concat(Text.of('\uDC00')).unwrap();

    test('adjacent high and low surrogate items fail to save', () {
      final document = Document.of(Text.of('a').concat(pair).unwrap());
      fails(encode(document, text), Kind.invalid, 'format: items: ');
    });

    test('in an inserted history item they fail to save', () {
      final document = Document.of(Text.of('a'))
          .apply(Insert(1, pair))
          .unwrap();
      fails(
        encode(document, text, history: true),
        Kind.invalid,
        'format: history[0][0]: items: ',
      );
    });

    test('in a Str attribute they fail to save', () {
      final document = Document.of(Text.of('ab'))
          .apply(Mark<int>(tagged(0, 1, attributes: {'name': Str(pair)})))
          .unwrap();
      fails(
        encode(document, text),
        Kind.invalid,
        'format: markers[0].attributes.name',
      );
    });

    test('lone surrogates, and a low one before a high one, round-trip', () {
      final items = Text.of('\uD800a\uDC00')
          .concat(Text.of('\uDC00'))
          .unwrap()
          .concat(Text.of('\uD800'))
          .unwrap();
      final document = Document.of(items)
          .apply(
            Mark<int>(
              tagged(0, 1, attributes: {'name': Str(Text.of('\uDC00x'))}),
            ),
          )
          .unwrap();
      final (loaded, _) = restore(
        wire(encode(document, text).unwrap()),
        text,
      ).unwrap();
      expect(loaded.items, document.items);
      expect(loaded.ranges, document.ranges);
    });
  });

  group('a faulty item format', () {
    final document = Document.of(Text.of('ab'));

    /// An item format whose write returns [json] for every sequence.
    Format<Sequence<int>, Object?> writing(Object? json) =>
        Custom((_) => Success(json), text.decode);

    test('that throws in read makes load fail, not throw', () {
      final throwing = Custom(text.encode, (_) => throw StateError('boom'));
      fails(
        restore(wire(encode(document, text).unwrap()), throwing),
        Kind.invalid,
        'format: items: format threw',
      );
    });

    test('that throws in write makes save fail, not throw', () {
      final throwing = Custom((_) => throw StateError('boom'), text.decode);
      fails(
        encode(document, throwing),
        Kind.invalid,
        'format: items: format threw',
      );
    });

    test('that writes something other than JSON makes save fail', () {
      fails(encode(document, writing(Object())), Kind.invalid, 'format: items');
      fails(encode(document, writing({1: 'a'})), Kind.invalid, 'format: items');
      fails(
        encode(document, writing([double.nan])),
        Kind.invalid,
        'format: items[0]',
      );
      final loop = <Object?>[];
      loop.add(loop);
      fails(encode(document, writing(loop)), Kind.invalid, 'format: items[0]');
    });

    test('that writes deeply nested JSON saves without overflowing', () {
      Object? list = 1;
      Object? map = 1;
      for (var depth = 0; depth < 20000; depth++) {
        list = [list];
        map = {'a': map};
      }
      expect(encode(document, writing(list)).unwrap()['items'], same(list));
      expect(encode(document, writing(map)).unwrap()['items'], same(map));
    });

    test('that writes a map containing itself deep down fails', () {
      final loop = <String, Object?>{};
      loop['a'] = [
        {'b': loop},
      ];
      fails(
        encode(document, writing(loop)),
        Kind.invalid,
        'format: items.a[0].b: the map contains itself',
      );
    });

    test('that writes nested JSON with finite numbers saves', () {
      final shared = [1, 2];
      final json = {'a': shared, 'b': shared, 'c': 1.5, 'd': null};
      expect(encode(document, writing(json)).unwrap()['items'], json);
    });

    test('in a history item is reported with its path', () {
      var calls = 0;
      final failing = Custom(
        (items) => ++calls > 1 ? throw StateError('boom') : text.encode(items),
        text.decode,
      );
      final edited = document.apply(Insert(0, Text.of('x'))).unwrap();
      fails(
        encode(edited, failing, history: true),
        Kind.invalid,
        'format: history[0][0]: items: format threw',
      );
    });
  });

  test('decode gives the document restore gives with its markers', () {
    final document = sample();
    final json = wire(encode(document, text).unwrap());
    final decoded = JSONFormat(text).decode(json).unwrap();
    final (restored, _) = JSONFormat(text).restore(json).unwrap();
    expect(decoded.items, restored.items);
    expect(decoded.ranges, restored.ranges);
    expect(decoded.ranges, document.ranges);
  });

  group('limits', () {
    // Version 0 holds 'abc' and two marks, one with two attributes;
    // version 1 inserts two items, in two commands.
    final base = Document.of(Text.of('abc'))
        .transact([
          Mark<int>(
            tagged(0, 1, attributes: {'x': const Num(1), 'y': const Num(2)}),
          ),
          Mark<int>(tagged(1, 1)),
        ])
        .unwrap()
        .compact();
    final edited = base.transact([
      Insert(3, Text.of('d')),
      Insert(4, Text.of('e')),
    ]).unwrap();

    /// [edited] saved with history under [limits].
    Result<Object?> save(Limits limits) =>
        JSONFormat(text, history: true, limits: limits).encode(edited);

    /// [edited], saved without limits, loaded under [limits].
    Result<Object?> load(Limits limits) => JSONFormat(
      text,
      limits: limits,
    ).decode(wire(JSONFormat(text, history: true).encode(edited).unwrap()));

    final cases = [
      (
        const Limits(items: 5),
        const Limits(items: 4),
        'format: history[0]: items: 5 exceeds 4',
        'format: history[0][1]: items: 5 exceeds 4',
      ),
      (
        const Limits(markers: 2),
        const Limits(markers: 1),
        'format: markers: markers: 2 exceeds 1',
        'format: markers: markers: 2 exceeds 1',
      ),
      (
        const Limits(commands: 2),
        const Limits(commands: 1),
        'format: history[0]: commands: 2 exceeds 1',
        'format: history[0]: commands: 2 exceeds 1',
      ),
      (
        const Limits(attributes: 2),
        const Limits(attributes: 1),
        'format: markers[0].attributes: attributes: 2 exceeds 1',
        'format: markers[0].attributes: attributes: 2 exceeds 1',
      ),
    ];
    for (final (fits, over, saving, loading) in cases) {
      test('$over fails past its bound and $fits passes at it', () {
        expect(save(fits), isA<Success<Object?>>());
        expect(load(fits), isA<Success<Object?>>());
        fails(save(over), Kind.invalid, saving);
        fails(load(over), Kind.invalid, loading);
      });
    }

    test('depth bounds the nesting an item format writes', () {
      final nested = Custom(
        (_) => const Success([
          [1],
        ]),
        text.decode,
      );
      final document = Document.of(Text.of('a'));
      expect(
        JSONFormat(nested, limits: const Limits(depth: 2)).encode(document),
        isA<Success<Object?>>(),
      );
      fails(
        JSONFormat(nested, limits: const Limits(depth: 1)).encode(document),
        Kind.invalid,
        'format: items[0]: depth: 2 exceeds 1',
      );
    });

    test('the items of version 0 are bounded', () {
      final document = Document.of(Text.of('abc'));
      const over = Limits(items: 2);
      fails(
        JSONFormat(text, limits: over).encode(document),
        Kind.invalid,
        'format: items: items: 3 exceeds 2',
      );
      fails(
        JSONFormat(
          text,
          limits: over,
        ).decode(JSONFormat(text).encode(document).unwrap()),
        Kind.invalid,
        'format: items: items: 3 exceeds 2',
      );
    });

    test('markers found only in the history are bounded', () {
      final mark = Mark<int>(tagged(0, 1));
      final document = Document.of(Text.of('abc'))
          .apply(mark)
          .unwrap()
          .apply(Unmark<int>(mark.marker))
          .unwrap();
      const over = Limits(markers: 0);
      fails(
        JSONFormat(text, history: true, limits: over).encode(document),
        Kind.invalid,
        'format: history: markers: 1 exceeds 0',
      );
      final json = wire(
        JSONFormat(text, history: true).encode(document).unwrap(),
      );
      fails(
        JSONFormat(text, limits: over).decode(json),
        Kind.invalid,
        'format: history: markers: 1 exceeds 0',
      );
    });

    test('depth bounds maps as it does lists', () {
      final nested = Custom(
        (_) => const Success({
          'a': {'b': 1},
        }),
        text.decode,
      );
      fails(
        JSONFormat(
          nested,
          limits: const Limits(depth: 1),
        ).encode(Document.of(Text.of('a'))),
        Kind.invalid,
        'format: items.a: depth: 2 exceeds 1',
      );
    });

    test('payload bounds the items decoded, kept or not', () {
      // Version 0 holds one item; each later version inserts four and
      // deletes them again, so the document never grows.
      final json = {
        'libara': 1,
        'items': 'a',
        'markers': <Object?>[],
        'history': [
          for (var version = 0; version < 3; version++)
            [
              {'command': 'insert', 'position': 1, 'items': 'bbbb'},
              {
                'command': 'delete',
                'range': [1, 4],
              },
            ],
        ],
      };
      Result<Document<int>> load(Limits limits) =>
          JSONFormat(text, limits: limits).decode(json);
      expect(load(const Limits(items: 5)), isA<Success<Object?>>());
      expect(load(const Limits(payload: 13)), isA<Success<Object?>>());
      fails(
        load(const Limits(payload: 12)),
        Kind.invalid,
        'format: history[2][0]: payload: 13 exceeds 12',
      );
      fails(
        load(const Limits(payload: 0)),
        Kind.invalid,
        'format: items: payload: 1 exceeds 0',
      );

      // The same document saved checks the same total.
      final document = load(const Limits()).unwrap();
      Result<Object?> save(Limits limits) =>
          JSONFormat(text, history: true, limits: limits).encode(document);
      expect(save(const Limits(payload: 13)), isA<Success<Object?>>());
      fails(
        save(const Limits(payload: 12)),
        Kind.invalid,
        'format: history[2][0]: payload: 13 exceeds 12',
      );
      fails(
        save(const Limits(payload: 0)),
        Kind.invalid,
        'format: items: payload: 1 exceeds 0',
      );
    });

    test('a short history cannot replay past the items bound', () {
      final json = {
        'libara': 1,
        'items': 'a',
        'markers': <Object?>[],
        'history': [
          for (var version = 0; version < 3; version++)
            [
              {'command': 'insert', 'position': 0, 'items': 'bb'},
            ],
        ],
      };
      expect(
        JSONFormat(text, limits: const Limits(items: 7)).decode(json),
        isA<Success<Object?>>(),
      );
      fails(
        JSONFormat(text, limits: const Limits(items: 4)).decode(json),
        Kind.invalid,
        'format: history[1][0]: items: 5 exceeds 4',
      );
    });
  });
}
