/// An example grammar over a small subset of XML, to show how a markup
/// language plugs into a layered document, with its tokens read by a
/// petitparser grammar. Not part of libara.
library;

import 'package:libara/libara.dart';
import 'package:petitparser/petitparser.dart'
    hide Failure, Result, Success, string;

/// Layered XML text in three layers.
///
/// Layer 2 is tokens over the code points: start tags, end tags,
/// empty-element tags, comments, text runs, and markup that does not parse.
/// A tag's name is its `name` attribute, and each XML attribute is an
/// attribute named with an `@` before it. Layer 3 is elements over the
/// tokens, from a start tag to the end tag that closes it, or an
/// empty-element tag alone.
///
/// Markup that does not parse, an unterminated comment, an end tag that
/// closes nothing open, a start tag never closed, and a bare `&` in text,
/// one that starts no reference such as `&amp;` or `&#38;`, are
/// diagnostics. This subset does not resolve references, so text holding
/// them reads as written.
final class XML implements Grammar<int> {
  /// An XML grammar.
  const XML();

  @override
  int get depth => 3;

  /// At layer 2, the tokens over [region] and the ones that do not parse;
  /// at layer 3, the elements and the tags that do not pair.
  @override
  Derived derive(Layered<int> document, int layer, Range region) {
    if (layer == 3) {
      final (elements, errors) = _parse(document, region);
      return (ranges: elements, diagnostics: errors);
    }
    final stretch = _Stretch(document.slice(region), region.start);
    final tokens = _lex(stretch);
    return (
      ranges: [for (final (token, _) in tokens) token],
      diagnostics: [
        for (final (token, problem) in tokens)
          if (problem != null) ARange.from(token, {'message': string(problem)}),
        for (final (token, _) in tokens)
          if (token.get('type') == string('text'))
            for (final at in _bare(
              stretch.buffer,
              token.start - stretch.offset,
              token.end - stretch.offset,
            ))
              _problem(stretch.offset + at, 1, 'bare &'),
      ],
    );
  }

  /// At layer 2, the text from the token at the change to the first place
  /// past it where an unchanged token starts, since lexing starts afresh at
  /// every token. A token starting right at the end of the change may have
  /// lost its first items to it, so lexing goes on past that one. At layer 3, the innermost element strictly around the
  /// changed tokens that still closes its own start tag, or every token.
  @override
  Range affected(Layered<int> document, int layer, Range changed) =>
      layer == 2 ? _relex(document, changed) : _element(document, changed);

  /// Carries out an XML edit:
  /// - at layer 2, `Mark` of a zero-length tag inserts its markup, `Update`
  ///   renames a tag, and `Delete` removes tokens;
  /// - at layer 3, `Mark` wraps tokens holding whole elements in a new
  ///   element, `Unmark` unwraps one, `Update` renames one, rewriting its
  ///   tags, and `Delete` removes elements with their tokens.
  ///
  /// Anything else, or an edit that would leave the markup parsing
  /// differently, such as wrapping half an element, is refused.
  @override
  Result<Derivation<int>> edit(
    Layered<int> document,
    Edit<int> change,
  ) => switch ((change.layer, change.command)) {
    (2, Mark(:final marker, :final range)) => _insert(document, marker, range),
    (2, Update(:final marker, :final attributes)) => _rename(
      document,
      marker,
      attributes,
    ),
    (2, Delete(:final span)) => _cut(document, span),
    (3, Mark(:final marker, :final range)) => _wrap(document, marker, range),
    (3, Unmark(:final marker)) => _unwrap(document, marker),
    (3, Update(:final marker, :final attributes)) => _retag(
      document,
      marker,
      attributes,
    ),
    (3, Delete(:final span)) => _drop(document, span),
    (final layer, final command) => Failure(
      Kind.invalid,
      'xml: $command at layer $layer is not an XML edit',
    ),
  };

