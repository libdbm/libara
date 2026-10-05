import 'dart:math';

import '../range/range.dart';
import '../sequence/sequence.dart';
import 'priority.dart' as priorities;
import 'treap.dart';

/// The largest number of items a node created by [Content.of] holds.
const _chunk = 64;

/// A persistent sequence of items: a treap whose nodes hold chunks of items
/// and the item count of their subtree.
///
/// Every edit is a split and a join, which copies one path of nodes and
/// shares the rest, so earlier versions stay valid and unchanged.
final class Content<T> {
  const Content._(this._root);

  /// Content with no items.
  const Content.empty() : this._(null);

  /// Content holding [source] in iteration order.
  factory Content.of(Iterable<T> source) {
    final list = source.toList();
    _Node<T>? root;
    for (var start = 0; start < list.length; start += _chunk) {
      final end = min(start + _chunk, list.length);
      root = join(root, _Node.leaf(list.sublist(start, end)));
    }
    return Content._(root);
  }

  final _Node<T>? _root;

  /// The number of items.
  int get length => _root?.size ?? 0;

  /// The number of tree nodes, each holding one chunk of items.
  int get nodes => _count(_root);

  /// The items in order.
  Iterable<T> get items => _walk(_root);

  /// Whether the tree keeps its invariants: every node holds at least one
  /// item and no node outranks its parent. A [Kind.invalid] failure names
  /// the first that does not.
  Result<void> check() => _filled(_root)
      ? heap(_root, 'content')
      : const Failure(Kind.invalid, 'content: a node holds no items');

  /// The item at [position], or `null` when out of bounds.
  T? item(int position) {
    if (position < 0 || position >= length) {
      return null;
    }
    var node = _root!;
    var offset = position;
    while (true) {
      final before = node.left?.size ?? 0;
      if (offset < before) {
        node = node.left!;
      } else if (offset < before + node.chunk.length) {
        return node.chunk[offset - before];
      } else {
        offset -= before + node.chunk.length;
        node = node.right!;
      }
    }
  }

  /// The [length] items from [start], both clamped to the content.
  List<T> slice(int start, int length) {
    final from = start.clamp(0, this.length);
    // Clamped before adding, so a huge length cannot wrap.
    final to = from + length.clamp(0, this.length - from);
    final (_, rest) = _split(_root, from);
    final (middle, _) = _split(rest, to - from);
    return _walk(middle).toList();
  }

  /// A copy with [added] inserted before [position].
  ///
  /// [position] may equal [length] to append. Any other position outside
  /// the content is a [Kind.bounds] failure. Items that fit in the chunk
  /// holding [position] go into it, so typing adds no nodes until a chunk
  /// is full.
  Result<Content<T>> insertAll(int position, Iterable<T> added) {
    if (position < 0 || position > length) {
      return Failure.bounds('insert', position);
    }
    final root = _root;
    final list = added is List<T> ? added : added.toList();
    if (root != null && list.length < _chunk) {
      final fitted = _fit(root, position, list);
      if (fitted != null) {
        return Success(Content._(fitted));
      }
    }
    final (left, right) = _split(_root, position);
    return Success(Content._(join(join(left, Content.of(list)._root), right)));
  }

  /// A copy without the items in [span].
  ///
  /// A span outside the content is a [Kind.bounds] failure.
  Result<Content<T>> deleteAll(Range span) {
    if (outside(span, length) case final position?) {
      return Failure.bounds('delete', position);
    }
    final (left, rest) = _split(_root, span.start);
    final (_, right) = _split(rest, span.length);
    return Success(Content._(join(left, right)));
  }
}

final class _Node<T> extends Node<_Node<T>> {
  _Node(this.chunk, this.left, this.right, this.priority)
    : size = (left?.size ?? 0) + chunk.length + (right?.size ?? 0);

  /// The measure of this node's chunk, computed when first asked. Only
  /// content of code points is ever asked.
  late final Measure own = _measured(chunk as List<int>, chunk.length)!;

  /// The measure of this node's subtree, computed when first asked from
  /// its chunk's and its children's. Nodes never change, so it never goes
  /// stale, and a node shared by many versions measures once.
  late final Measure measure = _joined(
    _joined(left?.measure, own),
    right?.measure,
  )!;

  _Node.leaf(List<T> chunk)
    : this(List.unmodifiable(chunk), null, null, priorities.priority());

  final List<T> chunk;
  @override
  final _Node<T>? left;
  @override
  final _Node<T>? right;
  @override
  final int priority;
  final int size;

  @override
  (_Node<T>?, _Node<T>?) open() => (left, right);

  @override
  _Node<T> make(_Node<T>? left, _Node<T>? right) =>
      _Node(chunk, left, right, priority);
}

/// The items below the root [root] in order.
Iterable<T> _walk<T>(_Node<T>? root) sync* {
  final walk = Walk<_Node<T>, void>(root, null, (_, _) {});
  while (walk.next()) {
    yield* walk.node.chunk;
  }
}

/// [node] with [added] placed [count] items in, inside the chunk that holds
/// that position, or `null` when that chunk has no room for them.
///
/// Copies one path and keeps every priority, so the heap order holds.
_Node<T>? _fit<T>(_Node<T> node, int count, List<T> added) {
  final before = node.left?.size ?? 0;
  final through = before + node.chunk.length;
  if (count < before) {
    final left = _fit(node.left!, count, added);
    return left == null ? null : node.make(left, node.right);
  }
  if (count > through) {
    final right = _fit(node.right!, count - through, added);
    return right == null ? null : node.make(node.left, right);
  }
  if (node.chunk.length + added.length > _chunk) {
    return null;
  }
  final cut = count - before;
  return _Node(
    List.unmodifiable(List.of(node.chunk)..insertAll(cut, added)),
    node.left,
    node.right,
    node.priority,
  );
}

