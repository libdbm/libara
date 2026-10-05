/// The replica module: peer-to-peer replication of a `Document`.
library;

import '../attributed/attributed.dart';
import '../persistent/persistent.dart';
import '../range/range.dart';
import '../sequence/sequence.dart';
import 'history.dart';
import 'operation.dart';
import 'stamp.dart';
import 'table.dart';

export 'format.dart';
export 'operation.dart';
export 'stamp.dart';

/// Milliseconds since the epoch, from the system clock.
int _now() => DateTime.now().millisecondsSinceEpoch;

int _stamps(Stamp a, Stamp b) => a.compareTo(b);

int _keys(Key a, Key b) =>
    a.stamp != b.stamp ? a.stamp.compareTo(b.stamp) : a.index - b.index;

int _markers(Marker a, Marker b) => a.sequence - b.sequence;

/// The replay of the operations up to some point of the canonical order:
/// the document, its history, and the heads of those operations.
typedef _State<T> = ({
  Document<T> document,
  History history,
  List<Stamp> heads,
});

/// One replica of a document edited by many, with no server.
///
/// Each [commit] makes an [Operation] to send to the other replicas, and
/// each operation from them goes to [receive]. Replicas that hold the same
/// operations hold equal documents, with the same ranges under the same
/// [Key]s. Immutable: [commit] and [receive] return a new replica.
final class Replica<T> {
  const Replica._(
    this.id,
    this._clock,
    this._state,
    this._states,
    this._operations,
    this._keyed,
    this._marked,
    this._unmarks,
  );

  /// An empty replica with [id], which must be non-empty and different
  /// from every other replica's, or a [Kind.invalid] failure.
  ///
  /// [clock] gives physical time in milliseconds since the epoch, the
  /// system clock by default; [skew] is how far ahead of it, in
  /// milliseconds, a received stamp may be, and must not be negative.
  static Result<Replica<S>> create<S>(
    String id, {
    int Function() clock = _now,
    int skew = 1000,
  }) {
    if (id.isEmpty) {
      return const Failure(Kind.invalid, 'replica: the id is empty');
    }
    if (skew < 0) {
      return Failure(Kind.invalid, 'replica: skew $skew is negative');
    }
    return Success(
      Replica<S>._(
        id,
        Clock(id, clock, skew),
        (
          document: Document<S>.empty(),
          history: const History.empty(),
          heads: const [],
        ),
        Table<Stamp, _State<S>>(_stamps),
        Table<Stamp, Operation<S>>(_stamps),
        const Table<Marker, Key>(_markers),
        const Table<Key, Marker>(_keys),
        const Table<Key, List<Stamp>>(_keys),
      ),
    );
  }

  /// The replica's id, in every stamp it makes.
  final String id;

  final Clock _clock;

  /// The replay of every operation held.
  final _State<T> _state;

  /// The replay up to and including each held operation, by its stamp, so
  /// that an operation arriving out of order replays from its place.
  final Table<Stamp, _State<T>> _states;

  /// Every operation held, by stamp.
  final Table<Stamp, Operation<T>> _operations;

  /// The replay of every operation held, in canonical order.
  Document<T> get document => _state.document;

  /// The stamps of the held operations that no held operation follows,
  /// in order.
  List<Stamp> get heads => _state.heads;

  /// The key of each of this replica's markers.
  final Table<Marker, Key> _keyed;

  /// This replica's marker for each key.
  final Table<Key, Marker> _marked;

  /// The stamps of the operations that unmarked each key.
  final Table<Key, List<Stamp>> _unmarks;

  /// The key of [marker], or `null` when this replica does not know it.
  Key? key(Marker marker) => _keyed.get(marker);

  /// This replica's marker for [key], or `null` when it holds no such key.
  Marker? marker(Key key) => _marked.get(key);

