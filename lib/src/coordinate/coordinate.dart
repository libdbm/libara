/// The coordinate module: [Coordinates] between code-point positions and an
/// editor's coordinates.
library;

import 'package:characters/characters.dart';

import '../attributed/attributed.dart';
import '../constructor/constructor.dart';
import '../persistent/persistent.dart';
import '../range/range.dart';
import '../sequence/sequence.dart';

part 'grapheme.dart';

/// An offset in UTF-16 code units, as JavaScript strings and the LSP count.
///
/// Not an `int`, so it cannot be used where a code point position is meant.
extension type const Unit._(int _units) {
  /// The offset of [offset] UTF-16 code units.
  const Unit(int offset) : this._(offset);

  /// The offset in UTF-16 code units.
  int get offset => _units;
}

/// What a column counts.
enum Columns {
  /// UTF-16 code units, the LSP's default position encoding.
  units,

  /// Code points, libara's own unit, the LSP's `utf-32`.
  points,

  /// Extended grapheme clusters, user-perceived characters.
  graphemes,
}

/// A line and a column, both from 0.
final class Place {
  /// The place at [line] and [column].
  const Place(this.line, this.column);

  /// The line, from 0.
  final int line;

  /// The column, from 0, in whatever unit it was asked in.
  final int column;

  @override
  bool operator ==(Object other) =>
      other is Place && other.line == line && other.column == column;

  @override
  int get hashCode => Object.hash(line, column);

  @override
  String toString() => '$line:$column';
}

/// Conversion between code-point positions and an editor's coordinates,
/// over the code points of one text.
///
/// Over a `Document<int>` it shares the document's content tree, whose
/// nodes cache what conversion needs, so every query is `O(log n)` in any
/// version. Immutable: coordinates over a later version are made from that
/// version.
final class Coordinates {
  Coordinates._(this._document);

  /// Coordinates over the code points of [text]. Any sequence but a
  /// `Document<int>` is first copied into one, in `O(n)`.
  factory Coordinates.of(Sequence<int> text) =>
      Coordinates._(text is Document<int> ? text : Document.of(text));

  final Document<int> _document;

  /// The number of code points.
  int get length => _document.length;

  /// The length in UTF-16 code units.
  Unit get units => Unit(_document.measure?.units ?? 0);

  /// The number of lines: one more than the number of line ends.
  int get lines => (_document.measure?.ends ?? 0) + 1;

  /// The UTF-16 offset of code point [position], or a [Kind.bounds]
  /// failure outside `0..length`.
  Result<Unit> unit(int position) {
    if (position < 0 || position > length) {
      return Failure(
        Kind.bounds,
        'coordinate: position $position is outside 0..$length',
      );
    }
    return Success(Unit(_document.prefix(position)?.units ?? 0));
  }

  /// The code point position at UTF-16 offset [unit]: a [Kind.bounds]
  /// failure outside `0..units`, and a [Kind.invalid] one between the two
  /// units of a surrogate pair.
  Result<int> point(Unit unit) {
    final offset = unit.offset;
    if (offset < 0 || offset > units.offset) {
      return Failure(
        Kind.bounds,
        'coordinate: unit $offset is outside 0..${units.offset}',
      );
    }
    final (position, exact) = _document.located(offset);
    return exact
        ? Success(position)
        : Failure(
            Kind.invalid,
            'coordinate: unit $offset is inside the pair at position '
            '$position',
          );
  }

  /// The line and column of code point [position], the column counted in
  /// [columns] from the start of its line: a [Kind.bounds] failure outside
  /// `0..length`, and a [Kind.invalid] one between the carriage return and
  /// the line feed of one line end.
  Result<Place> place(int position, {Columns columns = Columns.units}) {
    if (position < 0 || position > length) {
      return Failure(
        Kind.bounds,
        'coordinate: position $position is outside 0..$length',
      );
    }
    if (_inside(position)) {
      return Failure(
        Kind.invalid,
        'coordinate: position $position is inside a line end',
      );
    }
    final line = _document.prefix(position)?.ends ?? 0;
    final start = _start(line);
    final column = switch (columns) {
      Columns.points => position - start,
      Columns.units => _units(position) - _units(start),
      Columns.graphemes => _segment(start).indexOf(position),
    };
    if (column < 0) {
      return Failure(
        Kind.invalid,
        'coordinate: position $position is inside a grapheme cluster',
      );
    }
    return Success(Place(line, column));
  }

  /// The code point position of [place], its column counted in [columns]:
  /// a [Kind.bounds] failure for a line outside `0..lines - 1` or a column
  /// outside its line, and a [Kind.invalid] one for a column in units
  /// between the two units of a surrogate pair. A column in graphemes gives
  /// the start of its cluster.
  Result<int> locate(Place place, {Columns columns = Columns.units}) =>
      line(place.line).flatMap((range) {
        final column = place.column;
        final boundaries = columns == Columns.graphemes
            ? _segment(range.start)
            : const <int>[];
        final width = switch (columns) {
          Columns.points => range.length,
          Columns.units => _units(range.end) - _units(range.start),
          // A line's end is always a boundary.
          Columns.graphemes => boundaries.indexOf(range.end),
        };
        if (column < 0 || column > width) {
          return Failure(
            Kind.bounds,
            'coordinate: column $column is outside 0..$width of line '
            '${place.line}',
          );
        }
        if (columns == Columns.points) {
          return Success(range.start + column);
        }
        if (columns == Columns.graphemes) {
          return Success(boundaries[column]);
        }
        final (position, exact) = _document.located(
          _units(range.start) + column,
        );
        return exact
            ? Success(position)
            : Failure(
                Kind.invalid,
                'coordinate: column $column of line ${place.line} is inside '
                'the pair at position $position',
              );
      });

