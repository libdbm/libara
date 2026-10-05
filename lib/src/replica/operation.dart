import '../attributed/attributed.dart';
import '../persistent/persistent.dart';
import 'stamp.dart';

/// One transaction of one replica, as it travels to the others.
///
/// Its [commands] apply in order as `Document.transact` applies them, to
/// the document its context gives: the operations it had seen, which are
/// its [parents] and all their ancestors. Markers in the commands are the
/// sending replica's; [keys] gives each one's durable [Key].
final class Operation<T> {
  /// The operation stamped [stamp] after [parents], applying [commands],
  /// whose markers have [keys]. The collections are copied.
  Operation(
    this.stamp,
    List<Stamp> parents,
    List<Command<T>> commands,
    Map<Marker, Key> keys,
  ) : parents = List.unmodifiable(parents),
      commands = List.unmodifiable(commands),
      keys = Map.unmodifiable(keys);

  /// The operation's id and its place in the canonical order.
  final Stamp stamp;

  /// The heads of the replica that made it, at the time: the stamps of the
  /// operations it had seen that no other seen operation follows. Sorted,
  /// without duplicates; empty for a first operation.
  final List<Stamp> parents;

  /// The transaction.
  final List<Command<T>> commands;

  /// The key of every marker the commands name.
  final Map<Marker, Key> keys;

  /// Whether [other] has the same stamp, parents, and commands, comparing
  /// markers by their keys.
  bool same(Operation<Object?> other) {
    if (other.stamp != stamp ||
        other.parents.length != parents.length ||
        other.commands.length != commands.length) {
      return false;
    }
    for (final (index, parent) in parents.indexed) {
      if (other.parents[index] != parent) {
        return false;
      }
    }
    Key? key(Marker marker) => keys[marker];
    Key? theirs(Marker marker) => other.keys[marker];
    for (final (index, command) in commands.indexed) {
      final equal = switch ((command, other.commands[index])) {
        (Insert(:final position, :final items), final Insert<Object?> b) =>
          position == b.position && items == b.items,
        (Delete(:final span), final Delete<Object?> b) => span.same(b.span),
        (Replace(:final span, :final items), final Replace<Object?> b) =>
          span.same(b.span) && items == b.items,
        (final Mark<T> a, final Mark<Object?> b) =>
          a.range == b.range &&
              a.start == b.start &&
              a.end == b.end &&
              key(a.marker) == theirs(b.marker),
        (Unmark(:final marker), final Unmark<Object?> b) =>
          key(marker) == theirs(b.marker),
        (final Update<T> a, final Update<Object?> b) =>
          key(a.marker) == theirs(b.marker) &&
              _equal(a.attributes, b.attributes),
        _ => false,
      };
      if (!equal) {
        return false;
      }
    }
    return true;
  }

  @override
  String toString() => 'Operation($stamp, $parents, $commands)';
}

bool _equal(Map<String, Value> a, Map<String, Value> b) =>
    a.length == b.length &&
    a.entries.every((entry) => b[entry.key] == entry.value);
