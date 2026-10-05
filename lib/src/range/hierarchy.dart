import 'range.dart';

/// The parent of each range of a list, as `Ranges.parent` defines it, and
/// each range's place among its siblings, built in `O(m log m)` for `m`
/// ranges. Used by `Ranges.children` and the selector module; not part of
/// the public API.
///
/// The ranges are swept in start order, longest first at equal starts.
/// Every range swept before one starts at or before it, so its parent is
/// the latest swept range that ends at or after it and is not at the same
/// position: a later one has the greater start, or the same start and the
/// smaller length. A stack keeps the swept ranges that can still be that,
/// their ends decreasing upwards, since a range under one that ends no
/// earlier is never the latest to cover anything; the parent is found by
/// binary search. Ranges at one position have the same parent, and the
/// first of them in the list stands for them all, as `Ranges.parent`
/// returns the first of equal candidates.
final class Hierarchy {
  Hierarchy._(this.order, this.parents, this.places, this.sizes, this.previous);

  /// The hierarchy of [ranges].
  factory Hierarchy(List<Range> ranges) {
    final count = ranges.length;
    final order = List.generate(count, (index) => index)
      ..sort((a, b) {
        final (x, y) = (ranges[a], ranges[b]);
        final by = x.start != y.start ? x.start - y.start : y.length - x.length;
        return by != 0 ? by : a - b;
      });
    final parents = List<int>.filled(count, -1);
    final stack = <int>[];
    for (final index in order) {
      final range = ranges[index];
      if (stack.isNotEmpty && ranges[stack.last].same(range)) {
        parents[index] = parents[stack.last];
        continue;
      }
      // The topmost range on the stack ending at or after this one.
      var (low, high) = (0, stack.length);
      while (low < high) {
        final middle = (low + high) ~/ 2;
        if (ranges[stack[middle]].end >= range.end) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      parents[index] = low == 0 ? -1 : stack[low - 1];
      while (stack.isNotEmpty && ranges[stack.last].end <= range.end) {
        stack.removeLast();
      }
      stack.add(index);
    }
    // Places among siblings, in list order; the roots are one group.
    final sizes = <int, int>{};
    final places = [
      for (final parent in parents) sizes[parent] = (sizes[parent] ?? 0) + 1,
    ];
    final latest = <int, int>{};
    final previous = [
      for (final (index, parent) in parents.indexed)
        switch (latest[parent]) {
          final before => () {
            latest[parent] = index;
            return before ?? -1;
          }(),
        },
    ];
    return Hierarchy._(List.unmodifiable(order), parents, places, [
      for (final parent in parents) sizes[parent]!,
    ], previous);
  }

  /// The indices of the ranges in start order, longest first at equal
  /// starts, then in list order.
  final List<int> order;

  /// For each range, the index of its parent in the list, or -1.
  final List<int> parents;

  /// For each range, its place among its siblings, from 1.
  final List<int> places;

  /// For each range, how many siblings it has, itself included.
  final List<int> sizes;

  /// For each range, the index of its sibling just before it, or -1.
  final List<int> previous;
}
