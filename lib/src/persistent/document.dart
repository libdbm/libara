import '../attributed/attributed.dart';
import '../range/range.dart';
import '../sequence/sequence.dart';
import 'command.dart';
import 'endpoints.dart';
import 'index.dart';
import 'label.dart';
import 'content.dart';

/// What a document records for each marker: the labels and gravities of its
/// two endpoints, and the attributes of its range.
typedef _Entry = ({
  Label first,
  Label last,
  Gravity start,
  Gravity end,
  Map<String, Value> attributes,
});

/// The structures that make up one version: the items, one endpoint tree
/// per gravity, and the marker index.
typedef _Parts<T> = ({
  Content<T> content,
  Endpoints<Marker> right,
  Endpoints<Marker> left,
  Index<_Entry> index,
});

/// A persistent, versioned sequence whose ranges move with its items.
///
/// Every edit is a [Command] passed to [apply], which returns a new version
/// linked to this one through [previous]. Earlier versions stay valid and
/// unchanged, so undo is a step back through [previous].
final class Document<T> with SequenceBase<T> {
  Document._(_Parts<T> parts, this.version, this.previous, this._log)
    : _content = parts.content,
      _right = parts.right,
      _left = parts.left,
      _index = parts.index;

  /// Version 0 of a document holding [items].
  Document.of(Sequence<T> items)
    : this._(
        (
          content: Content.of(items.items),
          right: const Endpoints.empty(),
          left: const Endpoints.empty(),
          index: const Index.empty(),
        ),
        0,
        null,
        null,
      );

  /// Version 0 of a document with no items.
  Document.empty()
    : this._(
        (
          content: Content<T>.empty(),
          right: const Endpoints.empty(),
          left: const Endpoints.empty(),
          index: const Index.empty(),
        ),
        0,
        null,
        null,
      );

  final Content<T> _content;

  /// Endpoints with right gravity, which move past items inserted at them.
  final Endpoints<Marker> _right;

  /// Endpoints with left gravity, which stay before items inserted at them.
  final Endpoints<Marker> _left;

  final Index<_Entry> _index;

  _Parts<T> get _parts =>
      (content: _content, right: _right, left: _left, index: _index);

  Endpoints<Marker> _tree(Gravity gravity) =>
      gravity == Gravity.right ? _right : _left;

  /// 0 for a created document, one more than [previous] for each applied
  /// command.
  final int version;

  /// The version this one was derived from, or `null` for version 0.
  final Document<T>? previous;

  /// The commands that turned [previous] into this version, latest first,
  /// shared with the version they were coalesced into.
  final _Log<T>? _log;

  /// The commands that turned [previous] into this version, in order.
  ///
  /// Built when read, in time proportional to their number.
  List<Command<T>> get commands {
    final found = <Command<T>>[];
    for (var log = _log; log != null; log = log.before) {
      found.add(log.command);
    }
    return List.unmodifiable(found.reversed);
  }

  /// This document with [command] applied.
  ///
  /// The result is the next version, whose [previous] is this document. With
  /// [flatten] it instead replaces this version: it keeps this [version] and
  /// [previous] and appends [command] to [commands], so one step back
  /// undoes every coalesced command. A command that does not fit the
  /// document is a failure, and this document is unchanged.
  Result<Document<T>> apply(Command<T> command, {bool flatten = false}) {
    final Result<_Parts<T>> edited = switch (command) {
      // An endpoint exactly at the insertion point moves only with right
      // gravity, so the left tree shifts from the next position.
      Insert(:final position, :final items) =>
        _content
            .insertAll(position, items.items)
            .map(
              (content) => (
                content: content,
                right: _right.shift(position, items.length),
                left: _left.shift(position + 1, items.length),
                index: _index,
              ),
            ),
      Delete(:final span) =>
        _content
            .deleteAll(span)
            .map(
              (content) => (
                content: content,
                right: _right.collapse(span.start, span.end),
                left: _left.collapse(span.start, span.end),
                index: _index,
              ),
            ),
      // A deletion then an insertion at the span's start, with the same
      // endpoint shifts as each.
      Replace(:final span, :final items) => switch (outside(span, length)) {
        final position? => Failure.bounds('replace', position),
        null =>
          _content
              .deleteAll(span)
              .flatMap((content) => content.insertAll(span.start, items.items))
              .map(
                (content) => (
                  content: content,
                  right: _right
                      .collapse(span.start, span.end)
                      .shift(span.start, items.length),
                  left: _left
                      .collapse(span.start, span.end)
                      .shift(span.start + 1, items.length),
                  index: _index,
                ),
              ),
      },
      Mark(:final range, :final start, :final end, :final marker) => _mark(
        range,
        start,
        end,
        marker,
      ),
      Unmark(:final marker) => _unmark(marker),
      Update(:final marker, :final attributes) => _update(marker, attributes),
    };
    return edited.map(
      (parts) => flatten
          ? Document._(parts, version, previous, _Log(command, _log))
          : Document._(parts, version + 1, this, _Log(command, null)),
    );
  }

