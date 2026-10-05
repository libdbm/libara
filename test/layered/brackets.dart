import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/layered/layered.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';

import '../support.dart';

/// A test grammar over text with three layers.
///
/// Layer 2 is tokens: `[`, `]`, and maximal runs of other characters.
/// Layer 3 is groups, each over the tokens from an `[` to its matching `]`.
/// An unmatched bracket is a layer-3 diagnostic.
///
/// After a text edit, layer 2 is derived again over the changed text and
/// the text runs touching it, and layer 3 over the innermost group that
/// still pairs its brackets around the changed tokens.
final class Brackets implements Grammar<int> {
  /// A bracket grammar, whose layer-3 affected region is [named]'s when
  /// given, so tests can name too small a region on purpose.
  Brackets({this.named});

  /// The layer-3 affected region in place of the grammar's own.
  final Range Function(Range changed)? named;

  /// How many times layer 2 has been derived, for tests to count lexing.
  int lexed = 0;

  @override
  int get depth => 3;

  @override
  Derived derive(Layered<int> document, int layer, Range region) {
    if (layer == 2) {
      lexed++;
      return (ranges: _tokens(document, region), diagnostics: const []);
    }
    final (groups, unmatched) = _groups(document, region);
    return (ranges: groups, diagnostics: unmatched);
  }

  @override
  Range affected(Layered<int> document, int layer, Range changed) =>
      layer == 2 ? _text(document, changed) : _group(document, changed);

  /// Carries out a bracket edit:
  /// - at layer 2, `Mark` of a zero-length bracket inserts it, splitting a
  ///   text run it falls inside, and `Delete` removes tokens, merging the
  ///   text runs left on either side;
  /// - at layer 3, `Mark` wraps tokens holding whole groups in a new group,
  ///   `Unmark` unwraps a group, `Delete` removes groups with their tokens
  ///   and the groups nested in them, and `Update` sets a group's
  ///   attributes.
  @override
  Result<Derivation<int>> edit(
    Layered<int> document,
    Edit<int> change,
  ) => switch ((change.layer, change.command)) {
    (2, Mark(:final marker, :final range)) => _insert(document, marker, range),
    (2, Delete(:final span)) => _cut(document, span),
    (3, Mark(:final marker, :final range)) => _wrap(document, marker, range),
    (3, Unmark(:final marker)) => _unwrap(document, marker),
    (3, Delete(:final span)) => _drop(document, span),
    (3, Update(:final marker, :final attributes)) => Success((
      below: const [],
      created: const [],
      removed: const [],
      updated: {marker: attributes},
    )),
    (final layer, final command) => Failure(
      Kind.invalid,
      'brackets: $command at layer $layer is not a bracket edit',
    ),
  };

  /// Inserts the bracket that [range], zero-length, describes, under
  /// [marker].
  Result<Derivation<int>> _insert(
    Layered<int> document,
    Marker marker,
    ARange range,
  ) {
    final type = range.get('type');
    if (range.length != 0 ||
        range.start > document.items.length ||
        (type != kind('open') && type != kind('close'))) {
      return Failure(Kind.invalid, 'brackets: $range is not a new bracket');
    }
    final at = range.start;
    final point = type == kind('open') ? 0x5B : 0x5D;
    final bracket = (marker, tagged(at, 1, attributes: {'type': type!}));
    final below = [
      Edit<int>(1, Insert(at, Items.of([point]))),
    ];
    for (final (run, token) in document.markers(2)) {
      if (token.start < at && at < token.end) {
        return Success((
          below: below,
          created: [
            (Marker(), _run(token.start, at - token.start)),
            bracket,
            (Marker(), _run(at + 1, token.end - at)),
          ],
          removed: [run],
          updated: const {},
        ));
      }
    }
    return Success((
      below: below,
      created: [bracket],
      removed: const [],
      updated: const {},
    ));
  }

