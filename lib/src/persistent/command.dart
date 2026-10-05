import '../attributed/attributed.dart';
import '../range/range.dart';
import '../sequence/sequence.dart';

/// An edit to a document, applied with `Document.apply` to produce a new
/// version.
///
/// Commands are immutable values and can be applied to any number of
/// documents.
sealed class Command<T> {
  const Command();
}

/// Inserts [items] before [position], shifting every range endpoint at or
/// after it.
final class Insert<T> extends Command<T> {
  /// Inserts [items] before [position].
  const Insert(this.position, this.items);

  /// Where the items go; the document's length appends.
  final int position;

  /// The items to insert.
  final Sequence<T> items;

  @override
  String toString() => 'Insert($position, $items)';
}

/// Removes the items in [span], collapsing range endpoints inside it to its
/// start.
final class Delete<T> extends Command<T> {
  /// Removes the items in [span].
  const Delete(this.span);

  /// The items to remove.
  final Range span;

  @override
  String toString() => 'Delete($span)';
}

/// What happens to a range endpoint that sits exactly where items are
/// inserted.
enum Gravity {
  /// The endpoint stays before the inserted items.
  left,

  /// The endpoint moves past the inserted items.
  right,
}

/// Adds [range] to a document under a new [marker], with a [Gravity] for
/// each endpoint.
///
/// The marker is created with the command, so the caller has it before
/// applying the command, and can resolve the range in any later version.
final class Mark<T> extends Command<T> {
  /// Marks [range] under a new marker, with the given gravity at its
  /// [start] and [end].
  Mark(this.range, {this.start = Gravity.right, this.end = Gravity.right})
    : marker = Marker();

  /// Marks [range] under an existing [marker], as when a range is marked
  /// again after an unmark, or a saved document is loaded.
  const Mark.of(
    this.marker,
    this.range, {
    this.start = Gravity.right,
    this.end = Gravity.right,
  });

  /// The range to add, with its attributes.
  final ARange range;

  /// The gravity of the range's start.
  final Gravity start;

  /// The gravity of the range's end.
  final Gravity end;

  /// The identity of the range in every version that holds it.
  final Marker marker;

  @override
  String toString() => 'Mark($range, ${start.name}, ${end.name}, $marker)';
}

/// Replaces the items in [span] with [items]: exactly a [Delete] of [span]
/// followed by an [Insert] at its start, as one command.
///
/// Range endpoints inside [span] collapse to its start, then follow their
/// gravity, so a range covering exactly [span] with the default gravities
/// ends up empty after the new items.
final class Replace<T> extends Command<T> {
  /// Replaces the items in [span] with [items].
  const Replace(this.span, this.items);

  /// The items to remove.
  final Range span;

  /// The items to insert in their place.
  final Sequence<T> items;

  @override
  String toString() => 'Replace($span, $items)';
}

/// Removes the range identified by [marker] from a document.
final class Unmark<T> extends Command<T> {
  /// Removes the range under [marker].
  const Unmark(this.marker);

  /// The range to remove.
  final Marker marker;

  @override
  String toString() => 'Unmark($marker)';
}

/// Replaces the attributes of the range identified by [marker], keeping its
/// position, gravities, and identity.
final class Update<T> extends Command<T> {
  /// Gives the range under [marker] exactly [attributes].
  ///
  /// The map is copied, so later changes to the argument have no effect.
  Update(this.marker, Map<String, Value> attributes)
    : attributes = Map.unmodifiable(attributes);

  /// The range to update.
  final Marker marker;

  /// Its new attributes.
  final Map<String, Value> attributes;

  @override
  String toString() => 'Update($marker, $attributes)';
}

/// The identity of a range stored in a document, stable across edits.
///
/// Markers compare by identity. Each one also has a [sequence] number in
/// creation order, which documents use to index their markers.
final class Marker {
  /// A new marker, distinct from every other.
  Marker() : sequence = _next++;

  static int _next = 0;

  /// The position of this marker in creation order.
  final int sequence;

  @override
  String toString() => 'Marker($sequence)';
}
