import '../sequence/sequence.dart';
import 'label.dart';
import 'priority.dart' as priorities;
import 'treap.dart';

/// One endpoint of a range, with its absolute position, as listed by
/// [Endpoints.entries]. A start endpoint carries its end's label as
/// [partner].
typedef Endpoint<O> = ({
  int position,
  Label label,
  O owner,
  bool start,
  Label? partner,
});

/// A persistent treap of range endpoints in position order.
///
/// Each node stores its position relative to its parent, and a root stores
/// its absolute position, so moving a whole subtree is one change at its
/// root. A node flagged as flat places every endpoint below it at its own
/// position, which collapses a run of endpoints in one step.
///
/// Every endpoint also has a [Label]. Edits never reorder endpoints, so
/// labels stay in tree order forever, and an endpoint can be found by label
/// after any number of edits.
final class Endpoints<O> {
  const Endpoints._(this._root);

  /// A tree with no endpoints.
  const Endpoints.empty() : this._(null);

  /// A tree of [endpoints], given in tree order, each with whether its
  /// partner lives in another tree.
  ///
  /// The positions must never decrease and the labels must increase, as in
  /// [entries].
  factory Endpoints.of(Iterable<(Endpoint<O>, bool)> endpoints) {
    _Node<O>? root;
    for (final (endpoint, elsewhere) in endpoints) {
      final leaf = _Node.leaf(
        endpoint.position,
        endpoint.label,
        endpoint.owner,
        endpoint.start,
        endpoint.partner,
        elsewhere,
      );
      root = join(root, leaf);
    }
    return Endpoints._(root);
  }

  final _Node<O>? _root;

  /// Every endpoint in order.
  Iterable<Endpoint<O>> get entries => _walk(_root);

  /// The two endpoints of a range from [start] to [end], owned by [owner],
  /// and the labels that find them again.
  ///
  /// Each endpoint goes after every endpoint already at its position, so the
  /// start always precedes the end. A negative [start] or an [end] before
  /// [start] is a [Kind.invalid] failure.
  Result<(Endpoints<O>, Label, Label)> add(O owner, int start, int end) {
    if (start < 0 || end < start) {
      return Failure(
        Kind.invalid,
        'endpoints: invalid range from $start to $end',
      );
    }
    final (low, high) = _neighbours(_root, start);
    return Label.between(low, high).flatMap((first) {
      final (below, above) = _neighbours(_root, end);
      final floor = below == null || below.compareTo(first) < 0 ? first : below;
      return Label.between(floor, above).map((last) {
        final root = _place(
          _place(_root, _Node.leaf(start, first, owner, true, last, false)),
          _Node.leaf(end, last, owner, false, null, false),
        );
        return (Endpoints._(root), first, last);
      });
    });
  }

  /// One endpoint at [position], owned by [owner], and the label that finds
  /// it again.
  ///
  /// For a range whose other endpoint lives in another tree. A start
  /// endpoint takes the [partner] label of its end in that other tree. The
  /// endpoint goes after every endpoint already at [position]. A negative
  /// [position] is a [Kind.invalid] failure.
  Result<(Endpoints<O>, Label)> put(
    O owner,
    int position,
    bool start, {
    Label? partner,
  }) {
    if (position < 0) {
      return Failure(Kind.invalid, 'endpoints: position $position is negative');
    }
    final (low, high) = _neighbours(_root, position);
    return Label.between(low, high).map((label) {
      final leaf = _Node.leaf(position, label, owner, start, partner, true);
      return (Endpoints._(_place(_root, leaf)), label);
    });
  }

  /// Whether the tree keeps its invariants: labels strictly increase and
  /// positions never decrease in tree order, no position is negative, no
  /// node outranks its parent, and every cached partner summary matches
  /// its subtree. A [Kind.invalid] failure names the first that does not.
  Result<void> check() {
    Endpoint<O>? last;
    for (final endpoint in entries) {
      if (endpoint.position < 0) {
        return Failure(
          Kind.invalid,
          'endpoints: ${endpoint.label} is at ${endpoint.position}',
        );
      }
      if (last != null &&
          (endpoint.label.compareTo(last.label) <= 0 ||
              endpoint.position < last.position)) {
        return Failure(
          Kind.invalid,
          'endpoints: ${endpoint.label} is out of order after ${last.label}',
        );
      }
      last = endpoint;
    }
    return heap(_root, 'endpoints').flatMap((_) => _verify(_root)).map((_) {});
  }