  /// Deletes the tokens in [span], merging the text runs either side.
  Result<Derivation<int>> _cut(Layered<int> document, Range span) {
    final tokens = document.markers(2);
    if (span.end > tokens.length) {
      return Failure(Kind.invalid, 'brackets: $span is not a run of tokens');
    }
    if (span.length == 0) {
      return const Success((below: [], created: [], removed: [], updated: {}));
    }
    final first = tokens[span.start].$2;
    final last = tokens[span.end - 1].$2;
    final removed = [
      for (final (marker, _) in tokens.sublist(span.start, span.end)) marker,
    ];
    final created = <(Marker, ARange)>[];
    if (span.start > 0 && span.end < tokens.length) {
      final (before, left) = tokens[span.start - 1];
      final (after, right) = tokens[span.end];
      if (left.get('type') == kind('text') &&
          right.get('type') == kind('text')) {
        removed.addAll([before, after]);
        created.add((Marker(), _run(left.start, left.length + right.length)));
      }
    }
    return Success((
      below: [Edit(1, Delete<int>(_span(first.start, last.end - first.start)))],
      created: created,
      removed: removed,
      updated: const {},
    ));
  }

  /// Wraps the tokens in [range] in a new group under [marker].
  Result<Derivation<int>> _wrap(
    Layered<int> document,
    Marker marker,
    ARange range,
  ) {
    final tokens = document.layer(2).items.cast<ARange>().toList();
    if (range.end > tokens.length ||
        range.get('type') != kind('group') ||
        !_balanced(tokens, range)) {
      return Failure(
        Kind.invalid,
        'brackets: $range does not hold whole groups',
      );
    }
    final open = range.start < tokens.length
        ? tokens[range.start].start
        : document.items.length;
    final close = range.length == 0 ? open : tokens[range.end - 1].end;
    return Success((
      below: [
        Edit(2, Mark(tagged(close, 0, attributes: {'type': kind('close')}))),
        Edit(2, Mark(tagged(open, 0, attributes: {'type': kind('open')}))),
      ],
      created: [
        (
          marker,
          tagged(range.start, range.length + 2, attributes: range.attributes),
        ),
      ],
      removed: const [],
      updated: const {},
    ));
  }

  /// Removes the brackets of the group under [marker], keeping its tokens.
  Result<Derivation<int>> _unwrap(Layered<int> document, Marker marker) {
    for (final (group, range) in document.markers(3)) {
      if (group == marker) {
        return Success((
          below: [
            Edit(2, Delete<int>(_span(range.end - 1, 1))),
            Edit(2, Delete<int>(_span(range.start, 1))),
          ],
          created: const [],
          removed: [marker],
          updated: const {},
        ));
      }
    }
    return Failure(Kind.invalid, 'brackets: $marker is not a group');
  }

  /// Deletes the groups in [span], their tokens, and the groups nested in
  /// them.
  Result<Derivation<int>> _drop(Layered<int> document, Range span) {
    final groups = document.markers(3);
    if (span.end > groups.length) {
      return Failure(Kind.invalid, 'brackets: $span is not a run of groups');
    }
    if (span.length == 0) {
      return const Success((below: [], created: [], removed: [], updated: {}));
    }
    final picked = [
      for (final (_, range) in groups.sublist(span.start, span.end)) range,
    ];
    final start = picked.map((range) => range.start).reduce(min);
    final end = picked.map((range) => range.end).reduce(max);
    final run = _span(start, end - start);
    final tokens = document.layer(2).items.cast<ARange>().toList();
    if (!_balanced(tokens, run)) {
      return Failure(Kind.invalid, 'brackets: $span cuts through a group');
    }
    return Success((
      below: [Edit(2, Delete<int>(run))],
      created: const [],
      removed: [
        for (final (group, range) in groups)
          if (run.start <= range.start && range.end <= run.end) group,
      ],
      updated: const {},
    ));
  }

  /// Whether the brackets of [tokens] in [range] pair up among themselves.
  bool _balanced(List<ARange> tokens, Range range) {
    var depth = 0;
    for (var index = range.start; index < range.end; index++) {
      final type = tokens[index].get('type');
      if (type == kind('open')) {
        depth++;
      } else if (type == kind('close') && --depth < 0) {
        return false;
      }
    }
    return depth == 0;
  }

