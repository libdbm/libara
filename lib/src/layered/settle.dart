part of 'layered.dart';

/// A structural edit carried out up to its own layer: the document, each
/// layer-1 version an item edit made with the span it replaced there, what
/// changed in each layer from 2 up to the edited one, and the span of the
/// edited layer's items that changed.
typedef _Carried<T> = ({
  Layered<T> document,
  List<(Document<T>, Range)> spans,
  List<Delta> deltas,
  Range changed,
});

/// The edits below a structural edit carried out: the document, each
/// layer-1 version an item edit made with the span it replaced there, where
/// the layer below changed, each in the version it changed in, and what
/// changed in each layer from 2 up to below the edit's.
typedef _Lowered<T> = ({
  Layered<T> document,
  List<(Document<T>, Range)> spans,
  List<(Document<Object?>, Range)> cuts,
  List<Delta> deltas,
});

/// How a structural edit puts a layer's items in order: the indices of
/// the removed items, ascending; the layer once they are deleted, the runs
/// deletions below collapsed are reordered, and the new items inserted, as
/// one new version; the spans those reorders disturb; for each new item,
/// its index once the removed ones are gone, and its final index; and the
/// indices of the updated items before the edit.
typedef _Placement = ({
  List<int> indices,
  Document<Marker> placed,
  List<Range> areas,
  List<int> places,
  List<int> finals,
  List<int> revised,
});