  /// A new label for every endpoint, spaced evenly in tree order, keyed by
  /// its current label.
  Map<Label, Label> spacing() {
    final labels = [for (final endpoint in entries) endpoint.label];
    return Map.fromIterables(labels, Label.spread(labels.length));
  }

  /// A copy with every label replaced through [own], and every partner
  /// through [own], or through [other] for a partner in another tree.
  /// Positions, owners, and order are unchanged.
  Endpoints<O> relabel(Map<Label, Label> own, Map<Label, Label> other) =>
      Endpoints.of([
        for (final (position, node) in _absolute(_root))
          (
            (
              position: position,
              label: own[node.label]!,
              owner: node.owner,
              start: node.start,
              partner: switch (node.partner) {
                null => null,
                final partner => (node.elsewhere ? other : own)[partner]!,
              },
            ),
            node.elsewhere,
          ),
      ]);

  /// The label of the last endpoint at or before [position], or `null` when
  /// there is none.
  ///
  /// Every endpoint with a greater label lies after [position].
  Label? boundary(int position) => _neighbours(_root, position).$1;

  /// A copy without the endpoint labelled [label].
  ///
  /// Unchanged unless it is present and belongs to [owner].
  Endpoints<O> drop(O owner, Label label) {
    if (position(label, owner) == null) {
      return this;
    }
    return Endpoints._(_cut(_root, label));
  }

  /// The owners of every range whose start is in this tree and that
  /// contains [position], meaning its start is at or before [position] and
  /// its end is after it.
  ///
  /// A range's end may live in this tree or in another; [other] is that
  /// other tree's [boundary] for [position], where `null` means none of its
  /// endpoints is at or before [position]. Only subtrees whose greatest end
  /// label can pass a boundary are visited, so this costs O(log m) plus the
  /// ranges found.
  Iterable<O> containing(int position, Label? other) sync* {
    final own = boundary(position);
    if (own == null) {
      return;
    }
    // An end lies after position when its label is past the boundary of the
    // tree that holds it.
    bool after(Label? label, bool elsewhere) {
      if (label == null) {
        return false;
      }
      final limit = elsewhere ? other : own;
      return limit == null || label.compareTo(limit) > 0;
    }

    final pending = <_Node<O>>[?_root];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (!after(node.reach, false) && !after(node.beyond, true)) {
        continue;
      }
      final order = node.label.compareTo(own);
      if (order <= 0 && node.start && after(node.partner, node.elsewhere)) {
        yield node.owner;
      }
      if (order < 0 && node.right != null) {
        pending.add(node.right!);
      }
      if (node.left != null) {
        pending.add(node.left!);
      }
    }
  }

  /// The owners of every start endpoint strictly after [from] and before
  /// [to], in no particular order.
  ///
  /// Positions never decrease in tree order, so a subtree left of a node at
  /// or before [from], or right of one at or after [to], is skipped, and so
  /// is a subtree holding no start: this costs O(log m) for each start in
  /// the interval, and none for the ends there.
  Iterable<O> starting(int from, int to) sync* {
    final root = _root;
    if (root == null) {
      return;
    }
    final pending = <(_Node<O>, int, bool)>[(root, root.offset, root.flat)];
    while (pending.isNotEmpty) {
      final (node, at, flat) = pending.removeLast();
      if (!node.starts) {
        continue;
      }
      if (node.start && from < at && at < to) {
        yield node.owner;
      }
      final left = node.left;
      if (left != null && at > from) {
        final (position, level) = _descend(left, at, flat);
        pending.add((left, position, level));
      }
      final right = node.right;
      if (right != null && at < to) {
        final (position, level) = _descend(right, at, flat);
        pending.add((right, position, level));
      }
    }
  }

  /// The absolute position of the endpoint with [label], or `null` when it
  /// is absent or has a different [owner].
  int? position(Label label, O owner) {
    var node = _root;
    var at = node?.offset ?? 0;
    var flat = node?.flat ?? false;
    while (node != null) {
      final order = label.compareTo(node.label);
      if (order == 0) {
        return identical(node.owner, owner) ? at : null;
      }
      node = order < 0 ? node.left : node.right;
      (at, flat) = _descend(node, at, flat);
    }
    return null;
  }

  /// A copy without the endpoints labelled [first] and [last].
  ///
  /// Unchanged unless both are present and belong to [owner].
  Endpoints<O> remove(O owner, Label first, Label last) {
    if (position(first, owner) == null || position(last, owner) == null) {
      return this;
    }
    return Endpoints._(_cut(_cut(_root, first), last));
  }

  /// A copy with every endpoint at or after [at] moved by [count].
  Endpoints<O> shift(int at, int count) {
    final (before, after) = split(_root, (node) => node.offset < at);
    return Endpoints._(join(before, _moved(after, count)));
  }

  /// A copy with every endpoint in `[from, to)` moved to [from], and every
  /// endpoint at or after [to] moved back by `to - from`.
  Endpoints<O> collapse(int from, int to) {
    final (before, rest) = split(_root, (node) => node.offset < from);
    final (inside, after) = split(rest, (node) => node.offset < to);
    final flat = inside?.rebuild(offset: from, flat: true);
    return Endpoints._(join(join(before, flat), _moved(after, from - to)));
  }

  static _Node<O>? _cut<O>(_Node<O>? root, Label label) {
    final (before, rest) = split(
      root,
      (node) => node.label.compareTo(label) < 0,
    );
    final (_, after) = split(rest, (node) => node.label.compareTo(label) <= 0);
    return join(before, after);
  }
}

