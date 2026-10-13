/// The layered module: [Layered] documents of layers 1 to n over one
/// sequence, edited with the persistent commands, and the [Grammar] that
/// gives their layers meaning.
library;

import 'dart:collection';
import 'dart:math';

import '../attributed/attributed.dart';
import '../persistent/anchors.dart';
import '../persistent/document.dart' as persistent show check, placed;
import '../persistent/persistent.dart';
import '../range/range.dart';
import '../range/range.dart' as positions show extent;
import '../sequence/sequence.dart';
import 'grammar.dart';

export 'format.dart';
export 'grammar.dart';
export 'kept.dart';

part 'delta.dart';
part 'projection.dart';
part 'reconcile.dart';
part 'region.dart';
part 'settle.dart';

/// An edit to a layered document: a persistent [command] acting on the
/// items or ranges of [layer], or on its annotations.
final class Edit<T> {
  /// [command] at [layer].
  const Edit(this.layer, this.command) : annotation = false;

  /// [command], a `Mark`, `Update` or `Unmark`, acting on an annotation
  /// over the items of [layer]: a range the caller owns, which the grammar
  /// neither derives nor sees.
  const Edit.annotation(this.layer, this.command) : annotation = true;

  /// The layer whose items or ranges [command] acts on, from 1.
  final int layer;

  /// What the edit does.
  final Command<Object?> command;

  /// Whether [command] acts on an annotation over [layer]'s items rather
  /// than on the layer itself.
  final bool annotation;

  @override
  String toString() => annotation
      ? 'Edit.annotation($layer, $command)'
      : 'Edit($layer, $command)';
}

/// What one layer gained and lost in an edit.
///
/// For layer 1, `regions` holds the item spans the edit replaced and the
/// marker lists are empty. For a layer k >= 2, `created`, `removed`, and
/// `updated` name the layer-k ranges added, taken away, and given new
/// attributes, and `regions` the regions of layer k - 1 derived again.
/// Positions are in the new version.
typedef Delta = ({
  List<Marker> created,
  List<Marker> removed,
  List<Marker> updated,
  List<Range> regions,
});

/// The result of an edit: the new version; for each layer from 1, what
/// changed in it; and for each layer from 1, the annotations over its items
/// created, removed and updated, with no regions.
typedef Change<T> = ({
  Layered<T> document,
  List<Delta> layers,
  List<Delta> annotations,
});

/// A document of layers 1 to n over one sequence.
///
/// Layer 1 is the sequence itself. Each layer k above it is a sequence of
/// ranges over the items of layer k - 1, derived by the [grammar]. Every
/// layer is a persistent [Document]: layer 1 holds the items, and each
/// layer k >= 2 holds the markers of layer k's ranges, which are marked on
/// layer k - 1. So an edit to one layer moves the ranges above it without
/// rewriting their offsets.
final class Layered<T> {
  Layered._(
    this.grammar,
    this.depth,
    this._base,
    this._upper,
    this._flagged,
    this._annotations,
    this.version,
    this.previous,
    this.changes,
  );

  /// Version 0 of a layered document over [items], every layer derived by
  /// [grammar], whose depth is read once, here.
  ///
  /// A depth below 1, or a depth getter that throws, is a [Kind.invalid]
  /// failure. Nothing else fails: what does not parse becomes diagnostics,
  /// and so does a range the grammar returns outside the region it was
  /// asked about.
  static Result<Layered<S>> of<S>(Sequence<S> items, Grammar<S> grammar) =>
      switch (_ask('depth', () => grammar.depth)) {
        Failure(:final kind, :final message) => Failure(
          kind,
          'layered: $message',
        ),
        Success(value: final depth) when depth < 1 => Failure(
          Kind.invalid,
          'layered: grammar: depth $depth is below 1',
        ),
        Success(value: final depth) => _derived(items, grammar, depth),
      };