/// Structural edits: carried out below by the grammar's derivation, then
/// settled into the edited layer in start order.
extension _Settling<T> on Layered<T> {
  /// This document after the structural [edit], carried out down to layer
  /// 1 without deriving any layer, and with the layers above [edit]'s left
  /// as they are. A [nested] edit is carried for one at the layer above.
  Result<_Carried<T>> _carry(Edit<T> edit, {bool nested = false}) {
    final layer = edit.layer;
    final Derivation<T> derivation;
    switch (_ask(
      'edit of $edit',
      () => grammar.edit(this, edit),
    ).flatMap((result) => result)) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(:final value):
        derivation = value;
    }
    return switch (_lowered(edit, derivation.below)) {
      Failure(:final kind, :final message) => Failure(kind, message),
      Success(
        value: (:final document, :final spans, :final cuts, :final deltas),
      ) =>
        switch (document._settle(layer, derivation, this, cuts, nested)) {
          Failure(:final kind, :final message) => Failure(
            kind,
            'grammar: $edit: $message',
          ),
          Success(value: (final next, final delta, final changed)) => Success((
            document: next,
            spans: spans,
            deltas: [...deltas, delta],
            changed: changed,
          )),
        },
    };
  }

  /// This document after [lower], the edits one layer below [edit] that
  /// carry it out; with each layer-1 version an item edit made and the span
  /// it replaced there, where the layer below changed, each in the version
  /// it changed in, and what changed in each layer from 2 up to below
  /// [edit]'s.
  Result<_Lowered<T>> _lowered(Edit<T> edit, List<Edit<T>> lower) {
    final layer = edit.layer;
    var current = this;
    final spans = <(Document<T>, Range)>[];
    final cuts = <(Document<Object?>, Range)>[];
    var deltas = [for (var index = 2; index < layer; index++) _none];
    for (final below in lower) {
      if (below.layer != layer - 1) {
        return Failure(
          Kind.invalid,
          'grammar: $edit: $below is not at layer ${layer - 1}',
        );
      }
      if (layer == 2) {
        switch (current._itemized(edit, below)) {
          case Failure(:final kind, :final message):
            return Failure(kind, message);
          case Success(value: (final next, final cut)):
            current = next;
            spans.add((next._base, cut));
            cuts.add((next._base, cut));
        }
      } else if (below.command is Insert || below.command is Replace) {
        return Failure(
          Kind.invalid,
          'grammar: $edit: $below makes new items above layer 1',
        );
      } else {
        switch (current._carry(below, nested: true)) {
          case Failure(:final kind, :final message):
            return Failure(kind, message);
          case Success(
            value: (
              document: final next,
              spans: final more,
              deltas: final carried,
              :final changed,
            ),
          ):
            current = next;
            spans.addAll(more);
            cuts.add((next._document(layer - 1), changed));
            deltas = [
              for (final (index, delta) in deltas.indexed)
                _merge(delta, carried[index]),
            ];
        }
      }
    }
    return Success((
      document: current,
      spans: spans,
      cuts: cuts,
      deltas: deltas,
    ));
  }

  /// This document with [below], an item edit carrying out [edit], applied
  /// to layer 1, and the span of the items it replaced there.
  Result<(Layered<T>, Range)> _itemized(Edit<T> edit, Edit<T> below) {
    final typed = _retype(below.command);
    if (typed == null) {
      return Failure(
        Kind.invalid,
        'grammar: $edit: $below does not edit the items of layer 1',
      );
    }
    return switch (_base.apply(typed)) {
      Failure(:final kind, :final message) => Failure(
        kind,
        'grammar: $edit: $message',
      ),
      Success(value: final base) => Success((
        _with(base, _upper),
        _span(typed),
      )),
    };
  }

  /// This document with the ranges [derivation] creates, removes, and
  /// updates at [layer] applied, once its edits below have been; what
  /// changed in [layer], where a range is updated only when its attributes
  /// differ; and the span of [layer]'s items that changed.
  ///
  /// Every item is found by binary search on its range, so the cost
  /// follows the ranges the derivation names, not the layer. The edits
  /// below may have left the ranges they changed out of order, but they
  /// never change [layer]'s items, so an item is found by its range in
  /// [origin], this document before them.
  ///
  /// The edits below move every start monotonically, except that a
  /// deletion collapses the starts it holds onto one position, where the
  /// items may then be out of order by length. Those starts are at the
  /// [cuts], the spans of the layer below that changed, each in the
  /// version it changed in; the items starting there are put in order, and
  /// the span changed covers every layer-[layer] + 1 range the move
  /// disturbs, so the layer above is derived again over it. Under a
  /// [nested] edit, the layer above is not derived again, so a move fails.
  Result<(Layered<T>, Delta, Range)> _settle(
    int layer,
    Derivation<T> derivation,
    Layered<T> origin,
    List<(Document<Object?>, Range)> cuts,
    bool nested,
  ) {
    final (below: _, :created, :removed, :updated) = derivation;
    if (_checked(layer, derivation) case Failure(:final kind, :final message)) {
      return Failure(kind, message);
    }
    final Document<Object?> marked;
    switch (layer == 2
        ? _change(_base, removed, created, updated)
        : _change(_upper[layer - 3], removed, created, updated)) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(:final value):
        marked = value;
    }
    final before = origin._document(layer - 1);
    final _Placement placement;
    switch (_placed(layer, before, marked, derivation, cuts, nested)) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(:final value):
        placement = value;
    }
    final placed = placement.placed;
    final upper = [..._upper];
    upper[layer - 2] = placed;
    if (layer > 2) {
      upper[layer - 3] = marked as Document<Marker>;
    }
    final lower = _document(layer - 1);
    return Success((
      _with(layer == 2 ? marked as Document<T> : _base, upper),
      (
        created: List.unmodifiable([for (final (marker, _) in created) marker]),
        removed: List.unmodifiable(removed),
        updated: List.unmodifiable([
          for (final marker in updated.keys)
            if (lower.resolve(marker) != marked.resolve(marker)) marker,
        ]),
        regions: const <Range>[],
      ),
      _touched(placement),
    ));
  }

  /// Nothing, or a [Kind.invalid] failure when [derivation] removes or
  /// updates a marker that is not a range of [layer], updates one it
  /// removes, or creates one already in use or outside the layer below.
  Result<void> _checked(int layer, Derivation<T> derivation) {
    final (below: _, :created, :removed, :updated) = derivation;
    final lower = _document(layer - 1);
    final flagged = _flagged[layer - 2];
    bool present(Marker marker) =>
        lower.resolve(marker) != null && !flagged.contains(marker);
    final gone = removed.toSet();
    for (final marker in removed) {
      if (!present(marker)) {
        return Failure(
          Kind.invalid,
          'removes $marker, which is not a layer $layer range',
        );
      }
    }
    for (final marker in updated.keys) {
      if (!present(marker) || gone.contains(marker)) {
        return Failure(
          Kind.invalid,
          'updates $marker, which is not a kept layer $layer range',
        );
      }
    }
    final fresh = <Marker>{};
    for (final (marker, range) in created) {
      if (lower.resolve(marker) != null || !fresh.add(marker)) {
        return Failure(Kind.invalid, 'creates $marker, which is in use');
      }
      if (outside(range, lower.length) != null) {
        return Failure(
          Kind.invalid,
          'creates $range outside 0..${lower.length} of layer ${layer - 1}',
        );
      }
    }
    return const Success(null);
  }

  /// Where [_settle] puts [layer]'s items, [before] being the layer below
  /// before the edits below it and [marked] the layer below after them.
  ///
  /// Removed items go first. Runs whose starts the [cuts] collapsed are
  /// then put back in start order, which fails under a [nested] edit. Each
  /// new item then goes after the items that come before it or with it in
  /// start order, and after the new ones that do. [derivation] names the
  /// items created, removed, and updated.
  Result<_Placement> _placed(
    int layer,
    Document<Object?> before,
    Document<Object?> marked,
    Derivation<T> derivation,
    List<(Document<Object?>, Range)> cuts,
    bool nested,
  ) {
    final (below: _, :created, :removed, :updated) = derivation;
    final document = _upper[layer - 2];
    final found = _indices(before, document, {...removed, ...updated.keys});
    final indices = [for (final marker in removed.toSet()) found[marker]!]
      ..sort();
    final deletes = <Command<Marker>>[
      for (final index in indices.reversed) Delete(positions.extent(index, 1)),
    ];
    final Document<Marker> kept;
    switch (_staged(document, document, deletes)) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(:final value):
        kept = value;
    }
    final List<Command<Marker>> orders;
    final List<Range> areas;
    switch (_arrange(marked, kept, cuts)) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(value: (final ordered, final disturbed)):
        (orders, areas) = (ordered, disturbed);
    }
    if (nested && orders.isNotEmpty) {
      return Failure(
        Kind.invalid,
        'reorders layer $layer items under the layer above it',
      );
    }
    final Document<Marker> arranged;
    switch (_staged(document, kept, orders)) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(:final value):
        arranged = value;
    }
    final (:places, :finals, :inserts) = _inserted(marked, arranged, created);
    return _staged(document, arranged, inserts).map(
      (placed) => (
        indices: indices,
        placed: placed,
        areas: areas,
        places: places,
        finals: finals,
        revised: [for (final marker in updated.keys) found[marker]!],
      ),
    );
  }
}

