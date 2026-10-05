/// The Unicode grapheme break tests, read from the copy that
/// `package:characters` ships, so they follow its Unicode version.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:libara/src/coordinate/coordinate.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// Each test of `GraphemeBreakTest.txt`: its code points, and for each
/// position from 0 to their length, whether a cluster boundary is there.
Future<List<(List<int>, List<bool>)>> cases() async {
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:characters/characters.dart'),
  );
  final file = File.fromUri(
    library!.resolve('../third_party/Unicode_Consortium/GraphemeBreakTest.txt'),
  );
  return [
    for (final line in await file.readAsLines())
      if (line.startsWith('÷'))
        () {
          final points = <int>[];
          final breaks = <bool>[];
          for (final field in line.split('#').first.trim().split(' ')) {
            switch (field) {
              case '÷' || '×':
                breaks.add(field == '÷');
              default:
                points.add(int.parse(field, radix: 16));
            }
          }
          return (points, breaks);
        }(),
  ];
}

void main() {
  test('every grapheme break test passes', () async {
    final tests = await cases();
    expect(tests, hasLength(greaterThan(1000)));
    for (final (points, breaks) in tests) {
      final coordinates = Coordinates.of(Items.of(points));
      final reason = points
          .map((point) => point.toRadixString(16).padLeft(4, '0'))
          .join(' ');
      for (var position = 0; position <= points.length; position++) {
        expect(
          coordinates.boundary(position).unwrap(),
          breaks[position],
          reason: '$reason at $position',
        );
      }
      // Walking forward and back visits exactly the boundaries.
      final forward = [0];
      while (forward.last < points.length) {
        forward.add(coordinates.next(forward.last).unwrap());
      }
      final backward = [points.length];
      while (backward.last > 0) {
        backward.add(coordinates.previous(backward.last).unwrap());
      }
      final expected = [
        for (var position = 0; position <= points.length; position++)
          if (breaks[position]) position,
      ];
      expect(forward, expected, reason: reason);
      expect(backward.reversed, expected, reason: reason);
    }
  });
}
