import '../persistent/priority.dart' as priorities;
import '../persistent/treap.dart';

/// A persistent map from [K] to [V], ordered by a comparison: a treap.
///
/// Every change copies one path and shares the rest, so earlier tables
/// stay valid and unchanged.
final class Table<K, V> {
  const Table._(this._compare, this._root);

  /// A table with no entries, ordered by [compare].
  const Table(int Function(K a, K b) compare) : this._(compare, null);

  final int Function(K a, K b) _compare;
  final _Node<K, V>? _root;

  /// The number of entries.
  int get length => _root?.size ?? 0;

  /// The value for [key], or `null` when it is absent.
  V? get(K key) {
    var node = _root;
    while (node != null) {
      final order = _compare(key, node.key);
      if (order == 0) {
        return node.value;
      }
      node = order < 0 ? node.left : node.right;
    }
    return null;
  }

  /// A copy with [key] mapped to [value], replacing any earlier value.
  Table<K, V> put(K key, V value) {
    final (before, rest) = split(_root, (root) => _compare(root.key, key) < 0);
    final (_, after) = split(rest, (root) => _compare(root.key, key) <= 0);
    final node = _Node(key, value, priorities.priority(), null, null);
    return Table._(_compare, join(join(before, node), after));
  }

  /// Every entry, in key order.
  Iterable<(K, V)> get entries sync* {
    final walk = Walk<_Node<K, V>, void>(_root, null, (_, _) {});
    while (walk.next()) {
      yield (walk.node.key, walk.node.value);
    }
  }
}

final class _Node<K, V> extends Node<_Node<K, V>> {
  _Node(this.key, this.value, this.priority, this.left, this.right)
    : size = 1 + (left?.size ?? 0) + (right?.size ?? 0);

  final K key;
  final V value;
  @override
  final int priority;
  @override
  final _Node<K, V>? left;
  @override
  final _Node<K, V>? right;
  final int size;

  @override
  (_Node<K, V>?, _Node<K, V>?) open() => (left, right);

  @override
  _Node<K, V> make(_Node<K, V>? left, _Node<K, V>? right) =>
      _Node(key, value, priority, left, right);
}
