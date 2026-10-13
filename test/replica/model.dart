import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/replica/operation.dart';
import 'package:libara/src/replica/stamp.dart';
import 'package:libara/src/sequence/sequence.dart';

import '../support.dart';

/// The canonical replay of a set of operations, written independently and
/// sharing no code with the replica.
///
/// Slow by design: every state is recomputed from the whole tree. A
/// command's steps are numbered so that a `Replace` deletes before it
/// inserts: command `i` deletes at step `2i` and inserts at step `2i + 1`.
final class Model<T> {
  Model._(List<Operation<T>> operations)
    : _operations = {
        for (final operation in operations) operation.stamp: operation,
      };

  /// The replay of [operations], which must be valid and causally closed.
  static Model<T> of<T>(Iterable<Operation<T>> operations) {
    final model = Model<T>._(operations.toList());
    model._replay();
    return model;
  }

  final Map<Stamp, Operation<T>> _operations;

  /// The right children of the start.
  final List<_Item> _roots = [];

  /// The replayed document.
  Document<T> document = Document<T>.empty();

  /// The model's marker for each key the replay marked.
  final Map<Key, Marker> markers = {};

  void _replay() {
    final order = _operations.keys.toList()..sort();
    final before = <Stamp>{};
    for (final stamp in order) {
      final operation = _operations[stamp]!;
      final context = _ancestors(operation.parents);
      for (final (index, command) in operation.commands.indexed) {
        final source = _State(context, stamp, 2 * index);
        final target = _State(before, stamp, 2 * index);
        final commands = switch (command) {
          Insert(:final position, :final items) => _insert(
            stamp,
            index,
            position,
            items,
            _State(context, stamp, 2 * index + 1),
            _State(before, stamp, 2 * index + 1),
          ),
          Delete(:final span) => _delete(stamp, index, span, source, target),
          Replace(:final span, :final items) => [
            ..._delete(stamp, index, span, source, target),
            ..._insert(
              stamp,
              index,
              span.start,
              items,
              _State(context, stamp, 2 * index + 1),
              _State(before, stamp, 2 * index + 1),
            ),
          ],
          Mark(:final marker, :final range, :final start, :final end) => [
            _mark(operation.keys[marker]!, range, start, end, source, target),
          ],
          // A replica refuses a move, so none is ever replayed here.
          Move() => throw UnsupportedError('a move is not replicated'),
          Unmark(:final marker) => [
            if (_marked(operation.keys[marker]!) case final mine?)
              Unmark<T>(mine),
          ],
          Update(:final marker, :final attributes) => [
            if (_marked(operation.keys[marker]!) case final mine?)
              Update<T>(mine, attributes),
          ],
        };
        document = document.transact(commands).unwrap();
      }
      before.add(stamp);
    }
  }

  /// The stamps of [parents] and all their ancestors.
  Set<Stamp> _ancestors(List<Stamp> parents) {
    final found = <Stamp>{};
    final pending = [...parents];
    while (pending.isNotEmpty) {
      final stamp = pending.removeLast();
      if (found.add(stamp)) {
        pending.addAll(_operations[stamp]!.parents);
      }
    }
    return found;
  }

  /// Every item in tree order: left children, the item, right children.
  List<_Item> get _order {
    final order = <_Item>[];
    void read(_Item item) {
      item.lefts.forEach(read);
      order.add(item);
      item.rights.forEach(read);
    }

    _roots.forEach(read);
    return order;
  }

  List<Command<T>> _insert(
    Stamp stamp,
    int command,
    int position,
    Sequence<T> items,
    _State source,
    _State target,
  ) {
    if (items.length == 0) {
      return const [];
    }
    final held = [
      for (final item in _order)
        if (source.holds(item)) item,
    ];
    final shown = [
      for (final item in held)
        if (source.shows(item)) item,
    ];
    final before = position == 0 ? null : shown[position - 1];
    final rights = [
      for (final item in before?.rights ?? _roots)
        if (source.holds(item)) item,
    ];
    var (parent, right) = rights.isEmpty
        ? (before, true)
        : (held[before == null ? 0 : held.indexOf(before) + 1], false);
    _Item? first;
    for (var offset = 0; offset < items.length; offset++) {
      final item = _Item((stamp, command, offset), 2 * command + 1);
      _place(item, parent, right);
      first ??= item;
      (parent, right) = (item, true);
    }
    final at = _order
        .takeWhile((item) => item != first)
        .where(target.shows)
        .length;
    return [Insert(at, items)];
  }

