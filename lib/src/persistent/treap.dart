import '../sequence/sequence.dart';

/// A node of a persistent treap: a priority and two children.
///
/// Each tree extends this with what its nodes store. The shared operations
/// treat every node they handle as the root of its own tree: [open] gives
/// its children as roots, and [make] rebuilds it over new roots. A tree
/// whose nodes store nothing relative to their parent opens and makes
/// directly; the endpoint tree converts its relative offsets there.
abstract base class Node<N extends Node<N>> {
  /// For subclasses.
  const Node();

  /// The heap order: no node has a higher priority than its parent.
  int get priority;

  /// The left child as stored, relative to this node where the tree keeps
  /// relative values.
  N? get left;

  /// The right child as stored.
  N? get right;

  /// The children of this root, as roots.
  (N?, N?) open();

  /// This root rebuilt over the roots [left] and [right].
  N make(N? left, N? right);
}

/// The roots of [nodes], each a node with no children, built into one
/// tree in their order, in time linear in their number.
///
/// The tree is the one joining them one by one gives: a node keeps every
/// earlier node of no higher priority below it on its left, as [join] puts
/// the right tree on top where the priorities tie. Each node is made once,
/// when its right subtree is known.
N? built<N extends Node<N>>(Iterable<N> nodes) {
  // The right spine still open, each node with the left subtree it was
  // given; its right subtree is what is closed below it.
  final spine = <(N, N?)>[];
  for (final node in nodes) {
    N? closed;
    while (spine.isNotEmpty && spine.last.$1.priority <= node.priority) {
      final (open, left) = spine.removeLast();
      closed = open.make(left, closed);
    }
    spine.add((node, closed));
  }
  N? closed;
  while (spine.isNotEmpty) {
    final (open, left) = spine.removeLast();
    closed = open.make(left, closed);
  }
  return closed;
}

/// The roots [left] and [right] joined into one tree, every node of [left]
/// first.
N? join<N extends Node<N>>(N? left, N? right) {
  if (left == null) {
    return right;
  }
  if (right == null) {
    return left;
  }
  if (left.priority > right.priority) {
    final (low, high) = left.open();
    return left.make(low, join(high, right));
  }
  final (low, high) = right.open();
  return right.make(join(left, low), high);
}

/// The root [node] split into the nodes where [before] holds and the rest.
///
/// [before] sees each node as a root and must hold for a prefix of the tree
/// order.
(N?, N?) split<N extends Node<N>>(N? node, bool Function(N root) before) {
  if (node == null) {
    return (null, null);
  }
  final (left, right) = node.open();
  if (before(node)) {
    final (low, high) = split(right, before);
    return (node.make(left, low), high);
  }
  final (low, high) = split(left, before);
  return (low, node.make(high, right));
}

/// Nothing, or a [Kind.invalid] failure, naming the tree [name], for the
/// first node below [root] with a higher priority than its parent.
Result<void> heap<N extends Node<N>>(N? root, String name) =>
    _heap(root, null, name);

Result<void> _heap<N extends Node<N>>(N? node, int? limit, String name) {
  if (node == null) {
    return const Success(null);
  }
  if (limit != null && node.priority > limit) {
    return Failure(Kind.invalid, '$name: heap order broken');
  }
  return _heap(
    node.left,
    node.priority,
    name,
  ).flatMap((_) => _heap(node.right, node.priority, name));
}

/// A cursor over the nodes below a root in tree order, each with a
/// context: the given one for the root, and `down` of a child and its
/// parent's context for every other node.
///
/// Walks with explicit stacks over the stored children, so it neither
/// nests generators, rebuilds nodes, nor allocates per node.
final class Walk<N extends Node<N>, C> {
  /// A cursor before the first node below [root].
  Walk(N? root, C context, this._down) : _next = root, _context = context;

  final C Function(N child, C parent) _down;
  final _nodes = <N>[];
  final _contexts = <C>[];
  N? _next;
  C _context;

  /// The node the cursor is on, once [next] has returned `true`.
  late N node;

  /// The context of [node].
  late C context;

  /// Moves to the next node, or returns `false` past the last.
  bool next() {
    var node = _next;
    var current = _context;
    while (node != null) {
      _nodes.add(node);
      _contexts.add(current);
      final left = node.left;
      if (left != null) {
        current = _down(left, current);
      }
      node = left;
    }
    if (_nodes.isEmpty) {
      return false;
    }
    this.node = _nodes.removeLast();
    context = _contexts.removeLast();
    final right = this.node.right;
    _next = right;
    _context = right == null ? context : _down(right, context);
    return true;
  }
}
