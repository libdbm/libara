part of 'selector.dart';

/// A complex selector: [first], then [steps], each a combinator relating
/// the ranges matched so far to the ranges its compound matches. A range
/// matches when the last compound matches it, related through every step.
final class _Complex {
  _Complex(this.first, this.steps);

  final _Compound first;
  final List<(_Combinator, _Compound)> steps;

  @override
  bool operator ==(Object other) =>
      other is _Complex && other.first == first && _equal(other.steps, steps);

  @override
  int get hashCode => Object.hash(first, Object.hashAll(steps));

  @override
  String toString() => [
    '$first',
    for (final (combinator, compound) in steps)
      '${combinator.separator}$compound',
  ].join();
}

/// How the ranges a step's compound matches relate to those before it.
enum _Combinator {
  /// Contained in one of them, at another position.
  descendant(' '),

  /// Its parent is one of them.
  child(' > '),

  /// Its sibling just before it is one of them.
  next(' + '),

  /// One of its siblings before it is one of them.
  later(' ~ ');

  const _Combinator(this.separator);

  /// The combinator as canonical source writes it, spaces included.
  final String separator;
}

/// A compound selector: a range matches when it matches every one of
/// [simples].
final class _Compound {
  _Compound(this.simples);

  final List<_Simple> simples;

  @override
  bool operator ==(Object other) =>
      other is _Compound && _equal(other.simples, simples);

  @override
  int get hashCode => Object.hashAll(simples);

  @override
  String toString() => simples.join();
}

/// One test a range must pass within a compound selector.
sealed class _Simple {
  const _Simple();
}

/// A type selector: the type attribute is the text [name].
final class _Tag extends _Simple {
  const _Tag(this.name);

  final Str name;

  @override
  bool operator ==(Object other) => other is _Tag && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => '${name.value}';
}

/// The universal selector, `*`.
final class _Universal extends _Simple {
  const _Universal();

  @override
  bool operator ==(Object other) => other is _Universal;

  @override
  int get hashCode => 0;

  @override
  String toString() => '*';
}

/// An attribute selector: the attribute [name] is present and, with an
/// [operator], holds it against [value].
final class _Condition extends _Simple {
  _Condition(this.name, [this.operator, this.value]);

  final String name;
  final _Operator? operator;
  final Value? value;

  /// The code points of a text [value], for `*=` and `~=`, read when first
  /// needed.
  late final List<int> points = switch (value) {
    Str(:final value) => List.unmodifiable(value.items),
    _ => const [],
  };

  /// The Knuth, Morris, and Pratt failure table of [points], built when
  /// first needed and kept with the selector.
  late final List<int> table = _table(points);

  @override
  bool operator ==(Object other) =>
      other is _Condition &&
      other.name == name &&
      other.operator == operator &&
      other.value == value;

  @override
  int get hashCode => Object.hash(name, operator, value);

  @override
  String toString() => switch ((operator, value)) {
    (final operator?, final value?) =>
      '[$name${operator.symbol}${_quoted(value)}]',
    _ => '[$name]',
  };
}

/// `:not(...)`: a range matches none of [options].
final class _Not extends _Simple {
  const _Not(this.options);

  final List<_Complex> options;

  @override
  bool operator ==(Object other) =>
      other is _Not && _equal(other.options, options);

  @override
  int get hashCode => Object.hash(_Not, Object.hashAll(options));

  @override
  String toString() => ':not(${options.join(', ')})';
}

/// `:is(...)`: a range matches one of [options].
final class _Is extends _Simple {
  const _Is(this.options);

  final List<_Complex> options;

  @override
  bool operator ==(Object other) =>
      other is _Is && _equal(other.options, options);

  @override
  int get hashCode => Object.hash(_Is, Object.hashAll(options));

  @override
  String toString() => ':is(${options.join(', ')})';
}

