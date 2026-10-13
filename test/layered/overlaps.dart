import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/layered/layered.dart';
import 'package:libara/src/persistent/command.dart' show Crossing;
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';

import '../support.dart';
import 'brackets.dart' show kind;

/// A test-only grammar of five layers over words and spaces whose layers
/// overlap the ways the bracket and XML grammars never do: ranges sharing a
/// start, ends out of start order, and identical ranges.
///
/// Every layer k >= 2 is made of blocks of the layer below. At layer 2 a
/// block is a word, a run of items that are not spaces. Above it, a block
/// is a `whole` range of the layer below with every item starting inside
/// it. Each block of `c` items gives four ranges, in start order: a `head`
/// over its first item and a `whole` over all of it, which share a start,
/// and, when `c > 2`, an `inner` over its second item twice, which ends
/// before the `whole` does. Each layer also has an `all` range over every
/// item of the layer below, which holds any region but the whole layer
/// and starts with the first block, and changes only when an edit reaches
/// one of its ends.
final class Overlaps implements Grammar<int> {
  /// The overlap grammar.
  const Overlaps();

  /// A space, which separates words.
  static const space = 0x20;

  @override
  int get depth => 5;

  @override
  Derived derive(Layered<int> document, int layer, Range region) =>
      (ranges: _ranges(document, layer, region), diagnostics: const []);

  /// Layer [layer]'s ranges over [region]: those of every block inside it,
  /// and `all` when [region] is the whole layer.
  List<ARange> _ranges(Layered<int> document, int layer, Range region) => [
    if (region.start == 0 &&
        region.end == _length(document, layer) &&
        region.length > 0)
      tagged(0, region.length, attributes: {'type': kind('all')}),
    for (final block in blocks(document, layer))
      if (region.start <= block.start && block.end <= region.end) ...[
        tagged(block.start, 1, attributes: {'type': kind('head')}),
        tagged(block.start, block.length, attributes: {'type': kind('whole')}),
        if (block.length > 2)
          for (var copy = 0; copy < 2; copy++)
            tagged(block.start + 1, 1, attributes: {'type': kind('inner')}),
      ],
  ];

  /// Every block that meets [changed] or one of its ends, taken together
  /// with [changed]: a block's ranges change only when its items do, and
  /// items inserted at a block's end may join it. The whole layer when
  /// [changed] reaches either end of it, where the `all` range ends.
  @override
  Range affected(Layered<int> document, int layer, Range changed) {
    final length = _length(document, layer);
    if (changed.start == 0 || changed.end == length) {
      return span(0, length);
    }
    var (start, end) = (changed.start, changed.end);
    for (final block in blocks(document, layer)) {
      if (block.start <= changed.end && block.end >= changed.start) {
        start = block.start < start ? block.start : start;
        end = block.end > end ? block.end : end;
      }
    }
    return span(start, end - start);
  }

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) =>
      Failure(Kind.invalid, 'overlaps: no structural edits');

  /// The blocks of the items of the layer below [layer], in order.
  List<Range> blocks(Layered<int> document, int layer) {
    if (layer == 2) {
      final points = document.items.items.toList();
      final words = <Range>[];
      var start = 0;
      while (start < points.length) {
        if (points[start] == space) {
          start++;
          continue;
        }
        var end = start;
        while (end < points.length && points[end] != space) {
          end++;
        }
        words.add(span(start, end - start));
        start = end;
      }
      return words;
    }
    final items = document.layer(layer - 1).items.cast<ARange>().toList();
    return [
      for (final whole in items)
        if (whole.get('type') == kind('whole'))
          _run(items, whole.start, whole.end),
    ];
  }

  /// The number of items in the layer below [layer].
  static int _length(Layered<int> document, int layer) =>
      layer == 2 ? document.items.length : document.layer(layer - 1).length;

  /// The run of [items], in start order, that start in `from..to`.
  static Range _run(List<ARange> items, int from, int to) {
    var first = 0;
    while (items[first].start < from) {
      first++;
    }
    var last = first;
    while (last < items.length && items[last].start < to) {
      last++;
    }
    return span(first, last - first);
  }

  /// Every range is markup, so only an edit changing none is valid.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      kept(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}
