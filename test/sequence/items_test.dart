import 'package:libara/src/sequence/items.dart';
import 'package:libara/src/sequence/result.dart';
import 'package:test/test.dart';

void main() {
  group('Items query operations', () {
    test('empty has length zero and reports empty', () {
      final items = Items<int>.empty();
      expect(items.length, 0);
      expect(items.empty, isTrue);
    });

    test('of preserves order and length', () {
      final items = Items.of([3, 1, 2]);
      expect(items.length, 3);
      expect(items.empty, isFalse);
      expect(items.items, [3, 1, 2]);
    });

    test('item returns the element at a position', () {
      final items = Items.of([3, 1, 2]);
      expect(items.item(0), 3);
      expect(items.item(2), 2);
    });

    test('item is null out of bounds', () {
      final items = Items.of([3, 1, 2]);
      expect(items.item(3), isNull);
      expect(items.item(-1), isNull);
    });

    test('first and last on a populated sequence', () {
      final items = Items.of([3, 1, 2]);
      expect(items.first, 3);
      expect(items.last, 2);
    });

    test('first and last are null on empty', () {
      final items = Items<int>.empty();
      expect(items.first, isNull);
      expect(items.last, isNull);
    });

    test('contains uses equality', () {
      final items = Items.of(['a', 'b']);
      expect(items.contains('b'), isTrue);
      expect(items.contains('c'), isFalse);
    });

    test('slice returns the sub-sequence', () {
      final items = Items.of([0, 1, 2, 3, 4]);
      expect(items.slice(1, 3), Items.of([1, 2, 3]));
    });

    test('slice clamps a length past the end', () {
      final items = Items.of([0, 1, 2]);
      expect(items.slice(2, 10), Items.of([2]));
    });

    test('slice past the end is empty', () {
      final items = Items.of([0, 1, 2]);
      expect(items.slice(5, 1), Items<int>.empty());
    });

    test('slice with a negative start clamps to zero', () {
      final items = Items.of([0, 1, 2]);
      expect(items.slice(-2, 2), Items.of([0, 1]));
    });

    test('a slice cannot be changed through its items', () {
      final slice = Items.of([1, 2, 3]).slice(0, 2);
      final list = slice.items as List<int>;
      expect(() => list[0] = 99, throwsUnsupportedError);
      expect(() => list.add(4), throwsUnsupportedError);
      expect(() => list.removeLast(), throwsUnsupportedError);
      expect(slice, Items.of([1, 2]));
    });

    test('equality is pairwise and length based', () {
      expect(Items.of([1, 2]), Items.of([1, 2]));
      expect(Items.of([1, 2]), isNot(Items.of([2, 1])));
      expect(Items.of([1, 2]), isNot(Items.of([1, 2, 3])));
      expect(Items<int>.empty(), Items<int>.empty());
    });

    test('hashCode agrees with equality', () {
      expect(Items.of([1, 2]).hashCode, Items.of([1, 2]).hashCode);
    });

    test('of copies its input so later mutation has no effect', () {
      final source = [1, 2];
      final items = Items.of(source);
      source.add(3);
      expect(items.length, 2);
    });
  });

  group('Items edit operations', () {
    test('concat joins in order', () {
      expect(
        Items.of([1, 2]).concat(Items.of([3])),
        Success(Items.of([1, 2, 3])),
      );
    });

    test('concat with empty on either side is unchanged', () {
      expect(Items.of([1]).concat(Items<int>.empty()), Success(Items.of([1])));
      expect(Items<int>.empty().concat(Items.of([1])), Success(Items.of([1])));
    });

    test('insert places the item at the position', () {
      expect(Items.of([1, 3]).insert(1, 2), Success(Items.of([1, 2, 3])));
    });

    test('insert at zero prepends', () {
      expect(Items.of([2]).insert(0, 1), Success(Items.of([1, 2])));
    });

    test('insert at length appends', () {
      expect(Items.of([1, 2]).insert(2, 3), Success(Items.of([1, 2, 3])));
    });

    test('insert past length is a bounds failure', () {
      expect(
        Items.of([1, 2]).insert(3, 9),
        Failure<Items<int>>.bounds('insert', 3),
      );
    });

    test('insert at a negative position is a bounds failure', () {
      expect(
        Items.of([1, 2]).insert(-1, 9),
        Failure<Items<int>>.bounds('insert', -1),
      );
    });

    test('delete removes the item at the position', () {
      expect(Items.of([1, 2, 3]).delete(1), Success(Items.of([1, 3])));
    });

    test('delete the only item yields empty', () {
      expect(Items.of([1]).delete(0), Success(Items<int>.empty()));
    });

    test('delete at length is a bounds failure', () {
      expect(
        Items.of([1, 2]).delete(2),
        Failure<Items<int>>.bounds('delete', 2),
      );
    });

    test('delete on empty is a bounds failure', () {
      expect(
        Items<int>.empty().delete(0),
        Failure<Items<int>>.bounds('delete', 0),
      );
    });

    test('the receiver is unchanged by every edit', () {
      final items = Items.of([1, 2, 3]);
      final before = Items.of([1, 2, 3]);
      items.concat(Items.of([4]));
      items.insert(0, 0);
      items.delete(0);
      expect(items, before);
    });
  });

  group('Items set operations', () {
    test('diff keeps items not in other, order and duplicates preserved', () {
      expect(Items.of([1, 2, 2, 3]).diff(Items.of([2])), Items.of([1, 3]));
      expect(Items.of([1, 1, 3]).diff(Items.of([2])), Items.of([1, 1, 3]));
    });

    test('diff with empty on either side', () {
      expect(Items.of([1, 2]).diff(Items<int>.empty()), Items.of([1, 2]));
      expect(Items<int>.empty().diff(Items.of([1])), Items<int>.empty());
    });

    test('union appends items of other not already present', () {
      expect(
        Items.of([1, 2]).union(Items.of([2, 3, 1])),
        Success(Items.of([1, 2, 3])),
      );
    });

    test('union adds a repeated item from other only once', () {
      expect(Items.of([1]).union(Items.of([2, 2])), Success(Items.of([1, 2])));
    });

    test('union keeps duplicates already in the receiver', () {
      expect(
        Items.of([1, 1]).union(Items.of([2])),
        Success(Items.of([1, 1, 2])),
      );
    });

    test('union is not commutative', () {
      final a = Items.of([1, 2]);
      final b = Items.of([2, 1]);
      expect(a.union(b), isNot(b.union(a)));
    });

    test('union with empty on either side', () {
      expect(Items.of([1]).union(Items<int>.empty()), Success(Items.of([1])));
      expect(Items<int>.empty().union(Items.of([1])), Success(Items.of([1])));
    });

    test('intersect keeps items also in other, receiver order preserved', () {
      expect(Items.of([3, 1, 2]).intersect(Items.of([2, 3])), Items.of([3, 2]));
    });

    test('intersect keeps duplicates in the receiver', () {
      expect(
        Items.of([2, 1, 2, 3]).intersect(Items.of([2, 3, 3])),
        Items.of([2, 2, 3]),
      );
    });

    test('an int matches an equal double in other', () {
      final doubles = Items<num>.of([1.0, 2.5]);
      expect(Items.of([1, 2]).intersect(doubles), Items.of([1]));
      expect(Items.of([1, 2]).diff(doubles), Items.of([2]));
    });

    test('intersect with empty on either side is empty', () {
      expect(Items.of([1]).intersect(Items<int>.empty()), Items<int>.empty());
      expect(Items<int>.empty().intersect(Items.of([1])), Items<int>.empty());
    });
  });
}
