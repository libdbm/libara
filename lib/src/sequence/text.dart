import 'sequence.dart';

/// A [Sequence] of Unicode code points: the STRING type of Attributed Range
/// Algebra.
///
/// Positions count code points, never UTF-16 units. A lone surrogate in the
/// source string is kept as its own code point and round-trips through
/// [toString]. An item outside `0..0x10FFFF` is not a code point, so the
/// operations that add items fail with [Kind.invalid] for one.
final class Text with SequenceBase<int> implements Comparable<Text> {
  Text._(this._points);

  /// The code points of [source].
  Text.of(String source) : this._(Items.of(source.runes));

  final Items<int> _points;

  @override
  int get length => _points.length;

  @override
  Iterable<int> get items => _points.items;

  @override
  int? item(int position) => _points.item(position);

  @override
  Text slice(int start, int length) => Text._(_points.slice(start, length));

  @override
  Result<Text> concat(Sequence<int> other) => _check(
    'concat',
    other.items,
  ).flatMap((_) => _points.concat(other).map(Text._));

  @override
  Result<Text> insert(int position, int item) => _check('insert', [
    item,
  ]).flatMap((_) => _points.insert(position, item).map(Text._));

  @override
  Result<Text> delete(int position) => _points.delete(position).map(Text._);

  @override
  Text diff(Sequence<Object?> other) => Text._(_points.diff(other));

  @override
  Result<Text> union(Sequence<int> other) => _check(
    'union',
    other.items,
  ).flatMap((_) => _points.union(other).map(Text._));

  @override
  Text intersect(Sequence<Object?> other) => Text._(_points.intersect(other));

  /// Orders by code point, as the paper's Compare defines it.
  ///
  /// Returns -1, 0, or 1. When one text is a proper prefix of the other,
  /// the shorter one sorts first.
  int compare(Text other) {
    final shared = length < other.length ? length : other.length;
    for (var position = 0; position < shared; position++) {
      final difference = item(position)! - other.item(position)!;
      if (difference != 0) {
        return difference.sign;
      }
    }
    return (length - other.length).sign;
  }

  @override
  int compareTo(Text other) => compare(other);

  @override
  String toString() => String.fromCharCodes(items);

  /// A [Kind.invalid] failure for the first of [points] that is not a code
  /// point.
  static Result<void> _check(String operation, Iterable<int> points) {
    for (final point in points) {
      if (point < 0 || point > 0x10FFFF) {
        return Failure(Kind.invalid, '$operation: $point is not a code point');
      }
    }
    return const Success(null);
  }
}
