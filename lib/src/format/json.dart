part of 'format.dart';

/// Optional bounds on what [JSONFormat] reads and writes, for documents from
/// sources that are not trusted. A `null` bound is unlimited, and so is
/// `const Limits()`, the default.
///
/// Each bound is checked before the allocation it guards, and a value past
/// one is a [Kind.invalid] failure naming the bound and the path.
final class Limits {
  /// Bounds on [items], [payload], [markers], [commands], [attributes],
  /// and [depth].
  const Limits({
    this.items,
    this.payload,
    this.markers,
    this.commands,
    this.attributes,
    this.depth,
  });

  /// Items in any version. Loading checks it after each replayed command,
  /// so a short history cannot expand past it.
  final int? items;

  /// Items decoded in all: those of the first version and those of every
  /// insert and replace in the history, kept or later deleted. Loading
  /// checks it after each decode, before the next, so it bounds what the
  /// item format is asked to build, to within one decode.
  final int? payload;

  /// Marker ids, in the current version and the history.
  final int? markers;

  /// Commands in the saved history.
  final int? commands;

  /// Attributes on one range or in one update.
  final int? attributes;

  /// Nesting of the lists and maps in the JSON an item format writes.
  final int? depth;
}

/// Whether [count] is past [bound], when there is one.
bool _over(int? bound, int count) => bound != null && count > bound;

/// The failure at [path] for [count] past the bound called [name].
Failure<V> _exceeds<V>(String path, String name, int count, int? bound) =>
    Failure(Kind.invalid, '$path: $name: $count exceeds $bound');

/// A `Document<T>` as a JSON value, built only from maps, lists, strings,
/// integers, booleans, and `null`
///
/// The current version's markers get ids in the order of
/// [Document.markers]. With [history], the value holds version 0 and the
/// commands of every later version, and markers that appear only there get
/// the next ids. [decode] and [restore] never throw: input of the wrong
/// shape is a [Kind.syntax] failure and input that cannot be used is
/// [Kind.invalid], each naming its path.
final class JSONFormat<T> implements Format<Document<T>, Object?> {
  /// The format for documents whose items travel through [items].
  const JSONFormat(
    this.items, {
    this.history = false,
    this.limits = const Limits(),
  });

  /// How the document's items travel.
  final Format<Sequence<T>, Object?> items;

  /// Whether [encode] includes every earlier version.
  final bool history;

  /// The bounds [encode], [decode], and [restore] keep to.
  final Limits limits;

  @override
  Result<Object?> encode(Document<T> value) =>
      _save(value, items, history, limits);

  @override
  Result<Document<T>> decode(Object? form) =>
      restore(form).map((restored) => restored.$1);

  /// The document [form] holds, and one fresh [Marker] per saved marker
  /// id, in id order, for callers that keep references to markers across a
  /// save and load.
  Result<(Document<T>, List<Marker>)> restore(Object? form) =>
      _load(form, items, limits);
}

/// [points] as a string that reads back as the same points, or a failure
/// for a value that is not a code point or a surrogate pair that would
/// merge.
Result<String> _string(Iterable<int> points) {
  var high = false;
  for (final (position, point) in points.indexed) {
    if (point < 0 || point > 0x10FFFF) {
      return Failure(
        Kind.invalid,
        '$point at position $position is not a code point',
      );
    }
    final low = point >= 0xDC00 && point <= 0xDFFF;
    if (high && low) {
      return Failure(
        Kind.invalid,
        'surrogates at position ${position - 1} would merge into one '
        'character',
      );
    }
    high = point >= 0xD800 && point <= 0xDBFF;
  }
  return Success(String.fromCharCodes(points));
}

