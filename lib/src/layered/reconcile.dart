part of 'layered.dart';

/// Deriving a layer again over a region, keeping the markers of ranges that
/// come out identical.
extension _Reconciling<T> on Layered<T> {
  /// This document with layer [layer] derived again over the region of the
  /// layer below that [changed] items of it affect, the layer below being
  /// up to date; and what changed in layer [layer], and the span of its
  /// items derived again. Ranges and diagnostics outside the region keep
  /// their markers, and so do those inside it that come out identical.
  ///
  /// The items are in start order, so those starting in the region are one
  /// run, found by binary search, and the work is done within it: the cost
  /// follows the region, not the layer.
  ///
  /// A deletion below may have collapsed the starts of some items onto
  /// one position within [changed], leaving them out of order by length.
  /// They are put in order first, and the span returned covers the ranges
  /// above that the move disturbs, as `_settle` does.
  Result<(Layered<T>, Delta, Range)> _rederive(int layer, Range changed) {
    final below = _document(layer - 1);
    final document = _upper[layer - 2];
    switch (_arrange(below, document, [(below, changed)])) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(value: (final orders, final areas)) when orders.isNotEmpty:
        return _rearranged(layer, changed, orders, areas);
      case Success():
    }
    return _region(layer, changed).flatMap(
      (region) => _asked(
        layer,
        region,
      ).flatMap((asked) => _reconciled(layer, region, asked.$1, asked.$2)),
    );
  }

  /// [_rederive] over [region], once the grammar has derived [wanted]
  /// ranges and [notes] there.
  Result<(Layered<T>, Delta, Range)> _reconciled(
    int layer,
    Range region,
    List<ARange> wanted,
    List<ARange> notes,
  ) {
    final below = _document(layer - 1);
    final document = _upper[layer - 2];
    final first = _search(below, document, positions.extent(region.start, 0));
    final last = _search(below, document, positions.extent(region.end + 1, 0));
    final run = span(layer, positions.extent(first, last - first));
    final (:matched, :gone) = _matched(run, wanted, region);
    final removed = [for (final index in gone) run[index].$1];
    final added = [
      for (final (position, range) in wanted.indexed)
        if (matched[position] == null) range,
    ];
    final (:fresh, :stale) = _noted(layer, region, notes);
    final Document<Object?> placed;
    final List<Marker> marked;
    switch (_marks(layer, [...removed, ...stale], [...added, ...fresh])) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(:final value):
        (placed, marked) = value;
    }
    final created = marked.sublist(0, added.length);
    final (:edits, :spots) = spliced(
      run,
      wanted,
      matched,
      gone,
      created,
      region,
      first,
    );
    final Document<Marker> layered;
    switch (document.transact(edits)) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(:final value):
        layered = value;
    }
    return Success((
      _rebuilt(
        layer,
        placed,
        layered,
        stale.isEmpty && fresh.isEmpty
            ? _flagged[layer - 2]
            : Set<Marker>.unmodifiable({
                for (final marker in _flagged[layer - 2])
                  if (!stale.contains(marker)) marker,
                ...marked.sublist(added.length),
              }),
      ),
      (
        created: List.unmodifiable(created),
        removed: List.unmodifiable(removed),
        updated: const <Marker>[],
        regions: [region],
      ),
      spots.isEmpty
          ? positions.extent(first, 0)
          : positions.extent(spots.first, spots.last + 1 - spots.first),
    ));
  }

  /// The layer below [layer] with the marks [gone] removed and [ranges]
  /// marked, and the markers of the new marks, in order.
  Result<(Document<Object?>, List<Marker>)> _marks(
    int layer,
    List<Marker> gone,
    List<ARange> ranges,
  ) => layer == 2
      ? _replace<T>(_base, gone, ranges)
      : _replace<Marker>(_upper[layer - 3], gone, ranges);

  /// [_rederive] once [orders] put back in start order the items whose
  /// starts a deletion collapsed, the span returned taken together with the
  /// [areas] the reorder disturbs.
  Result<(Layered<T>, Delta, Range)> _rearranged(
    int layer,
    Range changed,
    List<Command<Marker>> orders,
    List<Range> areas,
  ) {
    final Document<Marker> arranged;
    switch (_upper[layer - 2].transact(orders)) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(:final value):
        arranged = value;
    }
    final upper = [..._upper];
    upper[layer - 2] = arranged;
    return _with(_base, upper)._rederive(layer, changed).flatMap((result) {
      final (next, delta, span) = result;
      final document = next._upper[layer - 2];
      var whole = span;
      for (final area in areas) {
        switch (mapped(
          area,
          arranged,
          document,
          start: Gravity.left,
          end: Gravity.right,
        )) {
          case Failure(:final kind, :final message):
            return Failure(kind, message);
          case Success(:final value):
            whole = _hull(whole, value);
        }
      }
      return Success((next, delta, whole));
    });
  }

  /// [layer]'s diagnostics within [region] against [notes], the ones
  /// derived over it: the notes no diagnostic matches by value, [fresh],
  /// and the diagnostics no note matches, [stale]. The rest are kept.
  ///
  /// Only the diagnostics within the region are read, through a regional
  /// query, so those elsewhere cost nothing.
  ({List<ARange> fresh, Set<Marker> stale}) _noted(
    int layer,
    Range region,
    List<ARange> notes,
  ) {
    final flagged = _flagged[layer - 2];
    final spare = <ARange, ListQueue<Marker>>{};
    if (flagged.isNotEmpty) {
      for (final (marker, range) in _document(layer - 1).within(region)) {
        if (flagged.contains(marker)) {
          (spare[range] ??= ListQueue()).add(marker);
        }
      }
    }
    final fresh = <ARange>[];
    for (final note in notes) {
      final queue = spare[note];
      if (queue != null && queue.isNotEmpty) {
        queue.removeFirst();
      } else {
        fresh.add(note);
      }
    }
    return (fresh: fresh, stale: {for (final queue in spare.values) ...queue});
  }

  /// This document with [placed] as the layer below [layer], [layered] as
  /// [layer], and [flags], unmodifiable, as [layer]'s diagnostics.
  Layered<T> _rebuilt(
    int layer,
    Document<Object?> placed,
    Document<Marker> layered,
    Set<Marker> flags,
  ) {
    final upper = [..._upper];
    upper[layer - 2] = layered;
    if (layer > 2) {
      upper[layer - 3] = placed as Document<Marker>;
    }
    final flagged = [..._flagged];
    flagged[layer - 2] = flags;
    return Layered<T>._(
      grammar,
      depth,
      layer == 2 ? placed as Document<T> : _base,
      List.unmodifiable(upper),
      List.unmodifiable(flagged),
      _annotations,
      version,
      previous,
      changes,
    );
  }
}

