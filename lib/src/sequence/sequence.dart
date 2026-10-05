/// The sequence module: [Result], [Sequence], and its implementations.
library;

import 'result.dart';

export 'items.dart';
export 'result.dart';
export 'text.dart';

/// A finite, ordered, immutable list of items from an alphabet.
///
/// This is the SEQUENCE data type of Core Range Algebra. Every operation
/// returns a new sequence and never modifies the receiver. Immutability
/// covers the sequence, not its items: a mutable item changed after it is
/// stored changes what the sequence holds, and can break equality and
/// hashing.
///
/// Dart generics are covariant, so a `Sequence<int>` can be held as a
/// `Sequence<num>`. Operations that only read their argument ([contains],
/// [diff], [intersect]) accept any item, so they never throw through a wider
/// type. Operations that store their argument in the result ([insert],
/// [concat], [union]) keep the runtime type, and throw a [TypeError] for an
/// item that does not fit it, as Dart's `List` does.
abstract interface class Sequence<T> {
  /// The number of items.
  int get length;

  /// Whether there are no items.
  bool get empty;

  /// The items in order, for iteration and interop.
  Iterable<T> get items;

  /// The item at [position], or `null` when out of bounds.
  T? item(int position);

  /// The item at [position], or a [Kind.bounds] failure when out of bounds.
  ///
  /// Unlike [item], this tells a stored `null` from a missing position.
  Result<T> get(int position);

  /// The first item, or `null` when empty.
  T? get first;

  /// The last item, or `null` when empty.
  T? get last;

  /// Whether some item is equal to [item], which may be of any type.
  bool contains(Object? item);

  /// The sub-sequence of [length] items starting at [start].
  ///
  /// Both bounds are clamped to the sequence, so this never fails.
  Sequence<T> slice(int start, int length);

  /// This sequence followed by [other].
  ///
  /// A [Failure] when an item of [other] is not acceptable to this
  /// sequence, such as an invalid code point for `Text`.
  Result<Sequence<T>> concat(Sequence<T> other);

  /// A copy with [item] inserted at [position].
  ///
  /// [position] may equal [length] to append. Any other position outside
  /// the sequence is a [Kind.bounds] failure.
  Result<Sequence<T>> insert(int position, T item);

  /// A copy without the item at [position].
  ///
  /// A position outside the sequence is a [Kind.bounds] failure.
  Result<Sequence<T>> delete(int position);

  /// The items of this sequence that are not in [other], order and
  /// duplicates preserved. [other] may hold items of any type.
  Sequence<T> diff(Sequence<Object?> other);

  /// This sequence followed by the items of [other] not already present.
  ///
  /// Not commutative: the order of the receiver wins. Fails as [concat]
  /// does.
  Result<Sequence<T>> union(Sequence<T> other);

  /// The items of this sequence that are also in [other], order of the
  /// receiver preserved. [other] may hold items of any type.
  Sequence<T> intersect(Sequence<Object?> other);
}

/// Behaviour shared by every [Sequence] that can be expressed through the
/// interface alone: equality, hashing, and the derived queries.
mixin SequenceBase<T> implements Sequence<T> {
  @override
  bool get empty => length == 0;

  @override
  Result<T> get(int position) => position < 0 || position >= length
      ? Failure.bounds('get', position)
      : Success(item(position) as T);

  @override
  T? get first => item(0);

  @override
  T? get last => item(length - 1);

  @override
  bool contains(Object? item) => items.contains(item);

  /// Whether [other] is a sequence with equal items in the same order.
  ///
  /// The type argument is not compared, so equality is symmetric when one
  /// side is held through a wider type.
  @override
  bool operator ==(Object other) {
    if (other is! Sequence || other.length != length) {
      return false;
    }
    // Walking both in step reads each item once, where looking every
    // position up costs a tree search per item in a persistent document.
    final left = items.iterator;
    final right = other.items.iterator;
    while (left.moveNext()) {
      if (!right.moveNext() || left.current != right.current) {
        return false;
      }
    }
    return !right.moveNext();
  }

  @override
  int get hashCode => Object.hashAll(items);

  @override
  String toString() => items.toString();
}