  /// Version 0 over [items], with layers 2 to [depth] derived by [grammar].
  static Result<Layered<S>> _derived<S>(
    Sequence<S> items,
    Grammar<S> grammar,
    int depth,
  ) {
    var document = Layered<S>._(
      grammar,
      depth,
      Document.of(items),
      const [],
      const [],
      List.unmodifiable(List.filled(depth, const <Marker>{})),
      0,
      null,
      const [],
    );
    for (var layer = 2; layer <= depth; layer++) {
      switch (document._derive(layer)) {
        case Failure(:final kind, :final message):
          return Failure(kind, 'layered: layer $layer: $message');
        case Success(:final value):
          document = value;
      }
    }
    return Success(document);
  }

  /// What the layers mean.
  final Grammar<T> grammar;

  /// Layer 1, holding the items and the marks of layer 2.
  final Document<T> _base;

  /// Layers 2 and up, from layer 2: the markers of each layer's ranges as
  /// items, and the marks of the layer above.
  final List<Document<Marker>> _upper;

  /// For each layer from 2, the markers on the layer below that are
  /// diagnostics rather than ranges.
  final List<Set<Marker>> _flagged;

  /// For each layer from 1, the markers on its document that are
  /// annotations: ranges over its items the caller owns, which are neither
  /// ranges of the layer above nor diagnostics.
  final List<Set<Marker>> _annotations;

  /// 0 for a derived document, one more for each edit.
  final int version;

  /// The version this one was derived from, or `null` for version 0.
  final Layered<T>? previous;

  /// The edits that made this version from [previous], in order: one for
  /// [apply], all of them for [transact], and none for version 0.
  final List<Edit<T>> changes;

  /// The number of layers, read from the [grammar] once, when version 0
  /// was built.
  final int depth;

  /// Version 0 with the same layers, markers, and diagnostics, no
  /// [previous], and no [changes]: every layer's document compacted, so the
  /// versions before it can be reclaimed once nothing else holds them.
  /// Cannot fail.
  Layered<T> compact() => Layered<T>._(
    grammar,
    depth,
    _base.compact(),
    List.unmodifiable([for (final document in _upper) document.compact()]),
    _flagged,
    _annotations,
    0,
    null,
    const [],
  );

  /// Layer 1: the items.
  Sequence<T> get items => _base;

  /// The number of layers built so far: all of them, except while
  /// [Layered.of] is still deriving.
  int get _built => 1 + _upper.length;

  /// The persistent document of [layer], from 1.
  Document<Object?> _document(int layer) =>
      layer == 1 ? _base : _upper[layer - 2];

  /// Layer [layer]'s ranges, each with its marker, in the layer's item
  /// order, over the items of the layer below. Empty outside `2..depth`.
  List<(Marker, ARange)> markers(int layer) {
    if (layer < 2 || layer > _built) {
      return const [];
    }
    final below = _document(layer - 1);
    return List.unmodifiable([
      for (final marker in _upper[layer - 2].items)
        (marker, below.resolve(marker)!),
    ]);
  }

  /// Layer [layer]'s ranges in the layer's item order, over the items of
  /// the layer below. Empty outside `2..depth`.
  Ranges layer(int layer) =>
      Ranges.of([for (final (_, range) in markers(layer)) range]);

  /// Where layer [layer] could not be derived, in start order: ranges over
  /// the items of the layer below, each with a `message` attribute.
  Ranges diagnostics(int layer) {
    if (layer < 2 || layer > _built) {
      return Ranges.empty();
    }
    final below = _document(layer - 1);
    return Ranges.of([
      for (final marker in _flagged[layer - 2]) below.resolve(marker)!,
    ]).startOrder();
  }

  /// Whether no layer has a diagnostic.
  bool get valid => _flagged.every((flagged) => flagged.isEmpty);

  /// The layer-[layer] range under [marker] projected down to layer 1, so
  /// callers can find the items it covers, or `null` when [marker] is not
  /// marked at that layer: the smallest range holding the projections of
  /// every item of the layer below that it covers. A zero-length range
  /// projects to the start of the item it stands before, or to the end of
  /// the last item when it stands at the end.
  Range? extent(int layer, Marker marker) => _project(layer, marker, {});

