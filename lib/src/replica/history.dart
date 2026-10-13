import '../persistent/persistent.dart';
import '../range/range.dart';
import '../sequence/sequence.dart';
import '../persistent/priority.dart' as priorities;
import '../persistent/treap.dart';
import 'stamp.dart';
import 'table.dart';

/// The identity of an inserted item: the [stamp] of its operation, the
/// index of its [command] there, and its [offset] among that command's
/// items.
typedef Identity = ({Stamp stamp, int command, int offset});

/// Identities in order: by stamp, then command, then offset.
int compare(Identity a, Identity b) => a.stamp != b.stamp
    ? a.stamp.compareTo(b.stamp)
    : a.command != b.command
    ? a.command - b.command
    : a.offset - b.offset;

/// What the history records of an item in the Fugue tree: its [parent],
/// `null` for the start, which [side] of it the item is on, and its
/// [lefts] and [rights] children in ascending identity.
typedef Entry = ({
  Identity? parent,
  Side side,
  List<Identity> lefts,
  List<Identity> rights,
});

/// An item as a context sees it: its [identity], its [rank] in the whole
/// history, and whether the context [shows] it.
typedef _Seen = ({Identity identity, int rank, bool shows});

/// The side of its parent an item is on in the Fugue tree.
enum Side {
  /// Before the parent, in tree order.
  left,

  /// After the parent, in tree order.
  right,
}

/// Every item ever inserted into a replica's document, deleted ones
/// included, in the order of the Fugue tree. The document's items are the
/// visible ones, in this order.
///
/// Immutable: [apply] returns a new history.
final class History {
  const History._(this._root, this._entries, this._roots);

  /// The history of an empty document.
  const History.empty() : this._(null, const Table(compare), const []);

  /// The items in tree order, each counting the visible items below it.
  final _Node? _root;

  /// What the tree records of each item.
  final Table<Identity, Entry> _entries;

  /// The right children of the start, in ascending identity.
  final List<Identity> _roots;

  /// The number of visible items, the length of the document.
  int get length => _root?.visible ?? 0;

  /// The number of items ever inserted.
  int get size => _entries.length;

  /// Every item's identity, in tree order, with the stamps of the
  /// operations that deleted it; an item is visible when there are none.
  Iterable<(Identity, List<Stamp>)> get items sync* {
    final walk = Walk<_Node, void>(_root, null, (_, _) {});
    while (walk.next()) {
      yield (walk.node.identity, walk.node.deleted);
    }
  }

  /// The right children of the start, in ascending identity.
  List<Identity> get roots => _roots;

  /// What the tree records of [identity], or `null` for an item it does
  /// not hold.
  Entry? entry(Identity identity) => _entries.get(identity);

  /// This history after the operation stamped [stamp], whose commands are
  /// [commands], applied to the document it describes. The commands must
  /// fit that document, as `Document.transact` has checked.
  History apply(Stamp stamp, List<Command<Object?>> commands) {
    var history = this;
    for (final (index, command) in commands.indexed) {
      history = switch (command) {
        Insert(:final position, :final items) => history._insert(
          stamp,
          index,
          position,
          items.length,
        ),
        Delete(:final span) => history._delete(stamp, span.start, span.length),
        Replace(:final span, :final items) =>
          history
              ._delete(stamp, span.start, span.length)
              ._insert(stamp, index, span.start, items.length),
        // A replica refuses a move when it is committed.
        Mark() || Unmark() || Update() || Move() => history,
      };
    }
    return history;
  }

  /// This history with [count] items inserted at [position] by command
  /// [command] of the operation stamped [stamp], whose context is this
  /// history: each lands right after the item before it.
  History _insert(Stamp stamp, int command, int position, int count) {
    if (count == 0) {
      return this;
    }
    final (before, after) = _cut(_root, position);
    final previous = before == null ? null : _last(before).identity;
    final following = after == null ? null : _first(after).identity;
    final rights = previous == null ? _roots : _entries.get(previous)!.rights;
    // The Fugue rule: a right child of the item before, unless it has right
    // children; then the item after is the first of its right subtree, has
    // no left children, and takes the new item as one.
    final (above, side) = rights.isEmpty
        ? (previous, Side.right)
        : (following!, Side.left);
    final (entries, roots, nodes) = _adopted(
      stamp,
      command,
      count,
      above,
      side,
    );
    final run = nodes.fold<_Node?>(null, join);
    return History._(join(join(before, run), after), entries, roots);
  }