  /// Accepts a text edit that reaches into no tag or comment, and leaves
  /// the markup and its diagnostics as they stand: every token but a run of
  /// text is markup.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) => kept(
    document,
    change,
    text: (token) => token.get('type') == string('text'),
  );

  /// [text] with `&` and `<` written as references, which this subset reads
  /// as text without resolving them.
  @override
  List<int> escaped(List<int> text, {bool raw = false}) => raw
      ? text
      : [
          for (final point in text)
            ...switch (point) {
              0x26 => '&amp;'.runes,
              0x3C => '&lt;'.runes,
              _ => [point],
            },
        ];

  /// A run of text crossing an edge of a move is cut back, and read again
  /// either side; a tag or a comment is not cut, and an element is moved
  /// only whole.
  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      layer == 2 && range.get('type') == string('text')
      ? Crossing.clamp
      : Crossing.refuse;

  /// Inserts the tag that [range], zero-length, describes, under [marker],
  /// splitting a text run it falls inside.
  Result<Derivation<int>> _insert(
    Layered<int> document,
    Marker marker,
    ARange range,
  ) {
    final markup = _markup(range.attributes);
    final at = range.start;
    final length = document.items.length;
    if (markup == null || range.length != 0 || at > length) {
      return Failure(Kind.invalid, 'xml: $range is not a new tag');
    }
    final inserted = Text.of(markup);
    final size = inserted.length;
    final below = [Edit<int>(1, Insert(at, inserted))];
    final tag = (marker, _range(at, size, range.attributes));
    for (final (token, current) in document.markers(2)) {
      if (current.start < at && at < current.end) {
        if (current.get('type') != string('text')) {
          return Failure(Kind.invalid, 'xml: $at is inside $current');
        }
        if (!_parted(_read(document, current), at - current.start)) {
          return Failure(Kind.invalid, 'xml: $at would cut a reference');
        }
        return Success((
          below: below,
          created: [
            (Marker(), _text(current.start, at - current.start)),
            tag,
            (Marker(), _text(at + size, current.end - at)),
          ],
          removed: [token],
          updated: const {},
        ));
      }
      if (current.end == at &&
          at == length &&
          current.get('type') == string('comment') &&
          _flawed(document, current)) {
        return Failure(Kind.invalid, 'xml: $at would join $current');
      }
    }
    return _done(below: below, created: [tag]);
  }

  /// Gives the tag under [marker] the name in [attributes], which must
  /// otherwise be its own, by rewriting the name inside its markup.
  Result<Derivation<int>> _rename(
    Layered<int> document,
    Marker marker,
    Map<String, Value> attributes,
  ) {
    final token = _find(document.markers(2), marker);
    final type = token?.get('type');
    final name = attributes['name'];
    if (token == null ||
        !(type == string('start') ||
            type == string('end') ||
            type == string('empty'))) {
      return Failure(Kind.invalid, 'xml: $marker is not a tag');
    }
    if (name == null ||
        _markup(attributes) == null ||
        !_alike({...token.attributes, 'name': name}, attributes)) {
      return Failure(Kind.invalid, 'xml: $attributes renames nothing');
    }
    final old = _string(token.get('name')!);
    final at = token.start + (type == string('end') ? 2 : 1);
    final fresh = _string(name);
    return _done(
      below: [
        Edit(1, Insert(at, Text.of(fresh))),
        Edit(1, Delete<int>(_Span(at + fresh.length, old.length))),
      ],
      updated: {marker: attributes},
    );
  }

  /// Deletes the tokens in [span], merging the text runs either side.
  Result<Derivation<int>> _cut(Layered<int> document, Range span) {
    final tokens = document.markers(2);
    if (span.end > tokens.length) {
      return Failure(Kind.invalid, 'xml: $span is not a run of tokens');
    }
    if (span.length == 0) {
      return _done();
    }
    final picked = tokens.sublist(span.start, span.end);
    for (final (_, token) in picked) {
      if (_flawed(document, token)) {
        return Failure(Kind.invalid, 'xml: $token holds markup in error');
      }
    }
    final removed = [for (final (marker, _) in picked) marker];
    final created = <(Marker, ARange)>[];
    if (span.start > 0 && span.end < tokens.length) {
      final (before, left) = tokens[span.start - 1];
      final (after, right) = tokens[span.end];
      if (right.get('type') == string('text')) {
        if (left.get('type') == string('text')) {
          final joined = _read(document, left) + _read(document, right);
          if (!_parted(joined, left.length)) {
            return Failure(Kind.invalid, 'xml: $span would join a reference');
          }
          removed.addAll([before, after]);
          created.add((
            Marker(),
            _text(left.start, left.length + right.length),
          ));
        } else if (_flawed(document, left)) {
          return Failure(Kind.invalid, 'xml: $span would join $left');
        }
      }
    }
    final first = picked.first.$2;
    return _done(
      below: [
        Edit(
          1,
          Delete<int>(_Span(first.start, picked.last.$2.end - first.start)),
        ),
      ],
      created: created,
      removed: removed,
    );
  }

  /// Wraps the tokens in [range] in a new element under [marker].
  Result<Derivation<int>> _wrap(
    Layered<int> document,
    Marker marker,
    ARange range,
  ) {
    final tokens = document.layer(2).items.cast<ARange>().toList();
    final name = range.get('name');
    if (range.end > tokens.length ||
        name == null ||
        !_alike(range.attributes, {'type': string('element'), 'name': name}) ||
        !_named(_string(name))) {
      return Failure(Kind.invalid, 'xml: $range is not a new element');
    }
    if (_parse(document, range).$2.isNotEmpty) {
      return Failure(Kind.invalid, 'xml: $range does not hold whole elements');
    }
    final open = range.start < tokens.length
        ? tokens[range.start].start
        : document.items.length;
    final close = range.length == 0 ? open : tokens[range.end - 1].end;
    return _done(
      below: [
        Edit(2, Mark(_range(close, 0, {'type': string('end'), 'name': name}))),
        Edit(2, Mark(_range(open, 0, {'type': string('start'), 'name': name}))),
      ],
      created: [
        (marker, _range(range.start, range.length + 2, range.attributes)),
      ],
    );
  }

  /// Removes the tags of the element under [marker], keeping its content,
  /// which must parse on its own, as a stray end tag in it would otherwise
  /// close an element outside.
  Result<Derivation<int>> _unwrap(Layered<int> document, Marker marker) {
    final element = _find(document.markers(3), marker);
    if (element == null || element.length < 2) {
      return Failure(
        Kind.invalid,
        'xml: $marker is not an element with tags to remove',
      );
    }
    if (_parse(document, element).$2.isNotEmpty) {
      return Failure(
        Kind.invalid,
        'xml: $element holds tags that would pair differently without it',
      );
    }
    return _done(
      below: [
        Edit(2, Delete<int>(_Span(element.end - 1, 1))),
        Edit(2, Delete<int>(_Span(element.start, 1))),
      ],
      removed: [marker],
    );
  }

  /// Renames the element under [marker] to the name in [attributes],
  /// rewriting its tags; its content must parse on its own, as a stray end
  /// tag in it with the new name would otherwise close it.
  Result<Derivation<int>> _retag(
    Layered<int> document,
    Marker marker,
    Map<String, Value> attributes,
  ) {
    final element = _find(document.markers(3), marker);
    final name = attributes['name'];
    if (element == null) {
      return Failure(Kind.invalid, 'xml: $marker is not an element');
    }
    if (name == null ||
        !_alike(attributes, {'type': string('element'), 'name': name})) {
      return Failure(Kind.invalid, 'xml: $attributes is not an element name');
    }
    if (_parse(document, element).$2.isNotEmpty) {
      return Failure(
        Kind.invalid,
        'xml: $element holds tags that would pair differently renamed',
      );
    }
    final tokens = document.markers(2);
    final (start, opening) = tokens[element.start];
    final (end, closing) = tokens[element.end - 1];
    return _done(
      below: [
        if (element.length > 1)
          Edit(2, Update<Object?>(end, {...closing.attributes, 'name': name})),
        Edit(2, Update<Object?>(start, {...opening.attributes, 'name': name})),
      ],
      updated: {marker: attributes},
    );
  }

  /// Deletes the elements in [span], their tokens, and the elements nested
  /// in them.
  Result<Derivation<int>> _drop(Layered<int> document, Range span) {
    final elements = document.markers(3);
    if (span.end > elements.length) {
      return Failure(Kind.invalid, 'xml: $span is not a run of elements');
    }
    if (span.length == 0) {
      return _done();
    }
    final picked = [
      for (final (_, range) in elements.sublist(span.start, span.end)) range,
    ];
    var (start, end) = (picked.first.start, picked.first.end);
    for (final range in picked) {
      start = range.start < start ? range.start : start;
      end = range.end > end ? range.end : end;
    }
    final run = _Span(start, end - start);
    if (_parse(document, run).$2.isNotEmpty) {
      return Failure(Kind.invalid, 'xml: $span cuts through an element');
    }
    return _done(
      below: [Edit(2, Delete<int>(run))],
      removed: [
        for (final (element, range) in elements)
          if (run.start <= range.start && range.end <= run.end) element,
      ],
    );
  }

  /// The tokens tile the text, so a position that no token crosses is
  /// where one starts, except within the changed items, which no token
  /// covers until they are lexed again. Lexing reads a stretch of the text
  /// from the start, twice as long each time a token reaches its end, as
  /// that token may go on past it.
  Range _relex(Layered<int> document, Range changed) {
    // The start of the token holding the item before the change, which the
    // change may extend.
    var start = changed.start;
    if (start > 0) {
      final around = document.crossing(2, start - 1);
      start = around.isEmpty ? start - 1 : around.single.$2.start;
    }
    final length = document.items.length;
    for (var size = changed.end - start + 256; ; size *= 2) {
      final end = start + size < length ? start + size : length;
      final stretch = _Stretch(
        document.slice(_Span(start, end - start)),
        start,
      );
      var position = start;
      while (position < end &&
          (position <= changed.end ||
              document.crossing(2, position).isNotEmpty)) {
        position = stretch.token(position - start).$1.end;
      }
      if (position < end || end == length) {
        final last = position < changed.end ? changed.end : position;
        return _Span(start, last - start);
      }
    }
  }

  Range _element(Layered<int> document, Range changed) {
    final elements = [
      for (final (_, element) in document.crossing(3, changed.start))
        if (changed.end < element.end) element,
    ]..sort((a, b) => a.length - b.length);
    for (final element in elements) {
      final (found, _) = _parse(document, element);
      if (found.any(
        (range) =>
            range.start == element.start && range.length == element.length,
      )) {
        return element;
      }
    }
    return _Span(0, document.layer(2).length);
  }

  /// The tokens of [stretch], each at its place in the text and with what
  /// is wrong with it, if anything.
  List<(ARange, String?)> _lex(_Stretch stretch) {
    final found = <(ARange, String?)>[];
    var position = 0;
    while (position < stretch.length) {
      final (token, problem) = stretch.token(position);
      found.add((token, problem));
      position = token.end - stretch.offset;
    }
    return found;
  }

  /// The elements in [region] of layer 2's tokens, in start order, and the
  /// tags that do not pair.
  (List<ARange>, List<ARange>) _parse(Layered<int> document, Range region) {
    final tokens = [for (final (_, token) in document.span(2, region)) token];
    final open = <(int, Value)>[];
    final elements = <ARange>[];
    final errors = <ARange>[];
    for (var index = region.start; index < region.end; index++) {
      final token = tokens[index - region.start];
      final name = token.get('name');
      switch (_string(token.get('type')!)) {
        case 'start':
          open.add((index, name!));
        case 'empty':
          elements.add(
            _range(index, 1, {'type': string('element'), 'name': name!}),
          );
        case 'end':
          if (open.isNotEmpty && open.last.$2 == name) {
            final (start, _) = open.removeLast();
            elements.add(
              _range(start, index - start + 1, {
                'type': string('element'),
                'name': name!,
              }),
            );
          } else {
            errors.add(_problem(index, 1, 'unexpected </${_string(name!)}>'));
          }
      }
    }
    for (final (index, name) in open) {
      errors.add(_problem(index, 1, 'unclosed <${_string(name)}>'));
    }
    return (
      Ranges.of(elements).startOrder().items.cast<ARange>().toList(),
      errors,
    );
  }
}

