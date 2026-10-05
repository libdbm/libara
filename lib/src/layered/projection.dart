part of 'layered.dart';

/// Projecting a range of any layer down to the layer-1 items it covers.
extension _Projecting<T> on Layered<T> {
  /// [extent], reusing the projections in [projected] and recording those
  /// it makes, so a lower range covered along several paths projects once.
  Range? _project(
    int layer,
    Marker marker,
    Map<(int, Marker), Range> projected,
  ) {
    if (layer < 2 || layer > _built) {
      return null;
    }
    final range = _document(layer - 1).resolve(marker);
    if (range == null) {
      return null;
    }
    if (layer == 2) {
      return positions.extent(range.start, range.length);
    }
    final items = _upper[layer - 3];
    // [range] is marked on [items], so every index it covers holds an
    // item, and every item is a range marked on the layer below, so it
    // projects.
    Range below(int index) {
      final item = items.item(index)!;
      return projected[(layer - 1, item)] ??= _project(
        layer - 1,
        item,
        projected,
      )!;
    }

    if (range.length == 0) {
      final at = range.start < items.length
          ? below(range.start).start
          : items.length == 0
          ? 0
          : below(items.length - 1).end;
      return positions.extent(at, 0);
    }
    // The items below need not end in start order, so each one counts.
    final first = below(range.start);
    var (start, end) = (first.start, first.end);
    for (var index = range.start + 1; index < range.end; index++) {
      final item = below(index);
      start = min(start, item.start);
      end = max(end, item.end);
    }
    return positions.extent(start, end - start);
  }
}

/// Projections of many ranges at once, for the selector module's `across`;
/// not exported from the package.
extension Projections<T> on Layered<T> {
  /// The ranges of every layer in [layers], each with its layer and marker,
  /// projected to layer 1 as [Layered.extent] projects them, with their
  /// attributes, in the order of [layers] and of each layer. One cache
  /// serves every projection, so each range below projects once. Layers
  /// outside `2..depth` give nothing.
  List<((int, Marker), ARange)> projected(Iterable<int> layers) {
    final cache = <(int, Marker), Range>{};
    return [
      for (final layer in layers.toSet())
        for (final (marker, range) in markers(layer))
          (
            (layer, marker),
            ARange.from(
              cache[(layer, marker)] ??= _project(layer, marker, cache)!,
              range.attributes,
            ),
          ),
    ];
  }
}
