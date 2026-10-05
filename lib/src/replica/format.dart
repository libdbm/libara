import '../format/format.dart';
import '../persistent/persistent.dart';
import '../sequence/sequence.dart';
import 'operation.dart';
import 'stamp.dart';

/// An [Operation] as a JSON value, for sending between replicas.
///
/// Commands are written as `JSONFormat` writes them, through the item
/// format [items], except that a marker is written as its key,
/// `[time, count, replica, index]`, in place of an integer id. A wrong
/// shape is a [Kind.syntax] failure and a value out of range a
/// [Kind.invalid] one, each naming the path. [limits] bound the commands,
/// the distinct markers, the attributes on one range, the items the
/// commands carry in all (`payload`), and the nesting of the JSON [items]
/// writes (`depth`).
final class OperationFormat<T> implements Format<Operation<T>, Object?> {
  /// A format for operations over items that [items] writes.
  const OperationFormat(this.items, {this.limits = const Limits()});

  /// The format of the items that insertions and replacements carry.
  final Format<Sequence<T>, Object?> items;

  /// Bounds on what an operation may hold.
  final Limits limits;

  @override
  Result<Object?> encode(Operation<T> value) => _prefixed(_encoded(value));

  @override
  Result<Operation<T>> decode(Object? form) => _prefixed(_decoded(form));

  Result<Object?> _encoded(Operation<T> value) {
    final count = value.commands.length;
    if (_over(limits.commands, count)) {
      return _exceeds('commands', 'commands', count, limits.commands);
    }
    if (_over(limits.markers, value.keys.length)) {
      return _exceeds('commands', 'markers', value.keys.length, limits.markers);
    }
    var payload = 0;
    final commands = <Object?>[];
    for (final (index, command) in value.commands.indexed) {
      payload += switch (command) {
        Insert(:final items) || Replace(:final items) => items.length,
        _ => 0,
      };
      if (_over(limits.payload, payload)) {
        return _exceeds('commands[$index]', 'payload', payload, limits.payload);
      }
      switch (write(
        command,
        (marker) => _key(value.keys[marker]!),
        items,
        limits,
      )) {
        case Failure(:final kind, :final message):
          return Failure(kind, 'commands[$index].$message');
        case Success(value: final json):
          commands.add(json);
      }
    }
    return Success({
      'libara': 1,
      'stamp': _stamp(value.stamp),
      'parents': [for (final parent in value.parents) _stamp(parent)],
      'commands': commands,
    });
  }

  Result<Operation<T>> _decoded(Object? form) {
    if (form is! Map<String, Object?>) {
      return const Failure(Kind.syntax, 'expected an object');
    }
    final version = form['libara'];
    if (version is! int) {
      return const Failure(Kind.syntax, 'libara: expected a version');
    }
    if (version != 1) {
      return Failure(Kind.invalid, 'unsupported version $version');
    }
    final saved = form['parents'];
    if (saved is! List<Object?>) {
      return const Failure(Kind.syntax, 'parents: expected a list');
    }
    final listed = form['commands'];
    if (listed is! List<Object?>) {
      return const Failure(Kind.syntax, 'commands: expected a list');
    }
    if (_over(limits.commands, listed.length)) {
      return _exceeds('commands', 'commands', listed.length, limits.commands);
    }
    return _read(form['stamp'], 'stamp').flatMap((stamp) {
      final parents = <Stamp>[];
      for (final (index, json) in saved.indexed) {
        switch (_read(json, 'parents[$index]')) {
          case Failure(:final kind, :final message):
            return Failure(kind, message);
          case Success(:final value):
            parents.add(value);
        }
      }
      // Each distinct key gets an index, and later a marker.
      final keys = <Key>[];
      final indices = <Key, int>{};
      Result<int> index(Object? json, String path) =>
          _keyed(json, path).flatMap((key) {
            if (indices[key] case final known?) {
              return Success(known);
            }
            if (_over(limits.markers, keys.length + 1)) {
              return _exceeds(path, 'markers', keys.length + 1, limits.markers);
            }
            keys.add(key);
            return Success(indices[key] = keys.length - 1);
          });
      final builds = <Command<T> Function(List<Marker> markers)>[];
      var payload = 0;
      for (final (position, json) in listed.indexed) {
        final path = 'commands[$position]';
        switch (read(json, path, items, limits.attributes, index)) {
          case Failure(:final kind, :final message):
            return Failure(kind, message);
          case Success(value: (_, final build, _, final added)):
            payload += added;
            if (_over(limits.payload, payload)) {
              return _exceeds(path, 'payload', payload, limits.payload);
            }
            builds.add(build);
        }
      }
      final markers = List.generate(keys.length, (_) => Marker());
      return Success(
        Operation(
          stamp,
          parents,
          [for (final build in builds) build(markers)],
          {for (final (at, marker) in markers.indexed) marker: keys[at]},
        ),
      );
    });
  }
}

/// [result] with a failure's message prefixed `replica: `.
Result<V> _prefixed<V>(Result<V> result) => switch (result) {
  Success() => result,
  Failure(:final kind, :final message) => Failure(kind, 'replica: $message'),
};

bool _over(int? bound, int count) => bound != null && count > bound;

Failure<V> _exceeds<V>(String path, String name, int count, int? bound) =>
    Failure(Kind.invalid, '$path: $name: $count exceeds $bound');

List<Object?> _stamp(Stamp stamp) => [stamp.time, stamp.count, stamp.replica];

List<Object?> _key(Key key) => [..._stamp(key.stamp), key.index];

/// The stamp [json] holds as `[time, count, replica]`.
Result<Stamp> _read(Object? json, String path) {
  if (json is! List<Object?> ||
      json.length != 3 ||
      json[0] is! int ||
      json[1] is! int ||
      json[2] is! String) {
    return Failure(Kind.syntax, '$path: expected [time, count, replica]');
  }
  return _stamped(json[0]! as int, json[1]! as int, json[2]! as String, path);
}

/// The stamp at [time] with [count] by [replica], which must be
/// non-negative and non-empty.
Result<Stamp> _stamped(int time, int count, String replica, String path) =>
    time < 0 || count < 0 || replica.isEmpty
    ? Failure(Kind.invalid, '$path: [$time, $count, "$replica"] is not a stamp')
    : Success(Stamp(time, count, replica));

/// The key [json] holds as `[time, count, replica, index]`.
Result<Key> _keyed(Object? json, String path) {
  if (json is! List<Object?> ||
      json.length != 4 ||
      json[0] is! int ||
      json[1] is! int ||
      json[2] is! String ||
      json[3] is! int) {
    return Failure(
      Kind.syntax,
      '$path: expected [time, count, replica, index]',
    );
  }
  final index = json[3]! as int;
  if (index < 0) {
    return Failure(Kind.invalid, '$path: index $index is negative');
  }
  return _stamped(
    json[0]! as int,
    json[1]! as int,
    json[2]! as String,
    path,
  ).map((stamp) => Key(stamp, index));
}