/// A text attribute value.
Value string(String value) => Str(Text.of(value));

/// A derivation of [below], [created], [removed], and [updated].
Result<Derivation<int>> _done({
  List<Edit<int>> below = const [],
  List<(Marker, ARange)> created = const [],
  List<Marker> removed = const [],
  Map<Marker, Map<String, Value>> updated = const {},
}) => Success((
  below: below,
  created: created,
  removed: removed,
  updated: updated,
));

/// The range under [marker] among [pairs], or `null`.
ARange? _find(List<(Marker, ARange)> pairs, Marker marker) {
  for (final (key, range) in pairs) {
    if (key == marker) {
      return range;
    }
  }
  return null;
}

/// Whether layer 2 of [document] has a diagnostic within [token]: over the
/// whole of it for a tag or comment, or over a bare `&` in a text run.
bool _flawed(Layered<int> document, ARange token) => document
    .diagnostics(2)
    .items
    .any((flaw) => token.start <= flaw.start && flaw.end <= token.end);

/// Where [text] has a bare `&`, one that starts no reference, from [start]
/// to [end]: found by searching for `&` alone, so a run of text without one
/// costs a scan and no copy.
List<int> _bare(String text, [int start = 0, int? end]) {
  final last = end ?? text.length;
  final found = <int>[];
  for (
    var at = text.indexOf('&', start);
    at >= 0 && at < last;
    at = text.indexOf('&', at + 1)
  ) {
    final reference = _reference.matchAsPrefix(text, at);
    if (reference == null || reference.end > last) {
      found.add(at);
    }
  }
  return found;
}