  /// The layer-1 items in [region], clamped to the items, in
  /// `O(log n + k)` for `k` items: for grammars that read one region.
  Sequence<T> slice(Range region) => _base.slice(region.start, region.length);

  /// Layer [layer]'s ranges lying within [region] of the layer below's
  /// items, its ends included, each with its marker, in the layer's order.
  /// Empty outside `2..depth`. The cost follows what it finds, as
  /// [Document.within]'s does.
  List<(Marker, ARange)> within(int layer, Range region) =>
      _ranges(layer, (document) => document.within(region));

  /// Layer [layer]'s ranges that start before [position] of the layer
  /// below's items and end after it, each with its marker, in the layer's
  /// order. Empty outside `2..depth`. The cost follows what it finds, as
  /// [Document.crossing]'s does.
  List<(Marker, ARange)> crossing(int layer, int position) =>
      _ranges(layer, (document) => document.crossing(position));

  /// Layer [layer]'s items at the indices in [indices], clamped to the
  /// layer, each with its marker, in the layer's order: a region of the
  /// layer as the layer above sees it. Empty outside `2..depth`.
  List<(Marker, ARange)> span(int layer, Range indices) {
    if (layer < 2 || layer > _built) {
      return const [];
    }
    final below = _document(layer - 1);
    final items = _upper[layer - 2];
    return List.unmodifiable([
      for (
        var index = indices.start;
        index < min(indices.end, items.length);
        index++
      )
        if (items.item(index) case final marker?)
          (marker, below.resolve(marker)!),
    ]);
  }

  /// The annotations over layer [layer]'s items, each with its marker, in
  /// start order: ranges the caller owns, added by [Edit.annotation], which
  /// no other query returns and the grammar never sees. Empty outside
  /// `1..depth`.
  List<(Marker, ARange)> annotations(int layer) {
    if (layer < 1 || layer > _built) {
      return const [];
    }
    // Each found by its marker, so the cost is theirs and not the layer's.
    final document = _document(layer);
    final pairs = [
      for (final marker in _annotations[layer - 1])
        (marker, document.resolve(marker)!),
    ];
    final order = List.generate(pairs.length, (index) => index)
      ..sort((a, b) {
        final (x, y) = (pairs[a].$2, pairs[b].$2);
        final by = x.start != y.start ? x.start - y.start : x.length - y.length;
        return by != 0 ? by : a - b;
      });
    return List.unmodifiable([for (final index in order) pairs[index]]);
  }

  /// The gravities of the annotation under [marker] over layer [layer]'s
  /// items, as [Document.gravity] gives a range's, or `null` when [marker]
  /// is not one.
  ({Gravity start, Gravity end})? gravity(int layer, Marker marker) =>
      layer < 1 || layer > _built || !_annotations[layer - 1].contains(marker)
      ? null
      : _document(layer).gravity(marker);

  /// This document after [edit], an annotation edit: its `Mark`, `Update`
  /// or `Unmark` applied to its layer's document alone, every layer left as
  /// it is, and nothing derived.
  Result<Change<T>> _annotate(Edit<T> edit) {
    final Edit(:layer, :command) = edit;
    final noted = _annotations[layer - 1];
    final Set<Marker> next;
    switch (command) {
      case Mark(:final marker):
        next = {...noted, marker};
      case Unmark(:final marker) when noted.contains(marker):
        next = {...noted}..remove(marker);
      case Update(:final marker) when noted.contains(marker):
        next = noted;
      default:
        return Failure(
          Kind.invalid,
          'layered: $command at layer $layer is not an annotation edit',
        );
    }
    final Result<Document<Object?>> applied = layer == 1
        ? _base.apply(_retyped<T>(command))
        : _upper[layer - 2].apply(_retyped<Marker>(command));
    return applied.map((document) {
      final upper = [..._upper];
      if (layer > 1) {
        upper[layer - 2] = document as Document<Marker>;
      }
      final annotations = [..._annotations];
      annotations[layer - 1] = Set.unmodifiable(next);
      return (
        document: Layered<T>._(
          grammar,
          depth,
          layer == 1 ? document as Document<T> : _base,
          List.unmodifiable(upper),
          _flagged,
          List.unmodifiable(annotations),
          version + 1,
          this,
          List.unmodifiable([edit]),
        ),
        layers: _quiet,
        annotations: List.unmodifiable([
          for (var at = 1; at <= depth; at++)
            at != layer
                ? _none
                : _frozen((
                    created: [if (command is Mark) command.marker],
                    removed: [if (command is Unmark) command.marker],
                    updated: [if (command is Update) command.marker],
                    regions: const [],
                  )),
        ]),
      );
    });
  }