  /// [position] in [from], this version or an earlier one in its history,
  /// carried through the commands between them into this version's
  /// positions, as an endpoint with [gravity] there would be.
  ///
  /// Gravity decides an insertion exactly at the position: right moves
  /// past the inserted items, left stays before them. A deletion holding
  /// the position moves it to the deletion's start. A [Kind.invalid]
  /// failure when [from] is not in the history, which includes a version
  /// before a [compact], or [position] is outside `0..from.length`. Costs
  /// O(q) for the q commands between them.
  Result<int> map(Document<T> from, int position, Gravity gravity) {
    if (position < 0 || position > from.length) {
      return Failure(
        Kind.invalid,
        'map: $position is outside 0..${from.length}',
      );
    }
    final versions = <Document<T>>[];
    Document<T>? version = this;
    while (version != null && !identical(version, from)) {
      versions.add(version);
      version = version.previous;
    }
    if (version == null) {
      return Failure(
        Kind.invalid,
        'map: version ${from.version} is not in the history of this one',
      );
    }
    var at = position;
    for (final version in versions.reversed) {
      for (final command in version.commands) {
        at = _moved(at, gravity, command);
      }
    }
    return Success(at);
  }

  /// [position] after [command], as an endpoint with [gravity] moves:
  /// collapsed by a deletion holding it, then shifted by items inserted
  /// after it, or at it with right gravity.
  static int _moved(int position, Gravity gravity, Command<Object?> command) {
    final (at, cut, put) = switch (command) {
      Insert(:final position, :final items) => (position, 0, items.length),
      Delete(:final span) => (span.start, span.length, 0),
      Replace(:final span, :final items) => (
        span.start,
        span.length,
        items.length,
      ),
      Mark() || Unmark() || Update() => (0, 0, 0),
    };
    final kept = position <= at
        ? position
        : position < at + cut
        ? at
        : position - cut;
    final shifted = gravity == Gravity.right ? kept >= at : kept > at;
    return put > 0 && shifted ? kept + put : kept;
  }

  /// This document with every one of [commands] applied in order, each to
  /// the result of the one before, as one new version.
  ///
  /// The result's [previous] is this document and its [commands] are
  /// [commands], so one step back undoes them all. An empty list returns
  /// this document. The first command that fails makes the whole
  /// transaction fail: its failure is returned with its kind and a message
  /// naming the command, and this document is unchanged.
  Result<Document<T>> transact(List<Command<T>> commands) {
    if (commands.isEmpty) {
      return Success(this);
    }
    var current = this;
    _Log<T>? log;
    var first = 0;
    // With no ranges yet, a leading run of marks is placed in one pass.
    final marks = _index.length == 0
        ? [
            for (final command in commands.takeWhile((c) => c is Mark<T>))
              command as Mark<T>,
          ]
        : <Mark<T>>[];
    if (marks.length > 1) {
      final seen = <Marker>{};
      for (final (index, mark) in marks.indexed) {
        if (outside(mark.range, length) case final position?) {
          return Failure(
            Kind.bounds,
            'transact: command $index: mark: '
            'position $position is out of bounds',
          );
        }
        if (!seen.add(mark.marker)) {
          return Failure(
            Kind.invalid,
            'transact: command $index: mark: ${mark.marker} is already present',
          );
        }
      }
      current = Document._(_markAll(marks), version, previous, null);
      for (final mark in marks) {
        log = _Log(mark, log);
      }
      first = marks.length;
    }
    for (final (index, command) in commands.indexed.skip(first)) {
      switch (current.apply(command)) {
        case Success(:final value):
          current = value;
          log = _Log(command, log);
        case Failure(:final kind, :final message):
          return Failure(kind, 'transact: command $index: $message');
      }
    }
    return Success(Document._(current._parts, version + 1, this, log));
  }

