import 'package:libara/src/attributed/attribute.dart';
import 'package:libara/src/attributed/value.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

void main() {
  group('Value cases', () {
    test('Str compares its text by code points', () {
      expect(Str(Text.of('header')), Str(Text.of('header')));
      expect(Str(Text.of('header')), isNot(Str(Text.of('Header'))));
      expect(Str(Text.of('header')).hashCode, Str(Text.of('header')).hashCode);
    });

    test('Num compares by value', () {
      expect(Num(5), Num(5));
      expect(Num(5), isNot(Num(6)));
      expect(Num(5).hashCode, Num(5).hashCode);
    });

    test('Bool compares by value', () {
      expect(Bool(true), Bool(true));
      expect(Bool(true), isNot(Bool(false)));
      expect(Bool(true).hashCode, Bool(true).hashCode);
    });

    test('Nil equals Nil', () {
      expect(const Nil(), const Nil());
      expect(const Nil().hashCode, const Nil().hashCode);
    });

    test('different cases are never equal', () {
      expect(Num(1), isNot(Bool(true)));
      expect(Str(Text.of('5')), isNot(Num(5)));
      expect(const Nil(), isNot(Num(0)));
    });

    test('toString uses the paper notation', () {
      expect(Str(Text.of('header')).toString(), 'header');
      expect(Num(5).toString(), '5');
      expect(Bool(true).toString(), 'true');
      expect(const Nil().toString(), 'null');
    });
  });

  group('Value.of', () {
    test('converts the supported Dart values', () {
      expect(Value.of('header'), Success<Value>(Str(Text.of('header'))));
      expect(Value.of(5), Success<Value>(Num(5)));
      expect(Value.of(false), Success<Value>(Bool(false)));
      expect(Value.of(null), Success<Value>(const Nil()));
    });

    test('rejects a double', () {
      expect(Value.of(1.5), invalid);
    });

    test('rejects a list', () {
      expect(Value.of([1]), invalid);
    });
  });

  group('Attribute', () {
    test('equality is by name and value', () {
      expect(
        Attribute('type', Value.of('header').unwrap()),
        Attribute('type', Value.of('header').unwrap()),
      );
      expect(
        Attribute('type', Value.of('header').unwrap()),
        isNot(Attribute('kind', Value.of('header').unwrap())),
      );
      expect(
        Attribute('type', Value.of('header').unwrap()),
        isNot(Attribute('type', Value.of('footer').unwrap())),
      );
      expect(
        Attribute('type', Value.of('header').unwrap()).hashCode,
        Attribute('type', Value.of('header').unwrap()).hashCode,
      );
    });

    test('same is identity', () {
      final attribute = Attribute('type', Value.of('header').unwrap());
      final copy = Attribute('type', Value.of('header').unwrap());
      expect(attribute.same(attribute), isTrue);
      expect(attribute.same(copy), isFalse);
      expect(attribute == copy, isTrue);
    });

    test('toString uses the paper notation', () {
      expect(
        Attribute('type', Value.of('header').unwrap()).toString(),
        'type:header',
      );
    });
  });
}