  /// A delta with nothing in it for every layer.
  List<Delta> get _quiet =>
      List.unmodifiable([for (var layer = 1; layer <= depth; layer++) _none]);

  /// What [query] finds among the marks on the layer below [layer] that
  /// are layer-[layer] ranges, not diagnostics.
  List<(Marker, ARange)> _ranges(
    int layer,
    List<(Marker, ARange)> Function(Document<Object?> document) query,
  ) {
    if (layer < 2 || layer > _built) {
      return const [];
    }
    final flagged = _flagged[layer - 2];
    final noted = _annotations[layer - 2];
    return List.unmodifiable([
      for (final pair in query(_document(layer - 1)))
        if (!flagged.contains(pair.$1) && !noted.contains(pair.$1)) pair,
    ]);
  }

  /// This document after [edit], and what changed in each layer.
  ///
  /// At layer 1, `Insert`, `Delete`, and `Replace` edit the items and are
  /// always accepted; the layers above are then derived again over the
  /// region the edit affects. Above layer 1, `Mark`, `Unmark`, `Update`,
  /// and `Delete` go to the grammar's [Grammar.edit], whose [Derivation]
  /// is checked and applied without deriving the edited layer, and the
  /// layers above it are derived again. A command that does not fit its
  /// layer, or a layer outside `1..depth`, is a [Kind.invalid] failure, and
  /// so is any command for the item type at layer 1 other than `T`, an
  /// edit the grammar refuses, and a derivation that does not fit.
  Result<Change<T>> apply(Edit<T> edit) {
    final Edit(:layer, :command) = edit;
    if (layer < 1 || layer > depth) {
      return Failure(Kind.invalid, 'layered: layer $layer is not in 1..$depth');
    }
    if (edit.annotation) {
      return _annotate(edit);
    }
    if (layer == 1) {
      return switch (_retype(command)) {
        final typed? => _text(edit, typed),
        null => Failure(
          Kind.invalid,
          'layered: $command does not edit the items of layer 1',
        ),
      };
    }
    if (command is Insert || command is Replace) {
      return Failure(
        Kind.invalid,
        'layered: $command at layer $layer: new items above layer 1 are '
        'made by Mark',
      );
    }
    final start = Layered<T>._(
      grammar,
      depth,
      _base,
      _upper,
      _flagged,
      _annotations,
      version + 1,
      this,
      List.unmodifiable([edit]),
    );
    switch (start._carry(edit)) {
      case Failure(:final kind, :final message):
        return Failure(kind, 'layered: $message');
      case Success(
        value: (
          document: final carried,
          :final spans,
          :final deltas,
          :final changed,
        ),
      ):
        return switch (carried._spanned(spans)) {
          Failure(:final kind, :final message) => Failure(
            kind,
            'layered: $message',
          ),
          Success(value: final regions) => carried._above(layer, changed, [
            (
              created: const [],
              removed: const [],
              updated: const [],
              regions: regions,
            ),
            ...deltas,
          ]),
        };
    }
  }