/// The number of nodes below [node], itself included.
int _count<T>(_Node<T>? node) =>
    node == null ? 0 : 1 + _count(node.left) + _count(node.right);

/// Whether every node below [node] holds at least one item.
bool _filled<T>(_Node<T>? node) =>
    node == null ||
    node.chunk.isNotEmpty && _filled(node.left) && _filled(node.right);

/// Splits [node] into the first [count] items and the rest.
///
/// Its own split, since the cut can fall inside a node's chunk, which then
/// becomes two nodes.
(_Node<T>?, _Node<T>?) _split<T>(_Node<T>? node, int count) {
  if (node == null) {
    return (null, null);
  }
  final before = node.left?.size ?? 0;
  final through = before + node.chunk.length;
  if (count <= before) {
    final (left, right) = _split(node.left, count);
    return (left, node.make(right, node.right));
  }
  if (count >= through) {
    final (left, right) = _split(node.right, count - through);
    return (node.make(node.left, left), right);
  }
  // The cut falls inside this node's chunk: each side keeps the node's
  // priority, so both halves still satisfy the heap order.
  final cut = count - before;
  return (
    _Node(
      List.unmodifiable(node.chunk.sublist(0, cut)),
      node.left,
      null,
      node.priority,
    ),
    _Node(
      List.unmodifiable(node.chunk.sublist(cut)),
      null,
      node.right,
      node.priority,
    ),
  );
}

/// What a run of code points measures: its UTF-16 [units], its line
/// [ends], and its [first] and [last] code points, which let two runs join
/// with a carriage return and a line feed across them counted once.
typedef Measure = ({int units, int ends, int first, int last});

/// A line end completes at [point], given the code point [previous] before
/// it, or -1 at the start: a line feed not after a carriage return, a
/// carriage return, NEL, LINE SEPARATOR, or PARAGRAPH SEPARATOR.
bool _ends(int point, int previous) => switch (point) {
  0x0A => previous != 0x0D,
  0x0D || 0x85 || 0x2028 || 0x2029 => true,
  _ => false,
};

/// The UTF-16 units [point] takes: two above U+FFFF, else one.
int _width(int point) => point > 0xFFFF ? 2 : 1;

/// The measure of the first [count] of [points], or `null` for none.
Measure? _measured(List<int> points, int count) {
  if (count == 0) {
    return null;
  }
  var units = 0;
  var ends = 0;
  var previous = -1;
  for (var index = 0; index < count; index++) {
    final point = points[index];
    units += _width(point);
    if (_ends(point, previous)) {
      ends++;
    }
    previous = point;
  }
  return (units: units, ends: ends, first: points[0], last: previous);
}

/// [a] followed by [b]. A line feed starting [b] after a carriage return
/// ending [a] is part of that end, so it is not counted again.
Measure? _joined(Measure? a, Measure? b) {
  if (a == null) {
    return b;
  }
  if (b == null) {
    return a;
  }
  final crossing = a.last == 0x0D && b.first == 0x0A ? 1 : 0;
  return (
    units: a.units + b.units,
    ends: a.ends + b.ends - crossing,
    first: a.first,
    last: b.last,
  );
}

/// Measures over content of code points, each one descent of the tree and
/// a scan of one chunk: `O(log n + C)` for chunks of `C` items. The
/// coordinate module's conversions are built on them.
extension Measures on Content<int> {
  /// The measure of every item, or `null` for no items.
  Measure? get measure => _root?.measure;

  /// The measure of the items before [position], which must be in
  /// `0..length`, or `null` for none.
  Measure? before(int position) {
    Measure? measure;
    var node = _root;
    var offset = position;
    while (node != null) {
      final left = node.left;
      final size = left?.size ?? 0;
      if (offset < size) {
        node = left;
        continue;
      }
      measure = _joined(measure, left?.measure);
      offset -= size;
      if (offset <= node.chunk.length) {
        return _joined(measure, _measured(node.chunk, offset));
      }
      measure = _joined(measure, node.own);
      offset -= node.chunk.length;
      node = node.right;
    }
    return measure;
  }

  /// The position whose items before it take [units] UTF-16 units, with
  /// `true`, or the position of the item whose units hold [units] inside
  /// them, with `false`. [units] must be in `0..measure.units`.
  (int, bool) at(int units) {
    var node = _root;
    var rest = units;
    var position = 0;
    while (node != null) {
      final left = node.left;
      final inside = left?.measure.units ?? 0;
      if (rest < inside) {
        node = left;
        continue;
      }
      rest -= inside;
      position += left?.size ?? 0;
      for (final point in node.chunk) {
        final width = _width(point);
        if (rest < width) {
          return (position, rest == 0);
        }
        rest -= width;
        position++;
      }
      node = node.right;
    }
    return (position, true);
  }

  /// The position of the item that completes the [count]th line end, for
  /// [count] in `1..measure.ends`: the line feed of a lone line feed, the
  /// carriage return of a carriage return and line feed, or the separator.
  int end(int count) {
    Measure? measure;
    var node = _root!;
    var position = 0;
    while (true) {
      final left = node.left;
      final through = _joined(measure, left?.measure);
      if (left != null && through!.ends >= count) {
        node = left;
        continue;
      }
      measure = through;
      position += left?.size ?? 0;
      var ends = measure?.ends ?? 0;
      var previous = measure?.last ?? -1;
      for (final point in node.chunk) {
        if (_ends(point, previous) && ++ends == count) {
          return position;
        }
        previous = point;
        position++;
      }
      measure = _joined(measure, node.own);
      node = node.right!;
    }
  }
}