  /// The parts with every one of [marks] placed, for a document with no
  /// ranges: each tree's endpoints sorted as marking them one by one would
  /// order them, then labelled evenly and built in one pass.
  _Parts<T> _markAll(List<Mark<T>> marks) {
    // Each endpoint goes after those already at its position, so ties keep
    // the order of the marks, and a range's start comes before its end.
    int order((int, int, bool) a, (int, int, bool) b) => a.$1 != b.$1
        ? a.$1 - b.$1
        : a.$2 != b.$2
        ? a.$2 - b.$2
        : a.$3
        ? -1
        : 1;
    final trees = {
      for (final gravity in Gravity.values) gravity: <(int, int, bool)>[],
    };
    for (final (index, mark) in marks.indexed) {
      trees[mark.start]!.add((mark.range.start, index, true));
      trees[mark.end]!.add((mark.range.end, index, false));
    }
    final firsts = List<Label?>.filled(marks.length, null);
    final lasts = List<Label?>.filled(marks.length, null);
    for (final endpoints in trees.values) {
      endpoints.sort(order);
      final labels = Label.spread(endpoints.length);
      for (final (index, (_, mark, start)) in endpoints.indexed) {
        (start ? firsts : lasts)[mark] = labels[index];
      }
    }
    Endpoints<Marker> build(Gravity gravity) => Endpoints.of([
      for (final (position, index, start) in trees[gravity]!)
        (
          (
            position: position,
            label: (start ? firsts : lasts)[index]!,
            owner: marks[index].marker,
            start: start,
            partner: start ? lasts[index] : null,
          ),
          marks[index].start != marks[index].end,
        ),
    ]);
    return (
      content: _content,
      right: build(Gravity.right),
      left: build(Gravity.left),
      index: Index.of([
        for (final (at, mark) in marks.indexed)
          (
            mark.marker,
            (
              first: firsts[at]!,
              last: lasts[at]!,
              start: mark.start,
              end: mark.end,
              attributes: mark.range.attributes,
            ),
          ),
      ]),
    );
  }

  Result<_Parts<T>> _mark(
    ARange range,
    Gravity start,
    Gravity end,
    Marker marker,
  ) {
    if (outside(range, length) case final position?) {
      return Failure.bounds('mark', position);
    }
    if (_index.get(marker) != null) {
      return Failure(Kind.invalid, 'mark: $marker is already present');
    }
    final Result<(_Parts<T>, Label, Label)> placed;
    if (start == end) {
      placed = _tree(start).add(marker, range.start, range.end).map((added) {
        final (tree, low, high) = added;
        return (_with(_parts, start, tree), low, high);
      });
    } else {
      // The end goes first, so the start can record its label.
      placed = _tree(end).put(marker, range.end, false).flatMap((closed) {
        final (closing, high) = closed;
        return _tree(start)
            .put(marker, range.start, true, partner: high)
            .map((opened) {
              final (opening, low) = opened;
              return (
                _with(_with(_parts, start, opening), end, closing),
                low,
                high,
              );
            });
      });
    }
    return placed.map((placement) {
      final (parts, first, last) = placement;
      final entry = (
        first: first,
        last: last,
        start: start,
        end: end,
        attributes: range.attributes,
      );
      return (
        content: parts.content,
        right: parts.right,
        left: parts.left,
        index: _index.put(marker, entry),
      );
    });
  }

