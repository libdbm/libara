import '../sequence/sequence.dart';
import 'range.dart';

/// The first range at a position and the ranges whose parent it is.
typedef _Family = ({Range first, List<Range> children});

/// A [Sequence] of [Range]s, with the Core Range Algebra operations that
/// order ranges and infer structure from how they contain one another.
final class Ranges with SequenceBase<Range> {
  Ranges._(this._ranges);

  /// A sequence holding [source] in iteration order.
  Ranges.of(Iterable<Range> source) : this._(Items.of(source));

  /// A sequence with no ranges.
  Ranges.empty() : this._(Items.empty());

  final Items<Range> _ranges;

  @override
  int get length => _ranges.length;

  @override
  Iterable<Range> get items => _ranges.items;

  @override
  Range? item(int position) => _ranges.item(position);

  @override
  Ranges slice(int start, int length) => Ranges._(_ranges.slice(start, length));

  @override
  Result<Ranges> concat(Sequence<Range> other) =>
      _ranges.concat(other).map(Ranges._);

  @override
  Result<Ranges> insert(int position, Range item) =>
      _ranges.insert(position, item).map(Ranges._);

  @override
  Result<Ranges> delete(int position) => _ranges.delete(position).map(Ranges._);

  @override
  Ranges diff(Sequence<Object?> other) => Ranges._(_ranges.diff(other));

  @override
  Result<Ranges> union(Sequence<Range> other) =>
      _ranges.union(other).map(Ranges._);

  @override
  Ranges intersect(Sequence<Object?> other) =>
      Ranges._(_ranges.intersect(other));

  /// Ascending by start, ties by ascending length: the paper's StartOrder.
  ///
  /// Stable, so ranges with equal start and length keep their order.
  Ranges startOrder() => _sort(
    (a, b) => a.start != b.start ? a.start - b.start : a.length - b.length,
  );

  /// Ascending by end, ties by ascending length: the paper's EndOrder.
  ///
  /// Stable, so ranges with equal end and length keep their order.
  Ranges endOrder() =>
      _sort((a, b) => a.end != b.end ? a.end - b.end : a.length - b.length);

  /// The first occurrence of each distinct range, in order: the paper's
  /// Unique.
  Ranges unique() => Ranges.of(items.toSet());

  /// Every range that contains [range] and is not the same as it, in
  /// sequence order: the paper's Ancestor.
  Ranges ancestors(Range range) => Ranges.of(
    items.where((item) => item.contains(range) && !item.same(range)),
  );

  /// Every range inside [range] and not the same as it, in sequence order:
  /// the paper's Descendant.
  Ranges descendants(Range range) =>
      Ranges.of(items.where((item) => item.within(range) && !item.same(range)));

  /// The innermost ancestor of [range], or `null` when it has none: the
  /// paper's Parent.
  ///
  /// The ancestor with the greatest start wins. Ancestors sharing that
  /// start are broken by the smallest length.
  Range? parent(Range range) {
    Range? best;
    for (final item in items) {
      if (!item.contains(range) || item.same(range)) {
        continue;
      }
      if (best == null ||
          item.start > best.start ||
          item.start == best.start && item.length < best.length) {
        best = item;
      }
    }
    return best;
  }

  /// Every range whose [parent] in this sequence is [range], in sequence
  /// order: the paper's Child.
  ///
  /// The paper's Child returns a single range; this returns all of them, as
  /// the paper's prose describes. The first call indexes the sequence's
  /// hierarchy in O(m log m) for `m` ranges; each call then costs O(1 + k)
  /// for `k` children, so walking a whole tree is O(m log m).
  Ranges children(Range range) {
    final entry = _children[(range.start, range.length)];
    // [parent] returns the first range at a position, so only it has
    // children there.
    return entry != null && entry.first == range
        ? Ranges.of(entry.children)
        : Ranges.empty();
  }

  /// For each position holding a range, the first range there and the
  /// ranges whose [parent] it is, in sequence order.
  late final Map<(int, int), _Family> _children = _families();

  /// Builds [_children] from the sequence's [Hierarchy].
  Map<(int, int), _Family> _families() {
    final list = items.toList();
    final parents = Hierarchy(list).parents;
    final families = <(int, int), _Family>{};
    for (final item in list) {
      final position = (item.start, item.length);
      families.putIfAbsent(position, () => (first: item, children: []));
    }
    for (final (index, parent) in parents.indexed) {
      if (parent >= 0) {
        final above = list[parent];
        families[(above.start, above.length)]!.children.add(list[index]);
      }
    }
    return families;
  }

  /// A stable sort. Dart's [List.sort] is not guaranteed stable, so ties
  /// are broken by original position.
  Ranges _sort(int Function(Range a, Range b) compare) {
    // Ranges a grammar reads come in order, and a stable sort leaves
    // ranges in order as they are, so a look saves the sorting.
    final list = items.toList();
    var ordered = true;
    for (var at = 1; at < list.length && ordered; at++) {
      ordered = compare(list[at - 1], list[at]) <= 0;
    }
    if (ordered) {
      return Ranges.of(list);
    }
    final indexed = items.indexed.toList()
      ..sort((a, b) {
        final order = compare(a.$2, b.$2);
        return order != 0 ? order : a.$1 - b.$1;
      });
    return Ranges.of(indexed.map((pair) => pair.$2));
  }
}