/// An entity or character reference.
final _reference = RegExp(
  r'&(?:[A-Za-z_][A-Za-z0-9_.-]*|#[0-9]+|#x[0-9A-Fa-f]+);',
);

/// Whether [text] cut at [at] has the same bare `&`s as it has whole, so a
/// tag there, or taking one away from there, changes no diagnostic.
bool _parted(String text, int at) {
  final apart = [
    ..._bare(text.substring(0, at)),
    for (final found in _bare(text.substring(at))) found + at,
  ];
  final whole = _bare(text);
  return apart.length == whole.length &&
      apart.indexed.every((pair) => pair.$2 == whole[pair.$1]);
}

/// The text of [document] under [range], one character per code point
/// in the BMP, as the lexer reads it.
String _read(Layered<int> document, Range range) => String.fromCharCodes([
  for (final point in document.slice(range).items)
    point > 0xFFFF ? 0xFFFD : point,
]);

/// Whether [a] and [b] hold the same attributes.
bool _alike(Map<String, Value> a, Map<String, Value> b) =>
    a.length == b.length &&
    a.entries.every((entry) => b[entry.key] == entry.value);

/// The markup of the tag [attributes] describe, as the lexer would read
/// them back, or `null` when they describe no tag.
String? _markup(Map<String, Value> attributes) {
  final type = attributes['type'];
  final name = attributes['name'];
  if (type == null || name == null || !_named(_string(name))) {
    return null;
  }
  final parts = <String>[];
  for (final MapEntry(:key, :value) in attributes.entries) {
    if (key == 'type' || key == 'name') {
      continue;
    }
    final content = _string(value);
    if (!key.startsWith('@') ||
        !_named(key.substring(1)) ||
        value is! Str ||
        content.contains('<') ||
        content.contains('&') ||
        (content.contains('"') && content.contains("'"))) {
      return null;
    }
    final quote = content.contains('"') ? "'" : '"';
    parts.add(' ${key.substring(1)}=$quote$content$quote');
  }
  final tag = _string(name);
  return switch (_string(type)) {
    'start' => '<$tag${parts.join()}>',
    'empty' => '<$tag${parts.join()}/>',
    'end' when parts.isEmpty => '</$tag>',
    _ => null,
  };
}