/// Where each of [created] goes among [arranged], items over [marked]:
/// its place once the removed items are gone, its final index, and the
/// commands that insert them all.
({List<int> places, List<int> finals, List<Command<Marker>> inserts}) _inserted(
  Document<Object?> marked,
  Document<Marker> arranged,
  List<(Marker, ARange)> created,
) {
  final ranges = [for (final (marker, _) in created) marked.resolve(marker)!];
  final places = [
    for (final range in ranges) _search(marked, arranged, range, after: true),
  ];
  final order = List.generate(created.length, (index) => index)
    ..sort((a, b) {
      final by = places[a] != places[b]
          ? places[a] - places[b]
          : _order(ranges[a], ranges[b]);
      return by != 0 ? by : a - b;
    });
  final finals = List<int>.filled(created.length, 0);
  final inserts = <Command<Marker>>[];
  for (final (rank, index) in order.indexed) {
    finals[index] = places[index] + rank;
    inserts.add(Insert(finals[index], Items.of([created[index].$1])));
  }
  return (places: places, finals: finals, inserts: inserts);
}

/// The span of a layer's items that [placement] changed: the new and
/// updated items, where removed ones were, which is before the first kept
/// item after them, and the areas reordering disturbs. Each point is found
/// by binary search, so the cost is O(k log k) in the items named.
Range _touched(_Placement placement) {
  final (:indices, placed: _, :areas, :places, :finals, :revised) = placement;
  // An item at [index] once the removed ones go stands after the new
  // ones placed at or before it.
  final sorted = [...places]..sort();
  int moved(int index) => index + _count(sorted, index);

  final points = <int>[
    for (final index in finals) ...[index, index + 1],
    // An updated item moves back past the removed items before it.
    for (final index in revised)
      ...switch (moved(index - _count(indices, index - 1))) {
        final at => [at, at + 1],
      },
    for (final (rank, index) in indices.indexed) moved(index - rank),
    for (final area in areas) ...[moved(area.start), moved(area.end - 1) + 1],
  ];
  final low = points.isEmpty ? 0 : points.reduce(min);
  final high = points.isEmpty ? 0 : points.reduce(max);
  return positions.extent(low, high - low);
}

