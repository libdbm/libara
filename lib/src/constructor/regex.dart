import '../attributed/attributed.dart';
import '../range/range.dart';
import '../sequence/sequence.dart';
import 'constructor.dart';

/// A constructor that finds every match of [pattern] and returns one range
/// per match, carrying [attributes].
///
/// The input is any sequence of Unicode code points, such as `Text` or a
/// `Document<int>`, and every offset is a code point. Dart gives positions
/// only for a whole match, so context that must not be part of the range is
/// written with lookbehind and lookahead. Matches of one pattern never
/// overlap; overlap between patterns comes from [union].
///
/// A pattern without `unicode: true` can match half of a character outside
/// the Basic Multilingual Plane. Such a match is widened to cover the whole
/// character, so patterns over that text should use `unicode: true`. A
/// pattern that matches the empty string gives zero-length ranges, except
/// between the two halves of a pair, where the empty match is dropped.
///
/// [attributes] is copied here, so changing the map afterwards does not
/// change what the constructor returns. An input item outside
/// `0..0x10FFFF`, which a `Document<int>` can hold, is a [Kind.invalid]
/// failure. Matching is synchronous and its cost depends on the pattern;
/// a backtracking pattern over untrusted text can take exponential time.
Constructor<int> regex(
  RegExp pattern, {
  Map<String, Value> attributes = const {},
}) {
  final frozen = Map<String, Value>.unmodifiable(attributes);
  return (input) => _match(pattern, input, frozen);
}

Result<Ranges> _match(
  RegExp pattern,
  Sequence<int> input,
  Map<String, Value> attributes,
) {
  final points = input.items.toList();
  for (final (position, point) in points.indexed) {
    if (point < 0 || point > 0x10FFFF) {
      return Failure(
        Kind.invalid,
        'regex: $point at position $position is not a code point',
      );
    }
  }
  // For each UTF-16 offset, the code point it starts in, and the code point
  // boundary at or after it. They differ only inside a surrogate pair.
  final floor = <int>[];
  final ceiling = <int>[];
  for (final (index, point) in points.indexed) {
    floor.add(index);
    ceiling.add(index);
    if (point > 0xFFFF) {
      floor.add(index);
      ceiling.add(index + 1);
    }
  }
  floor.add(points.length);
  ceiling.add(points.length);

  return Success(
    Ranges.of([
      for (final match in pattern.allMatches(String.fromCharCodes(points)))
        // An empty match between the two halves of a pair has no code point
        // boundary to sit on.
        if (match.start != match.end ||
            floor[match.start] == ceiling[match.start])
          ARange.from(
            extent(floor[match.start], ceiling[match.end] - floor[match.start]),
            attributes,
          ),
    ]),
  );
}
