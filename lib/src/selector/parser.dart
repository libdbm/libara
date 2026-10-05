part of 'selector.dart';

/// A recursive descent parser for one selector's source, one method per
/// production, each written in its method's comment.
///
/// A method that cannot read its production records the first problem and
/// its column and returns `null`, so the parse ends without throwing, and
/// [parse] turns the problem into a failure.
final class _Parser {
  _Parser(String source, this._nesting) : _points = source.runes.toList();

  final List<int> _points;

  /// How deep the pseudo-classes that take selectors may nest.
  final int _nesting;

  /// How deep they nest at the next code point.
  var _depth = 0;

  /// The index of the next code point to read.
  var _at = 0;

  /// The first problem found, and the column it was found at.
  String? _problem;
  var _column = 0;

  /// The selector list of the whole source, or a [Kind.syntax] failure.
  Result<List<_Complex>> parse() {
    final options = _list();
    if (options != null) {
      _space();
      if (_at == _points.length) {
        return Success(options);
      }
      _fail("expected ',' or the end");
    }
    return Failure(Kind.syntax, 'selector: column $_column: $_problem');
  }

  /// `list ::= complex ( ',' complex )*`
  List<_Complex>? _list() {
    final options = <_Complex>[];
    do {
      _space();
      final complex = _complex();
      if (complex == null) {
        return null;
      }
      options.add(complex);
      _space();
    } while (_take(_comma));
    return List.unmodifiable(options);
  }

  /// `complex ::= compound ( combinator compound )*`, where whitespace
  /// between two compounds is the descendant combinator.
  _Complex? _complex() {
    final first = _compound();
    if (first == null) {
      return null;
    }
    final steps = <(_Combinator, _Compound)>[];
    while (true) {
      final before = _at;
      _space();
      final _Combinator combinator;
      if (_take(_greater)) {
        combinator = _Combinator.child;
      } else if (_take(_plus)) {
        combinator = _Combinator.next;
      } else if (_take(_tilde)) {
        combinator = _Combinator.later;
      } else if (_at > before && _begins(_peek)) {
        combinator = _Combinator.descendant;
      } else {
        _at = before;
        break;
      }
      _space();
      final compound = _compound();
      if (compound == null) {
        return null;
      }
      steps.add((combinator, compound));
    }
    return _Complex(first, List.unmodifiable(steps));
  }

  /// Whether [point] can begin a compound selector.
  static bool _begins(int point) =>
      _start(point) || point == _star || point == _open || point == _colon;

  /// `compound ::= type ( attribute | pseudo )* | ( attribute | pseudo )+`
  _Compound? _compound() {
    final simples = <_Simple>[];
    if (_take(_star)) {
      simples.add(const _Universal());
    } else if (_name() case final name?) {
      simples.add(_Tag(Str(Text.of(name))));
    }
    while (true) {
      final _Simple? simple;
      if (_peek == _open) {
        simple = _condition();
      } else if (_peek == _colon) {
        simple = _pseudo();
      } else {
        break;
      }
      if (simple == null) {
        return null;
      }
      simples.add(simple);
    }
    if (simples.isEmpty) {
      return _fail('expected a selector');
    }
    return _Compound(List.unmodifiable(simples));
  }

  /// `attribute ::= '[' name ( operator value )? ']'`
  _Condition? _condition() {
    _take(_open);
    _space();
    final name = _name();
    if (name == null) {
      return _fail('expected an attribute name');
    }
    _space();
    if (_take(_close)) {
      return _Condition(name);
    }
    final operator = _operator();
    if (operator == null) {
      return _fail("expected an operator or ']'");
    }
    _space();
    final column = _at + 1;
    final value = _value();
    if (value == null) {
      return null;
    }
    if (operator.textual && value is! Str) {
      return _fail('${operator.symbol} needs a text value', column);
    }
    _space();
    if (!_take(_close)) {
      return _fail("expected ']'");
    }
    return _Condition(name, operator, value);
  }

  /// The longest operator at the next code point, or `null`.
  _Operator? _operator() {
    for (final (operator, symbol) in _operators) {
      if (_at + symbol.length > _points.length) {
        continue;
      }
      var index = 0;
      while (index < symbol.length && _points[_at + index] == symbol[index]) {
        index++;
      }
      if (index == symbol.length) {
        _at += symbol.length;
        return operator;
      }
    }
    return null;
  }

