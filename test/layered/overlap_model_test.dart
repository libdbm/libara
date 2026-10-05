import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/layered/layered.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'overlaps.dart';
import 'reads.dart';

void main() {
  /// A random text of [length] letters and spaces from [random].
  String text(Random random, int length) => String.fromCharCodes([
    for (var index = 0; index < length; index++)
      'ab  c'.codeUnitAt(random.nextInt(5)),
  ]);

  test('every layer has shared starts, unordered ends, and duplicates', () {
    final document = Layered.of(
      Text.of('abcd ef ghi'),
      const Overlaps(),
    ).unwrap();
    expect(check(document), const Success<void>(null));
    for (var layer = 2; layer <= document.depth; layer++) {
      final ranges = document.layer(layer).items.cast<ARange>().toList();
      final why = 'layer $layer';
      expect(
        [
          for (var index = 1; index < ranges.length; index++)
            if (ranges[index].start == ranges[index - 1].start) index,
        ],
        isNotEmpty,
        reason: '$why: shared starts',
      );
      expect(
        [
          for (var index = 1; index < ranges.length; index++)
            if (ranges[index].end < ranges[index - 1].end) index,
        ],
        isNotEmpty,
        reason: '$why: ends out of start order',
      );
      expect(
        [
          for (var index = 1; index < ranges.length; index++)
            if (ranges[index] == ranges[index - 1]) index,
        ],
        isNotEmpty,
        reason: '$why: identical ranges',
      );
    }
  });

  test('every version matches a derivation from scratch', () {
    var edits = 0;
    var local = 0;
    for (var seed = 0; seed < 40; seed++) {
      final random = Random(seed);
      var document = Layered.of(
        Text.of(text(random, 8 + random.nextInt(24))),
        const Overlaps(),
      ).unwrap();
      for (var step = 0; step < 40; step++) {
        final items = document.items.length;
        final start = random.nextInt(items + 1);
        final edit = Edit<int>(
          1,
          Replace(
            span(start, random.nextInt(min(4, items - start) + 1)),
            Text.of(text(random, random.nextInt(4))),
          ),
        );
        final change = document.apply(edit).unwrap();
        final below = document.layer(2).length;
        document = change.document;
        edits++;
        if (change.layers[2].regions.every((region) => region.length < below)) {
          local++;
        }
        final reason =
            'seed $seed, step $step, '
            '"${String.fromCharCodes(document.items.items)}"';
        expect(check(document), const Success<void>(null), reason: reason);
        regional(document, Random(seed * 1000 + step), reason);
        final scratch = Layered.of(
          Items.of(document.items.items),
          const Overlaps(),
        ).unwrap();
        for (var layer = 2; layer <= document.depth; layer++) {
          expect(
            document.layer(layer),
            scratch.layer(layer),
            reason: '$reason: layer $layer',
          );
          for (final (index, (marker, range))
              in document.markers(layer).indexed) {
            expect(
              document.extent(layer, marker),
              projected(document, layer, range),
              reason: '$reason: layer $layer item $index extent',
            );
          }
        }
      }
    }
    expect(edits, 1600);
    // Most edits derive part of a layer again, not all of it.
    expect(local, greaterThan(edits ~/ 2));
  });
}

/// [range] of [layer] projected down to layer 1 the long way: the
/// smallest range holding the projections of every item it covers.
Range projected(Layered<int> document, int layer, Range range) {
  if (layer == 2) {
    return span(range.start, range.length);
  }
  final items = document.layer(layer - 1).items.toList();
  final parts = [
    for (var index = range.start; index < range.end; index++)
      projected(document, layer - 1, items[index]),
  ];
  final start = parts.map((part) => part.start).reduce(min);
  final end = parts.map((part) => part.end).reduce(max);
  return span(start, end - start);
}
