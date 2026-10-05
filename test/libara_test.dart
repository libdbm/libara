import 'dart:convert';

import 'package:libara/libara.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('the public entry point exposes every sequence module type', () {
    final Sequence<int> items = Items.of([0x61]);
    final Sequence<int> text = Text.of('a');
    final Result<Sequence<int>> result = items.delete(5);
    expect(text, items);
    expect(result, isA<Failure<Sequence<int>>>());
    expect((result as Failure).kind, Kind.bounds);
    expect(Success(1).value, 1);
  });

  test('the public entry point exposes every range module type', () {
    final ranges = Ranges.of([span(0, 4), span(1, 2)]);
    expect(ranges.parent(span(1, 2)), span(0, 4));
    expect(span(1, 2).extract(Text.of('abcd')), Text.of('bc'));
  });

  test('the public entry point exposes every attributed module type', () {
    final range = tagged(
      0,
      5,
      attributes: {'type': Value.of('header').unwrap()},
    );
    final Value value = range.get('type')!;
    expect(value, isA<Str>());
    expect(range.all, [Attribute('type', Str(Text.of('header')))]);
    expect([Num(1), Bool(true), const Nil()], hasLength(3));
  });

  test('the public entry point exposes the persistent module', () {
    final mark = Mark<int>(tagged(0, 1), start: Gravity.left);
    expect(mark.end, Gravity.right);
    final commands = <Command<int>>[
      Insert(0, Text.of('ab')),
      mark,
      Delete(span(1, 1)),
      Unmark(mark.marker),
    ];
    var document = Document<int>.empty();
    for (final command in commands) {
      document = document.apply(command).or(document);
    }
    final Marker marker = mark.marker;
    expect(document.resolve(marker), isNull);
    expect(document.version, 4);
    expect(String.fromCharCodes(document.items), 'a');
  });

  test('the public entry point exposes the constructor module', () {
    final Constructor<int> words = regex(RegExp('[a-z]+'));
    final Constructor<int> both = union([
      words,
      concat([words]),
    ]);
    final counted = layer(both, (lower) => Ranges.of([span(0, lower.length)]));
    expect(both(Text.of('ab cd')).or(Ranges.empty()).length, 2);
    expect(counted(Text.of('ab cd')), Success(Ranges.of([span(0, 2)])));
  });

  test('the barrel imports alongside dart:convert without hiding names', () {
    // Both libraries in one file: Format does not collide with Codec.
    final document = (Document.of(Text.of('ab')).apply(
      Mark<int>((ARange.create(0, 1) as Success<ARange>).value),
    ) as Success<Document<int>>).value;
    final json = jsonEncode(
      (JSONFormat(text).encode(document) as Success<Object?>).value,
    );
    final decoded = JSONFormat(text).decode(jsonDecode(json));
    expect((decoded as Success<Document<int>>).value.ranges, document.ranges);
  });

  test('the public entry point exposes the selector module', () {
    final selector = Selector.parse('p[lang="en"]').unwrap();
    final scope = [
      (1, tagged(0, 1, attributes: {'name': Str(Text.of('p'))})),
      (
        2,
        tagged(
          0,
          1,
          attributes: {'name': Str(Text.of('p')), 'lang': Str(Text.of('en'))},
        ),
      ),
    ];
    expect([for (final (key, _) in selector.select(scope)) key], [2]);
  });

  test('the public entry point exposes the replica module', () {
    final (replica, operation) = Replica.create<int>('a')
        .unwrap()
        .commit([Insert(0, Text.of('a'))])
        .unwrap();
    final Stamp stamp = operation.stamp;
    expect(replica.heads, [stamp]);
    expect(Key(stamp, 0).toString(), '$stamp#0');
    final json = const OperationFormat(text).encode(operation).unwrap();
    final back = const OperationFormat(text)
        .decode(jsonDecode(jsonEncode(json)))
        .unwrap();
    expect(back.same(operation), isTrue);
    expect(edits(Text.of('ab'), Text.of('b')), hasLength(1));
  });

  test('the public entry point exposes the coordinate module', () {
    final coordinates = Coordinates.of(Text.of('a😀\nb'));
    final Unit unit = coordinates.unit(2).unwrap();
    expect(unit, const Unit(3));
    expect(
      coordinates.place(3, columns: Columns.points).unwrap(),
      const Place(1, 0),
    );
  });

  test('the public entry point exposes graphemes and prepared scopes', () {
    final coordinates = Coordinates.of(Text.of('e\u0301!'));
    expect(coordinates.next(0).unwrap(), 2);
    expect(coordinates.graphemes, 2);
    final Range widened = coordinates.snap(span(1, 1)).unwrap();
    expect(widened, span(0, 2));
    final scope = Scope([
      (1, tagged(0, 1, attributes: {'name': Str(Text.of('p'))})),
    ]);
    expect(scope.select(Selector.parse('p').unwrap()), hasLength(1));
  });
}
