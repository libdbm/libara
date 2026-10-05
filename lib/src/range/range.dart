/// The range module: [Range] and sequences of ranges.
library;

import '../sequence/sequence.dart';

export 'hierarchy.dart';
export 'ranges.dart';

/// A contiguous span of a [Sequence], identified by start position and
/// length: the RANGE data type of Core Range Algebra.
///
/// A range knows nothing about the items it spans. [end] is exclusive, so
/// `end - start == length`, and a zero-length range is allowed.
///
/// Ranges are made with [create], which checks its input, so a range never
/// holds a negative start or length. The constructor takes no arguments, so
/// a subclass supplies [start] and [length] itself.
abstract base class Range {
  /// For subclasses, which supply [start] and [length].
  const Range();

  /// A range of [length] items starting at [start]: a [Kind.invalid]
  /// failure for a negative [start] or [length], or for an end past the
  /// largest integer, where `start + length` would wrap.
  static Result<Range> create(int start, int length) {
    if (start < 0) {
      return Failure(Kind.invalid, 'range: start $start is negative');
    }
    if (length < 0) {
      return Failure(Kind.invalid, 'range: length $length is negative');
    }
    if (start + length < start) {
      return Failure(Kind.invalid, 'range: $start + $length overflows');
    }
    return Success(_Span(start, length));
  }

  /// The position of the first item.
  int get start;

  /// The number of items spanned.
  int get length;

  /// The position one past the last item.
  int get end => start + length;

  /// Whether this range starts before [other] starts.
  bool startsBefore(Range other) => start < other.start;

  /// Whether this range starts after [other] starts.
  bool startsAfter(Range other) => start > other.start;

  /// Whether the start of this range lies inside [other].
  bool startsWithin(Range other) => start >= other.start && start < other.end;

  /// Whether this range ends at or before the start of [other].
  bool endsBefore(Range other) => end <= other.start;

  /// Whether this range ends after [other] ends.
  bool endsAfter(Range other) => end > other.end;

  /// Whether the end of this range lies inside [other], its last position
  /// included.
  bool endsWithin(Range other) => end > other.start && end <= other.end;

  /// Whether this range lies entirely inside [other].
  ///
  /// The paper's prose for Within says "a contains b", but its formula tests
  /// a inside b. This follows the formula; [contains] is the converse.
  bool within(Range other) => start >= other.start && end <= other.end;

  /// Whether [other] lies entirely inside this range.
  bool contains(Range other) => other.within(this);

  /// Whether this range and [other] share at least one position.
  ///
  /// Follows the formula `start < other.end && other.start < end`, so a
  /// zero-length range strictly inside [other] overlaps it, and one at
  /// either boundary does not.
  bool overlaps(Range other) => start < other.end && other.start < end;

  /// Whether this range has the same start and length as [other]: the
  /// paper's Same.
  bool same(Range other) => start == other.start && length == other.length;

  /// This range moved by [delta] positions: the paper's Move.
  ///
  /// A negative resulting start, or a start or end that would wrap past
  /// the largest integer, is a [Kind.bounds] failure.
  Result<Range> move(int delta) {
    final moved = start + delta;
    if (moved < 0) {
      return Failure.bounds('move', moved);
    }
    if (delta > 0 && (moved < start || moved + length < moved)) {
      return Failure(Kind.bounds, 'move: $this by $delta overflows');
    }
    return Success(_Span(moved, length));
  }

  /// This range with its length changed by [delta]: the paper's Resize.
  ///
  /// A negative resulting length, or a length or end that would wrap past
  /// the largest integer, is a [Kind.bounds] failure.
  Result<Range> resize(int delta) {
    final resized = length + delta;
    if (resized < 0) {
      return Failure.bounds('resize', resized);
    }
    if (delta > 0 && (resized < length || start + resized < start)) {
      return Failure(Kind.bounds, 'resize: $this by $delta overflows');
    }
    return Success(_Span(start, resized));
  }

  /// The items of [from] spanned by this range: the paper's Flatten.
  ///
  /// Clamped to [from], so this never fails.
  Sequence<T> extract<T>(Sequence<T> from) => from.slice(start, length);

  /// Whether [other] is a range of the same runtime type, start, and
  /// length.
  ///
  /// Requiring the same runtime type keeps equality symmetric with
  /// subclasses that compare more fields. Use [same] to compare positions
  /// regardless of type.
  @override
  bool operator ==(Object other) =>
      other is Range &&
      other.runtimeType == runtimeType &&
      other.start == start &&
      other.length == length;

  @override
  int get hashCode => Object.hash(start, length);

  /// The paper's notation, for example `{4,5}`.
  @override
  String toString() => '{$start,$length}';
}

/// A plain range.
final class _Span extends Range {
  const _Span(this.start, this.length);

  @override
  final int start;

  @override
  final int length;
}

/// The range of [length] items from [start], without checking them.
///
/// For library code whose values are non-negative by construction. Hidden
/// from the public `libara` library; everything else uses [Range.create].
Range extent(int start, int length) => _Span(start, length);

/// The first position of [range] outside `0..limit`, or `null` when it fits.
///
/// Checked without adding, so neither an extreme length nor a subclass
/// that breaks the invariant can pass by wrapping its end. For library
/// code; hidden from the public `libara` library.
int? outside(Range range, int limit) {
  final Range(:start, :length) = range;
  if (start < 0 || start > limit || length < 0) {
    return start;
  }
  if (length > limit - start) {
    final end = range.end;
    return end > limit ? end : limit + 1;
  }
  return null;
}
