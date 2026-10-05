import 'package:libara/libara.dart';

import 'xml.dart';

/// The value of [result]; an application would handle the failure instead.
T value<T>(Result<T> result) => switch (result) {
  Success(:final value) => value,
  Failure(:final message) => throw StateError(message),
};

/// The markup of [document], through the layered and text formats.
String markup(Layered<int> document) =>
    value(text.encode(value(const LayeredFormat(XML()).encode(document))))
        as String;

/// An attributed range of [length] items from [start].
ARange range(int start, int length, Map<String, Value> attributes) =>
    value(ARange.create(start, length, attributes: attributes));

void main() {
  // Layer 1 is the text, layer 2 its tokens, and layer 3 the elements.
  var document = value(
    Layered.of(
      Text.of('<list><!-- fruit --><item>apple</item>pear</list>'),
      const XML(),
    ),
  );
  print(
    'tokens: ${document.layer(2).length}, '
    'elements: ${document.layer(3).length}',
  );

  // Wrap the text "pear" (token 5) in a new element at layer 3; the
  // grammar inserts the tags, and no text is lexed again.
  final wrap = Mark<Object?>(
    range(5, 1, {'type': string('element'), 'name': string('item')}),
  );
  document = value(document.apply(Edit(3, wrap))).document;
  print(markup(document));

  // Rename the first item, rewriting both its tags.
  final (first, _) = document.markers(3)[1];
  final rename = Update<Object?>(first, {
    'type': string('element'),
    'name': string('entry'),
  });
  document = value(document.apply(Edit(3, rename))).document;
  print(markup(document));

  // Wrapping half an element is refused, and the document is unchanged.
  final half = Mark<Object?>(
    range(2, 2, {'type': string('element'), 'name': string('bad')}),
  );
  print('refused: ${document.apply(Edit(3, half)) is Failure}');

  // A text edit that breaks the markup gives a diagnostic, not a failure.
  final cut = Delete<int>(value(Range.create(0, 1)));
  final typed = value(document.apply(Edit(1, cut))).document;
  for (final problem in typed.diagnostics(3).items.cast<ARange>()) {
    print('diagnostic: ${problem.get('message')}');
  }

  // Undo is a step back.
  print(markup(typed.previous!));
}