  /// [spans], each in the layer-1 version it was made in, in this version's
  /// layer-1 positions.
  Result<List<Range>> _spanned(List<(Document<T>, Range)> spans) {
    final regions = <Range>[];
    for (final (version, span) in spans) {
      switch (mapped(span, version, _base)) {
        case Failure(:final kind, :final message):
          return Failure(kind, message);
        case Success(:final value):
          regions.add(value);
      }
    }
    return Success(regions);
  }

  /// This document with [base] and [upper] as its layers, and its
  /// diagnostics, version, and history as they are.
  Layered<T> _with(Document<T> base, List<Document<Marker>> upper) =>
      Layered<T>._(
        grammar,
        depth,
        base,
        List.unmodifiable(upper),
        _flagged,
        _annotations,
        version,
        previous,
        changes,
      );

  /// This document, with every layer up to [from] up to date and [changed]
  /// items of layer [from] changed, after the layers above are derived
  /// again; with [deltas], for layers 1 to [from], followed by those for
  /// the layers derived.
  Result<Change<T>> _above(int from, Range changed, List<Delta> deltas) {
    var current = this;
    var span = changed;
    final all = [for (final delta in deltas) _frozen(delta)];
    for (var layer = from + 1; layer <= depth; layer++) {
      switch (current._rederive(layer, span)) {
        case Failure(:final kind, :final message):
          return Failure(kind, 'layered: layer $layer: $message');
        case Success(value: (final next, final delta, final items)):
          current = next;
          span = items;
          all.add(_frozen(delta));
      }
    }
    return Success((
      document: current,
      layers: List.unmodifiable(all),
      annotations: _quiet,
    ));
  }

  /// This document with every one of [edits] applied in order, each to the
  /// result of the one before, as one new version, and what changed in
  /// each layer across them all.
  ///
  /// The result's [previous] is this document and its [changes] are [edits],
  /// so one step back undoes them all. A marker created and then removed
  /// appears in neither list, and every region is moved by the edits after
  /// it into the new version's positions. No edits return this document.
  /// The first edit that fails makes the whole transaction fail: its
  /// failure is returned with its kind and a message naming the edit, and
  /// this document is unchanged.
  Result<Change<T>> transact(List<Edit<T>> edits) {
    if (edits.isEmpty) {
      return Success((document: this, layers: _quiet, annotations: _quiet));
    }
    var current = this;
    final steps = <Change<T>>[];
    for (final (index, edit) in edits.indexed) {
      switch (current.apply(edit)) {
        case Failure(:final kind, :final message):
          return Failure(kind, 'transact: edit $index: $message');
        case Success(:final value):
          steps.add(value);
          current = value.document;
      }
    }
    final last = current;
    return Success((
      document: Layered<T>._(
        grammar,
        depth,
        last._base,
        last._upper,
        last._flagged,
        last._annotations,
        version + 1,
        this,
        List.unmodifiable(edits),
      ),
      layers: List.unmodifiable([
        for (var layer = 1; layer <= depth; layer++)
          _settled(_merged(_carried(this, steps, layer)), layer, this, last),
      ]),
      annotations: List.unmodifiable([
        for (var layer = 1; layer <= depth; layer++)
          _merged([for (final step in steps) step.annotations[layer - 1]]),
      ]),
    ));
  }

  /// [command], where it is a move, with every annotation over layer
  /// [layer]'s items that it does not decide clamped: an annotation a move
  /// cuts keeps the part outside it, and the grammar is never asked about
  /// one, since a move decides from its own `crossings` first.
  Command<S> _clamped<S>(Command<S> command, int layer) => switch (command) {
    Move(:final span, :final to, :final crossings) => Move<S>(span, to, {
      for (final marker in _annotations[layer - 1]) marker: Crossing.clamp,
      ...crossings,
    }),
    _ => command,
  };

  /// What the grammar does with a token crossing an edge of a move, the
  /// tokens being the ranges marked on layer 1.
  Crossing _crossing(ARange range) => grammar.crossing(this, 2, range);