  Result<_Parts<T>> _unmark(Marker marker) {
    final entry = _index.get(marker);
    if (entry == null) {
      return Failure(Kind.missing, 'unmark: $marker is not present');
    }
    var parts = _parts;
    if (entry.start == entry.end) {
      final tree = _tree(entry.start);
      parts = _with(
        parts,
        entry.start,
        tree.remove(marker, entry.first, entry.last),
      );
    } else {
      parts = _with(
        parts,
        entry.start,
        _tree(entry.start).drop(marker, entry.first),
      );
      parts = _with(
        parts,
        entry.end,
        _tree(entry.end).drop(marker, entry.last),
      );
    }
    return Success((
      content: parts.content,
      right: parts.right,
      left: parts.left,
      index: _index.remove(marker),
    ));
  }

  Result<_Parts<T>> _update(Marker marker, Map<String, Value> attributes) {
    final entry = _index.get(marker);
    if (entry == null) {
      return Failure(Kind.missing, 'update: $marker is not present');
    }
    return Success((
      content: _content,
      right: _right,
      left: _left,
      index: _index.put(marker, (
        first: entry.first,
        last: entry.last,
        start: entry.start,
        end: entry.end,
        attributes: attributes,
      )),
    ));
  }

  /// [parts] with the tree for [gravity] replaced by [tree].
  static _Parts<T> _with<T>(
    _Parts<T> parts,
    Gravity gravity,
    Endpoints<Marker> tree,
  ) => (
    content: parts.content,
    right: gravity == Gravity.right ? tree : parts.right,
    left: gravity == Gravity.left ? tree : parts.left,
    index: parts.index,
  );

  /// Nothing, or a failure for the first endpoint that disagrees with the
  /// index, or a count of endpoints that does not match it.
  Result<void> _agrees() {
    var starts = 0;
    var ends = 0;
    for (final gravity in Gravity.values) {
      for (final endpoint in _tree(gravity).entries) {
        final entry = _index.get(endpoint.owner);
        if (entry == null) {
          return Failure(
            Kind.invalid,
            'document: ${endpoint.owner} is not indexed',
          );
        }
        final (label, side) = endpoint.start
            ? (entry.first, entry.start)
            : (entry.last, entry.end);
        if (side != gravity || label != endpoint.label) {
          return Failure(
            Kind.invalid,
            'document: ${endpoint.owner} disagrees with the index',
          );
        }
        if (endpoint.start && endpoint.partner != entry.last) {
          return Failure(
            Kind.invalid,
            'document: ${endpoint.owner} has the wrong partner',
          );
        }
        if (endpoint.start) {
          starts++;
        } else {
          ends++;
        }
      }
    }
    if (starts != _index.length || ends != _index.length) {
      return Failure(
        Kind.invalid,
        'document: ${_index.length} markers, $starts starts, $ends ends',
      );
    }
    return const Success(null);
  }

  /// This document as version 0: the same items, ranges, and markers, with
  /// no history, and every endpoint label spaced evenly again.
  ///
  /// Labels lengthen as ranges are marked into the same gaps; compacting
  /// shortens them to what the number of endpoints needs, one digit for
  /// fewer than 65,536 in each gravity. The result does not reach any
  /// earlier version, so those can be reclaimed once nothing else holds
  /// them. Expected `O(m log m)` for `m` ranges.
  Document<T> compact() {
    final right = _right.spacing();
    final left = _left.spacing();
    Map<Label, Label> labels(Gravity gravity) =>
        gravity == Gravity.right ? right : left;
    var index = const Index<_Entry>.empty();
    for (final tree in [_right, _left]) {
      for (final endpoint in tree.entries) {
        if (!endpoint.start) {
          continue;
        }
        final entry = _index.get(endpoint.owner)!;
        index = index.put(endpoint.owner, (
          first: labels(entry.start)[entry.first]!,
          last: labels(entry.end)[entry.last]!,
          start: entry.start,
          end: entry.end,
          attributes: entry.attributes,
        ));
      }
    }
    return Document._(
      (
        content: _content,
        right: _right.relabel(right, left),
        left: _left.relabel(left, right),
        index: index,
      ),
      0,
      null,
      null,
    );
  }

