import 'sequence.dart';

/// The reference [Sequence] implementation, backed by an unmodifiable list.
///
/// With n items here and u in the other sequence: [length] and [item] are
/// O(1); [slice] of k items is O(k); [insert], [delete], and [contains] are
/// O(n); [concat] is O(n + u); [union] is expected O(n + u), as it hashes
/// items; [diff] and [intersect] are expected O(n + u), as they hash the
/// other sequence's items. The persistent module provides the efficient implementation
/// for editing.
final class Items<T> with SequenceBase<T> {
  Items._(this._list);

  /// A sequence holding a copy of [source] in iteration order.
  Items.of(Iterable<T> source) : this._(List.unmodifiable(source));

  /// A sequence with no items.
  Items.empty() : this._(List.unmodifiable(<T>[]));

  final List<T> _list;

  @override
  int get length => _list.length;

  @override
  Iterable<T> get items => _list;

  @override
  T? item(int position) =>
      position < 0 || position >= _list.length ? null : _list[position];

  @override
  Items<T> slice(int start, int length) {
    final from = start.clamp(0, _list.length);
    // Clamped before adding, so a huge length cannot wrap.
    final to = from + length.clamp(0, _list.length - from);
    return Items.of(_list.getRange(from, to));
  }

  @override
  Result<Items<T>> concat(Sequence<T> other) =>
      Success(Items.of(_list.followedBy(other.items)));

  @override
  Result<Items<T>> insert(int position, T item) {
    if (position < 0 || position > _list.length) {
      return Failure.bounds('insert', position);
    }
    return Success(Items.of([..._list]..insert(position, item)));
  }

  @override
  Result<Items<T>> delete(int position) {
    if (position < 0 || position >= _list.length) {
      return Failure.bounds('delete', position);
    }
    return Success(Items.of([..._list]..removeAt(position)));
  }

  @override
  Items<T> diff(Sequence<Object?> other) {
    final members = other.items.toSet();
    return Items.of(_list.where((item) => !members.contains(item)));
  }

  @override
  Result<Items<T>> union(Sequence<T> other) {
    final seen = Set<T>.of(_list);
    return Success(Items.of(_list.followedBy(other.items.where(seen.add))));
  }

  @override
  Items<T> intersect(Sequence<Object?> other) {
    final members = other.items.toSet();
    return Items.of(_list.where(members.contains));
  }
}
