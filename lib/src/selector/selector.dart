/// The selector module: [Selector], CSS-like queries over attributed
/// ranges.
library;

import 'dart:collection';
import 'dart:math';

import '../attributed/attributed.dart';
import '../layered/layered.dart';
import '../persistent/persistent.dart';
import '../range/range.dart' show Hierarchy;
import '../sequence/sequence.dart';

part 'evaluate.dart';
part 'parser.dart';
part 'syntax.dart';

/// A CSS-like selector over attributed ranges.
///
/// A selector is read from source by [parse], selects the ranges of a
/// scope that match with [select], and tests one with [matches]. It is
/// immutable, equal to another with the same structure and [type], and
/// prints back to source that [parse] reads to an equal selector.
final class Selector {
  Selector._(this._options, this.type);

  /// The selector in [source], or a [Kind.syntax] failure naming the
  /// column, counted in code points from 1. A type selector such as `p`
  /// reads the attribute called [type].
  ///
  /// The pseudo-classes that take selectors, `:not`, `:is`, `:has`,
  /// `:overlaps`, and `:crosses`, nest at most [nesting] deep; one deeper
  /// is a failure at its column. This bounds the work and the stack that
  /// parsing, evaluating, and printing take, so a hostile source cannot
  /// exhaust them.
  static Result<Selector> parse(
    String source, {
    String type = 'name',
    int nesting = 64,
  }) => _Parser(
    source,
    nesting,
  ).parse().map((options) => Selector._(options, type));

  /// The selectors of the list, any of which a range may match.
  final List<_Complex> _options;

  /// The attribute a type selector reads.
  final String type;

  /// The pairs of [scope] whose range this selector matches, in the order
  /// of [scope]. A [Scope] prepared once serves many selections.
  List<(K, ARange)> select<K>(List<(K, ARange)> scope) =>
      Scope(scope).select(this);

  /// Whether this selector matches the range of the first pair of [scope]
  /// under [key], or a [Kind.missing] failure when no pair has [key].
  Result<bool> matches<K>(K key, List<(K, ARange)> scope) =>
      Scope(scope).matches(this, key);

  /// Whether [other] is a selector with the same structure and [type].
  @override
  bool operator ==(Object other) =>
      other is Selector &&
      other.type == type &&
      _equal(other._options, _options);

  @override
  int get hashCode => Object.hash(type, Object.hashAll(_options));

  /// The selector in canonical source: one space after each comma, and
  /// every text value quoted.
  @override
  String toString() => _options.join(', ');
}

/// A scope of keyed ranges indexed once, for many selections.
///
/// It keeps what does not depend on a selector: the ranges' hierarchy,
/// with their start order, and the first place of each key, each built
/// when first needed. What a selection computes lasts one selection, so a
/// scope used with many selectors does not grow, and selectors with
/// different type attributes share it. Immutable, over a copy of its
/// pairs.
final class Scope<K> {
  /// [pairs] as a scope, in their order.
  Scope(List<(K, ARange)> pairs) : pairs = List.unmodifiable(pairs);

  /// The pairs, in their order.
  final List<(K, ARange)> pairs;

  late final List<ARange> _ranges = List.unmodifiable([
    for (final (_, range) in pairs) range,
  ]);

  late final Hierarchy _hierarchy = Hierarchy(_ranges);

  /// The first place of each key.
  late final Map<K, int> _places = () {
    final places = <K, int>{};
    for (final (index, (key, _)) in pairs.indexed) {
      places.putIfAbsent(key, () => index);
    }
    return places;
  }();

  /// The pairs whose range [selector] matches, in their order.
  List<(K, ARange)> select(Selector selector) {
    final selected = _Selection(
      this,
      selector.type,
    ).selected(selector._options);
    return List.unmodifiable([
      for (final (index, pair) in pairs.indexed)
        if (selected[index]) pair,
    ]);
  }

  /// Whether [selector] matches the range of the first pair under [key],
  /// or a [Kind.missing] failure when no pair has [key]. Finds the key in
  /// `O(1)`.
  Result<bool> matches(Selector selector, K key) => switch (_places[key]) {
    final index? => Success(
      _matched(selector._options, _Selection(this, selector.type), index),
    ),
    null => Failure(Kind.missing, 'selector: $key is not in the scope'),
  };
}

/// Selection over the ranges of a [Document].
extension DocumentSelection<T> on Document<T> {
  /// The ranges of this version that [selector] matches, with their
  /// markers, in start order: [Selector.select] over [Document.markers].
  List<(Marker, ARange)> select(Selector selector) => selector.select(markers);

  /// Whether the range under [marker] matches [selector] among the ranges
  /// of this version, or a [Kind.missing] failure when [marker] is not
  /// marked.
  Result<bool> matches(Selector selector, Marker marker) =>
      selector.matches(marker, markers);

  /// The ranges of this version with their markers, in start order, as a
  /// prepared [Scope].
  Scope<Marker> scope() => Scope(markers);
}

/// Selection over one layer of a [Layered] document.
extension LayeredSelection<T> on Layered<T> {
  /// Layer [layer]'s ranges that [selector] matches, with their markers,
  /// in the layer's order: [Selector.select] over [Layered.markers], so
  /// diagnostics are never selected. Empty outside `2..depth`.
  List<(Marker, ARange)> select(Selector selector, int layer) =>
      selector.select(markers(layer));

  /// Whether layer [layer]'s range under [marker] matches [selector] among
  /// that layer's ranges, or a [Kind.missing] failure when it is not one.
  Result<bool> matches(Selector selector, int layer, Marker marker) =>
      selector.matches(marker, markers(layer));

  /// Layer [layer]'s ranges with their markers, in the layer's order, as a
  /// prepared [Scope]; empty outside `2..depth`.
  Scope<Marker> scope(int layer) => Scope(markers(layer));

  /// The ranges of every layer in [layers] projected to layer 1, as
  /// [Layered.extent] projects them, with their attributes, each keyed by
  /// its layer and marker: a scope in which one selector relates ranges of
  /// different layers by containment in base positions.
  ///
  /// In start order, longest first at equal starts, then by layer, then in
  /// each layer's order. Ranges of different layers that project to the
  /// same extent are at one position, so they are siblings. Layers outside
  /// `2..depth` give nothing. With the XML example,
  /// `Selector.parse('p [type=text]')` over `across([2, 3])` selects the layer-2
  /// text tokens inside layer-3 `p` elements. Each range below projects once.
  List<((int, Marker), ARange)> across(Iterable<int> layers) {
    final ranges = projected(layers).indexed.toList()
      ..sort((a, b) {
        final ((x, ((first, _), one)), (y, ((second, _), other))) = (a, b);
        return one.start != other.start
            ? one.start - other.start
            : one.length != other.length
            ? other.length - one.length
            : first != second
            ? first - second
            : x - y;
      });
    return List.unmodifiable([for (final (_, pair) in ranges) pair]);
  }
}
