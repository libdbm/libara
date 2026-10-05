part of 'layered.dart';

/// The region a text edit derives a layer again over, and the grammar's checked
/// answers there.
extension _Widening<T> on Layered<T> {
  /// The grammar's ranges, in start order, and diagnostics for layer
  /// [layer] over [region] of the layer below, or a [Kind.invalid] failure
  /// when the grammar throws. A range or diagnostic outside the region, and
  /// a diagnostic without a `message`, is replaced by a diagnostic over the
  /// region saying why.
  Result<(List<ARange>, List<ARange>)> _asked(int layer, Range region) {
    final Derived derived;
    switch (_ask(
      'derive at layer $layer over $region',
      () => grammar.derive(this, layer, region),
    )) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(:final value):
        derived = value;
    }
    final (:ranges, :diagnostics) = derived;
    bool fits(ARange range) =>
        outside(range, region.end) == null && range.start >= region.start;
    ARange flag(ARange range, String problem) => ARange.from(region, {
      'message': Str(Text.of('grammar: $range $problem')),
    });
    final kept = <ARange>[];
    final flags = <ARange>[];
    for (final range in ranges) {
      if (fits(range)) {
        kept.add(range);
      } else {
        flags.add(flag(range, 'is outside $region'));
      }
    }
    for (final range in diagnostics) {
      flags.add(switch ((fits(range), range.has('message'))) {
        (true, true) => range,
        (false, _) => flag(range, 'is outside $region'),
        (true, false) => flag(range, 'has no message'),
      });
    }
    return Success((
      Ranges.of(kept).startOrder().items.cast<ARange>().toList(),
      flags,
    ));
  }

  /// The region of layer [layer] - 1 to derive layer [layer] again over,
  /// after [changed] items of it changed: the grammar's affected region,
  /// taken together with [changed], then widened until no layer-[layer]
  /// range crosses its boundary and every diagnostic that overlaps or
  /// touches it lies inside it.
  Result<Range> _region(int layer, Range changed) {
    final below = _document(layer - 1);
    final Range named;
    switch (_ask(
      'affected at layer $layer for $changed',
      () => grammar.affected(this, layer, changed),
    )) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(:final value):
        named = value;
    }
    if (outside(named, below.length) != null) {
      return Failure(
        Kind.invalid,
        'grammar: affected region $named is outside 0..${below.length}',
      );
    }
    var region = _hull(named, changed);
    var widened = true;
    while (widened) {
      widened = false;
      // A range crossing the region spans one of its ends: its start, ending
      // before the region does, or its end, starting after the region does.
      for (final range in [
        for (final (_, range) in crossing(layer, region.start))
          if (range.end < region.end) range,
        for (final (_, range) in crossing(layer, region.end))
          if (range.start > region.start) range,
      ]) {
        region = _hull(region, range);
        widened = true;
      }
      for (final (_, flag) in _outlying(layer, region)) {
        region = _hull(region, flag);
        widened = true;
      }
    }
    return Success(region);
  }

  /// [layer]'s diagnostics that touch [region] of the layer below and
  /// stick out of it, each with its marker, found by queries at its ends,
  /// so the cost follows the ranges there, not the diagnostics elsewhere
  /// or the size of the region.
  ///
  /// Such a range starts before the region and crosses its start or ends
  /// at it, or ends after the region and crosses its end or starts at it.
  /// One ending at the start crosses the position before it or covers just
  /// that position, and one starting at the end crosses the position after
  /// it or covers just the end.
  List<(Marker, ARange)> _outlying(int layer, Range region) {
    final flagged = _flagged[layer - 2];
    if (flagged.isEmpty) {
      return const [];
    }
    final below = _document(layer - 1);
    final (start, end) = (region.start, region.end);
    final found = <Marker, ARange>{};
    for (final (marker, range) in [
      ...below.crossing(start),
      ...below.crossing(end),
      if (start > 0) ...[
        ...below.crossing(start - 1),
        ...below.within(positions.extent(start - 1, 1)),
      ],
      if (end < below.length) ...[
        ...below.crossing(end + 1),
        ...below.within(positions.extent(end, 1)),
      ],
    ]) {
      if (flagged.contains(marker) &&
          _touches(range, region) &&
          !range.within(region)) {
        found[marker] = range;
      }
    }
    return [for (final MapEntry(:key, :value) in found.entries) (key, value)];
  }
}

/// Whether [range] meets [region] or one of its ends.
bool _touches(Range range, Range region) =>
    range.start <= region.end && range.end >= region.start;
