import '../attributed/attributed.dart';
import '../persistent/persistent.dart';
import '../range/range.dart';
import '../sequence/sequence.dart';
import 'layered.dart';

/// The change a text [change], at layer 1, makes to [document] where it
/// leaves the markup and its diagnostics as they stand, or a [Kind.invalid]
/// failure saying what it would make of them: the check every
/// [Grammar.valid] carries out, with the grammar saying only which of its
/// layer-2 ranges are [text] rather than markup. By default none are, so
/// every range is markup.
///
/// The edit must be an `Insert`, `Delete` or `Replace` at layer 1 that
/// reaches into no markup range. Once it is applied, the markup ranges of
/// layer 2 must be the same, in order, each by its attributes and the items
/// it covers; and at every layer the diagnostics must be the same, in
/// order, each by its message and what lies under it: the items it covers
/// at layer 2, and at a layer above, each range of the layer below it
/// covers, by attributes and the items under that range. Counting is not
/// enough, since one range may have become another, and nor is a marker,
/// since deriving again may mark an unchanged range afresh. Annotations
/// take no part: no query it makes returns one.
Result<Change<T>> kept<T>(
  Layered<T> document,
  Edit<T> change, {
  bool Function(ARange range) text = _none,
}) {
  final (start, end) = switch (change.command) {
    Insert(:final position) => (position, position),
    Delete(:final span) || Replace(:final span) => (span.start, span.end),
    _ => (-1, -1),
  };
  if (change.layer != 1 || start < 0) {
    return Failure(Kind.invalid, 'valid: $change is not a text edit');
  }
  for (final range in _markup(document, text)) {
    if (range.start < end && start < range.end ||
        range.start < start && start < range.end) {
      return Failure(Kind.invalid, 'valid: the edit reaches into $range');
    }
  }
  return document.apply(change).flatMap((applied) {
    // As many ranges, or diagnostics, is not enough: one may have become
    // another.
    if (!_matching(
      _pieces(document, _markup(document, text)),
      _pieces(applied.document, _markup(applied.document, text)),
    )) {
      return Failure(Kind.invalid, 'valid: the edit changes the markup');
    }
    final (before, after) = (_flaws(document), _flaws(applied.document));
    if (before.length != after.length ||
        before.indexed.any((pair) {
          final (layer, attributes, under) = pair.$2;
          final (other, those, beneath) = after[pair.$1];
          return layer != other ||
              !_alike(attributes, those) ||
              !_matching(under, beneath);
        })) {
      return Failure(Kind.invalid, 'valid: the edit changes the diagnostics');
    }
    return Success(applied);
  });
}

/// No range is text.
bool _none(ARange range) => false;

/// A range as its attributes and the items under it.
typedef _Piece<T> = (Map<String, Value>, List<T>);

/// The layer-2 ranges of [document] that are not [text], in order.
List<ARange> _markup<T>(
  Layered<T> document,
  bool Function(ARange range) text,
) => [
  for (final range in document.layer(2).items.cast<ARange>())
    if (!text(range)) range,
];

/// Each of [ranges], over layer 1 of [document], as a piece.
List<_Piece<T>> _pieces<T>(Layered<T> document, List<ARange> ranges) => [
  for (final range in ranges) (range.attributes, _items(document, range)),
];

/// The diagnostics of [document], layer by layer and each layer's in order,
/// each with its layer, its attributes, and what lies under it: the items
/// it covers at layer 2, and at a layer above, each range of the layer
/// below it covers, by attributes and the items under that range. What lies
/// under one need not be balanced markup: it may start inside one unit of
/// the grammar and end inside another.
List<(int, Map<String, Value>, List<_Piece<T>>)> _flaws<T>(
  Layered<T> document,
) => [
  for (var layer = 2; layer <= document.depth; layer++)
    for (final flaw in document.diagnostics(layer).items.cast<ARange>())
      (
        layer,
        flaw.attributes,
        layer == 2
            ? [(const <String, Value>{}, _items(document, flaw))]
            : [
                for (final (marker, range) in document.span(layer - 1, flaw))
                  (
                    range.attributes,
                    _items(document, document.extent(layer - 1, marker)!),
                  ),
              ],
      ),
];

/// The items of layer 1 of [document] under [range].
List<T> _items<T>(Layered<T> document, Range range) =>
    document.slice(range).items.toList();

/// Whether [a] and [b] are the same pieces in the same order.
bool _matching<T>(List<_Piece<T>> a, List<_Piece<T>> b) =>
    a.length == b.length &&
    a.indexed.every((pair) {
      final (attributes, items) = pair.$2;
      final (those, others) = b[pair.$1];
      return _alike(attributes, those) &&
          items.length == others.length &&
          items.indexed.every((item) => item.$2 == others[item.$1]);
    });

/// Whether [a] and [b] hold the same attributes.
bool _alike(Map<String, Value> a, Map<String, Value> b) =>
    a.length == b.length &&
    a.entries.every((entry) => b[entry.key] == entry.value);