/// A text run of [length] items from [start].
ARange _text(int start, int length) =>
    _range(start, length, {'type': string('text')});

/// Whether [name] is a name, as a tag or an attribute has.
bool _named(String name) => _name.end().accept(name);

/// The text a text attribute value holds.
String _string(Value value) => switch (value) {
  Str(:final value) => String.fromCharCodes(value.items),
  _ => '$value',
};

/// A diagnostic over [length] tokens from [start].
ARange _problem(int start, int length, String message) =>
    _range(start, length, {'message': string(message)});

/// The range of [length] items from [start] carrying [attributes].
ARange _range(int start, int length, Map<String, Value> attributes) =>
    ARange.from(_Span(start, length), attributes);

/// A range whose start and length are non-negative by construction.
final class _Span extends Range {
  const _Span(this.start, this.length);

  @override
  final int start;

  @override
  final int length;
}

/// A stretch of the text from [offset], held in [buffer] one character
/// per code point, so a position in the buffer is a position in the
/// stretch: a code point outside the BMP is U+FFFD there, which is never
/// markup, and attribute values are read from [items] instead.
final class _Stretch {
  _Stretch(this.items, this.offset)
    : buffer = String.fromCharCodes([
        for (final point in items.items) point > 0xFFFF ? 0xFFFD : point,
      ]);