  /// [command] as an edit to layer 1's items of [T], or `null` when it is
  /// not an item edit or holds an item that is not a [T].
  ///
  /// The command is checked by its items rather than its type argument,
  /// which inference often makes `Object?`.
  Command<T>? _retype(Command<Object?> command) {
    Items<T>? typed(Sequence<Object?> items) =>
        items.items.every((item) => item is T)
        ? Items.of(items.items.cast<T>())
        : null;
    return switch (command) {
      Insert(:final position, :final items) => switch (typed(items)) {
        final items? => Insert(position, items),
        null => null,
      },
      Delete(:final span) => Delete<T>(span),
      Replace(:final span, :final items) => switch (typed(items)) {
        final items? => Replace(span, items),
        null => null,
      },
      Move(:final span, :final to, :final crossings) => Move<T>(
        span,
        to,
        crossings,
      ),
      _ => null,
    };
  }

  /// This document after [command] edits layer 1, with each layer above
  /// derived again over the region the edit affects.
  ///
  /// A move moves the items of each layer above that lie wholly inside the
  /// items it moves, so the ranges over them go along under their markers.
  Result<Change<T>> _text(Edit<T> edit, Command<T> command) {
    final Document<T> base;
    switch (_base.apply(_clamped(command, 1), crossing: _crossing)) {
      case Failure(:final kind, :final message):
        return Failure(kind, 'layered: $message');
      case Success(:final value):
        base = value;
    }
    final List<Document<Marker>> upper;
    switch (command is Move<T> ? _lifted(command) : Success(_upper)) {
      case Failure(:final kind, :final message):
        return Failure(kind, 'layered: $message');
      case Success(:final value):
        upper = value;
    }
    return Layered<T>._(
      grammar,
      depth,
      base,
      List.unmodifiable(upper),
      _flagged,
      _annotations,
      version + 1,
      this,
      List.unmodifiable([edit]),
    )._above(1, _span(command), [
      (
        created: const [],
        removed: const [],
        updated: const [],
        regions: [_span(command)],
      ),
    ]);
  }

  /// The layers above 1 once [move] has moved layer 1's items: in each that
  /// has ranges over it, the run of items whose ranges lie wholly inside
  /// what moved below goes to where those ranges went, the ranges over them
  /// moving along, and the grammar deciding those crossing an edge of the
  /// run. The top layer is lifted too when it holds annotations, so they go
  /// with its items; one that holds nothing is left for deriving it again
  /// to put in order. A layer whose items that move are not one run refuses
  /// the move.
  Result<List<Document<Marker>>> _lifted(Move<T> move) {
    final upper = [..._upper];
    var (start, end, to) = (move.span.start, move.span.end, move.to);
    final last = _annotations[_built - 1].isEmpty ? _built - 1 : _built;
    for (var layer = 2; layer <= last; layer++) {
      final ranges = markers(layer);
      final inside = [
        for (final (index, (_, range)) in ranges.indexed)
          if (start <= range.start &&
              range.end <= end &&
              (range.start < range.end ||
                  (start < range.start && range.start < end)))
            index,
      ];
      if (inside.isEmpty) {
        break;
      }
      final first = inside.first;
      if (inside.last - first + 1 != inside.length) {
        return Failure(
          Kind.invalid,
          'move: the layer-$layer ranges it moves are not one run',
        );
      }
      final place = ranges.where((pair) => pair.$2.start < to).length;
      final run = positions.extent(first, inside.length);
      switch (upper[layer - 2].apply(
        _clamped(Move<Marker>(run, place), layer),
        crossing: (range) => grammar.crossing(this, layer + 1, range),
      )) {
        case Failure(:final kind, :final message):
          return Failure(kind, message);
        case Success(:final value):
          upper[layer - 2] = value;
      }
      (start, end, to) = (run.start, run.end, place);
    }
    return Success(upper);
  }

