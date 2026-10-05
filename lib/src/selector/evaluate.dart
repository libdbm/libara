part of 'selector.dart';

/// One selection over a [Scope]: the attribute its type selectors read,
/// and the set each selector list matches, computed once and kept for
/// this selection only, so a scope serves many selections without
/// growing.
///
/// Evaluation is a set at a time: each compound of a complex selector
/// gives the ranges it matches among those the combinator before it
/// relates to the set so far, so nothing is evaluated twice and nothing
/// backtracks.
final class _Selection {
  _Selection(this.scope, this.type);

  final Scope<Object?> scope;
  final String type;

  /// The scope's ranges, in its order.
  List<ARange> get ranges => scope._ranges;

  /// The scope's hierarchy, built once per scope.
  Hierarchy get hierarchy => scope._hierarchy;

  /// The set each selector list, or list of relative selectors, matches,
  /// by the list's identity.
  final Map<List<Object>, List<bool>> _sets = Map.identity();

  /// For each range, whether a chain of ranges runs out of it as one of
  /// [relatives] says.
  ///
  /// Each relative selector is evaluated from right to left: the last
  /// compound's set, then each compound before it among the ranges with a
  /// range of the set after it, by the inverse of the combinator between
  /// them, and last the ranges the leading combinator relates to that.
  List<bool> anchored(
    List<(_Combinator, _Complex)> relatives,
  ) => _sets[relatives] ??= () {
    final union = List<bool>.filled(ranges.length, false);
    for (final (leading, complex) in relatives) {
      final compounds = [complex.first, for (final (_, c) in complex.steps) c];
      final combinators = [
        leading,
        for (final (combinator, _) in complex.steps) combinator,
      ];
      var set = _compound(compounds.last, null);
      for (var step = compounds.length - 2; step >= 0; step--) {
        set = _compound(compounds[step], _inverse(combinators[step + 1], set));
      }
      for (final (index, has) in _inverse(leading, set).indexed) {
        union[index] = union[index] || has;
      }
    }
    return union;
  }();

  /// The set each overlap pseudo-class matches, by its identity.
  final Map<_Overlap, List<bool>> _overlaps = Map.identity();

  /// For each range, whether [overlap] matches it.
  List<bool> overlapped(_Overlap overlap) =>
      _overlaps[overlap] ??= overlap.crossing
      ? _crosses(selected(overlap.options))
      : _overlapping(selected(overlap.options));

  /// For each range, whether a range of [set] other than itself overlaps
  /// it.
  ///
  /// With the ranges of [set] in start order and, for each prefix, the
  /// greatest end and the greatest end of a range other than the one
  /// holding it, a range is overlapped when, among the ranges starting
  /// before its end, the greatest end of a range other than itself is past
  /// its start. One binary search per range.
  List<bool> _overlapping(List<bool> set) {
    // In start order, which the scope's hierarchy keeps.
    final members = [
      for (final index in hierarchy.order)
        if (set[index]) index,
    ];
    final best = <int>[];
    final second = <int>[];
    var (first, next) = (-1, -1);
    for (final member in members) {
      final end = ranges[member].end;
      if (first < 0 || end > ranges[first].end) {
        (first, next) = (member, first);
      } else if (next < 0 || end > ranges[next].end) {
        next = member;
      }
      best.add(first);
      second.add(next);
    }
    return [
      for (final (index, range) in ranges.indexed)
        () {
          // How many members start before this range ends.
          var (low, high) = (0, members.length);
          while (low < high) {
            final middle = (low + high) ~/ 2;
            if (ranges[members[middle]].start < range.end) {
              low = middle + 1;
            } else {
              high = middle;
            }
          }
          if (low == 0) {
            return false;
          }
          final other = best[low - 1] == index
              ? second[low - 1]
              : best[low - 1];
          return other >= 0 && ranges[other].end > range.start;
        }(),
    ];
  }