  /// [commands] as a new operation made here: the next replica and the
  /// operation to send to the others.
  ///
  /// The operation's stamp is greater than every held stamp, so it applies
  /// to [document] as `Document.transact` does, and fails as that fails,
  /// with the same kind and message. An empty list, a `Mark` of a marker
  /// this replica already knows, and an `Unmark` or `Update` of one it does
  /// not are [Kind.invalid] failures.
  Result<(Replica<T>, Operation<T>)> commit(List<Command<T>> commands) {
    if (commands.isEmpty) {
      return const Failure(Kind.invalid, 'replica: nothing to commit');
    }
    final created = <Marker, int>{};
    for (final (index, command) in commands.indexed) {
      switch (command) {
        case Mark(:final marker):
          if (_keyed.get(marker) != null || created.containsKey(marker)) {
            return Failure(
              Kind.invalid,
              'replica: command $index: $marker is already known',
            );
          }
          created[marker] = index;
        case Unmark(:final marker) || Update(:final marker):
          if (_keyed.get(marker) == null && !created.containsKey(marker)) {
            return Failure(
              Kind.invalid,
              'replica: command $index: $marker is not known',
            );
          }
        case Insert() || Delete() || Replace():
          break;
      }
    }
    return document.transact(commands).map((next) {
      final (clock, stamp) = _clock.tick();
      final fresh = {
        for (final MapEntry(key: marker, value: index) in created.entries)
          Key(stamp, index): marker,
      };
      final keys = <Marker, Key>{};
      for (final command in commands) {
        if (_named(command) case final marker?) {
          keys[marker] = _keyed.get(marker) ?? Key(stamp, created[marker]!);
        }
      }
      final operation = Operation<T>(stamp, heads, commands, keys);
      final state = (
        document: next,
        history: _state.history.apply(stamp, commands),
        heads: _following(heads, operation),
      );
      return (_added(operation, clock, [(stamp, state)], fresh), operation);
    });
  }

  /// This replica with [operation] merged, and the commands that turn the
  /// previous [document] into the new one.
  ///
  /// An operation already held changes nothing. A parent this replica
  /// does not hold is a [Kind.missing] failure naming it. A stamp more
  /// than the skew ahead of the clock, a stamp not after every parent's,
  /// parents not sorted without duplicates, a different operation under a
  /// held stamp, a `Mark` whose key is not its stamp and place, a marker
  /// with no key, and an `Unmark` or `Update` of a key not marked in its
  /// context are [Kind.invalid] failures. A command that does not fit its
  /// context fails as `Document.transact` reports it there.
  ///
  /// An operation with a stamp below a held one replays from its place:
  /// it and every later operation are applied again to the replay of the
  /// operations before it, which the replica keeps for each.
  Result<(Replica<T>, List<Command<T>>)> receive(Operation<T> operation) {
    final stamp = operation.stamp;
    Failure<(Replica<T>, List<Command<T>>)> failure(Kind kind, String text) =>
        Failure(kind, 'replica: $stamp: $text');
    if (_operations.get(stamp) case final held?) {
      return held.same(operation)
          ? Success((this, const []))
          : failure(Kind.invalid, 'differs from the held operation');
    }
    final parents = operation.parents;
    for (final (index, parent) in parents.indexed) {
      if (index > 0 && parents[index - 1].compareTo(parent) >= 0) {
        return failure(Kind.invalid, 'parents are not sorted and distinct');
      }
    }
    for (final parent in parents) {
      if (_operations.get(parent) == null) {
        return failure(Kind.missing, 'parent $parent is not held');
      }
    }
    if (_clock.check(stamp) case Failure(:final kind, :final message)) {
      return Failure(kind, message);
    }
    for (final parent in parents) {
      if (stamp.compareTo(parent) <= 0) {
        return failure(Kind.invalid, 'is not after its parent $parent');
      }
    }
    for (final (index, command) in operation.commands.indexed) {
      final named = _named(command);
      if (named == null) {
        continue;
      }
      final key = operation.keys[named];
      if (key == null) {
        return failure(Kind.invalid, 'command $index: $named has no key');
      }
      if (command is Mark<T> && key != Key(stamp, index)) {
        return failure(
          Kind.invalid,
          'command $index: key $key is not ${Key(stamp, index)}',
        );
      }
    }
    final clock = _clock.take(stamp);
    if (heads.isEmpty || stamp.compareTo(heads.last) > 0) {
      return switch (_step(operation, _state)) {
        Failure(:final kind, :final message) => failure(kind, message),
        Success(value: (final state, final local, final created)) => Success((
          _added(operation, clock, [(stamp, state)], created),
          local,
        )),
      };
    }
    // Out of order: replay from the operation's place.
    var base = _empty;
    for (final (held, state) in _states.entries) {
      if (held.compareTo(stamp) > 0) {
        break;
      }
      base = state;
    }
    final _State<T> placed;
    final Map<Key, Marker> created;
    switch (_step(operation, base)) {
      case Failure(:final kind, :final message):
        return failure(kind, message);
      case Success(value: (final state, _, final fresh)):
        (placed, created) = (state, fresh);
    }
    var state = placed;
    final checkpoints = [(stamp, state)];
    for (final (held, later) in _operations.entries) {
      if (held.compareTo(stamp) < 0) {
        continue;
      }
      switch (_step(later, state)) {
        case Failure(:final kind, :final message):
          return failure(kind, 'replaying $held: $message');
        case Success(value: (final next, _, _)):
          state = next;
          checkpoints.add((held, state));
      }
    }
    return _changes(state).map(
      (commands) => (_added(operation, clock, checkpoints, created), commands),
    );
  }

