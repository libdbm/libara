import 'dart:math';

import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/sequence/sequence.dart';

import '../support.dart';

/// Code points that exercise every conversion: ASCII, a two-unit
/// character, lone surrogates, and every line end, carriage returns twice
/// so that they often meet line feeds.
const alphabet = [
  0x61,
  0xE9,
  0x1F600,
  0xD800,
  0xDC00,
  0x0A,
  0x0D,
  0x0D,
  0x85,
  0x2028,
  0x2029,
];

/// [count] random code points from [alphabet].
List<int> points(Random random, int count) => [
  for (var index = 0; index < count; index++)
    alphabet[random.nextInt(alphabet.length)],
];

/// The UTF-16 units of [points] before [position], from a Dart string,
/// which is UTF-16.
int units(List<int> points, int position) =>
    String.fromCharCodes(points.take(position)).length;

/// Every version of a document of [count] random code points edited by
/// [rounds] random insertions, deletions, and replacements.
List<Document<int>> versions(Random random, int count, int rounds) {
  var document = Document.of(Items.of(points(random, count)));
  final versions = [document];
  for (var round = 0; round < rounds; round++) {
    final length = document.length;
    final start = random.nextInt(length + 1);
    final size = random.nextInt(length - start + 1);
    final added = Items.of(points(random, random.nextInt(80)));
    final Command<int> command = switch (random.nextInt(3)) {
      0 => Insert(start, added),
      1 => Delete(span(start, size)),
      _ => Replace(span(start, size), added),
    };
    document = document.apply(command).unwrap();
    versions.add(document);
  }
  return versions;
}