/// For each of [wanted], the index in [run] of an identical old range
/// inside [region] that it keeps, or `null`; and the indices of the old
/// ranges inside [region] that none keeps.
///
/// Matching keeps the old order, so the kept items need no reordering.
/// A range in the run that holds the region stays as it is.
({List<int?> matched, Set<int> gone}) _matched(
  List<(Marker, ARange)> run,
  List<ARange> wanted,
  Range region,
) {
  final unused = <ARange, ListQueue<int>>{};
  for (final (index, (_, range)) in run.indexed) {
    if (range.within(region)) {
      (unused[range] ??= ListQueue()).add(index);
    }
  }
  final matched = List<int?>.filled(wanted.length, null);
  var latest = -1;
  for (final (position, range) in wanted.indexed) {
    final queue = unused[range];
    if (queue != null && queue.isNotEmpty && queue.first > latest) {
      latest = queue.removeFirst();
      matched[position] = latest;
    }
  }
  final kept = {for (final index in matched) ?index};
  return (
    matched: matched,
    gone: {
      for (final (index, (_, range)) in run.indexed)
        if (range.within(region) && !kept.contains(index)) index,
    },
  );
}

/// The commands that turn [run], the items of a layer from [first],
/// into [wanted] over [region], as [matched] and [gone] pair them, with
/// the [created] markers for the ranges no old one matched; and the
/// index each wanted range ends up at.
///
/// Once the [gone] items go, the kept ones stand in start order among
/// the ranges of the run that hold the region, which may lie between
/// them. Each wanted range takes its place in that order: kept where
/// matched, and a new one after the wanted range before it and after
/// every holding range that comes before it. Indices are within the run.
/// One forward merge, so the cost is linear in the run and [wanted].
///
/// For the library and its tests; hidden from the public `libara` library.
({List<Command<Marker>> edits, List<int> spots}) spliced(
  List<(Marker, ARange)> run,
  List<ARange> wanted,
  List<int?> matched,
  Set<int> gone,
  List<Marker> created,
  Range region,
  int first,
) {
  final rest = [
    for (final (index, pair) in run.indexed)
      if (!gone.contains(index)) pair,
  ];
  final edits = <Command<Marker>>[
    for (final index in gone.toList()..sort((a, b) => b - a))
      Delete(positions.extent(first + index, 1)),
  ];
  // One forward merge: [taken] items of [rest] are passed, and the list
  // built so far, of those and the wanted ranges, has [placed] items, so
  // each new range is inserted at the end of it.
  final spots = <int>[];
  var taken = 0;
  var placed = 0;
  var next = 0;
  for (final (position, index) in matched.indexed) {
    if (index == null) {
      final range = wanted[position];
      while (taken < rest.length &&
          !rest[taken].$2.within(region) &&
          _order(rest[taken].$2, range) < 0) {
        taken++;
        placed++;
      }
      edits.add(Insert(first + placed, Items.of([created[next++]])));
    } else {
      final marker = run[index].$1;
      while (rest[taken].$1 != marker) {
        taken++;
        placed++;
      }
      taken++;
    }
    spots.add(first + placed++);
  }
  return (edits: edits, spots: spots);
}

/// [document] with the marks [gone] removed and [ranges] marked, and the
/// markers of the new marks, in order.
Result<(Document<S>, List<Marker>)> _replace<S>(
  Document<S> document,
  List<Marker> gone,
  List<ARange> ranges,
) {
  final marks = [for (final range in ranges) _mark<S>(range)];
  return document
      .transact([for (final marker in gone) Unmark<S>(marker), ...marks])
      .map((placed) => (placed, [for (final mark in marks) mark.marker]));
}
