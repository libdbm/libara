part of 'coordinate.dart';

/// The grapheme cluster boundaries of [points], the code points of one line
/// with its end, as offsets from 0 to their length, in order.
///
/// `package:characters` segments a `String`, so the code points become
/// one, and each cluster's UTF-16 length maps back to code points by
/// counting units. A lone high surrogate followed by a lone low one, which
/// the string reads as one character, falls in one cluster.
List<int> _clusters(List<int> points) {
  final boundaries = [0];
  var index = 0;
  for (final cluster in String.fromCharCodes(points).characters) {
    var units = cluster.length;
    while (units > 0) {
      units -= points[index] > 0xFFFF ? 2 : 1;
      index++;
    }
    boundaries.add(index);
  }
  return boundaries;
}

/// Grapheme cluster boundaries of a [Coordinates] value's text, found one
/// line at a time: UAX #29 always breaks around line ends, so clusters
/// never cross them and segmentation can start at any line's start.
extension _Segments on Coordinates {
  /// The boundaries of the line holding [position], with its end, as
  /// positions in the text, from the line's start to the next line's.
  ///
  /// A position between a carriage return and its line feed belongs to the
  /// line they end. The text's length belongs to the last line.
  List<int> _segment(int position) {
    var line = _document.prefix(position)?.ends ?? 0;
    if (_inside(position)) {
      line--;
    }
    final start = _start(line);
    final end = line == lines - 1 ? length : _start(line + 1);
    return [
      for (final offset in _clusters(
        _document.slice(start, end - start).items.toList(),
      ))
        start + offset,
    ];
  }
}
