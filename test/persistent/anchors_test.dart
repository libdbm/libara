import 'dart:math';

import 'package:libara/src/persistent/anchors.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

void main() {
  test('anchors move as Document.map carries their positions', () {
    for (var seed = 0; seed < 50; seed++) {
      final random = Random(seed);
      var document = Document.of(Text.of('abcdefgh'));
      var anchors = const Anchors.empty();
      // Each anchor with the version and position it was placed at.
      final placed = <(Anchor, Document<int>, int, Gravity)>[];
      for (var step = 0; step < 40; step++) {
        for (var count = random.nextInt(3); count > 0; count--) {
          final position = random.nextInt(document.length + 1);
          final gravity = Gravity.values[random.nextInt(2)];
          final (next, anchor) = anchors.add(position, gravity).unwrap();
          anchors = next;
          placed.add((anchor, document, position, gravity));
        }
        final length = document.length;
        final start = random.nextInt(length + 1);
        final cut = span(start, random.nextInt(min(3, length - start) + 1));
        final Command<int> command = switch (random.nextInt(4)) {
          0 => Insert(start, Text.of('xy'.substring(random.nextInt(2)))),
          1 => Delete(cut),
          2 => Replace(cut, Text.of('z')),
          _ => Mark(tagged(start, 0)),
        };
        document = document.apply(command).unwrap();
        anchors = anchors.apply(command);
      }
      for (final (anchor, version, position, gravity) in placed) {
        expect(
          Success(anchors.position(anchor)),
          document.map(version, position, gravity),
          reason: 'seed $seed, $position $gravity',
        );
      }
    }
  });

  test('a negative position is invalid', () {
    expect(const Anchors.empty().add(-1, Gravity.right), invalid);
  });
}