  void _place(_Item item, _Item? parent, bool right) {
    final siblings = parent == null
        ? _roots
        : right
        ? parent.rights
        : parent.lefts;
    var at = 0;
    while (at < siblings.length && _compare(siblings[at].id, item.id) < 0) {
      at++;
    }
    siblings.insert(at, item);
  }

  List<Command<T>> _delete(
    Stamp stamp,
    int command,
    Range span,
    _State source,
    _State target,
  ) {
    final shown = [
      for (final item in _order)
        if (source.shows(item)) item,
    ];
    final doomed = shown.sublist(span.start, span.end);
    final visible = [
      for (final item in _order)
        if (target.shows(item)) item,
    ];
    final places = [
      for (final item in doomed)
        if (target.shows(item)) visible.indexOf(item),
    ];
    final runs = <(int, int)>[];
    for (final place in places) {
      if (runs.isNotEmpty && runs.last.$2 == place) {
        runs.last = (runs.last.$1, place + 1);
      } else {
        runs.add((place, place + 1));
      }
    }
    for (final item in doomed) {
      item.deletions.add((stamp, 2 * command));
    }
    return [
      for (final (start, end) in runs.reversed) Delete<T>(_between(start, end)),
    ];
  }

  Command<T> _mark(
    Key key,
    ARange range,
    Gravity start,
    Gravity end,
    _State source,
    _State target,
  ) {
    final order = _order;
    final shown = [
      for (final item in order)
        if (source.shows(item)) item,
    ];
    int mapped(int position, Gravity gravity) {
      if (gravity == Gravity.right) {
        if (position == shown.length) {
          return order.where(target.shows).length;
        }
        final anchor = shown[position];
        return order
            .takeWhile((item) => item != anchor)
            .where(target.shows)
            .length;
      }
      if (position == 0) {
        return 0;
      }
      final anchor = shown[position - 1];
      final upto = order.indexOf(anchor) + 1;
      return order.take(upto).where(target.shows).length;
    }

    final first = mapped(range.start, start);
    final last = mapped(range.end, end);
    final marker = Marker();
    markers[key] = marker;
    return Mark.of(
      marker,
      ARange.from(
        span(first, last < first ? 0 : last - first),
        range.attributes,
      ),
      start: start,
      end: end,
    );
  }

  /// The model's marker for [key] when the document holds it marked.
  Marker? _marked(Key key) {
    final marker = markers[key];
    return marker != null && document.resolve(marker) != null ? marker : null;
  }
}

typedef _Identity = (Stamp, int, int);

int _compare(_Identity a, _Identity b) => a.$1 != b.$1
    ? a.$1.compareTo(b.$1)
    : a.$2 != b.$2
    ? a.$2 - b.$2
    : a.$3 - b.$3;

/// The range from [start] to [end].
Range _between(int start, int end) => span(start, end - start);

final class _Item {
  _Item(this.id, this.step);

  final _Identity id;

  /// The step of its operation that inserted it.
  final int step;

  final List<_Item> lefts = [];
  final List<_Item> rights = [];

  /// The operations and steps that deleted it.
  final List<(Stamp, int)> deletions = [];
}

/// A document state: the operations in [operations], and the steps of
/// operation [stamp] before [step].
final class _State {
  _State(this.operations, this.stamp, this.step);

  final Set<Stamp> operations;
  final Stamp stamp;
  final int step;

  bool _has(Stamp stamp, int step) =>
      operations.contains(stamp) || (stamp == this.stamp && step < this.step);

  /// Whether the state holds [item], deleted or not.
  bool holds(_Item item) => _has(item.id.$1, item.step);

  /// Whether [item] is visible in the state.
  bool shows(_Item item) =>
      holds(item) &&
      !item.deletions.any((deletion) => _has(deletion.$1, deletion.$2));
}