  /// For each range, whether a range of [set] overlaps it and neither
  /// contains the other: one starting before it and ending inside it, or,
  /// the same with positions negated, one starting inside it and ending
  /// after it.
  List<bool> _crosses(List<bool> set) {
    final left = _entering(set, [
      for (final range in ranges) (range.start, range.end),
    ]);
    final right = _entering(set, [
      for (final range in ranges) (-range.end, -range.start),
    ]);
    return [
      for (var index = 0; index < ranges.length; index++)
        left[index] || right[index],
    ];
  }

  /// For each of [spans], whether a span of [set] starts strictly before it
  /// and ends strictly inside it.
  ///
  /// In start order, the ends of the spans of [set] started strictly
  /// before are kept in a sorted multiset, and the least end past a span's
  /// start is checked against its end.
  List<bool> _entering(List<bool> set, List<(int, int)> spans) {
    final order = List.generate(spans.length, (index) => index)
      ..sort((a, b) => spans[a].$1 - spans[b].$1);
    final ends = SplayTreeMap<int, int>();
    final entering = List<bool>.filled(spans.length, false);
    var added = 0;
    for (final index in order) {
      final (start, end) = spans[index];
      while (added < order.length && spans[order[added]].$1 < start) {
        if (set[order[added]]) {
          final close = spans[order[added]].$2;
          ends[close] = (ends[close] ?? 0) + 1;
        }
        added++;
      }
      final least = ends.firstKeyAfter(start);
      entering[index] = least != null && least < end;
    }
    return entering;
  }

  /// For each range, whether [combinator] relates a range of [set] to it,
  /// as the anchor: the inverse of [_related].
  List<bool> _inverse(_Combinator combinator, List<bool> set) {
    final related = List<bool>.filled(ranges.length, false);
    switch (combinator) {
      case _Combinator.child:
        for (final (index, parent) in hierarchy.parents.indexed) {
          if (set[index] && parent >= 0) {
            related[parent] = true;
          }
        }
      case _Combinator.next:
        for (final (index, before) in hierarchy.previous.indexed) {
          if (set[index] && before >= 0) {
            related[before] = true;
          }
        }
      case _Combinator.later:
        // Whether a sibling group has a range of the set later on.
        final seen = <int>{};
        for (var index = ranges.length - 1; index >= 0; index--) {
          final parent = hierarchy.parents[index];
          related[index] = seen.contains(parent);
          if (set[index]) {
            seen.add(parent);
          }
        }
      case _Combinator.descendant:
        return _containing(set);
    }
    return related;
  }

  /// For each range, whether it contains a range of [set] at another
  /// position.
  ///
  /// In reverse start order, longest last at equal starts, every range
  /// before one starts at or after it and, at its start, is shorter, so it
  /// contains one of them when the least end among them is within its
  /// end. Ranges at its own position come together, so the least end is
  /// taken over the positions before.
  List<bool> _containing(List<bool> set) {
    final order = hierarchy.order.reversed.toList();
    final containing = List<bool>.filled(ranges.length, false);
    int? least;
    var group = 0;
    while (group < order.length) {
      final first = ranges[order[group]];
      var end = group;
      while (end < order.length && ranges[order[end]].same(first)) {
        end++;
      }
      for (var at = group; at < end; at++) {
        containing[order[at]] = least != null && least <= first.end;
      }
      for (var at = group; at < end; at++) {
        if (set[order[at]]) {
          least = least == null ? first.end : min(least, first.end);
        }
      }
      group = end;
    }
    return containing;
  }

  /// For each range, whether it matches one of [options].
  List<bool> selected(List<_Complex> options) =>
      _sets[options] ??= _union(options);

  List<bool> _union(List<_Complex> options) {
    final union = List<bool>.filled(ranges.length, false);
    for (final complex in options) {
      for (final (index, matched) in _complex(complex).indexed) {
        union[index] = union[index] || matched;
      }
    }
    return union;
  }