/// [document] as a JSON value; see [JSONFormat].
Result<Map<String, Object?>> _save<T>(
  Document<T> document,
  Format<Sequence<T>, Object?> format,
  bool history,
  Limits limits,
) {
  final ids = <Marker, int>{
    for (final (id, (marker, _)) in document.markers.indexed) marker: id,
  };
  int id(Marker marker) => ids.putIfAbsent(marker, () => ids.length);
  final chain = [document];
  if (history) {
    for (var earlier = document.previous; earlier != null;) {
      chain.add(earlier);
      earlier = earlier.previous;
    }
  }
  final base = chain.last;
  if (_over(limits.items, base.length)) {
    return _exceeds('format: items', 'items', base.length, limits.items);
  }
  var payload = base.length;
  if (_over(limits.payload, payload)) {
    return _exceeds('format: items', 'payload', payload, limits.payload);
  }
  final json = <String, Object?>{'libara': 1};
  switch (_written(format, base, 'items', limits.depth)) {
    case Failure(:final kind, :final message):
      return Failure(kind, 'format: $message');
    case Success(:final value):
      json['items'] = value;
  }
  final marked = base.markers;
  if (_over(limits.markers, marked.length)) {
    return _exceeds(
      'format: markers',
      'markers',
      marked.length,
      limits.markers,
    );
  }
  final markers = <Object?>[];
  for (final (index, (marker, range)) in marked.indexed) {
    switch (_range(range, base.gravity(marker)!, limits)) {
      case Failure(:final kind, :final message):
        return Failure(kind, 'format: markers[$index].$message');
      case Success(:final value):
        markers.add({'id': id(marker), ...value});
    }
  }
  json['markers'] = markers;
  if (history) {
    final versions = <Object?>[];
    var total = 0;
    for (final (index, version) in chain.reversed.skip(1).indexed) {
      final path = 'format: history[$index]';
      if (_over(limits.items, version.length)) {
        return _exceeds(path, 'items', version.length, limits.items);
      }
      total += version.commands.length;
      if (_over(limits.commands, total)) {
        return _exceeds(path, 'commands', total, limits.commands);
      }
      final commands = <Object?>[];
      for (final (position, command) in version.commands.indexed) {
        payload += switch (command) {
          Insert(:final items) || Replace(:final items) => items.length,
          _ => 0,
        };
        if (_over(limits.payload, payload)) {
          return _exceeds(
            'format: history[$index][$position]',
            'payload',
            payload,
            limits.payload,
          );
        }
        switch (write(command, id, format, limits)) {
          case Failure(:final kind, :final message):
            return Failure(
              kind,
              'format: history[$index][$position]: $message',
            );
          case Success(:final value):
            commands.add(value);
        }
      }
      versions.add(commands);
    }
    json['history'] = versions;
    if (_over(limits.markers, ids.length)) {
      return _exceeds('format: history', 'markers', ids.length, limits.markers);
    }
  }
  return Success(json);
}

/// The range, gravities, and attributes of a marker or a mark command.
Result<Map<String, Object?>> _range(
  ARange range,
  ({Gravity start, Gravity end}) gravity,
  Limits limits,
) => _values(range.attributes, limits.attributes).map(
  (attributes) => {
    'range': [range.start, range.length],
    'start': gravity.start.name,
    'end': gravity.end.name,
    'attributes': attributes,
  },
);

/// [attributes] as JSON values, or a failure, with the path from
/// `attributes`, for more than [bound] of them or for text that would not
/// read back the same.
Result<Map<String, Object?>> _values(
  Map<String, Value> attributes,
  int? bound,
) {
  if (_over(bound, attributes.length)) {
    return _exceeds('attributes', 'attributes', attributes.length, bound);
  }
  final json = <String, Object?>{};
  for (final MapEntry(key: name, value: value) in attributes.entries) {
    switch (value) {
      case Str(:final value):
        switch (_string(value.items)) {
          case Failure(:final kind, :final message):
            return Failure(kind, 'attributes.$name: $message');
          case Success(:final value):
            json[name] = value;
        }
      case Num(:final value):
        json[name] = value;
      case Bool(:final value):
        json[name] = value;
      case Nil():
        json[name] = null;
    }
  }
  return Success(json);
}