/// `:has(...)`: some chain of ranges runs out of a range as one of
/// [relatives] says, each a leading combinator relating the first compound
/// to the range, then a complex selector.
final class _Has extends _Simple {
  const _Has(this.relatives);

  final List<(_Combinator, _Complex)> relatives;

  @override
  bool operator ==(Object other) =>
      other is _Has && _equal(other.relatives, relatives);

  @override
  int get hashCode => Object.hash(_Has, Object.hashAll(relatives));

  @override
  String toString() =>
      ':has(${[for (final (combinator, complex) in relatives) combinator == _Combinator.descendant ? '$complex' : '${combinator.separator.trim()} $complex'].join(', ')})';
}

/// `:overlaps(...)`, or `:crosses(...)` when [crossing]: another range of
/// the scope matches one of [options] and overlaps the range, and, when
/// [crossing], neither contains the other.
final class _Overlap extends _Simple {
  const _Overlap(this.options, {required this.crossing});

  final List<_Complex> options;
  final bool crossing;

  @override
  bool operator ==(Object other) =>
      other is _Overlap &&
      other.crossing == crossing &&
      _equal(other.options, options);

  @override
  int get hashCode => Object.hash(crossing, Object.hashAll(options));

  @override
  String toString() =>
      ':${crossing ? 'crosses' : 'overlaps'}(${options.join(', ')})';
}

/// A pseudo-class of a range's place in the hierarchy, without arguments.
final class _Structural extends _Simple {
  const _Structural(this.position);

  final _Position position;

  @override
  bool operator ==(Object other) =>
      other is _Structural && other.position == position;

  @override
  int get hashCode => position.hashCode;

  @override
  String toString() => ':${position.source}';
}

/// The pseudo-classes [_Structural] stands for, each with its [source].
enum _Position {
  root('root'),
  empty('empty'),
  first('first-child'),
  last('last-child'),
  only('only-child');

  const _Position(this.source);

  /// The pseudo-class's name in source.
  final String source;
}

/// `:nth-child(an+b)`, or `:nth-last-child(an+b)` when counted from the
/// [last]: a range's place among its siblings, from 1, is `a * n + b` for
/// some `n >= 0`.
final class _Nth extends _Simple {
  const _Nth(this.a, this.b, {required this.last});

  final int a;
  final int b;
  final bool last;

  /// Whether [place] is `a * n + b` for some `n >= 0`.
  bool holds(int place) =>
      a == 0 ? place == b : (place - b) % a == 0 && (place - b) ~/ a >= 0;

  @override
  bool operator ==(Object other) =>
      other is _Nth && other.a == a && other.b == b && other.last == last;

  @override
  int get hashCode => Object.hash(a, b, last);

  @override
  String toString() {
    final step = switch (a) {
      0 => '',
      1 => 'n',
      -1 => '-n',
      _ => '${a}n',
    };
    final offset = a == 0
        ? '$b'
        : b > 0
        ? '+$b'
        : b < 0
        ? '$b'
        : '';
    return ':nth-${last ? 'last-' : ''}child($step$offset)';
  }
}

/// The operators of attribute selectors, each with its [symbol].
enum _Operator {
  equal('='),
  unequal('!='),
  prefix('^='),
  suffix(r'$='),
  substring('*='),
  word('~='),
  less('<'),
  upto('<='),
  greater('>'),
  from('>=');

  const _Operator(this.symbol);

  /// The operator as source writes it.
  final String symbol;

  /// Whether the operator compares text with text only.
  bool get textual =>
      this == prefix || this == suffix || this == substring || this == word;
}

/// [value] as source: text quoted, with `\` before a quote or backslash.
String _quoted(Value value) => switch (value) {
  Str(:final value) =>
    '"${'$value'.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"',
  Num(:final value) => '$value',
  Bool(:final value) => '$value',
  Nil() => 'null',
};

/// Whether [a] and [b] hold equal elements in the same order.
bool _equal(List<Object> a, List<Object> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) {
      return false;
    }
  }
  return true;
}