  /// The range from [start] to [end] as read: an end before its start reads
  /// as zero-length at the start.
  static ARange _read(int start, int end, Map<String, Value> attributes) =>
      ARange.from(extent(start, end < start ? 0 : end - start), attributes);

  /// The current range for [marker], or `null` when it is not marked in
  /// this version.
  ARange? resolve(Marker marker) {
    final entry = _index.get(marker);
    if (entry == null) {
      return null;
    }
    final start = _tree(entry.start).position(entry.first, marker)!;
    final end = _tree(entry.end).position(entry.last, marker)!;
    return _read(start, end, entry.attributes);
  }

  /// The gravity of each endpoint of [marker], or `null` when it is not
  /// marked in this version.
  ({Gravity start, Gravity end})? gravity(Marker marker) {
    final entry = _index.get(marker);
    return entry == null ? null : (start: entry.start, end: entry.end);
  }

  /// Every range containing [position], in start order, with its
  /// attributes.
  ///
  /// A range contains the positions from its start up to, but not
  /// including, its end, so a zero-length range contains none.
  ///
  Ranges at(int position) {
    final right = _right.boundary(position);
    final left = _left.boundary(position);
    return Ranges.of([
      for (final marker in _right.containing(position, left)) resolve(marker)!,
      for (final marker in _left.containing(position, right)) resolve(marker)!,
    ]).startOrder();
  }

  /// Every range that overlaps [range], as [Range.overlaps] defines it, in
  /// start order, with its attributes.
  ///
  /// A range starting at or before `range.start` overlaps when it contains
  /// that position, which [at] finds; one starting strictly inside [range]
  /// always overlaps. So the cost follows the ranges found, not the ranges
  /// elsewhere.
  Ranges overlapping(Range range) => Ranges.of([
    for (final item in at(range.start).items)
      if (item.overlaps(range)) item,
    for (final tree in [_right, _left])
      for (final marker in tree.starting(range.start, range.end))
        resolve(marker)!,
  ]).startOrder();

  /// Every marked range lying within [region], its ends included, with its
  /// marker, in start order.
  ///
  /// Ranges are read as [resolve] reads them, so an inverted range counts
  /// at its start. The candidates are the ranges starting in [region], so
  /// the cost follows those found and those starting in [region] that end
  /// after it.
  List<(Marker, ARange)> within(Range region) => _ordered([
    // Positions are integers, so starts strictly between start - 1 and
    // end + 1 are the starts in the region, its ends included.
    for (final tree in [_right, _left])
      for (final marker in tree.starting(region.start - 1, region.end + 1))
        if (resolve(marker)! case final range when range.end <= region.end)
          (marker, range),
  ]);

  /// Every marked range that starts before [position] and ends after it,
  /// with its marker, in start order. A range starting or ending at
  /// [position] does not cross it.
  ///
  /// The candidates are those [at] finds, so the cost is the same.
  List<(Marker, ARange)> crossing(int position) {
    final right = _right.boundary(position);
    final left = _left.boundary(position);
    return _ordered([
      for (final (tree, other) in [(_right, left), (_left, right)])
        for (final marker in tree.containing(position, other))
          if (resolve(marker)! case final range when range.start < position)
            (marker, range),
    ]);
  }

  /// [pairs] in start order: by start, then by length, ties as found.
  static List<(Marker, ARange)> _ordered(List<(Marker, ARange)> pairs) {
    final order = List.generate(pairs.length, (index) => index)
      ..sort((a, b) {
        final (x, y) = (pairs[a].$2, pairs[b].$2);
        final by = x.start != y.start ? x.start - y.start : x.length - y.length;
        return by != 0 ? by : a - b;
      });
    return List.unmodifiable([for (final index in order) pairs[index]]);
  }

  /// Every range in this version, in start order, with its attributes.
  Ranges get ranges => Ranges.of([for (final (_, range) in markers) range]);