  /// The code points of the stretch.
  final Sequence<int> items;

  /// Where the stretch starts in the text.
  final int offset;

  /// The code points as a string the grammar reads.
  final String buffer;

  /// The number of code points.
  int get length => buffer.length;

  /// The token at [at] of the stretch, at its place in the text, and what
  /// is wrong with it, if anything.
  (ARange, String?) token(int at) {
    // Every code point starts a text run or markup, so the grammar never
    // fails.
    final result = _token.parseOn(Context(buffer, at));
    final (:type, :name, :attributes, :problem) = result.value;
    return (
      _range(offset + at, result.position - at, {
        if (name != null) 'name': string(name),
        for (final (key, value) in attributes)
          '@$key': string(
            String.fromCharCodes(items.slice(value.start, value.length).items),
          ),
        'type': string(type),
      }),
      problem,
    );
  }
}

/// A token as the grammar reads it: its type, its tag's name and
/// attributes, each with the span of its value, and what is wrong with
/// it, if anything.
typedef _Lexeme = ({
  String type,
  String? name,
  List<(String, Token<String>)> attributes,
  String? problem,
});

/// A lexeme of [type].
_Lexeme _lexeme(
  String type, {
  String? name,
  List<(String, Token<String>)> attributes = const [],
  String? problem,
}) => (type: type, name: name, attributes: attributes, problem: problem);

/// A name: a letter or `_`, then letters, digits, `_`, `-`, and `.`.
final _name = (pattern('A-Za-z_') & pattern('A-Za-z0-9_.-').star()).flatten();

/// A white space character.
final _blank = pattern(' \t\n\r');

/// An attribute: its name and the span of its quoted value, which holds no
/// `<`.
final _attribute = seq3(
  _name,
  char('=').trim(_blank),
  [
    for (final quote in ['"', "'"])
      pattern('^$quote<')
          .starString()
          .token()
          .skip(before: char(quote), after: char(quote)),
  ].toChoiceParser(),
).map3((key, _, value) => (key, value));

/// A start tag or an empty-element tag.
final _open =
    seq4(
      _name.skip(before: char('<')),
      _attribute.skip(before: _blank.star()).star(),
      _blank.star(),
      ['/>'.toParser(), '>'.toParser()].toChoiceParser(),
    ).map4(
      (name, attributes, _, close) => _lexeme(
        close == '/>' ? 'empty' : 'start',
        name: name,
        attributes: attributes,
      ),
    );

/// An end tag.
final _close = _name
    .skip(before: '</'.toParser(), after: _blank.star() & char('>'))
    .map((name) => _lexeme('end', name: name));

/// A comment, or one never closed, which runs to the end.
final _comment = [
  ('<!--'.toParser() & any().starLazy('-->'.toParser()) & '-->'.toParser()).map(
    (_) => _lexeme('comment'),
  ),
  ('<!--'.toParser() & any().star()).map(
    (_) => _lexeme('comment', problem: 'unterminated comment'),
  ),
].toChoiceParser();

/// A token: a text run up to the next `<`, a comment, a tag, or markup
/// that does not parse, up to the next `<`.
final _token = [
  pattern('^<').plus().map((_) => _lexeme('text')),
  _comment,
  _open,
  _close,
  (char('<') & pattern('^<').star()).map(
    (_) => _lexeme('error', problem: 'malformed markup'),
  ),
].toChoiceParser();
