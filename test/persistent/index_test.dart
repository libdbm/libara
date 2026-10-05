import 'dart:math';

import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/index.dart';
import 'package:test/test.dart';

void main() {
  test('markers are distinct and ordered by creation', () {
    final first = Marker();
    final second = Marker();
    expect(first, isNot(second));
    expect(first.sequence, lessThan(second.sequence));
  });

  test('a marker never put is absent', () {
    final index = Index<int>.empty().put(Marker(), 1);
    expect(index.get(Marker()), isNull);
    expect(Index<int>.empty().get(Marker()), isNull);
  });

  test('put replaces the value for a marker already present', () {
    final marker = Marker();
    final index = Index<int>.empty().put(marker, 1).put(marker, 2);
    expect(index.get(marker), 2);
    expect(index.length, 1);
  });

  test('remove of an absent marker leaves the index equal in content', () {
    final marker = Marker();
    final index = Index<int>.empty().put(marker, 1).remove(Marker());
    expect(index.get(marker), 1);
    expect(index.length, 1);
  });

  test('an earlier index is unchanged by later puts and removes', () {
    final markers = List.generate(50, (_) => Marker());
    var index = Index<int>.empty();
    for (final (value, marker) in markers.indexed) {
      index = index.put(marker, value);
    }
    final earlier = index;
    for (final marker in markers.take(25)) {
      index = index.remove(marker).put(Marker(), -1);
    }
    for (final (value, marker) in markers.indexed) {
      expect(earlier.get(marker), value);
    }
    expect(earlier.length, 50);
  });

  test('agrees with a Map over 200 seeded random scripts', () {
    final random = Random(42);
    for (var script = 0; script < 200; script++) {
      var index = Index<int>.empty();
      final model = <Marker, int>{};
      final known = <Marker>[];
      for (var step = 0; step < 80; step++) {
        final choice = random.nextInt(3);
        if (choice == 0 || known.isEmpty) {
          final marker = Marker();
          known.add(marker);
          index = index.put(marker, step);
          model[marker] = step;
        } else if (choice == 1) {
          final marker = known[random.nextInt(known.length)];
          index = index.put(marker, -step);
          model[marker] = -step;
        } else {
          final marker = known[random.nextInt(known.length)];
          index = index.remove(marker);
          model.remove(marker);
        }
        expect(index.length, model.length, reason: 'script $script step $step');
        for (final marker in known) {
          expect(
            index.get(marker),
            model[marker],
            reason: 'script $script step $step',
          );
        }
      }
    }
  });
}