  /// Every marker in this version with its current range, in the order of
  /// [ranges]: by start, then by length.
  List<(Marker, ARange)> get markers {
    final starts = <Marker, int>{};
    final ends = <Marker, int>{};
    for (final tree in [_right, _left]) {
      for (final endpoint in tree.entries) {
        (endpoint.start ? starts : ends)[endpoint.owner] = endpoint.position;
      }
    }
    final pairs = [
      for (final MapEntry(key: marker, value: start) in starts.entries)
        (marker, _read(start, ends[marker]!, _index.get(marker)!.attributes)),
    ];
    // Stable, as startOrder is: ties keep the order they were found in.
    return _ordered(pairs);
  }

  @override
  int get length => _content.length;

  @override
  Iterable<T> get items => _content.items;

  @override
  T? item(int position) => _content.item(position);

  /// The items from [start], without ranges or history.
  @override
  Items<T> slice(int start, int length) =>
      Items.of(_content.slice(start, length));

  /// The next version with [other] appended. Ranges in this document are
  /// kept; ranges in [other] are not.
  @override
  Result<Document<T>> concat(Sequence<T> other) => apply(Insert(length, other));

  /// The next version with [item] inserted before [position].
  @override
  Result<Document<T>> insert(int position, T item) =>
      apply(Insert(position, Items.of([item])));

  /// The next version without the item at [position].
  @override
  Result<Document<T>> delete(int position) {
    if (position < 0 || position >= length) {
      return Failure.bounds('delete', position);
    }
    return apply(Delete(extent(position, 1)));
  }

  /// The items not in [other], without ranges or history.
  @override
  Items<T> diff(Sequence<Object?> other) => Items.of(items).diff(other);

  /// The items followed by those of [other] not already present, without
  /// ranges or history.
  @override
  Result<Items<T>> union(Sequence<T> other) => Items.of(items).union(other);

  /// The items also in [other], without ranges or history.
  @override
  Items<T> intersect(Sequence<Object?> other) =>
      Items.of(items).intersect(other);
}

/// Version 0 of [fresh]'s items with every one of [marks] placed: what
/// `fresh.transact(marks).compact()` gives, for a [fresh] document holding
/// no marks. For the library; hidden from the public `libara` library.
///
/// Placing several marks at once already labels their endpoints evenly,
/// which is all compacting would do besides dropping the history, so the
/// history is dropped and nothing is built twice.
Result<Document<T>> placed<T>(Document<T> fresh, List<Mark<T>> marks) => fresh
    .transact(marks)
    .map(
      (document) => marks.length > 1 && fresh._index.length == 0
          ? Document._(document._parts, 0, null, null)
          : document.compact(),
    );

/// Whether [document] keeps its invariants: the content tree and both
/// endpoint trees keep their own, and the marker index and the trees agree,
/// with one start and one end per indexed marker, in the tree its gravity
/// names, under the labels the index records. A [Kind.invalid] failure
/// names the first that does not.
///
/// A diagnostic for tests. Hidden from the public `libara` library.
Result<void> check<T>(Document<T> document) => document._content
    .check()
    .flatMap((_) => document._right.check())
    .flatMap((_) => document._left.check())
    .flatMap((_) => document._agrees());

/// One command in a version's history, linked to the commands applied
/// before it in the same version.
final class _Log<T> {
  const _Log(this.command, this.before);

  final Command<T> command;
  final _Log<T>? before;
}

/// Measures of a document of code points, for the coordinate module:
/// UTF-16 units and line ends, cached by its content tree. Not exported
/// from the package.
extension DocumentMeasures on Document<int> {
  /// The measure of every item, or `null` for no items.
  ({int units, int ends, int first, int last})? get measure => _content.measure;

  /// The measure of the items before [position], which must be in
  /// `0..length`, or `null` for none.
  ({int units, int ends, int first, int last})? prefix(int position) =>
      _content.before(position);

  /// The position whose items before it take [units] UTF-16 units, with
  /// `true`, or the position of the item whose units hold [units] inside
  /// them, with `false`. [units] must be in `0..measure.units`.
  (int, bool) located(int units) => _content.at(units);

  /// The position of the item that completes the [count]th line end, for
  /// [count] in `1..measure.ends`.
  int ending(int count) => _content.end(count);
}