final class _Node<O> extends Node<_Node<O>> {
  _Node(
    this.offset,
    this.label,
    this.owner,
    this.start,
    this.partner,
    this.elsewhere,
    this.priority,
    this.left,
    this.right,
    this.flat,
  ) : reach = _greatest(
        _greatest(left?.reach, right?.reach),
        start && !elsewhere ? partner : null,
      ),
      beyond = _greatest(
        _greatest(left?.beyond, right?.beyond),
        start && elsewhere ? partner : null,
      ),
      starts = start || (left?.starts ?? false) || (right?.starts ?? false);

  /// A new root endpoint with no children.
  _Node.leaf(
    int position,
    Label label,
    O owner,
    bool start,
    Label? partner,
    bool elsewhere,
  ) : this(
        position,
        label,
        owner,
        start,
        partner,
        elsewhere,
        priorities.priority(),
        null,
        null,
        false,
      );

  /// The position relative to the parent, or absolute for a root.
  final int offset;
  final Label label;
  final O owner;
  final bool start;
  @override
  final int priority;
  @override
  final _Node<O>? left;
  @override
  final _Node<O>? right;

  /// Whether every node below this one sits at this node's position.
  final bool flat;

  /// For a start endpoint, the label of its range's end.
  final Label? partner;

  /// Whether [partner] lives in another tree.
  final bool elsewhere;

  /// The greatest end label in this tree among the start endpoints in this
  /// subtree.
  ///
  /// Labels never change on shifts or collapses, so neither does this.
  final Label? reach;

  /// The greatest end label in another tree among the start endpoints in
  /// this subtree.
  final Label? beyond;

  /// Whether this subtree holds a start endpoint.
  final bool starts;

  _Node<O> rebuild({
    required int offset,
    bool flat = false,
    _Node<O>? left,
    _Node<O>? right,
    bool children = false,
  }) => _Node(
    offset,
    label,
    owner,
    start,
    partner,
    elsewhere,
    priority,
    children ? left : this.left,
    children ? right : this.right,
    flat || (!children && this.flat),
  );