  /// A text run of [length] items from [start].
  ARange _run(int start, int length) =>
      tagged(start, length, attributes: {'type': kind('text')});

  /// The range of [length] items from [start].
  Range _span(int start, int length) => span(start, length);

  /// [changed] with every token that may lex differently: text runs
  /// touching it, which may merge with the new text, and brackets
  /// overlapping it or emptied by the edit.
  Range _text(Layered<int> document, Range changed) {
    var (start, end) = (changed.start, changed.end);
    for (final token in document.layer(2).items.cast<ARange>()) {
      final touches = token.start <= changed.end && token.end >= changed.start;
      final overlaps = token.start < changed.end && token.end > changed.start;
      if (touches &&
          (token.get('type') == kind('text') ||
              overlaps ||
              token.length == 0)) {
        start = min(start, token.start);
        end = max(end, token.end);
      }
    }
    return span(start, end - start);
  }

  /// The innermost group strictly around [changed] whose tokens still pair
  /// its first bracket with its last, or every token when there is none.
  Range _group(Layered<int> document, Range changed) {
    if (named case final named?) {
      return named(changed);
    }
    final tokens = document.layer(2).items.cast<ARange>().toList();
    final groups = [
      for (final group in document.layer(3).items)
        if (group.start < changed.start && changed.end < group.end) group,
    ]..sort((a, b) => a.length - b.length);
    for (final group in groups) {
      if (_paired(tokens, group)) {
        return group;
      }
    }
    return span(0, tokens.length);
  }

  /// Whether [tokens] over [group] open with a bracket that closes only at
  /// its last token.
  bool _paired(List<ARange> tokens, Range group) {
    var depth = 0;
    for (var index = group.start; index < group.end; index++) {
      final type = tokens[index].get('type');
      if (type == kind('open')) {
        depth++;
      } else if (type == kind('close')) {
        depth--;
        if (depth < 0 || (depth == 0 && index != group.end - 1)) {
          return false;
        }
      } else if (depth == 0) {
        return false;
      }
    }
    return depth == 0 && group.length > 0;
  }

  List<ARange> _tokens(Layered<int> document, Range region) {
    final points = document.items.items.toList();
    final found = <ARange>[];
    var position = region.start;
    while (position < region.end) {
      final point = points[position];
      if (point == 0x5B || point == 0x5D) {
        found.add(tagged(position, 1, attributes: {'type': type(point)}));
        position++;
        continue;
      }
      var end = position;
      while (end < region.end && points[end] != 0x5B && points[end] != 0x5D) {
        end++;
      }
      found.add(
        tagged(position, end - position, attributes: {'type': kind('text')}),
      );
      position = end;
    }
    return found;
  }

  (List<ARange>, List<ARange>) _groups(Layered<int> document, Range region) {
    final tokens = document.layer(2).items.cast<ARange>().toList();
    final open = <int>[];
    final groups = <ARange>[];
    final errors = <ARange>[];
    for (var index = region.start; index < region.end; index++) {
      final type = tokens[index].get('type');
      if (type == kind('open')) {
        open.add(index);
      } else if (type == kind('close')) {
        if (open.isEmpty) {
          errors.add(
            tagged(index, 1, attributes: {'message': kind('unmatched ]')}),
          );
        } else {
          final start = open.removeLast();
          groups.add(
            tagged(
              start,
              index - start + 1,
              attributes: {'type': kind('group')},
            ),
          );
        }
      }
    }
    for (final start in open) {
      errors.add(
        tagged(start, 1, attributes: {'message': kind('unmatched [')}),
      );
    }
    return (
      Ranges.of(groups).startOrder().items.cast<ARange>().toList(),
      errors,
    );
  }
}

/// The token type of a bracket code point.
Value type(int point) => kind(point == 0x5B ? 'open' : 'close');

/// A text attribute value.
Value kind(String name) => Str(Text.of(name));