  List<bool> _complex(_Complex complex) {
    var set = _compound(complex.first, null);
    for (final (combinator, compound) in complex.steps) {
      set = _compound(compound, _related(combinator, set));
    }
    return set;
  }

  /// For each range, whether it matches [compound], testing only those
  /// [within] holds when given.
  List<bool> _compound(_Compound compound, List<bool>? within) => [
    for (var index = 0; index < ranges.length; index++)
      (within == null || within[index]) &&
          compound.simples.every((simple) => _passes(simple, this, index)),
  ];

  /// For each range, whether [combinator] relates it to a range of [set].
  List<bool> _related(_Combinator combinator, List<bool> set) {
    final (:parents, :previous) = (
      parents: hierarchy.parents,
      previous: hierarchy.previous,
    );
    switch (combinator) {
      case _Combinator.child:
        return [for (final parent in parents) parent >= 0 && set[parent]];
      case _Combinator.next:
        return [for (final before in previous) before >= 0 && set[before]];
      case _Combinator.later:
        // Whether a sibling group has had a range of the set yet.
        final seen = <int>{};
        return [
          for (final (index, parent) in parents.indexed)
            () {
              final related = seen.contains(parent);
              if (set[index]) {
                seen.add(parent);
              }
              return related;
            }(),
        ];
      case _Combinator.descendant:
        return _contained(set);
    }
  }

  /// For each range, whether a range of [set] at another position
  /// contains it.
  ///
  /// In start order, longest first at equal starts, every range before one
  /// starts at or before it, so one of them contains it when the greatest
  /// end among them reaches its end. Ranges at its own position come
  /// together, so the greatest end is taken over the positions before.
  List<bool> _contained(List<bool> set) {
    final order = hierarchy.order;
    final contained = List<bool>.filled(ranges.length, false);
    var reach = -1;
    var group = 0;
    while (group < order.length) {
      final first = ranges[order[group]];
      var end = group;
      while (end < order.length && ranges[order[end]].same(first)) {
        end++;
      }
      for (var at = group; at < end; at++) {
        contained[order[at]] = reach >= first.end;
      }
      for (var at = group; at < end; at++) {
        if (set[order[at]]) {
          reach = max(reach, first.end);
        }
      }
      group = end;
    }
    return contained;
  }
}

/// Whether the range at [index] of [scope] matches one of [options].
bool _matched(List<_Complex> options, _Selection scope, int index) =>
    scope.selected(options)[index];

/// Whether the range at [index] of [scope] passes [simple].
bool _passes(_Simple simple, _Selection scope, int index) {
  final range = scope.ranges[index];
  return switch (simple) {
    _Tag(:final name) => range.get(scope.type) == name,
    _Universal() => true,
    _Condition(:final name) => switch (range.get(name)) {
      final actual? => _holds(actual, simple),
      null => false,
    },
    _Not(:final options) => !_matched(options, scope, index),
    _Is(:final options) => _matched(options, scope, index),
    _Has(:final relatives) => scope.anchored(relatives)[index],
    _Overlap() => scope.overlapped(simple)[index],
    _Structural(:final position) => switch (position) {
      _Position.root => scope.hierarchy.parents[index] < 0,
      _Position.empty => range.length == 0,
      _Position.first => scope.hierarchy.places[index] == 1,
      _Position.last =>
        scope.hierarchy.places[index] == scope.hierarchy.sizes[index],
      _Position.only => scope.hierarchy.sizes[index] == 1,
    },
    _Nth(:final last) => simple.holds(
      last
          ? scope.hierarchy.sizes[index] - scope.hierarchy.places[index] + 1
          : scope.hierarchy.places[index],
    ),
  };
}

