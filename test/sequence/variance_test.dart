import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

/// Every test holds a sequence of `int` through the wider static type
/// `Sequence<num>`, which Dart allows because generics are covariant.
void main() {
  group('read-only operations accept any item', () {
    test('contains a value of the wider type', () {
      final Sequence<num> items = Items<int>.of([1, 2]);
      expect(items.contains(1.5), isFalse);
      expect(items.contains(2), isTrue);
    });

    test('diff against a sequence of the wider type', () {
      final Sequence<num> items = Items<int>.of([1, 2]);
      expect(items.diff(Items<num>.of([2, 1.5])), Items<int>.of([1]));
    });

    test('intersect with a sequence of the wider type', () {
      final Sequence<num> items = Items<int>.of([1, 2]);
      expect(items.intersect(Items<num>.of([2, 1.5])), Items<int>.of([2]));
    });

    test('Text accepts the same wider arguments', () {
      final Sequence<Object> text = Text.of('ab');
      expect(text.contains('a'), isFalse);
      expect(text.diff(Items<Object>.of([0x61, 'x'])), Text.of('b'));
      expect(text.intersect(Items<Object>.of([0x61, 'x'])), Text.of('a'));
    });
  });

  group('equality ignores the type argument', () {
    test('sequences with equal items are equal in both directions', () {
      expect(Items<int>.of([1]) == Items<num>.of([1]), isTrue);
      expect(Items<num>.of([1]) == Items<int>.of([1]), isTrue);
    });

    test('empty sequences of different types are equal', () {
      final Sequence<Object> numbers = Items<int>.empty();
      final Sequence<Object> words = Items<String>.empty();
      expect(numbers == words, isTrue);
      expect(words == numbers, isTrue);
    });

    test('Success values are equal in both directions', () {
      expect(Success<int>(1) == Success<num>(1), isTrue);
      expect(Success<num>(1) == Success<int>(1), isTrue);
    });
  });

  group('operations that store their argument keep the runtime type', () {
    // Storing a double in a sequence of int would be unsound, so these throw
    // a TypeError, as Dart's List does. This pins that decision.
    test('insert of a wider value throws', () {
      final Sequence<num> items = Items<int>.of([1]);
      expect(() => items.insert(0, 1.5), throwsA(isA<TypeError>()));
    });

    test('concat with a wider sequence throws', () {
      final Sequence<num> items = Items<int>.of([1]);
      expect(
        () => items.concat(Items<num>.of([1.5])),
        throwsA(isA<TypeError>()),
      );
    });

    test('union with a wider sequence throws', () {
      final Sequence<num> items = Items<int>.of([1]);
      expect(
        () => items.union(Items<num>.of([1.5])),
        throwsA(isA<TypeError>()),
      );
    });

    test('insert of a value of the runtime type works', () {
      final Sequence<num> items = Items<int>.of([1]);
      expect(items.insert(0, 0), Success(Items<int>.of([0, 1])));
    });
  });
}
