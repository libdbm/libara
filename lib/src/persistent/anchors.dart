import '../sequence/sequence.dart';
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
  const Anchors._(this._right, this._left, this._count);

  /// No positions.
  const Anchors.empty()
    : this._(const Endpoints.empty(), const Endpoints.empty(), 0);

  final Endpoints<int> _right;
  final Endpoints<int> _left;

  /// How many anchors have been added, which numbers the next.
  final int _count;

  /// These anchors with one more at [position] with [gravity], and the
  /// anchor that finds it again: a [Kind.invalid] failure for a negative
  /// [position].
  Result<(Anchors, Anchor)> add(int position, Gravity gravity) {
    final tree = gravity == Gravity.right ? _right : _left;
    return tree.put(_count, position, false).map((placed) {
      final (endpoints, label) = placed;
      final anchor = (label: label, owner: _count, gravity: gravity);
      final next = gravity == Gravity.right
          ? Anchors._(endpoints, _left, _count + 1)
          : Anchors._(_right, endpoints, _count + 1);
      return (next, anchor);
    });
  }

  /// These anchors moved by [command], as [Document.apply] moves
  /// endpoints: a deletion collapses those in its span to its start, and
  /// an insertion moves those after it, and those at it with right
  /// gravity, past the inserted items.
  Anchors apply(Command<Object?> command) => switch (command) {
    Insert(:final position, :final items) => Anchors._(
      _right.shift(position, items.length),
      _left.shift(position + 1, items.length),
      _count,
    ),
    Delete(:final span) => Anchors._(
      _right.collapse(span.start, span.end),
      _left.collapse(span.start, span.end),
      _count,
    ),
    Replace(:final span, :final items) => Anchors._(
      _right.collapse(span.start, span.end).shift(span.start, items.length),
      _left.collapse(span.start, span.end).shift(span.start + 1, items.length),
      _count,
    ),
    Mark() || Unmark() || Update() => this,
  };

  /// Where [anchor], added to these anchors or ones they were moved from,
  /// stands now.
  int position(Anchor anchor) =>
      (anchor.gravity == Gravity.right ? _right : _left).position(
        anchor.label,
        anchor.owner,
      )!;
}