  /// The children with absolute offsets, carrying this root's flat flag
  /// down.
  @override
  (_Node<O>?, _Node<O>?) open() {
    _Node<O>? absolute(_Node<O>? child) => child?.rebuild(
      offset: flat ? offset : offset + child.offset,
      flat: flat,
    );
    return (absolute(left), absolute(right));
  }

  /// This root over the absolute roots [left] and [right], stored relative
  /// to it.
  @override
  _Node<O> make(_Node<O>? left, _Node<O>? right) {
    _Node<O>? relative(_Node<O>? child) =>
        child?.rebuild(offset: child.offset - offset);
    return rebuild(
      offset: offset,
      left: relative(left),
      right: relative(right),
      children: true,
    );
  }
}

Label? _greatest(Label? a, Label? b) {
  if (a == null) {
    return b;
  }
  if (b == null) {
    return a;
  }
  return a.compareTo(b) >= 0 ? a : b;
}

/// The label of the last endpoint at or before [position], and of the first
/// endpoint after it.
(Label?, Label?) _neighbours<O>(_Node<O>? root, int position) {
  Label? low;
  Label? high;
  var node = root;
  var at = node?.offset ?? 0;
  var flat = node?.flat ?? false;
  while (node != null) {
    if (at <= position) {
      low = node.label;
      node = node.right;
    } else {
      high = node.label;
      node = node.left;
    }
    (at, flat) = _descend(node, at, flat);
  }
  return (low, high);
}

/// The absolute position and flat flag of [child], below a parent at
/// absolute position [at] with flag [flat]: the same rule as
/// [_Node.open], without rebuilding the child.
(int, bool) _descend<O>(_Node<O>? child, int at, bool flat) {
  if (child == null) {
    return (at, flat);
  }
  return (flat ? at : at + child.offset, flat || child.flat);
}

/// The root [node] with the root [leaf] added in label order.
_Node<O> _place<O>(_Node<O>? node, _Node<O> leaf) {
  final (before, after) = split(
    node,
    (root) => root.label.compareTo(leaf.label) < 0,
  );
  return join(join(before, leaf), after)!;
}

/// The root [node] moved by [count], with everything below it.
_Node<O>? _moved<O>(_Node<O>? node, int count) =>
    node?.rebuild(offset: node.offset + count);

Iterable<Endpoint<O>> _walk<O>(_Node<O>? root) => _absolute(root).map(
  (entry) => (
    position: entry.$1,
    label: entry.$2.label,
    owner: entry.$2.owner,
    start: entry.$2.start,
    partner: entry.$2.partner,
  ),
);

/// Every node below the root [root] in tree order, with its absolute
/// position, carried down with the flat flag as the walk's context so no
/// node is rebuilt.
Iterable<(int, _Node<O>)> _absolute<O>(_Node<O>? root) sync* {
  final walk = Walk<_Node<O>, (int, bool)>(root, (
    root?.offset ?? 0,
    root?.flat ?? false,
  ), (child, parent) => _descend(child, parent.$1, parent.$2));
  while (walk.next()) {
    yield (walk.context.$1, walk.node);
  }
}

/// The partner summaries of [node] recomputed from its subtree, or a
/// failure when a node's cached summary disagrees.
Result<(Label?, Label?)> _verify<O>(_Node<O>? node) {
  if (node == null) {
    return const Success((null, null));
  }
  final starts =
      node.start ||
      (node.left?.starts ?? false) ||
      (node.right?.starts ?? false);
  if (starts != node.starts) {
    return Failure(
      Kind.invalid,
      'endpoints: stale start summary at ${node.label}',
    );
  }
  return _verify(node.left).flatMap(
    (left) => _verify(node.right).flatMap((right) {
      final own = node.start ? node.partner : null;
      final reach = _greatest(
        _greatest(left.$1, right.$1),
        node.elsewhere ? null : own,
      );
      final beyond = _greatest(
        _greatest(left.$2, right.$2),
        node.elsewhere ? own : null,
      );
      if (reach != node.reach || beyond != node.beyond) {
        return Failure(
          Kind.invalid,
          'endpoints: stale partner summary at ${node.label}',
        );
      }
      return Success((reach, beyond));
    }),
  );
}