/// [command] as a JSON value, each marker written as [id] gives it.
///
/// Shared with the replica module, which writes markers as keys; not
/// exported from the package.
Result<Map<String, Object?>> write<T>(
  Command<T> command,
  Object? Function(Marker marker) id,
  Format<Sequence<T>, Object?> format,
  Limits limits,
) => switch (command) {
  Insert(:final position, :final items) => _written(
    format,
    items,
    'items',
    limits.depth,
  ).map((items) => {'command': 'insert', 'position': position, 'items': items}),
  Delete(:final span) => Success({
    'command': 'delete',
    'range': [span.start, span.length],
  }),
  Replace(:final span, :final items) =>
    _written(format, items, 'items', limits.depth).map(
      (items) => {
        'command': 'replace',
        'range': [span.start, span.length],
        'items': items,
      },
    ),
  Mark(:final marker, :final range, :final start, :final end) => _range(range, (
    start: start,
    end: end,
  ), limits).map((json) => {'command': 'mark', 'id': id(marker), ...json}),
  Unmark(:final marker) => Success({'command': 'unmark', 'id': id(marker)}),
  Update(:final marker, :final attributes) => _values(
    attributes,
    limits.attributes,
  ).map((json) => {'command': 'update', 'id': id(marker), 'attributes': json}),
};

/// A command built once every marker exists, from the markers by id.
typedef _Build<T> = Command<T> Function(List<Marker> markers);

/// A marker id and the path where it appeared.
typedef _Id = (int, String);

/// Reads a marker id from JSON at a path.
typedef _Ids = Result<int> Function(Object? json, String path);

/// A marker id written as an integer, as documents save them.
Result<int> _integer(Object? json, String path) => switch (json) {
  final int id => Success(id),
  _ => Failure(Kind.syntax, '$path: expected an integer'),
};

/// A saved command: the marker ids it refers to, how to build it, and the
/// most items it removes and the items it adds, so replay can be bounded
/// before it runs.
typedef _Read<T> = (List<_Id>, _Build<T>, int, int);

/// The document [json] holds, and its markers in id order; see
/// [JSONFormat.restore].
Result<(Document<T>, List<Marker>)> _load<T>(
  Object? json,
  Format<Sequence<T>, Object?> format,
  Limits limits,
) {
  if (json is! Map<String, Object?>) {
    return const Failure(Kind.syntax, 'format: expected an object');
  }
  final version = json['libara'];
  if (version is! int) {
    return const Failure(Kind.syntax, 'format: libara: expected a version');
  }
  if (version != 1) {
    return Failure(Kind.invalid, 'format: unsupported version $version');
  }
  return _decoded(format, json['items'], 'format: items').flatMap((items) {
    if (_over(limits.items, items.length)) {
      return _exceeds('format: items', 'items', items.length, limits.items);
    }
    var payload = items.length;
    if (_over(limits.payload, payload)) {
      return _exceeds('format: items', 'payload', payload, limits.payload);
    }
    final ids = <_Id>[];
    final base = <_Build<T>>[];
    final entries = json['markers'];
    if (entries is! List<Object?>) {
      return const Failure(Kind.syntax, 'format: markers: expected a list');
    }
    if (_over(limits.markers, entries.length)) {
      return _exceeds(
        'format: markers',
        'markers',
        entries.length,
        limits.markers,
      );
    }
    final seen = <int>{};
    for (final (index, entry) in entries.indexed) {
      final path = 'markers[$index]';
      switch (_mark<T>(
        entry,
        path,
        items.length,
        limits.attributes,
        _integer,
      )) {
        case Failure(:final kind, :final message):
          return Failure(kind, 'format: $message');
        case Success(value: (final id, final build)):
          if (!seen.add(id)) {
            return Failure(Kind.invalid, 'format: $path.id: repeated id $id');
          }
          ids.add((id, '$path.id'));
          base.add(build);
      }
    }
    final steps = <List<_Read<T>>>[];
    final saved = json['history'];
    if (saved != null) {
      if (saved is! List<Object?>) {
        return const Failure(Kind.syntax, 'format: history: expected a list');
      }
      var total = 0;
      for (final (index, commands) in saved.indexed) {
        if (commands is! List<Object?> || commands.isEmpty) {
          return Failure(
            Kind.syntax,
            'format: history[$index]: expected a non-empty list',
          );
        }
        total += commands.length;
        if (_over(limits.commands, total)) {
          return _exceeds(
            'format: history[$index]',
            'commands',
            total,
            limits.commands,
          );
        }
        final step = <_Read<T>>[];
        for (final (position, command) in commands.indexed) {
          switch (read(
            command,
            'history[$index][$position]',
            format,
            limits.attributes,
            _integer,
          )) {
            case Failure(:final kind, :final message):
              return Failure(kind, 'format: $message');
            case Success(:final value):
              payload += value.$4;
              if (_over(limits.payload, payload)) {
                return _exceeds(
                  'format: history[$index][$position]',
                  'payload',
                  payload,
                  limits.payload,
                );
              }
              ids.addAll(value.$1);
              step.add(value);
          }
        }
        steps.add(step);
      }
    }
    final count = {for (final (id, _) in ids) id}.length;
    if (_over(limits.markers, count)) {
      return _exceeds('format: history', 'markers', count, limits.markers);
    }
    for (final (id, path) in ids) {
      if (id < 0 || id >= count) {
        return Failure(Kind.invalid, 'format: $path: unknown id $id');
      }
    }
    final markers = List.generate(count, (_) => Marker());
    Document<T> document;
    switch (Document.of(items)
        .transact([for (final build in base) build(markers)])) {
      case Failure(:final kind, :final message):
        return Failure(kind, 'format: markers: $message');
      case Success(:final value):
        document = value.compact();
    }
    var length = items.length;
    for (final (index, step) in steps.indexed) {
      // Bounded before the version is built: a deletion removes at most
      // its span, and replay fails anyway when it removes less.
      for (final (position, (_, _, removed, added)) in step.indexed) {
        length = max(0, length - removed) + added;
        if (_over(limits.items, length)) {
          return _exceeds(
            'format: history[$index][$position]',
            'items',
            length,
            limits.items,
          );
        }
      }
      switch (document.transact([
        for (final (_, build, _, _) in step) build(markers),
      ])) {
        case Failure(:final kind, :final message):
          return Failure(kind, 'format: history[$index]: $message');
        case Success(:final value):
          document = value;
      }
    }
    return Success((document, List<Marker>.unmodifiable(markers)));
  });
}