  /// The held operations not in the causal past of [heads], in canonical
  /// order: what a replica whose heads are [heads] lacks. Stamps this
  /// replica does not hold are ignored.
  List<Operation<T>> since(List<Stamp> heads) {
    final seen = _ancestors([
      for (final head in heads)
        if (_operations.get(head) != null) head,
    ]);
    return List.unmodifiable([
      for (final (stamp, operation) in _operations.entries)
        if (!seen.contains(stamp)) operation,
    ]);
  }

  /// The replay of nothing.
  _State<T> get _empty => (
    document: Document<T>.empty(),
    history: const History.empty(),
    heads: const [],
  );

  /// [operation], whose keys are checked, applied to [state], the replay of
  /// the operations before it in canonical order: the next state, the
  /// commands that carried it out, and this replica's markers for the keys
  /// its marks created, existing ones kept.
  ///
  /// With every operation before it in its context, its commands apply as
  /// they are. Otherwise each is transformed from its context: positions
  /// through the history, and an `Unmark` or `Update` of a key no longer
  /// marked becomes nothing.
  Result<(_State<T>, List<Command<T>>, Map<Key, Marker>)> _step(
    Operation<T> operation,
    _State<T> state,
  ) {
    final stamp = operation.stamp;
    final sequential = _equal(operation.parents, state.heads);
    final seen = sequential
        ? const <Stamp>{}
        : {..._ancestors(operation.parents), stamp};
    var history = state.history;
    final local = <Command<T>>[];
    final created = <Key, Marker>{};
    final gone = <Key>{};

    // This replica's marker for [key] when the state, with this operation's
    // earlier commands, holds it marked.
    Marker? current(Key key) {
      if (gone.contains(key)) {
        return null;
      }
      if (created[key] case final mine?) {
        return mine;
      }
      final mine = _marked.get(key);
      return mine != null && state.document.resolve(mine) != null ? mine : null;
    }

    // Whether [key] is marked in the context of the command: marked by an
    // operation the context holds, or earlier in this one, and not unmarked
    // by one it holds, or earlier in this one.
    bool context(Key key) {
      if (gone.contains(key)) {
        return false;
      }
      if (key.stamp == stamp) {
        return created.containsKey(key);
      }
      if (sequential) {
        return current(key) != null;
      }
      final marking = _operations.get(key.stamp);
      return seen.contains(key.stamp) &&
          key.index < marking!.commands.length &&
          marking.commands[key.index] is Mark &&
          // Its own unmarks, recorded when it was first applied, count only
          // through [gone].
          !(_unmarks.get(key) ?? const []).any(
            (unmark) => unmark != stamp && seen.contains(unmark),
          );
    }

    for (final (index, command) in operation.commands.indexed) {
      final named = _named(command);
      final key = named == null ? null : operation.keys[named];
      switch (command) {
        case Mark(:final range, :final start, :final end):
          final Range mapped;
          if (sequential) {
            mapped = range;
          } else {
            switch (history.mapped(range, start, end, seen, index)) {
              case Failure(:final kind, :final message):
                return Failure(kind, message);
              case Success(:final value):
                mapped = value;
            }
          }
          final mine = _marked.get(key!) ?? Marker();
          created[key] = mine;
          local.add(
            Mark.of(
              mine,
              ARange.from(mapped, range.attributes),
              start: start,
              end: end,
            ),
          );
        case Unmark() || Update():
          if (!context(key!)) {
            return Failure(Kind.invalid, 'command $index: $key is not marked');
          }
          // The key may have been unmarked concurrently: then nothing.
          if (current(key) case final mine?) {
            local.add(
              command is Update<T>
                  ? Update(mine, command.attributes)
                  : Unmark(mine),
            );
          }
          if (command is Unmark<T>) {
            gone.add(key);
          }
        case Insert() || Delete() || Replace():
          if (sequential) {
            local.add(command);
            continue;
          }
          switch (history.merge(stamp, index, command, seen)) {
            case Failure(:final kind, :final message):
              return Failure(kind, message);
            case Success(value: (final next, final commands)):
              history = next;
              local.addAll(commands);
          }
      }
    }
    return state.document
        .transact(local)
        .map(
          (next) => (
            (
              document: next,
              history: sequential ? history.apply(stamp, local) : history,
              heads: _following(state.heads, operation),
            ),
            List<Command<T>>.unmodifiable(local),
            created,
          ),
        );
  }

