import '../range/range.dart';
import '../sequence/sequence.dart';
import 'command.dart';

/// Commands that turn [from] into [to] when applied in order with
/// `Document.transact`.
///
/// The commands come from a shortest edit script: the common prefix and
/// suffix are trimmed, then Myers' algorithm runs on the rest in linear
/// space. Each changed run of items is one [Replace], or an [Insert] or
/// [Delete] when it only gains or loses items, last run first, so each
/// command's positions are those of [from]. Items compare with `==`.
///
/// A shortest script is ambiguous, so the commands may differ from the
/// edit that was made: deleting one `a` of `aa` reads as deleting the
/// second. Callers with the real commands should use those. Costs
/// `O(n + m + (n' + m') D)` time and `O(n + m)` space for `n` and `m`
/// items, `n'` and `m'` after trimming, and a script of length `D`.
List<Command<T>> edits<T>(Sequence<T> from, Sequence<T> to) {
  final script = _Script<T>(
    from.items.toList(growable: false),
    to.items.toList(growable: false),
  )..walk(0, from.length, 0, to.length);
  return [
    for (final (:start, :end, :first, :last) in script.runs.reversed)
      if (end == start)
        Insert<T>(start, to.slice(first, last - first))
      else if (last == first)
        Delete<T>(extent(start, end - start))
      else
        Replace<T>(extent(start, end - start), to.slice(first, last - first)),
  ];
}

/// A changed run: items `start..end` of the old sequence become items
/// `first..last` of the new one.
typedef _Run = ({int start, int end, int first, int last});

/// A shortest edit script from [before] to [after], built as [runs] in
/// order. The divide and conquer follows Myers' linear space refinement,
/// as diff-match-patch writes it.
final class _Script<T> {
  _Script(this.before, this.after);

  final List<T> before;
  final List<T> after;

  /// The changed runs found so far, in order, adjacent runs merged.
  final List<_Run> runs = [];

  /// Adds the runs that turn `before[start..end]` into `new[first..last]`.
  void walk(int start, int end, int first, int last) {
    var (low, high, lower, upper) = (start, end, first, last);
    while (low < high && lower < upper && before[low] == after[lower]) {
      low++;
      lower++;
    }
    while (low < high &&
        lower < upper &&
        before[high - 1] == after[upper - 1]) {
      high--;
      upper--;
    }
    if (low == high || lower == upper) {
      _add(low, high, lower, upper);
      return;
    }
    switch (_middle(low, high, lower, upper)) {
      case (final x, final y):
        walk(low, x, lower, y);
        walk(x, high, y, upper);
      case null:
        _add(low, high, lower, upper);
    }
  }

  /// Records a run, merging it into the last one when they touch.
  void _add(int start, int end, int first, int last) {
    if (start == end && first == last) {
      return;
    }
    if (runs.isNotEmpty && runs.last.end == start && runs.last.last == first) {
      final previous = runs.removeLast();
      runs.add((
        start: previous.start,
        end: end,
        first: previous.first,
        last: last,
      ));
      return;
    }
    runs.add((start: start, end: end, first: first, last: last));
  }

  /// Where a shortest path from `(start, first)` to `(end, last)` crosses
  /// its middle, found by searching from both ends at once, or `null`
  /// when the two windows share no item. The windows differ in their
  /// first and in their last items.
  (int, int)? _middle(int start, int end, int first, int last) {
    final (width, height) = (end - start, last - first);
    final most = (width + height + 1) ~/ 2;
    final offset = most;
    // Indices reach offset + most, one past the deepest diagonal.
    final size = 2 * most + 2;
    final forward = List.filled(size, -1);
    final backward = List.filled(size, -1);
    forward[offset + 1] = 0;
    backward[offset + 1] = 0;
    final delta = width - height;
    // With an odd delta the forward search meets the backward one, else
    // the backward search meets the forward one.
    final odd = delta.isOdd;
    var (forwardStart, forwardEnd, backwardStart, backwardEnd) = (0, 0, 0, 0);
    for (var depth = 0; depth < most; depth++) {
      for (var k = -depth + forwardStart; k <= depth - forwardEnd; k += 2) {
        final at = offset + k;
        var x = k == -depth || (k != depth && forward[at - 1] < forward[at + 1])
            ? forward[at + 1]
            : forward[at - 1] + 1;
        var y = x - k;
        while (x < width &&
            y < height &&
            before[start + x] == after[first + y]) {
          x++;
          y++;
        }
        forward[at] = x;
        if (x > width) {
          forwardEnd += 2;
        } else if (y > height) {
          forwardStart += 2;
        } else if (odd) {
          final other = offset + delta - k;
          if (other >= 0 && other < size && backward[other] != -1) {
            if (x >= width - backward[other]) {
              return (start + x, first + y);
            }
          }
        }
      }
      for (var k = -depth + backwardStart; k <= depth - backwardEnd; k += 2) {
        final at = offset + k;
        var x =
            k == -depth || (k != depth && backward[at - 1] < backward[at + 1])
            ? backward[at + 1]
            : backward[at - 1] + 1;
        var y = x - k;
        while (x < width &&
            y < height &&
            before[end - 1 - x] == after[last - 1 - y]) {
          x++;
          y++;
        }
        backward[at] = x;
        if (x > width) {
          backwardEnd += 2;
        } else if (y > height) {
          backwardStart += 2;
        } else if (!odd) {
          final other = offset + delta - k;
          if (other >= 0 && other < size && forward[other] != -1) {
            final across = forward[other];
            if (across >= width - x) {
              return (start + across, first + offset + across - other);
            }
          }
        }
      }
    }
    return null;
  }
}