/// The id of the marker [json] describes, read by [ids], and how to build
/// its mark. With [length], the range must fit that many items. [bound]
/// limits its attributes.
Result<(int, _Build<T>)> _mark<T>(
  Object? json,
  String path,
  int? length,
  int? bound,
  _Ids ids,
) {
  if (json is! Map<String, Object?>) {
    return Failure(Kind.syntax, '$path: expected an object');
  }
  return ids(
    json['id'],
    '$path.id',
  ).flatMap((id) => _marked<T>(json, path, length, bound, id));
}

/// [_mark] once its [id] is read.
Result<(int, _Build<T>)> _marked<T>(
  Map<String, Object?> json,
  String path,
  int? length,
  int? bound,
  int id,
) {
  return _span(json['range'], '$path.range').flatMap((span) {
    final (start, size) = span;
    if (length != null && (start > length || size > length - start)) {
      return Failure(
        Kind.invalid,
        '$path.range: [$start, $size] does not fit $length items',
      );
    }
    return _gravity(json['start'], '$path.start').flatMap(
      (first) => _gravity(json['end'], '$path.end').flatMap(
        (last) =>
            _attributes(json['attributes'], '$path.attributes', bound).flatMap(
              (attributes) =>
                  _prefix(
                    ARange.create(start, size, attributes: attributes),
                    '$path.range',
                  ).map(
                    (range) => (
                      id,
                      (markers) => Mark<T>.of(
                        markers[id],
                        range,
                        start: first,
                        end: last,
                      ),
                    ),
                  ),
            ),
      ),
    );
  });
}

/// The command [json] describes, with at most [bound] attributes and its
/// markers' ids read by [ids]: the ids with their paths, how to build the
/// command from the markers by id, and the most items it removes and the
/// items it adds.
///
/// Shared with the replica module, which reads markers from keys; not
/// exported from the package.
Result<
  (List<(int, String)>, Command<T> Function(List<Marker> markers), int, int)