/// [current], [origin] or a version made from it by [_staged], with
/// [commands] applied as one more stage of the same next version: the
/// version, [Document.previous], and [Document.commands] `transact` would
/// give for every stage's commands at once, without applying any twice.
Result<Document<S>> _staged<S>(
  Document<S> origin,
  Document<S> current,
  List<Command<S>> commands,
) {
  var next = current;
  for (final command in commands) {
    switch (next.apply(command, flatten: !identical(next, origin))) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(:final value):
        next = value;
    }
  }
  return Success(next);
}

/// The commands that put [items], markers of ranges marked on [below],
/// back in start order after deletions within [cuts] collapsed some of
/// their starts, each replacing a run with the same items in order; and
/// for each, the span of [items] it changes together with the ranges
/// marked on [items] that it disturbs.
Result<(List<Command<Marker>>, List<Range>)> _arrange(
  Document<Object?> below,
  Document<Marker> items,
  List<(Document<Object?>, Range)> cuts,
) {
  final List<(int, int)> runs;
  switch (_collapsed(below, items, cuts)) {
    case Failure(:final kind, :final message):
      return Failure(kind, message);
    case Success(:final value):
      runs = value;
  }
  final orders = <Command<Marker>>[];
  final areas = <Range>[];
  for (final (low, high) in runs) {
    final run = [
      for (var index = low; index < high; index++) items.item(index)!,
    ];
    final ranks = List.generate(run.length, (index) => index)
      ..sort((a, b) {
        final by = _order(below.resolve(run[a])!, below.resolve(run[b])!);
        return by != 0 ? by : a - b;
      });
    if (ranks.indexed.every((pair) => pair.$1 == pair.$2)) {
      continue;
    }
    final span = positions.extent(low, high - low);
    orders.add(Replace(span, Items.of([for (final rank in ranks) run[rank]])));
    areas.add(_disturbed(items, span));
  }
  return Success((orders, areas));
}

/// The runs of [items], markers of ranges marked on [below] in start
/// order but for the length order among equal starts, whose ranges start
/// within one of [cuts] carried into [below]: as index spans, merged
/// where they overlap.
Result<List<(int, int)>> _collapsed(
  Document<Object?> below,
  Document<Marker> items,
  List<(Document<Object?>, Range)> cuts,
) {
  // Starts at a cut move as an endpoint of right gravity does.
  final spans = <Range>[];
  for (final (from, cut) in cuts) {
    switch (mapped(cut, from, below, end: Gravity.right)) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(:final value):
        spans.add(value);
    }
  }
  spans.sort((a, b) => a.start - b.start);
  final runs = <(int, int)>[];
  for (final Range(:start, :end) in spans) {
    // The search orders by start before length, so it finds the run
    // whatever the order within it.
    final low = _search(below, items, positions.extent(start, 0));
    final high = _search(below, items, positions.extent(end + 1, 0));
    if (low == high) {
      continue;
    }
    if (runs.isNotEmpty && runs.last.$2 >= low) {
      runs.last = (runs.last.$1, max(runs.last.$2, high));
    } else {
      runs.add((low, high));
    }
  }
  return Success(runs);
}

/// [run], a span of the items of [items], taken together with the ranges
/// marked on [items] that replacing it disturbs: those with an end
/// inside it, or that start at its start or end at its end.
Range _disturbed(Document<Marker> items, Range run) {
  var area = run;
  for (final (_, range) in [
    for (final pair in items.crossing(run.start))
      if (pair.$2.end <= run.end) pair,
    for (final pair in items.crossing(run.end))
      if (pair.$2.start >= run.start) pair,
  ]) {
    area = _hull(area, range);
  }
  return area;
}

/// [document] with the marks [removed] taken away, [created] marked, and
/// [updated] given their new attributes.
Result<Document<S>> _change<S>(
  Document<S> document,
  List<Marker> removed,
  List<(Marker, ARange)> created,
  Map<Marker, Map<String, Value>> updated,
) => document.transact([
  for (final marker in removed) Unmark<S>(marker),
  for (final (marker, range) in created)
    Mark<S>.of(marker, range, end: Gravity.left),
  for (final MapEntry(key: marker, value: attributes) in updated.entries)
    Update<S>(marker, attributes),
]);
