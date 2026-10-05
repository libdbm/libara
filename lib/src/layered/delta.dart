part of 'layered.dart';

/// A [Delta] with nothing in it.
const Delta _none = (
  created: <Marker>[],
  removed: <Marker>[],
  updated: <Marker>[],
  regions: <Range>[],
);

/// [delta] with every list unmodifiable, as a [Change] returns it.
Delta _frozen(Delta delta) => (
  created: List.unmodifiable(delta.created),
  removed: List.unmodifiable(delta.removed),
  updated: List.unmodifiable(delta.updated),
  regions: List.unmodifiable(delta.regions),
);

/// [a] followed by [b], as one delta: a marker created and then removed
/// appears in neither.
Delta _merge(Delta a, Delta b) => _merged([a, b]);

/// [deltas] one after another, as one delta, as [_merge] folds them: a
/// marker created and then removed appears in neither.
///
/// One pass, adding each delta to sets frozen once at the end, so the cost
/// is linear in the markers and regions of [deltas], rather than copying
/// what came before for each one.
Delta _merged(List<Delta> deltas) {
  final created = <Marker>{};
  final removed = <Marker>{};
  final updated = <Marker>{};
  final regions = <Range>[];
  for (final delta in deltas) {
    // Removed unless created by an earlier delta.
    final gone = [
      for (final marker in delta.removed)
        if (!created.contains(marker)) marker,
    ];
    removed.addAll(gone);
    created
      ..addAll(delta.created)
      ..removeAll(delta.removed);
    updated.addAll(delta.updated);
    // The markers updated so far are neither created nor removed, so only
    // those this delta names can now be either.
    for (final marker in [...gone, ...delta.created, ...delta.updated]) {
      if (removed.contains(marker) || created.contains(marker)) {
        updated.remove(marker);
      }
    }
    regions.addAll(delta.regions);
  }
  return (
    created: List.unmodifiable(created),
    removed: List.unmodifiable(removed),
    updated: List.unmodifiable(updated),
    regions: List.unmodifiable(regions),
  );
}

/// The item span the layer-1 [command] replaced, in the version after it.
Range _span(Command<Object?> command) {
  final (start, length) = switch (command) {
    Insert(:final position, :final items) => (position, items.length),
    Delete(:final span) => (span.start, 0),
    Replace(:final span, :final items) => (span.start, items.length),
    _ => (0, 0),
  };
  return positions.extent(start, length);
}

/// [delta] for [layer] across a transaction from [from] to [to], updating
/// only the ranges whose attributes differ between them, as later edits may
/// have set them back.
Delta _settled<T>(Delta delta, int layer, Layered<T> from, Layered<T> to) {
  if (layer == 1) {
    return delta;
  }
  final (before, after) = (from._document(layer - 1), to._document(layer - 1));
  return (
    created: delta.created,
    removed: delta.removed,
    updated: List.unmodifiable([
      for (final marker in delta.updated)
        if (!alike(
          before.resolve(marker)!.attributes,
          after.resolve(marker)!.attributes,
        ))
          marker,
    ]),
    regions: delta.regions,
  );
}

/// The deltas of [steps] for [layer], each step made from the one before
/// it starting at [from], with every region carried into the positions of
/// the last step.
///
/// One pass over the commands between the steps: each step's regions
/// become anchors, which the later commands move all at once, so the cost
/// is linear in the commands and regions, up to a log factor, rather than
/// the product of the two.
List<Delta> _carried<T>(Layered<T> from, List<Change<T>> steps, int layer) {
  final under = layer == 1 ? 1 : layer - 1;
  var anchors = const Anchors.empty();
  final placed = <List<(Anchor, Anchor)>>[];
  var before = from._document(under);
  for (final step in steps) {
    final after = step.document._document(under);
    for (final command in _between(before, after)) {
      anchors = anchors.apply(command);
    }
    final pairs = <(Anchor, Anchor)>[];
    for (final region in step.layers[layer - 1].regions) {
      // A region is a range, so its ends are never negative.
      if (anchors.add(region.start, Gravity.right) case Success(
        value: (final started, final start),
      )) {
        if (started.add(region.end, Gravity.left) case Success(
          value: (final ended, final end),
        )) {
          anchors = ended;
          pairs.add((start, end));
        }
      }
    }
    placed.add(pairs);
    before = after;
  }
  return [
    for (final (index, step) in steps.indexed)
      (
        created: step.layers[layer - 1].created,
        removed: step.layers[layer - 1].removed,
        updated: step.layers[layer - 1].updated,
        regions: [
          for (final (start, end) in placed[index])
            switch ((anchors.position(start), anchors.position(end))) {
              (final first, final last) => positions.extent(
                first,
                last < first ? 0 : last - first,
              ),
            },
        ],
      ),
  ];
}

/// The commands that made [to] from [from], an earlier version of the same
/// document, in the order they were applied.
List<Command<Object?>> _between(Document<Object?> from, Document<Object?> to) {
  final versions = <Document<Object?>>[];
  for (
    Document<Object?>? version = to;
    version != null && !identical(version, from);
    version = version.previous
  ) {
    versions.add(version);
  }
  return [for (final version in versions.reversed) ...version.commands];
}

/// [span] in [from] carried into the positions of [to], a later version of
/// the same document, its ends moving as endpoints with [start] and [end]
/// gravity: by default its start follows items inserted at it and its end
/// does not, as a range grows only inward. A [Kind.invalid] failure names
/// the broken invariant when [from] is not in the history of [to].
///
/// For the library and its tests; hidden from the public `libara` library.
Result<Range> mapped(
  Range span,
  Document<Object?> from,
  Document<Object?> to, {
  Gravity start = Gravity.right,
  Gravity end = Gravity.left,
}) => switch ((to.map(from, span.start, start), to.map(from, span.end, end))) {
  (Success(value: final first), Success(value: final last)) => Success(
    positions.extent(first, last < first ? 0 : last - first),
  ),
  (Failure(:final message), _) || (_, Failure(:final message)) => Failure(
    Kind.invalid,
    'invariant: $span does not carry: $message',
  ),
};