>
read<T>(
  Object? json,
  String path,
  Format<Sequence<T>, Object?> format,
  int? bound,
  Result<int> Function(Object? json, String path) ids,
) {
  if (json is! Map<String, Object?>) {
    return Failure(Kind.syntax, '$path: expected an object');
  }
  Result<int> id() => ids(json['id'], '$path.id');
  Result<Sequence<T>> items() => _decoded(format, json['items'], '$path.items');
  Result<Range> range() => _span(
    json['range'],
    '$path.range',
  ).flatMap((span) => _prefix(Range.create(span.$1, span.$2), '$path.range'));
  return switch (json['command']) {
    'insert' => switch (json['position']) {
      final int position => items().map(
        (items) => (<_Id>[], (_) => Insert(position, items), 0, items.length),
      ),
      _ => Failure(Kind.syntax, '$path.position: expected an integer'),
    },
    'delete' => range().map(
      (span) => (<_Id>[], (_) => Delete<T>(span), span.length, 0),
    ),
    'replace' => range().flatMap(
      (span) => items().map(
        (items) =>
            (<_Id>[], (_) => Replace(span, items), span.length, items.length),
      ),
    ),
    'mark' => _mark<T>(
      json,
      path,
      null,
      bound,
      ids,
    ).map((parsed) => ([(parsed.$1, '$path.id')], parsed.$2, 0, 0)),
    'unmark' => id().map(
      (id) => ([(id, '$path.id')], (markers) => Unmark<T>(markers[id]), 0, 0),
    ),
    'update' => id().flatMap(
      (id) => _attributes(json['attributes'], '$path.attributes', bound).map(
        (attributes) => (
          [(id, '$path.id')],
          (markers) => Update<T>(markers[id], attributes),
          0,
          0,
        ),
      ),
    ),
    _ => Failure(Kind.syntax, '$path.command: unknown command'),
  };
}

/// The `[start, length]` pair [json] holds, both non-negative.
Result<(int, int)> _span(Object? json, String path) {
  if (json is! List<Object?> ||
      json.length != 2 ||
      json[0] is! int ||
      json[1] is! int) {
    return Failure(Kind.syntax, '$path: expected [start, length]');
  }
  final (start, length) = (json[0]! as int, json[1]! as int);
  if (start < 0 || length < 0) {
    return Failure(Kind.invalid, '$path: [$start, $length] is negative');
  }
  return Success((start, length));
}

Result<Gravity> _gravity(Object? json, String path) => switch (json) {
  'left' => const Success(Gravity.left),
  'right' => const Success(Gravity.right),
  _ => Failure(Kind.syntax, '$path: expected "left" or "right"'),
};

Result<Map<String, Value>> _attributes(Object? json, String path, int? bound) {
  if (json is! Map<String, Object?>) {
    return Failure(Kind.syntax, '$path: expected an object');
  }
  if (_over(bound, json.length)) {
    return _exceeds(path, 'attributes', json.length, bound);
  }
  final attributes = <String, Value>{};
  for (final MapEntry(key: name, value: value) in json.entries) {
    final Value? decoded = switch (value) {
      final String text => Str(Text.of(text)),
      final int number => Num(number),
      final bool flag => Bool(flag),
      null => const Nil(),
      _ => null,
    };
    if (decoded == null) {
      return Failure(
        Kind.syntax,
        '$path.$name: expected a string, integer, boolean, or null',
      );
    }
    attributes[name] = decoded;
  }
  return Success(attributes);
}

/// [items] written by [format], or a [Kind.invalid] failure naming [path]
/// when the format throws or writes something that is not JSON, or JSON
/// nested deeper than [depth].
///
/// The format is the caller's code, so this is where the library turns its
/// exceptions into failures; the only other place the library catches is
/// the layered document's calls into a grammar.
Result<Object?> _written<T>(
  Format<Sequence<T>, Object?> format,
  Sequence<T> items,
  String path,
  int? depth,
) {
  final Result<Object?> result;
  try {
    result = format.encode(items);
  } on Object catch (error) {
    return Failure(Kind.invalid, '$path: format threw $error');
  }
  return _prefix(
    result,
    path,
  ).flatMap((json) => _json(json, path, depth).map((_) => json));
}