  /// This document with layer [layer] derived over the whole of the layer
  /// below, which must be the top layer built so far.
  Result<Layered<T>> _derive(int layer) {
    final below = _document(layer - 1);
    final region = positions.extent(0, below.length);
    // Layered.of fails only for a bad depth, so a grammar that throws
    // while deriving leaves a diagnostic.
    final (kept, flags) = switch (_asked(layer, region)) {
      Success(:final value) => value,
      Failure(:final message) => (
        const <ARange>[],
        [
          ARange.from(region, {'message': Str(Text.of(message))}),
        ],
      ),
    };
    final Document<Object?> placed;
    final List<Marker> ranges;
    final List<Marker> flagged;
    switch (layer == 2
        ? _place(_base, kept, flags)
        : _place(_upper[layer - 3], kept, flags)) {
      case Failure(:final kind, :final message):
        return Failure(kind, message);
      case Success(value: (final document, final marks, final notes)):
        (placed, ranges, flagged) = (document, marks, notes);
    }
    final upper = [..._upper];
    if (layer > 2) {
      upper[layer - 3] = placed as Document<Marker>;
    }
    return Success(
      Layered<T>._(
        grammar,
        depth,
        layer == 2 ? placed as Document<T> : _base,
        List.unmodifiable([...upper, Document.of(Items.of(ranges))]),
        List.unmodifiable([..._flagged, Set<Marker>.unmodifiable(flagged)]),
        _annotations,
        version,
        previous,
        changes,
      ),
    );
  }
}