  /// The operators with their code points, longest first, so that `<=` is
  /// read before `<`.
  static final List<(_Operator, List<int>)> _operators = [
    for (final operator in [
      ..._Operator.values,
    ]..sort((a, b) => b.symbol.length - a.symbol.length))
      (operator, operator.symbol.runes.toList()),
  ];

  /// `value ::= name | string | integer | 'true' | 'false' | 'null'`
  Value? _value() {
    final next = _peek;
    if (next == _single || next == _double) {
      return _string();
    }
    if (_digit(next) ||
        ((next == _plus || next == _minus) &&
            _at + 1 < _points.length &&
            _digit(_points[_at + 1]))) {
      return _integer();
    }
    return switch (_name()) {
      'true' => const Bool(true),
      'false' => const Bool(false),
      'null' => const Nil(),
      final name? => Str(Text.of(name)),
      null => _fail('expected a value'),
    };
  }

  /// A string in single or double quotes, with `\` before a quote or a
  /// backslash.
  Str? _string() {
    final column = _at + 1;
    final quote = _points[_at++];
    final points = <int>[];
    while (_at < _points.length && _points[_at] != quote) {
      if (_points[_at] == _backslash) {
        final escaped = _at + 1 < _points.length ? _points[_at + 1] : -1;
        if (escaped != _single && escaped != _double && escaped != _backslash) {
          return _fail('unknown escape', _at + 1);
        }
        _at++;
      }
      points.add(_points[_at++]);
    }
    if (!_take(quote)) {
      return _fail('unclosed string', column);
    }
    return Str(Text.of(String.fromCharCodes(points)));
  }

  /// An optionally signed decimal integer.
  Num? _integer() {
    final column = _at + 1;
    final start = _at;
    if (_peek == _plus || _peek == _minus) {
      _at++;
    }
    while (_digit(_peek)) {
      _at++;
    }
    final source = String.fromCharCodes(_points, start, _at);
    // On the web a large integer parses inexactly instead of failing, so
    // its magnitude must print back as the digits written; and zero is
    // kept unsigned, as the web would print -0 otherwise.
    final digits = source.replaceFirst(RegExp(r'^[+-]?0*'), '');
    return switch (int.tryParse(source)) {
      final value? when '${value.abs()}' == (digits.isEmpty ? '0' : digits) =>
        Num(value == 0 ? 0 : value),
      _ => _fail('integer out of range', column),
    };
  }

  /// `pseudo ::= ':root' | ':empty' | ':first-child' | ':last-child'
  /// | ':only-child' | ':nth-child(' nth ')' | ':nth-last-child(' nth ')'
  /// | ':not(' list ')' | ':is(' list ')' | ':has(' relatives ')'
  /// | ':overlaps(' list ')' | ':crosses(' list ')'`
  _Simple? _pseudo() {
    final column = _at + 1;
    _take(_colon);
    final name = _name();
    if (name == null) {
      return _fail('expected a pseudo-class');
    }
    for (final position in _Position.values) {
      if (position.source == name) {
        return _Structural(position);
      }
    }
    if (name != 'not' &&
        name != 'is' &&
        name != 'has' &&
        name != 'overlaps' &&
        name != 'crosses' &&
        name != 'nth-child' &&
        name != 'nth-last-child') {
      return _fail('unknown pseudo-class :$name', column);
    }
    if (!_take(_round)) {
      return _fail("expected '('");
    }
    final nests = name != 'nth-child' && name != 'nth-last-child';
    if (nests && _depth >= _nesting) {
      return _fail('nesting deeper than $_nesting', column);
    }
    _space();
    if (nests) {
      _depth++;
    }
    final _Simple? simple = switch (name) {
      'not' => switch (_list()) {
        final options? => _Not(options),
        null => null,
      },
      'is' => switch (_list()) {
        final options? => _Is(options),
        null => null,
      },
      'overlaps' || 'crosses' => switch (_list()) {
        final options? => _Overlap(options, crossing: name == 'crosses'),
        null => null,
      },
      'has' => switch (_relatives()) {
        final relatives? => _Has(relatives),
        null => null,
      },
      _ => _nth(last: name == 'nth-last-child'),
    };
    if (nests) {
      _depth--;
    }
    if (simple == null) {
      return null;
    }
    _space();
    if (!_take(_closing)) {
      return _fail("expected ')'");
    }
    return simple;
  }