/// The items [format] reads from [json], or a [Kind.invalid] failure naming
/// [path] when the format throws.
Result<Sequence<T>> _decoded<T>(
  Format<Sequence<T>, Object?> format,
  Object? json,
  String path,
) {
  try {
    return _prefix(format.decode(json), path);
  } on Object catch (error) {
    return Failure(Kind.invalid, '$path: format threw $error');
  }
}

/// Nothing, or a [Kind.invalid] failure for the first part of [value] that
/// `jsonEncode` would reject: anything but `null`, a boolean, an integer, a
/// finite double, a string, a list, or a map with string keys, or a list or
/// map that contains itself, or lists and maps nested deeper than [bound].
/// [path] names [value] in failures.
///
/// The walk keeps its own stack, so nesting of any depth costs heap rather
/// than the Dart stack, and visits in the order a recursive walk would, so
/// the first failure is the same. Paths are built only for a failure.
Result<void> _json(Object? value, String path, int? bound) {
  // The lists and maps around the part being checked.
  final open = Set<Object>.identity();
  final pending = <(Object?, _Place?, _Visit)>[(value, null, _Visit.check)];
  String at(_Place? place) => place?.path(path) ?? path;
  while (pending.isNotEmpty) {
    final (part, place, visit) = pending.removeLast();
    switch (visit) {
      case _Visit.leave:
        open.remove(part);
        continue;
      case _Visit.entry:
        final MapEntry(:key, value: item) = part as MapEntry<Object?, Object?>;
        if (key is! String) {
          return Failure(
            Kind.invalid,
            '${at(place)}: key $key is not a string',
          );
        }
        pending.add((item, _Place(place, '.$key'), _Visit.check));
        continue;
      case _Visit.check:
    }
    switch (part) {
      case null || bool() || int() || String():
        break;
      case final double number:
        if (!number.isFinite) {
          return Failure(
            Kind.invalid,
            '${at(place)}: $number is not a finite number',
          );
        }
      case final List<Object?> list:
        if (!open.add(list)) {
          return Failure(
            Kind.invalid,
            '${at(place)}: the list contains itself',
          );
        }
        if (_over(bound, _Place.depth(place) + 1)) {
          return _exceeds(at(place), 'depth', _Place.depth(place) + 1, bound);
        }
        pending.add((list, place, _Visit.leave));
        for (var index = list.length - 1; index >= 0; index--) {
          pending.add((list[index], _Place(place, '[$index]'), _Visit.check));
        }
      case final Map<Object?, Object?> map:
        if (!open.add(map)) {
          return Failure(Kind.invalid, '${at(place)}: the map contains itself');
        }
        if (_over(bound, _Place.depth(place) + 1)) {
          return _exceeds(at(place), 'depth', _Place.depth(place) + 1, bound);
        }
        pending.add((map, place, _Visit.leave));
        for (final entry in map.entries.toList().reversed) {
          pending.add((entry, place, _Visit.entry));
        }
      default:
        return Failure(
          Kind.invalid,
          '${at(place)}: ${part.runtimeType} is not a JSON value',
        );
    }
  }
  return const Success(null);
}

/// What [_json] does with a part it takes from its stack.
enum _Visit {
  /// Check the part, and stack what it contains.
  check,

  /// Check a map entry's key, and stack its value.
  entry,

  /// Leave a list or map whose contents are all checked.
  leave,
}

/// Where a part sits in the JSON [_json] walks: the [step] into it from the
/// container at [up], or from the top when [up] is `null`.
final class _Place {
  _Place(this.up, this.step) : steps = depth(up) + 1;

  final _Place? up;

  /// `[index]` or `.key`.
  final String step;

  /// The steps from the top to here.
  final int steps;

  /// The steps from the top to [place], 0 at the top.
  static int depth(_Place? place) => place?.steps ?? 0;

  /// The path to this place from [root].
  String path(String root) {
    final steps = <String>[];
    for (_Place? place = this; place != null; place = place.up) {
      steps.add(place.step);
    }
    return root + steps.reversed.join();
  }
}

/// [result] with a failure's message prefixed by `[path]: `.
Result<V> _prefix<V>(Result<V> result, String path) => switch (result) {
  Success() => result,
  Failure(:final kind, :final message) => Failure(kind, '$path: $message'),
};