  /// This history with the [count] visible items from [position] deleted by
  /// the operation stamped [stamp].
  History _delete(Stamp stamp, int position, int count) {
    if (count == 0) {
      return this;
    }
    final (before, rest) = _cut(_root, position);
    final (inside, after) = _cut(rest, count);
    final run = _hide(inside, stamp);
    return History._(join(join(before, run), after), _entries, _roots);
  }

  /// The entries and start children with [count] new items of command
  /// [command] of the operation stamped [stamp] in the tree, the first a
  /// [side] child of [parent] and each later one a right child of the one
  /// before, and their nodes, in order.
  (Table<Identity, Entry>, List<Identity>, List<_Node>) _adopted(
    Stamp stamp,
    int command,
    int count,
    Identity? parent,
    Side side,
  ) {
    var entries = _entries;
    var roots = _roots;
    var (above, placed) = (parent, side);
    final nodes = <_Node>[];
    for (var offset = 0; offset < count; offset++) {
      final identity = (stamp: stamp, command: command, offset: offset);
      entries = entries.put(identity, (
        parent: above,
        side: placed,
        lefts: const [],
        rights: const [],
      ));
      if (above == null) {
        roots = _placed(roots, identity);
      } else {
        final entry = entries.get(above)!;
        entries = entries.put(above, (
          parent: entry.parent,
          side: entry.side,
          lefts: placed == Side.left
              ? _placed(entry.lefts, identity)
              : entry.lefts,
          rights: placed == Side.right
              ? _placed(entry.rights, identity)
              : entry.rights,
        ));
      }
      nodes.add(_Node(identity, const [], priorities.priority(), null, null));
      (above, placed) = (identity, Side.right);
    }
    return (entries, roots, nodes);
  }

  /// This history after command [index] of the operation stamped [stamp],
  /// an `Insert`, `Delete`, or `Replace` whose context holds the operations
  /// in [seen], its ancestors and itself, with the commands that carry it
  /// out on the document this history describes. A command that does not
  /// fit its context is a [Kind.bounds] failure. Other commands move no
  /// items and give none.
  ///
  /// Costs a scan of every item, `O(N)`, to view the context.
  Result<(History, List<Command<T>>)> merge<T>(
    Stamp stamp,
    int index,
    Command<T> command,
    Set<Stamp> seen,
  ) => switch (command) {
    Insert(:final position, :final items) => _merged(
      stamp,
      index,
      position,
      items,
      seen,
    ),
    Delete(:final span) => _erased<T>(stamp, index, span, seen),
    Replace(:final span, :final items) =>
      _erased<T>(stamp, index, span, seen).flatMap(
        (done) => done.$1
            ._merged(stamp, index, span.start, items, seen)
            .map((put) => (put.$1, [...done.$2, ...put.$2])),
      ),
    Mark() || Unmark() || Update() => Success((this, const [])),
    Move() => Failure(Kind.invalid, 'replica: a move is not replicated'),
  };

  /// The current range of a range at [range] in the context holding the
  /// operations in [seen], its ends with gravities [start] and [end]: a
  /// right end stays before the item at it, or at the end, and a left end
  /// after the item before it, or at the start. A start mapped past the end
  /// gives a zero-length range at the start. A range past its context is a
  /// [Kind.bounds] failure naming command [index].
  ///
  /// Costs a scan of every item, `O(N)`, to view the context.
  Result<Range> mapped(
    Range range,
    Gravity start,
    Gravity end,
    Set<Stamp> seen,
    int index,
  ) {
    final (held, before) = _view(seen);
    final shown = [
      for (final item in held)
        if (item.shows) item,
    ];
    if (range.end > shown.length) {
      return Failure(
        Kind.bounds,
        'command $index: $range is out of bounds of its context of '
        '${shown.length} items',
      );
    }
    int map(int position, Gravity gravity) => gravity == Gravity.right
        ? (position == shown.length
              ? before.last
              : before[shown[position].rank])
        : (position == 0 ? 0 : before[shown[position - 1].rank + 1]);
    final first = map(range.start, start);
    final last = map(range.end, end);
    return Success(extent(first, last < first ? 0 : last - first));
  }

