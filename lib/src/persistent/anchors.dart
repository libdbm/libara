import '../sequence/sequence.dart';
import 'carry.dart';
import 'command.dart';
import 'endpoints.dart';
import 'label.dart';

/// A position held by [Anchors], found again by [Anchors.position].
typedef Anchor = ({Label label, int owner, Gravity gravity});

/// Positions that move with edits as a [Document]'s endpoints do, each
/// with a gravity: a set of [Document.map]s carried through the commands
/// together.
///
/// The positions sit in two endpoint trees, one per gravity, which move a
/// suffix of them in one step, so a command costs O(log m) for m positions
/// however many it moves, and carrying r positions through q commands
/// costs O((q + r) log m) rather than the O(q r) of mapping each one.
///
/// Internal: for carrying a transaction's change regions to its last
/// version.
final class Anchors {
  const Anchors._(
    this._right,
    this._left,
    this._count, [
    this._labels = const {},
  ]);

  /// No positions.
  const Anchors.empty()
    : this._(const Endpoints.empty(), const Endpoints.empty(), 0);

  final Endpoints<int> _right;
  final Endpoints<int> _left;

  /// How many anchors have been added, which numbers the next.
  final int _count;

  /// The label of each anchor a move has placed again, by owner: an anchor
  /// not here keeps the label it was added with.
  final Map<int, Label> _labels;

  /// These anchors with one more at [position] with [gravity], and the
  /// anchor that finds it again: a [Kind.invalid] failure for a negative
  /// [position].
  Result<(Anchors, Anchor)> add(int position, Gravity gravity) {
    final tree = gravity == Gravity.right ? _right : _left;
    return tree.put(_count, position, false).map((placed) {
      final (endpoints, label) = placed;
      final anchor = (label: label, owner: _count, gravity: gravity);
      final next = gravity == Gravity.right
          ? Anchors._(endpoints, _left, _count + 1, _labels)
          : Anchors._(_right, endpoints, _count + 1, _labels);
      return (next, anchor);
    });
  }

  /// These anchors moved by [command], as [Document.apply] moves
  /// endpoints: a deletion collapses those in its span to its start, an
  /// insertion moves those after it, and those at it with right gravity,
  /// past the inserted items, and a move takes those strictly inside its
  /// span along with the items.
  Anchors apply(Command<Object?> command) => switch (command) {
    Insert(:final position, :final items) => Anchors._(
      _right.shift(position, items.length),
      _left.shift(position + 1, items.length),
      _count,
      _labels,
    ),
    Delete(:final span) => Anchors._(
      _right.collapse(span.start, span.end),
      _left.collapse(span.start, span.end),
      _count,
      _labels,
    ),
    Replace(:final span, :final items) => Anchors._(
      _right.collapse(span.start, span.end).shift(span.start, items.length),
      _left.collapse(span.start, span.end).shift(span.start + 1, items.length),
      _count,
      _labels,
    ),
    Move(:final span, :final to) when to == span.start || to == span.end =>
      this,
    Move() => _move(command),
    Mark() || Unmark() || Update() => this,
  };

  /// These anchors after [move], which reorders positions: the labels must
  /// increase in position order, so each tree is built again with fresh
  /// labels, and [_labels] records them for the anchors already handed
  /// out. Costs O(m log m) for m anchors.
  Anchors _move(Move<Object?> move) {
    final labels = {..._labels};
    Endpoints<int> placed(Endpoints<int> tree, Gravity gravity) {
      // Ties keep their order, as the sort is not stable on its own.
      final entries = [
        for (final (index, endpoint) in tree.entries.indexed)
          (moved(endpoint.position, gravity, move), index, endpoint),
      ]..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
      final fresh = Label.spread(entries.length);
      for (final (index, (_, _, endpoint)) in entries.indexed) {
        labels[endpoint.owner] = fresh[index];
      }
      return Endpoints.of([
        for (final (index, (position, _, endpoint)) in entries.indexed)
          (
            (
              position: position,
              label: fresh[index],
              owner: endpoint.owner,
              start: endpoint.start,
              partner: endpoint.partner,
            ),
            true,
          ),
      ]);
    }

    return Anchors._(
      placed(_right, Gravity.right),
      placed(_left, Gravity.left),
      _count,
      Map.unmodifiable(labels),
    );
  }

  /// Where [anchor], added to these anchors or ones they were moved from,
  /// stands now.
  int position(Anchor anchor) =>
      (anchor.gravity == Gravity.right ? _right : _left).position(
        _labels[anchor.owner] ?? anchor.label,
        anchor.owner,
      )!;
}