/// Whether the value [actual] of a present attribute holds [condition]'s
/// operator against its value; with no operator, presence is enough.
bool _holds(Value actual, _Condition condition) =>
    switch ((condition.operator, actual, condition.value)) {
      (null, _, _) => true,
      (_Operator.equal, _, final expected) => actual == expected,
      (_Operator.unequal, _, final expected) => actual != expected,
      (_Operator.prefix, Str(:final value), Str(value: final part)) => _at(
        value,
        part,
        0,
      ),
      (_Operator.suffix, Str(:final value), Str(value: final part)) => _at(
        value,
        part,
        value.length - part.length,
      ),
      (_Operator.substring, Str(:final value), Str()) => _contains(
        value,
        condition,
      ),
      (_Operator.word, Str(:final value), Str()) => _word(value, condition),
      (final operator?, Num(value: final a), Num(value: final b)) => _ordered(
        operator,
        a.compareTo(b),
      ),
      (final operator?, Str(value: final a), Str(value: final b)) => _ordered(
        operator,
        a.compare(b),
      ),
      _ => false,
    };

/// Whether [order], a comparison of two values, satisfies [operator], one
/// of the four comparisons.
bool _ordered(_Operator operator, int order) => switch (operator) {
  _Operator.less => order < 0,
  _Operator.upto => order <= 0,
  _Operator.greater => order > 0,
  _Operator.from => order >= 0,
  _ => false,
};

/// Whether [part] occurs in [text] from [start], by code points.
bool _at(Text text, Text part, int start) {
  if (start < 0 || start + part.length > text.length) {
    return false;
  }
  for (var index = 0; index < part.length; index++) {
    if (text.item(start + index) != part.item(index)) {
      return false;
    }
  }
  return true;
}

/// Whether [condition]'s value occurs anywhere in [text], by code points:
/// a Knuth, Morris, and Pratt search, `O(L + P)`. An empty value occurs in
/// every text.
bool _contains(Text text, _Condition condition) =>
    condition.points.isEmpty || _ends(text, condition).isNotEmpty;

/// Whether [condition]'s value is one of the words of [text], its runs of
/// code points between whitespace: each occurrence, found by a Knuth,
/// Morris, and Pratt search, is checked for whitespace or the text's ends
/// on either side, `O(L + P)`. An empty value, or one holding whitespace,
/// is none of them.
bool _word(Text text, _Condition condition) {
  final word = condition.points;
  if (word.isEmpty || word.any(_blank)) {
    return false;
  }
  for (final end in _ends(text, condition)) {
    final start = end - word.length;
    if ((start == 0 || _blank(text.item(start - 1)!)) &&
        (end == text.length || _blank(text.item(end)!))) {
      return true;
    }
  }
  return false;
}

/// Where each occurrence of [condition]'s non-empty value in [text] ends,
/// in order, overlapping ones included.
Iterable<int> _ends(Text text, _Condition condition) sync* {
  final part = condition.points;
  final table = condition.table;
  var matched = 0;
  var position = 0;
  for (final point in text.items) {
    while (matched > 0 && point != part[matched]) {
      matched = table[matched - 1];
    }
    if (point == part[matched]) {
      matched++;
    }
    position++;
    if (matched == part.length) {
      yield position;
      matched = table[matched - 1];
    }
  }
}

/// For each prefix of [part], the length of its longest proper prefix that
/// is also its suffix: the Knuth, Morris, and Pratt failure table.
List<int> _table(List<int> part) {
  final table = List.filled(part.length, 0);
  var matched = 0;
  for (var index = 1; index < part.length; index++) {
    while (matched > 0 && part[index] != part[matched]) {
      matched = table[matched - 1];
    }
    if (part[index] == part[matched]) {
      matched++;
    }
    table[index] = matched;
  }
  return List.unmodifiable(table);
}

/// Whether [point] is whitespace, as selector source counts it.
bool _blank(int point) =>
    point == 0x20 ||
    point == 0x09 ||
    point == 0x0A ||
    point == 0x0D ||
    point == 0x0C;
