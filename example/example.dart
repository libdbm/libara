import 'dart:convert';

import 'package:libara/libara.dart';

/// The value of [result]; an application would handle the failure instead.
T value<T>(Result<T> result) => switch (result) {
  Success(:final value) => value,
  Failure(:final message) => throw StateError(message),
};

void main() {
  // A document holds a sequence, here the code points of a text, and every
  // edit returns a new version.
  final source = Text.of('The cat sat on the mat.');
  var document = Document.of(source);

  // A constructor finds ranges. Each word becomes an attributed range.
  final words = regex(
    RegExp('[a-z]+', caseSensitive: false),
    attributes: {'type': Str(Text.of('word'))},
  );
  final found = value(words(source)).items.cast<ARange>().toList();
  print('words: ${found.length}');

  // Marking stores each range under a marker. A left-gravity end keeps a
  // word from absorbing text typed right after it.
  final marks = [
    for (final range in found) Mark<int>(range, end: Gravity.left),
  ];
  document = value(document.transact(marks));

  // Edits move every range; the caller never adjusts an offset.
  document = value(document.apply(Insert(4, Text.of('black '))));
  print(String.fromCharCodes(document.items));
  print('cat is now at ${document.resolve(marks[1].marker)}');

  // Queries find the ranges at a position or across a span.
  final view = value(Range.create(4, 9));
  print('over "black cat": ${document.overlapping(view)}');

  // Undo is a step back to the previous version.
  print('undo: ${String.fromCharCodes(document.previous!.items)}');

  // A document saves to JSON and loads back with fresh markers, in the
  // order of document.markers.
  final format = JSONFormat(text, history: true);
  final json = jsonEncode(value(format.encode(document)));
  final (loaded, markers) = value(format.restore(jsonDecode(json)));
  print('loaded ${loaded.ranges.length} ranges, version ${loaded.version}');
  print('first word: ${loaded.resolve(markers.first)}');

  // A selector finds ranges by their attributes and by how they nest.
  // Here a type selector reads the `type` attribute, and `phrase > word`
  // selects the words whose innermost container is the phrase.
  final phrase = Mark<int>(
    value(ARange.create(4, 13, attributes: {'type': Str(Text.of('phrase'))})),
  );
  final selector = value(Selector.parse('phrase > word', type: 'type'));
  final inside = value(loaded.apply(phrase)).select(selector);
  print('in the phrase: ${[for (final (_, range) in inside) range]}');

  // Replicas edit one document with no server. Each commit is an
  // operation to send to the others, and concurrent edits converge.
  var alice = value(Replica.create<int>('alice'));
  var bob = value(Replica.create<int>('bob'));
  final Operation<int> hello;
  (alice, hello) = value(alice.commit([Insert(0, Text.of('hello'))]));
  (bob, _) = value(bob.receive(hello));
  final Operation<int> world;
  (alice, world) = value(alice.commit([Insert(5, Text.of(' world'))]));
  final Operation<int> oh;
  (bob, oh) = value(bob.commit([Insert(0, Text.of('Oh, '))]));
  // Operations travel as JSON, here bob's to alice.
  final wire = OperationFormat(text);
  final sent = jsonEncode(value(wire.encode(oh)));
  (alice, _) = value(alice.receive(value(wire.decode(jsonDecode(sent)))));
  (bob, _) = value(bob.receive(world));
  print('alice: ${String.fromCharCodes(alice.document.items)}');
  print('bob: ${String.fromCharCodes(bob.document.items)}');
}
