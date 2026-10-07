import 'command.dart';
import 'priority.dart' as priorities;
import 'treap.dart';

/// A persistent map from [Marker] to [V]: a treap keyed by each marker's
/// sequence number.
///
/// Every change copies one path and shares the rest, so earlier indexes
/// stay valid and unchanged.
final class Index<V> {
  const Index._(this._root);

  /// An index with no markers.
  const Index.empty() : this._(null);

  /// An index of [pairs], each marker distinct, built in one pass after
  /// sorting them by marker.
  factory Index.of(Iterable<(Marker, V)> pairs) {
    final sorted = [...pairs]
      ..sort((one, other) => one.$1.sequence - other.$1.sequence);
    return Index._(
      built([
        for (final (marker, value) in sorted)
          _Node(marker, value, priorities.priority(), null, null),
      ]),
    );
  }

  final _Node<V>? _root;

  /// The number of markers.
  int get length => _root?.size ?? 0;

  /// The value for [marker], or `null` when it is absent.
  V? get(Marker marker) {
    var node = _root;
    while (node != null) {
      final order = marker.sequence - node.marker.sequence;
      if (order == 0) {
        return identical(node.marker, marker) ? node.value : null;
      }
      node = order < 0 ? node.left : node.right;
    }
    return null;
  }

  /// A copy with [marker] mapped to [value], replacing any earlier value.
  Index<V> put(Marker marker, V value) {
    final (before, rest) = _below(_root, marker.sequence);
    final (_, after) = _below(rest, marker.sequence + 1);
    final node = _Node(marker, value, priorities.priority(), null, null);
    return Index._(join(join(before, node), after));
  }

  /// A copy without [marker]. Unchanged in content when it is absent.
  Index<V> remove(Marker marker) {
    final (before, rest) = _below(_root, marker.sequence);
    final (_, after) = _below(rest, marker.sequence + 1);
    return Index._(join(before, after));
  }
}

final class _Node<V> extends Node<_Node<V>> {
  _Node(this.marker, this.value, this.priority, this.left, this.right)
    : size = 1 + (left?.size ?? 0) + (right?.size ?? 0);

  final Marker marker;
  final V value;
  @override
  final int priority;
  @override
  final _Node<V>? left;
  @override
  final _Node<V>? right;
  final int size;

  @override
  (_Node<V>?, _Node<V>?) open() => (left, right);

  @override
  _Node<V> make(_Node<V>? left, _Node<V>? right) =>
      _Node(marker, value, priority, left, right);
}

/// Splits [node] into markers with a sequence below [key] and the rest.
(_Node<V>?, _Node<V>?) _below<V>(_Node<V>? node, int key) =>
    split(node, (root) => root.marker.sequence < key);
