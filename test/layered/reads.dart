import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/layered/layered.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:test/test.dart';

import '../support.dart';

/// Expects the regional reads of [document], `slice`, `within`,
/// `crossing`, and `span`, to agree with filtering its whole layers, over
/// regions, positions, and spans drawn from [random].
void regional(Layered<int> document, Random random, String reason) {
  final items = document.items.items.toList();
  for (var round = 0; round < 4; round++) {
    final start = random.nextInt(items.length + 1);
    final region = span(start, random.nextInt(items.length - start + 1));
    expect(
      document.slice(region).items,
      items.sublist(region.start, region.end),
      reason: '$reason slice $region',
    );
  }
  for (var layer = 2; layer <= document.depth; layer++) {
    final pairs = document.markers(layer);
    final below = layer == 2 ? items.length : document.layer(layer - 1).length;
    final why = '$reason layer $layer';
    for (var round = 0; round < 4; round++) {
      final start = random.nextInt(below + 1);
      final region = span(start, random.nextInt(below - start + 1));
      expect(
        document.within(layer, region),
        unorderedEquals(<(Marker, ARange)>[
          for (final pair in pairs)
            if (region.start <= pair.$2.start && pair.$2.end <= region.end)
              pair,
        ]),
        reason: '$why within $region',
      );
      final position = random.nextInt(below + 2) - 1;
      expect(
        document.crossing(layer, position),
        unorderedEquals(<(Marker, ARange)>[
          for (final pair in pairs)
            if (pair.$2.start < position && position < pair.$2.end) pair,
        ]),
        reason: '$why crossing $position',
      );
      final first = random.nextInt(pairs.length + 1);
      final indices = span(first, random.nextInt(pairs.length - first + 2));
      expect(
        document.span(layer, indices),
        pairs.sublist(first, min(indices.end, pairs.length)),
        reason: '$why span $indices',
      );
    }
  }
}