  /// Every item in tree order as a context holding the operations in
  /// [seen] sees it, keeping only those it holds, and for each rank in the
  /// whole history the number of visible items before it.
  (List<_Seen>, List<int>) _view(Set<Stamp> seen) {
    final held = <_Seen>[];
    final before = <int>[0];
    final walk = Walk<_Node, void>(_root, null, (_, _) {});
    var rank = 0;
    while (walk.next()) {
      final node = walk.node;
      if (seen.contains(node.identity.stamp)) {
        held.add((
          identity: node.identity,
          rank: rank,
          shows: !node.deleted.any(seen.contains),
        ));
      }
      before.add(before.last + (node.shown ? 1 : 0));
      rank++;
    }
    return (held, before);
  }

  /// The rank of each item in the whole history.
  Map<Identity, int> get _ranks {
    final ranks = <Identity, int>{};
    final walk = Walk<_Node, void>(_root, null, (_, _) {});
    while (walk.next()) {
      ranks[walk.node.identity] = ranks.length;
    }
    return ranks;
  }

  /// [merge] for [items] inserted at context position [position].
  Result<(History, List<Command<T>>)> _merged<T>(
    Stamp stamp,
    int index,
    int position,
    Sequence<T> items,
    Set<Stamp> seen,
  ) {
    final (held, before) = _view(seen);
    final shown = [
      for (final item in held)
        if (item.shows) item,
    ];
    if (position > shown.length) {
      return Failure(
        Kind.bounds,
        'command $index: position $position is out of bounds of its '
        'context of ${shown.length} items',
      );
    }
    if (items.length == 0) {
      return Success((this, const []));
    }
    final previous = position == 0 ? null : shown[position - 1];
    final rights = [
      for (final right
          in previous == null
              ? _roots
              : _entries.get(previous.identity)!.rights)
        if (seen.contains(right.stamp)) right,
    ];
    // The Fugue rule, in the context: a right child of the item before,
    // unless it has right children there; then a left child of the item
    // after it there, which has no left children there.
    final (parent, side) = rights.isEmpty
        ? (previous?.identity, Side.right)
        : (
            held[previous == null ? 0 : held.indexOf(previous) + 1].identity,
            Side.left,
          );
    final (entries, roots, nodes) = _adopted(
      stamp,
      index,
      items.length,
      parent,
      side,
    );
    final rank = _placement(entries, roots, nodes.first.identity);
    final (low, high) = _split(_root, rank);
    final run = nodes.fold<_Node?>(null, join);
    return Success((
      History._(join(join(low, run), high), entries, roots),
      [Insert<T>(before[rank], items)],
    ));
  }

  /// The rank in this history at which [identity], already in [entries]
  /// and [roots], belongs. Operations are applied in canonical order, so
  /// a new item's identity is the greatest held and it is the last child on
  /// its side: a left child goes right before its parent, and a right child
  /// right after the subtree of its previous sibling, or its parent.
  int _placement(
    Table<Identity, Entry> entries,
    List<Identity> roots,
    Identity identity,
  ) {
    final ranks = _ranks;
    final entry = entries.get(identity)!;
    final parent = entry.parent;
    if (entry.side == Side.left) {
      return ranks[parent]!;
    }
    final siblings = parent == null ? roots : entries.get(parent)!.rights;
    if (siblings.length == 1) {
      return parent == null ? 0 : ranks[parent]! + 1;
    }
    var last = siblings[siblings.length - 2];
    for (
      var rights = entries.get(last)!.rights;
      rights.isNotEmpty;
      rights = entries.get(last)!.rights
    ) {
      last = rights.last;
    }
    return ranks[last]! + 1;
  }

