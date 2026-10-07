import 'package:libara/src/attributed/arange.dart';
import 'package:libara/src/attributed/attribute.dart';
import 'package:libara/src/attributed/value.dart';
import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

final header = Value.of('header').unwrap();

/// A caller's kind of attributed range, saying by its class what it is.
final class Kept extends ARange {
  Kept(super.range, super.attributes) : super.from();
}

void main() {
  group('A subclass of ARange', () {
    test('equals a plain ARange at its position with its attributes', () {
      final kept = Kept(Range.create(1, 2).unwrap(), {'k': const Num(1)});
      final plain = tagged(1, 2, attributes: {'k': const Num(1)});
      expect(kept, plain);
      expect(plain, kept);
      expect(kept.hashCode, plain.hashCode);
    });

    test('is stored by a document as a plain ARange', () {
      final mark = Mark<int>(Kept(Range.create(0, 1).unwrap(), {}));
      final document = Document.of(Text.of('ab')).apply(mark).unwrap();
      final stored = document.resolve(mark.marker)!;
      expect(stored.runtimeType, ARange);
      expect(stored, mark.range);
    });
  });

  test('create reports a negative start or length as invalid', () {
    expect(ARange.create(-1, 2), invalid);
    expect(ARange.create(0, -1, attributes: {'k': const Num(1)}), invalid);
  });

  test('create keeps the attributes', () {
    expect(
      ARange.create(1, 2, attributes: {'k': const Num(1)}),
      Success(tagged(1, 2, attributes: {'k': const Num(1)})),
    );
  });

  group('ARange attributes', () {
    test('a new range has no attributes by default', () {
      final range = tagged(0, 5);
      expect(range.names, isEmpty);
      expect(range.has('type'), isFalse);
      expect(range.get('type'), isNull);
    });

    test('from copies the position of a range', () {
      final range = ARange.from(span(4, 5), {'type': header});
      expect(range.start, 4);
      expect(range.length, 5);
      expect(range.get('type'), header);
    });

    test('set then get round-trips', () {
      final range = tagged(0, 5).set('type', header);
      expect(range.has('type'), isTrue);
      expect(range.get('type'), header);
    });

    test('set on an existing name replaces the value', () {
      final range = tagged(
        0,
        5,
        attributes: {'type': header},
      ).set('type', Value.of('footer').unwrap());
      expect(range.get('type'), Value.of('footer').unwrap());
      expect(range.names, ['type']);
    });

    test('remove drops the attribute', () {
      final range = tagged(0, 5, attributes: {'type': header}).remove('type');
      expect(range.has('type'), isFalse);
    });

    test('remove of an absent name returns an equal range', () {
      final range = tagged(0, 5, attributes: {'type': header});
      expect(range.remove('label'), range);
    });

    test('a Nil attribute is present, unlike an absent one', () {
      final range = tagged(0, 5, attributes: {'type': const Nil()});
      expect(range.has('type'), isTrue);
      expect(range.get('type'), const Nil());
      expect(range.get('label'), isNull);
    });

    test('names and all list every attribute', () {
      final range = tagged(
        0,
        5,
        attributes: {'type': header, 'label': Value.of('P').unwrap()},
      );
      expect(range.names, unorderedEquals(['type', 'label']));
      expect(
        range.all,
        unorderedEquals([
          Attribute('type', header),
          Attribute('label', Value.of('P').unwrap()),
        ]),
      );
    });

    test('the receiver is unchanged by set and remove', () {
      final range = tagged(0, 5, attributes: {'type': header});
      range.set('label', Value.of('P').unwrap());
      range.set('type', Value.of('footer').unwrap());
      range.remove('type');
      expect(range, tagged(0, 5, attributes: {'type': header}));
    });

    test('the attribute map rejects writes', () {
      final range = tagged(0, 5, attributes: {'type': header});
      expect(() => range.attributes['label'] = header, throwsUnsupportedError);
    });

    test('later changes to the source map have no effect', () {
      final source = {'type': header};
      final range = tagged(0, 5, attributes: source);
      source['label'] = header;
      expect(range.has('label'), isFalse);
    });
  });

  group('ARange equality', () {
    test('equal position and attributes are equal', () {
      final a = tagged(0, 5, attributes: {'type': header});
      final b = tagged(0, 5, attributes: {'type': Value.of('header').unwrap()});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('insertion order of attributes does not matter', () {
      final a = tagged(
        0,
        5,
        attributes: {'type': header, 'label': Value.of('P').unwrap()},
      );
      final b = tagged(
        0,
        5,
        attributes: {'label': Value.of('P').unwrap(), 'type': header},
      );
      expect(a, b);
      expect({a, b}, hasLength(1));
    });

    test('different attributes are not equal but are the same', () {
      final a = tagged(0, 5, attributes: {'type': header});
      final b = tagged(0, 5);
      expect(a, isNot(b));
      expect(a.same(b), isTrue);
      expect(a.same(tagged(0, 5, attributes: {'type': header})), isTrue);
    });

    test('different positions are not equal', () {
      expect(
        tagged(0, 5, attributes: {'type': header}),
        isNot(tagged(1, 5, attributes: {'type': header})),
      );
    });

    test('equality is symmetric across Range and ARange', () {
      final all = [
        span(0, 5),
        tagged(0, 5),
        tagged(0, 5, attributes: {'type': header}),
        tagged(0, 5, attributes: {'type': Value.of('footer').unwrap()}),
        tagged(
          0,
          5,
          attributes: {'type': header, 'label': Value.of('P').unwrap()},
        ),
      ];
      for (final a in all) {
        for (final b in all) {
          expect(a == b, b == a, reason: '$a == $b');
        }
      }
    });

    test('a plain Range never equals an ARange', () {
      expect(span(0, 5), isNot(tagged(0, 5)));
      expect(tagged(0, 5), isNot(span(0, 5)));
      expect(span(0, 5).same(tagged(0, 5)), isTrue);
    });
  });

  group('ARange notation', () {
    test('without attributes it matches Range', () {
      expect(tagged(0, 5).toString(), '{0,5}');
    });

    test('attributes print in name order', () {
      final range = tagged(
        0,
        5,
        attributes: {'type': header, 'label': Value.of('P').unwrap()},
      );
      expect(range.toString(), '{0,5,label:P,type:header}');
    });
  });

  group('ARange move and resize', () {
    final range = tagged(
      4,
      5,
      attributes: {'type': header, 'label': Value.of('P').unwrap()},
    );

    test('move keeps every attribute and returns ARange', () {
      final Result<ARange> moved = range.move(3);
      expect(
        moved,
        Success(
          tagged(
            7,
            5,
            attributes: {'type': header, 'label': Value.of('P').unwrap()},
          ),
        ),
      );
    });

    test('resize keeps every attribute and returns ARange', () {
      final Result<ARange> resized = range.resize(2);
      expect(
        resized,
        Success(
          tagged(
            4,
            7,
            attributes: {'type': header, 'label': Value.of('P').unwrap()},
          ),
        ),
      );
    });

    test('a negative resulting start is the same bounds failure as Range', () {
      expect(range.move(-5), Failure<ARange>.bounds('move', -1));
    });

    test('a negative resulting length is the same bounds failure as Range', () {
      expect(range.resize(-6), Failure<ARange>.bounds('resize', -1));
    });

    test(
      'moving an ARange through a Range reference still keeps attributes',
      () {
        final Range plain = range;
        expect(plain.move(1).or(span(0, 0)), isA<ARange>());
      },
    );
  });
}