/// The index of the first of [items], markers of ranges marked on
/// [below] in start order, whose range comes at or after [range] in that
/// order, or after it when [after], by binary search.
int _search(
  Document<Object?> below,
  Document<Marker> items,
  Range range, {
  bool after = false,
}) {
  var (low, high) = (0, items.length);
  while (low < high) {
    final middle = (low + high) ~/ 2;
    final order = _order(below.resolve(items.item(middle)!)!, range);
    if (order < 0 || (after && order == 0)) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

/// The index of each of [markers] among [items], markers of ranges marked
/// on [below] in start order, or the length of [items] for one not there:
/// each found by its range, then among the items with the same start and
/// length.
///
/// The markers are grouped by position, and the items from where each
/// position starts are walked once for the whole group, so many markers
/// among many items at one position cost time linear in those items, not
/// their product.
Map<Marker, int> _indices(
  Document<Object?> below,
  Document<Marker> items,
  Iterable<Marker> markers,
) {
  final groups = <(int, int), Set<Marker>>{};
  for (final marker in markers) {
    final range = below.resolve(marker)!;
    (groups[(range.start, range.length)] ??= {}).add(marker);
  }
  final found = <Marker, int>{};
  for (final MapEntry(key: (start, length), value: group) in groups.entries) {
    var index = _search(below, items, positions.extent(start, length));
    var left = group.length;
    while (left > 0 && index < items.length) {
      final item = items.item(index)!;
      if (group.contains(item)) {
        found[item] = index;
        left--;
      }
      index++;
    }
  }
  return {for (final marker in markers) marker: found[marker] ?? items.length};
}

/// How many of [sorted], in ascending order, are at most [value], by
/// binary search.
int _count(List<int> sorted, int value) {
  var (low, high) = (0, sorted.length);
  while (low < high) {
    final middle = (low + high) ~/ 2;
    if (sorted[middle] <= value) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

/// The smallest range holding both [a] and [b].
Range _hull(Range a, Range b) {
  final start = a.start < b.start ? a.start : b.start;
  final end = a.end > b.end ? a.end : b.end;
  return positions.extent(start, end - start);
}

/// A mark of [range] that grows only for items inserted strictly inside
/// it: items inserted at either end fall outside it.
Mark<S> _mark<S>(ARange range) => Mark<S>(range, end: Gravity.left);

/// [command], a `Mark`, `Update` or `Unmark`, as a command on a document of
/// [S].
Command<S> _retyped<S>(Command<Object?> command) => switch (command) {
  Mark(:final marker, :final range, :final start, :final end) => Mark<S>.of(
    marker,
    range,
    start: start,
    end: end,
  ),
  Update(:final marker, :final attributes) => Update<S>(marker, attributes),
  Unmark(:final marker) => Unmark<S>(marker),
  _ => throw StateError('$command is not a Mark, Update or Unmark'),
};

/// What [call] into the grammar returns, or a [Kind.invalid] failure
/// naming [what] the grammar was asked when it throws. The grammar is
/// the caller's code, so this is where its exceptions become failures.
Result<V> _ask<V>(String what, V Function() call) {
  try {
    return Success(call());
  } on Object catch (error) {
    return Failure(Kind.invalid, 'grammar: $what threw $error');
  }
}

/// [document], which holds no marks yet, with [ranges] and [flags]
/// marked on it; and the markers of each, in order. Every range and
/// diagnostic was checked to fit, so a failure to mark them is a broken
/// invariant.
Result<(Document<S>, List<Marker>, List<Marker>)> _place<S>(
  Document<S> document,
  List<ARange> ranges,
  List<ARange> flags,
) {
  final marks = [for (final range in ranges) _mark<S>(range)];
  final notes = [for (final range in flags) _mark<S>(range)];
  return switch (persistent.placed(document, [...marks, ...notes])) {
    Success(:final value) => Success((
      value,
      [for (final mark in marks) mark.marker],
      [for (final mark in notes) mark.marker],
    )),
    Failure(:final message) => Failure(
      Kind.invalid,
      'invariant: checked ranges do not mark: $message',
    ),
  };
}

/// Whether [document] keeps its invariants: each layer's persistent
/// documents keep their own, every layer-k item is a range marked on layer
/// k - 1 and not a diagnostic, the items are in start order, ties by
/// length, and every
/// mark on layer k - 1 is either a layer-k item or a diagnostic. A
/// [Kind.invalid] failure names the first that does not.
///
/// A diagnostic for tests. Hidden from the public `libara` library.
Result<void> check<T>(Layered<T> document) {
  for (var layer = 1; layer <= document._built; layer++) {
    if (persistent.check(document._document(layer))
        case final Failure<void> failure) {
      return failure;
    }
    final marks = document._document(layer);
    for (final marker in document._annotations[layer - 1]) {
      if (marks.resolve(marker) == null) {
        return Failure(
          Kind.invalid,
          'layered: layer $layer annotation $marker is not marked there',
        );
      }
    }
  }
  final top = document._built;
  if (document._document(top).markers.length !=
      document._annotations[top - 1].length) {
    return Failure(
      Kind.invalid,
      'layered: layer $top holds marks that are not annotations',
    );
  }
  for (var layer = 2; layer <= document._built; layer++) {
    final below = document._document(layer - 1);
    final items = document._upper[layer - 2].items.toList();
    final flagged = document._flagged[layer - 2];
    final noted = document._annotations[layer - 2];
    if (flagged.any(noted.contains)) {
      return Failure(
        Kind.invalid,
        'layered: layer ${layer - 1} has a diagnostic that is an annotation',
      );
    }
    Range? previous;
    for (final (index, marker) in items.indexed) {
      final range = below.resolve(marker);
      if (range == null || flagged.contains(marker) || noted.contains(marker)) {
        return Failure(
          Kind.invalid,
          'layered: layer $layer item $index is not a range of layer $layer',
        );
      }
      if (previous != null && _order(previous, range) > 0) {
        return Failure(
          Kind.invalid,
          'layered: layer $layer item $index is out of start order',
        );
      }
      previous = range;
    }
    if (below.markers.length != items.length + flagged.length + noted.length) {
      return Failure(
        Kind.invalid,
        'layered: layer ${layer - 1} holds marks that are neither layer '
        '$layer items, diagnostics, nor annotations',
      );
    }
  }
  return const Success(null);
}

/// The order of a layer's items: by start, then by length.
int _order(Range a, Range b) =>
    a.start != b.start ? a.start - b.start : a.length - b.length;