  /// [merge] for the items of [span] in the context deleted.
  Result<(History, List<Command<T>>)> _erased<T>(
    Stamp stamp,
    int index,
    Range span,
    Set<Stamp> seen,
  ) {
    final (held, before) = _view(seen);
    final shown = [
      for (final item in held)
        if (item.shows) item,
    ];
    if (span.end > shown.length) {
      return Failure(
        Kind.bounds,
        'command $index: $span is out of bounds of its context of '
        '${shown.length} items',
      );
    }
    final doomed = shown.sublist(span.start, span.end);
    final runs = <(int, int)>[];
    var root = _root;
    for (final item in doomed) {
      if (before[item.rank + 1] > before[item.rank]) {
        final place = before[item.rank];
        if (runs.isNotEmpty && runs.last.$2 == place) {
          runs.last = (runs.last.$1, place + 1);
        } else {
          runs.add((place, place + 1));
        }
      }
      root = _deleted(root, item.rank, stamp);
    }
    return Success((
      History._(root, _entries, _roots),
      [
        for (final (start, end) in runs.reversed)
          Delete<T>(extent(start, end - start)),
      ],
    ));
  }
}

/// [identities] with [identity] last, where its greatest identity puts it.
List<Identity> _placed(List<Identity> identities, Identity identity) =>
    List.unmodifiable([...identities, identity]);

/// [node] split after its [count]th visible item, so the left part ends
/// with that item and the deleted items after it go right. With [count]
/// 0, everything goes right.
(_Node?, _Node?) _cut(_Node? node, int count) {
  if (node == null) {
    return (null, null);
  }
  if (count == 0) {
    return (null, node);
  }
  final left = node.left?.visible ?? 0;
  if (count <= left) {
    final (low, high) = _cut(node.left, count);
    return (low, node.make(high, node.right));
  }
  final (low, high) = _cut(node.right, count - left - (node.shown ? 1 : 0));
  return (node.make(node.left, low), high);
}

/// [node] with every visible item deleted by the operation stamped
/// [stamp]. Subtrees with nothing visible are kept as they are.
_Node? _hide(_Node? node, Stamp stamp) {
  if (node == null || node.visible == 0) {
    return node;
  }
  return _Node(
    node.identity,
    node.shown ? [stamp] : node.deleted,
    node.priority,
    _hide(node.left, stamp),
    _hide(node.right, stamp),
  );
}

/// [node] split into its first [rank] items and the rest.
(_Node?, _Node?) _split(_Node? node, int rank) {
  if (node == null) {
    return (null, null);
  }
  final left = node.left?.size ?? 0;
  if (rank <= left) {
    final (low, high) = _split(node.left, rank);
    return (low, node.make(high, node.right));
  }
  final (low, high) = _split(node.right, rank - left - 1);
  return (node.make(node.left, low), high);
}

/// [node] with the item at [rank] also deleted by the operation stamped
/// [stamp].
_Node _deleted(_Node? node, int rank, Stamp stamp) {
  final left = node!.left?.size ?? 0;
  if (rank < left) {
    return node.make(_deleted(node.left, rank, stamp), node.right);
  }
  if (rank > left) {
    return node.make(node.left, _deleted(node.right, rank - left - 1, stamp));
  }
  return _Node(
    node.identity,
    List.unmodifiable([...node.deleted, stamp]),
    node.priority,
    node.left,
    node.right,
  );
}

/// The first item below [node] in tree order.
_Node _first(_Node node) {
  var first = node;
  for (var left = first.left; left != null; left = left.left) {
    first = left;
  }
  return first;
}

/// The last item below [node] in tree order.
_Node _last(_Node node) {
  var last = node;
  for (var right = last.right; right != null; right = right.right) {
    last = right;
  }
  return last;
}

final class _Node extends Node<_Node> {
  _Node(this.identity, this.deleted, this.priority, this.left, this.right)
    : visible =
          (deleted.isEmpty ? 1 : 0) +
          (left?.visible ?? 0) +
          (right?.visible ?? 0),
      size = 1 + (left?.size ?? 0) + (right?.size ?? 0);

  final Identity identity;

  /// The stamps of the operations that deleted the item.
  final List<Stamp> deleted;
  @override
  final int priority;
  @override
  final _Node? left;
  @override
  final _Node? right;

  /// The visible items in this subtree.
  final int visible;

  /// The items in this subtree.
  final int size;

  /// Whether the item is visible, that is, not deleted.
  bool get shown => deleted.isEmpty;

  @override
  (_Node?, _Node?) open() => (left, right);

  @override
  _Node make(_Node? left, _Node? right) =>
      _Node(identity, deleted, priority, left, right);
}