  /// `relative ( ',' relative )*`, where `relative ::= combinator? complex`
  /// and no combinator is the descendant combinator.
  List<(_Combinator, _Complex)>? _relatives() {
    final relatives = <(_Combinator, _Complex)>[];
    do {
      _space();
      final combinator = _take(_greater)
          ? _Combinator.child
          : _take(_plus)
          ? _Combinator.next
          : _take(_tilde)
          ? _Combinator.later
          : _Combinator.descendant;
      _space();
      final complex = _complex();
      if (complex == null) {
        return null;
      }
      relatives.add((combinator, complex));
      _space();
    } while (_take(_comma));
    return List.unmodifiable(relatives);
  }

  /// `nth ::= 'odd' | 'even' | an+b`, as CSS writes it: an integer, or an
  /// optionally signed and scaled `n`, then optionally `+` or `-` and a
  /// count, with spaces around the sign.
  _Nth? _nth({required bool last}) {
    final column = _at + 1;
    final start = _at;
    switch (_name()) {
      case 'odd':
        return _Nth(2, 1, last: last);
      case 'even':
        return _Nth(2, 0, last: last);
      case _:
        _at = start;
    }
    var sign = 1;
    if (_take(_plus)) {
    } else if (_take(_minus)) {
      sign = -1;
    }
    final digits = _digits();
    if (_peek != _n) {
      if (digits == null) {
        return _fail('expected an+b', column);
      }
      return _Nth(0, sign * digits, last: last);
    }
    _at++;
    final a = sign * (digits ?? 1);
    final after = _at;
    _space();
    var direction = 0;
    if (_take(_plus)) {
      direction = 1;
    } else if (_take(_minus)) {
      direction = -1;
    } else {
      _at = after;
      return _Nth(a, 0, last: last);
    }
    _space();
    final b = _digits();
    if (b == null) {
      return _fail('expected an+b', column);
    }
    return _Nth(a, direction * b, last: last);
  }

  /// The unsigned decimal integer at the next code point, or `null`.
  int? _digits() {
    final start = _at;
    while (_digit(_peek)) {
      _at++;
    }
    if (_at == start) {
      return null;
    }
    final digits = String.fromCharCodes(_points, start, _at);
    return switch (int.tryParse(digits)) {
      final value?
          when '$value' == digits.replaceFirst(RegExp('^0+(?=.)'), '') =>
        value,
      _ => null,
    };
  }

  /// The name at the next code point, or `null` when none starts there.
  String? _name() {
    if (!_start(_peek)) {
      return null;
    }
    final start = _at;
    while (_start(_peek) || _digit(_peek) || _peek == _minus) {
      _at++;
    }
    return String.fromCharCodes(_points, start, _at);
  }

  /// Skips whitespace.
  void _space() {
    while (_peek == 0x20 ||
        _peek == 0x09 ||
        _peek == 0x0A ||
        _peek == 0x0D ||
        _peek == 0x0C) {
      _at++;
    }
  }

  /// Whether the next code point is [point], reading it when it is.
  bool _take(int point) {
    if (_peek != point) {
      return false;
    }
    _at++;
    return true;
  }

  /// The next code point, or -1 at the end.
  int get _peek => _at < _points.length ? _points[_at] : -1;

  /// `null`, having recorded [problem] at [column], or at the next code
  /// point, unless a problem was recorded first.
  Null _fail(String problem, [int? column]) {
    if (_problem == null) {
      _problem = problem;
      _column = column ?? _at + 1;
    }
    return null;
  }

  static bool _digit(int point) => point >= 0x30 && point <= 0x39;

  /// Whether [point] may start a name: an ASCII letter, `_`, or `@`.
  static bool _start(int point) =>
      (point >= 0x41 && point <= 0x5A) ||
      (point >= 0x61 && point <= 0x7A) ||
      point == 0x5F ||
      point == 0x40;

  static const _comma = 0x2C;
  static const _star = 0x2A;
  static const _open = 0x5B;
  static const _close = 0x5D;
  static const _colon = 0x3A;
  static const _round = 0x28;
  static const _closing = 0x29;
  static const _single = 0x27;
  static const _double = 0x22;
  static const _backslash = 0x5C;
  static const _plus = 0x2B;
  static const _minus = 0x2D;
  static const _n = 0x6E;
  static const _greater = 0x3E;
  static const _tilde = 0x7E;
}