  /// The code points of line [index], without its end, or a [Kind.bounds]
  /// failure outside `0..lines - 1`.
  Result<Range> line(int index) {
    if (index < 0 || index >= lines) {
      return Failure(
        Kind.bounds,
        'coordinate: line $index is outside 0..${lines - 1}',
      );
    }
    final start = _start(index);
    final end = index == lines - 1 ? length : _document.ending(index + 1);
    return Success(extent(start, end - start));
  }

  /// Whether code point [position] is a grapheme cluster boundary, or a
  /// [Kind.bounds] failure outside `0..length`. 0 and the length always
  /// are.
  Result<bool> boundary(int position) =>
      _within(position, length).map((_) => _boundary(position));

  /// The first grapheme cluster boundary after code point [position], or a
  /// [Kind.bounds] failure outside `0..length - 1`.
  Result<int> next(int position) =>
      _within(position, length - 1).map((_) => _next(position));

  /// The last grapheme cluster boundary before code point [position], or a
  /// [Kind.bounds] failure outside `1..length`.
  Result<int> previous(int position) {
    if (position < 1 || position > length) {
      return Failure(
        Kind.bounds,
        'coordinate: position $position is outside 1..$length',
      );
    }
    return Success(_previous(position));
  }

  /// The grapheme cluster holding code point [position], or a [Kind.bounds]
  /// failure outside `0..length - 1`.
  Result<Range> cluster(int position) => _within(position, length - 1).map((_) {
    final boundaries = _segment(position);
    final start = boundaries.lastWhere((at) => at <= position);
    final end = boundaries.firstWhere((at) => at > position);
    return extent(start, end - start);
  });

  /// The number of grapheme clusters in the text, counted line by line
  /// when first asked and kept by this value: `O(n)` once.
  late final int graphemes = () {
    var count = 0;
    for (var line = 0; line < lines; line++) {
      count += _segment(_start(line)).length - 1;
    }
    return count;
  }();

  /// [range] widened to grapheme cluster boundaries: its start moved back
  /// to the boundary at or before it and its end forward to the one at or
  /// after it. An attributed range keeps its attributes. A zero-length
  /// range inside a cluster moves to the boundary before it and stays
  /// zero-length. A range past the text is a [Kind.bounds] failure, and a
  /// range of another type than [Range] or [ARange], which cannot be built
  /// again, a [Kind.invalid] one.
  Result<R> snap<R extends Range>(R range) {
    if (range.end > length) {
      return Failure(Kind.bounds, 'coordinate: $range is outside 0..$length');
    }
    final start = _boundary(range.start) ? range.start : _previous(range.start);
    final end = range.length == 0
        ? start
        : _boundary(range.end)
        ? range.end
        : _next(range.end);
    final snapped = extent(start, end - start);
    return switch (range) {
      final ARange attributed => Success(
        ARange.from(snapped, attributed.attributes) as R,
      ),
      _ when range.runtimeType == snapped.runtimeType => Success(snapped as R),
      _ => Failure(
        Kind.invalid,
        'coordinate: a ${range.runtimeType} cannot be snapped',
      ),
    };
  }

  /// The first cluster boundary after [position], in `0..length - 1`.
  int _next(int position) =>
      _segment(position).firstWhere((at) => at > position);

  /// The last cluster boundary before [position], in `1..length`. A line's
  /// own start is a boundary, so one before it is the line above's.
  int _previous(int position) =>
      _segment(position - 1).lastWhere((at) => at < position);

  /// Whether [position], in `0..length`, is a cluster boundary.
  bool _boundary(int position) =>
      position == length || _segment(position).contains(position);

  /// Nothing, or a [Kind.bounds] failure for [position] outside `0..last`.
  Result<void> _within(int position, int last) =>
      position < 0 || position > last
      ? Failure(
          Kind.bounds,
          'coordinate: position $position is outside 0..$last',
        )
      : const Success(null);

  /// The UTF-16 units before code point [position].
  int _units(int position) => _document.prefix(position)?.units ?? 0;

  /// The position where line [index] starts: after the end before it, two
  /// code points after a carriage return followed by a line feed.
  int _start(int index) {
    if (index == 0) {
      return 0;
    }
    final end = _document.ending(index);
    return _document.item(end) == 0x0D && _document.item(end + 1) == 0x0A
        ? end + 2
        : end + 1;
  }

  /// Whether [position] falls between the carriage return and the line
  /// feed of one line end.
  bool _inside(int position) =>
      position > 0 &&
      _document.item(position - 1) == 0x0D &&
      _document.item(position) == 0x0A;
}

/// [inner], with every range it gives widened to grapheme cluster
/// boundaries of its input, as [Coordinates.snap] widens them: for markup
/// that must not split a character, such as a regex's matches. An input
/// item outside `0..0x10FFFF` is a [Kind.invalid] failure, as for `regex`.
Constructor<int> snapped(Constructor<int> inner) => (input) {
  for (final (position, point) in input.items.indexed) {
    if (point < 0 || point > 0x10FFFF) {
      return Failure(
        Kind.invalid,
        'coordinate: $point at position $position is not a code point',
      );
    }
  }
  return inner(input).flatMap((ranges) {
    final coordinates = Coordinates.of(input);
    final widened = <Range>[];
    for (final range in ranges.items) {
      switch (coordinates.snap(range)) {
        case Failure(:final kind, :final message):
          return Failure(kind, message);
        case Success(:final value):
          widened.add(value);
      }
    }
    return Success(Ranges.of(widened));
  });
};