  /// Commands that turn [document] into the document of [state]: the items
  /// that became visible or hidden, found through the two histories, then
  /// every marker whose range or attributes differ, compared by marker.
  Result<List<Command<T>>> _changes(_State<T> state) {
    final shown = {
      for (final (identity, deleted) in _state.history.items)
        if (deleted.isEmpty) identity,
    };
    final after = state.document;
    final items = <Command<T>>[];
    var (position, index, deleting, inserting) = (0, 0, 0, 0);
    void flush() {
      if (deleting > 0) {
        items.add(Delete(extent(position, deleting)));
        deleting = 0;
      }
      if (inserting > 0) {
        items.add(Insert(position, after.slice(index - inserting, inserting)));
        position += inserting;
        inserting = 0;
      }
    }

    for (final (identity, deleted) in state.history.items) {
      final was = shown.contains(identity);
      final now = deleted.isEmpty;
      if (was && now) {
        flush();
        position++;
        index++;
      } else if (was) {
        if (inserting > 0) {
          flush();
        }
        deleting++;
      } else if (now) {
        if (deleting > 0) {
          flush();
        }
        inserting++;
        index++;
      }
    }
    flush();
    return document.transact(items).map((moved) {
      final before = {
        for (final (marker, range) in moved.markers) marker: range,
      };
      final commands = [...items];
      for (final marker in before.keys) {
        if (after.resolve(marker) == null) {
          commands.add(Unmark(marker));
        }
      }
      for (final (marker, range) in after.markers) {
        final old = before[marker];
        final gravity = after.gravity(marker)!;
        if (old != null && old.same(range)) {
          if (old != range) {
            commands.add(Update(marker, range.attributes));
          }
          continue;
        }
        if (old != null) {
          commands.add(Unmark(marker));
        }
        commands.add(
          Mark.of(marker, range, start: gravity.start, end: gravity.end),
        );
      }
      return List.unmodifiable(commands);
    });
  }

  /// The stamps of [parents] and all their ancestors.
  Set<Stamp> _ancestors(List<Stamp> parents) {
    final found = <Stamp>{};
    final pending = [...parents];
    while (pending.isNotEmpty) {
      final stamp = pending.removeLast();
      if (found.add(stamp)) {
        pending.addAll(_operations.get(stamp)!.parents);
      }
    }
    return found;
  }

  /// This replica holding [operation], with [clock] as its clock, each of
  /// [checkpoints] as the replay up to its stamp, the last as the replay of
  /// everything, and [fresh] the markers the operation's marks created, by
  /// key.
  Replica<T> _added(
    Operation<T> operation,
    Clock clock,
    List<(Stamp, _State<T>)> checkpoints,
    Map<Key, Marker> fresh,
  ) {
    var keyed = _keyed;
    var marked = _marked;
    for (final MapEntry(:key, value: marker) in fresh.entries) {
      keyed = keyed.put(marker, key);
      marked = marked.put(key, marker);
    }
    var unmarks = _unmarks;
    for (final command in operation.commands) {
      if (command case Unmark(:final marker)) {
        final key = operation.keys[marker]!;
        unmarks = unmarks.put(key, [...?unmarks.get(key), operation.stamp]);
      }
    }
    var states = _states;
    for (final (stamp, state) in checkpoints) {
      states = states.put(stamp, state);
    }
    return Replica._(
      id,
      clock,
      checkpoints.last.$2,
      states,
      _operations.put(operation.stamp, operation),
      keyed,
      marked,
      unmarks,
    );
  }
}

/// The heads after [operation] follows the operations whose heads are
/// [heads].
List<Stamp> _following(List<Stamp> heads, Operation<Object?> operation) =>
    List.unmodifiable(
      [
        for (final head in heads)
          if (!operation.parents.contains(head)) head,
        operation.stamp,
      ]..sort(),
    );

/// The marker [command] names, or `null` for one that names none.
Marker? _named(Command<Object?> command) => switch (command) {
  Mark(:final marker) ||
  Unmark(:final marker) ||
  Update(:final marker) => marker,
  Insert() || Delete() || Replace() => null,
};

bool _equal(List<Stamp> a, List<Stamp> b) {
  if (a.length != b.length) {
    return false;
  }
  for (final (index, stamp) in a.indexed) {
    if (b[index] != stamp) {
      return false;
    }
  }
  return true;
}
