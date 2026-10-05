import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/selector/selector.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// A text attribute value.
Str string(String value) => Str(Text.of(value));

/// The selector in [source], which must parse.
Selector parsed(String source, {String type = 'name'}) =>
    Selector.parse(source, type: type).unwrap();

/// Expects [source] to fail to parse as [Kind.syntax] at [column], with a
/// message containing [problem].
void refused(String source, int column, String problem) {
  final result = Selector.parse(source);
  expect(result, isA<Failure<Selector>>(), reason: source);
  final failure = result as Failure<Selector>;
  expect(failure.kind, Kind.syntax, reason: source);
  expect(failure.message, startsWith('selector: column $column: '));
  expect(failure.message, contains(problem));
}

void main() {
  group('parse and print', () {
    const cases = {
      'p': 'p',
      '*': '*',
      '[a]': '[a]',
      '[a=v]': '[a="v"]',
      '[ a = "v w" ]': '[a="v w"]',
      r"[a='it\'s']": '[a="it\'s"]',
      r'[a="back\\slash"]': r'[a="back\\slash"]',
      '[a!=2]': '[a!=2]',
      '[a^=x]': '[a^="x"]',
      r'[a$=x]': r'[a$="x"]',
      '[a*=x]': '[a*="x"]',
      '[a~=x]': '[a~="x"]',
      '[a<2]': '[a<2]',
      '[a<=-2]': '[a<=-2]',
      '[a>+3]': '[a>3]',
      '[a>=0]': '[a>=0]',
      '[a=-0]': '[a=0]',
      '[a=007]': '[a=7]',
      '[a=true]': '[a=true]',
      '[a=false]': '[a=false]',
      '[a=null]': '[a=null]',
      '[a="true"]': '[a="true"]',
      '[@a=v]': '[@a="v"]',
      'p-q_r@s': 'p-q_r@s',
      'p[a][b=1]': 'p[a][b=1]',
      '*[a]': '*[a]',
      'p:not(q, [b])': 'p:not(q, [b])',
      ':is(p , *)': ':is(p, *)',
      ':not(:is(p))': ':not(:is(p))',
      ' a , b ': 'a, b',
    };
    for (final MapEntry(key: source, value: printed) in cases.entries) {
      test('"$source" prints as $printed and reads back', () {
        final selector = parsed(source);
        expect(selector.toString(), printed);
        expect(parsed(printed), selector);
        expect(parsed(printed).hashCode, selector.hashCode);
      });
    }

    test('the type attribute is part of equality', () {
      expect(parsed('p', type: 'type'), isNot(parsed('p')));
      expect(parsed('p', type: 'type').type, 'type');
      expect(parsed('p').type, 'name');
    });
  });

  group('malformed selectors', () {
    test('fail with the column and the problem', () {
      refused('', 1, 'expected a selector');
      refused('[a', 3, "expected an operator or ']'");
      refused('[a=v', 5, "expected ']'");
      refused('[a="v', 4, 'unclosed string');
      refused(r'[a="\x"]', 5, 'unknown escape');
      refused('[1]', 2, 'expected an attribute name');
      refused('[a=]', 4, 'expected a value');
      refused('[a^=2]', 5, '^= needs a text value');
      refused('[a~=true]', 5, '~= needs a text value');
      refused('[a=99999999999999999999]', 4, 'integer out of range');
      refused(':not(p', 7, "expected ')'");
      refused(':not p', 5, "expected '('");
      refused(':hover', 1, 'unknown pseudo-class :hover');
      refused(':', 2, 'expected a pseudo-class');
      refused('p,', 3, 'expected a selector');
      refused('p ]', 3, "expected ',' or the end");
      refused('-p', 1, 'expected a selector');
    });

    test('nest at most as deep as the limit allows', () {
      String nested(int depth, [String pseudo = 'is']) =>
          '${':$pseudo(' * depth}p${')' * depth}';
      expect(Selector.parse(nested(64)), isA<Success<Selector>>());
      // The 65th pseudo-class starts at column 64 * 4 + 1.
      refused(nested(65), 257, 'nesting deeper than 64');
      expect(Selector.parse(nested(2), nesting: 2), isA<Success<Selector>>());
      final shallow = Selector.parse(nested(3), nesting: 2);
      expect(
        (shallow as Failure<Selector>).message,
        'selector: column 9: nesting deeper than 2',
      );
      for (final pseudo in ['not', 'has', 'overlaps', 'crosses']) {
        expect(
          Selector.parse(nested(2, pseudo), nesting: 1),
          isA<Failure<Selector>>(),
          reason: pseudo,
        );
      }
      expect(
        Selector.parse(':nth-child(2):is(:nth-child(1))', nesting: 1),
        isA<Success<Selector>>(),
      );
    });

    test('a deeply nested source is a failure, not a throw', () {
      final result = Selector.parse('${':is(' * 10000}p${')' * 10000}');
      expect(result, isA<Failure<Selector>>());
      expect((result as Failure<Selector>).kind, Kind.syntax);
    });

    test('never throw, and what parses prints back to itself', () {
      const alphabet = 'pab*[]=!^\$~<>"\'\\():, -+019@notisrue';
      for (var seed = 0; seed < 3000; seed++) {
        final random = Random(seed);
        final source = String.fromCharCodes([
          for (var index = random.nextInt(16); index > 0; index--)
            alphabet.codeUnitAt(random.nextInt(alphabet.length)),
        ]);
        final result = Selector.parse(source);
        if (result case Success(value: final selector)) {
          expect(parsed(selector.toString()), selector, reason: source);
        }
      }
    });
  });

  group('selecting', () {
    test('a type selector reads the type attribute', () {
      final scope = [
        (1, tagged(0, 1, attributes: {'name': string('p')})),
        (2, tagged(0, 1, attributes: {'type': string('p')})),
        (3, tagged(0, 1)),
      ];
      expect([for (final (key, _) in parsed('p').select(scope)) key], [1]);
      expect(
        [for (final (key, _) in parsed('p', type: 'type').select(scope)) key],
        [2],
      );
    });

    test('values are typed', () {
      final text = tagged(0, 1, attributes: {'a': string('2')});
      final number = tagged(0, 1, attributes: {'a': const Num(2)});
      final scope = [(0, text), (1, number)];
      List<int> keys(String source) => [
        for (final (key, _) in parsed(source).select(scope)) key,
      ];
      expect(keys('[a=2]'), [1]);
      expect(keys('[a="2"]'), [0]);
      expect(keys('[a<3]'), [1]);
      expect(keys('[a<"3"]'), [0]);
      expect(keys('[a!=2]'), [0]);
    });

    test('keeps the order and keys of the scope', () {
      final scope = [
        ('z', tagged(5, 1, attributes: {'a': const Nil()})),
        ('y', tagged(0, 1)),
        ('x', tagged(2, 1, attributes: {'a': const Bool(true)})),
      ];
      expect(
        [for (final (key, _) in parsed('[a]').select(scope)) key],
        ['z', 'x'],
      );
    });

    test('matches tests one pair, and a missing key is a failure', () {
      final scope = [
        (1, tagged(0, 1, attributes: {'a': const Num(1)})),
        (2, tagged(0, 1)),
      ];
      expect(parsed('[a]').matches(1, scope), const Success(true));
      expect(parsed('[a]').matches(2, scope), const Success(false));
      final missing = parsed('[a]').matches(3, scope);
      expect(missing, isA<Failure<bool>>());
      expect((missing as Failure<bool>).kind, Kind.missing);
    });

    test('every term agrees with a naive model', () {
      final values = <Value>[
        string('p'),
        string('q'),
        string('2'),
        string('px'),
        string('x p y'),
        string(''),
        const Num(1),
        const Num(2),
        const Num(3),
        const Bool(true),
        const Bool(false),
        const Nil(),
      ];
      final literals = {
        '"p"': string('p'),
        '"q"': string('q'),
        '"2"': string('2'),
        '"x"': string('x'),
        '"x p y"': string('x p y'),
        '""': string(''),
        '1': const Num(1),
        '2': const Num(2),
        'true': const Bool(true),
        'null': const Nil(),
      };
      const operators = [
        '=',
        '!=',
        '^=',
        r'$=',
        '*=',
        '~=',
        '<',
        '<=',
        '>',
        '>=',
      ];
      final texts = ['^=', r'$=', '*=', '~='];

      /// Whether [actual], present, holds [operator] against [expected].
      bool holds(Value actual, String operator, Value expected) {
        final (a, b) = (actual, expected);
        String? text(Value value) =>
            value is Str ? String.fromCharCodes(value.value.items) : null;
        final (x, y) = (text(a), text(b));
        int? order() => switch ((a, b)) {
          (Num(value: final p), Num(value: final q)) => p.compareTo(q),
          (Str(), Str()) => x!.compareTo(y!),
          _ => null,
        };
        return switch (operator) {
          '=' => a == b,
          '!=' => a != b,
          '^=' => x != null && x.startsWith(y!),
          r'$=' => x != null && x.endsWith(y!),
          '*=' => x != null && x.contains(y!),
          '~=' => x != null && x.split(RegExp(r'[ \t\n\r\f]+')).contains(y!),
          '<' => (order() ?? 0) < 0 && order() != null,
          '<=' => order() != null && order()! <= 0,
          '>' => order() != null && order()! > 0,
          _ => order() != null && order()! >= 0,
        };
      }

      final random = Random(7);

      /// A random compound, as source and as a model over a range, nesting
      /// `:not` and `:is` up to [depth] deep.
      late final (String, bool Function(ARange)) Function(int depth) compound;

      /// A random condition or pseudo-class, as source and model.
      (String, bool Function(ARange)) condition(int depth) {
        switch (random.nextInt(depth > 0 ? 4 : 2)) {
          case 0:
            final name = ['a', 'b'][random.nextInt(2)];
            return ('[$name]', (range) => range.has(name));
          case 1:
            final name = ['a', 'b', 'name'][random.nextInt(3)];
            final operator = operators[random.nextInt(operators.length)];
            final pool = texts.contains(operator)
                ? literals.entries.where((entry) => entry.value is Str)
                : literals.entries;
            final MapEntry(key: literal, value: expected) = pool.elementAt(
              random.nextInt(pool.length),
            );
            return (
              '[$name$operator$literal]',
              (range) => switch (range.get(name)) {
                final actual? => holds(actual, operator, expected),
                null => false,
              },
            );
          case 2:
            final (source, model) = compound(depth - 1);
            return (':not($source)', (range) => !model(range));
          default:
            final (first, one) = compound(depth - 1);
            final (second, other) = compound(depth - 1);
            return (
              ':is($first, $second)',
              (range) => one(range) || other(range),
            );
        }
      }

      compound = (depth) {
        final parts = <(String, bool Function(ARange))>[
          switch (random.nextInt(3)) {
            0 => ('*', (_) => true),
            1 => ('p', (range) => range.get('name') == string('p')),
            _ => ('', (_) => true),
          },
          for (var count = random.nextInt(3); count > 0; count--)
            condition(depth),
        ];
        if (parts.length == 1 && parts.first.$1.isEmpty) {
          parts.add(condition(depth));
        }
        return (
          parts.map((part) => part.$1).join(),
          (range) => parts.every((part) => part.$2(range)),
        );
      };

      for (var round = 0; round < 400; round++) {
        final scope = [
          for (var index = 0; index < 20; index++)
            (
              index,
              tagged(
                index,
                1,
                attributes: {
                  for (final name in ['name', 'a', 'b'])
                    if (random.nextInt(3) > 0)
                      name: values[random.nextInt(values.length)],
                },
              ),
            ),
        ];
        final (source, model) = compound(2);
        expect(
          [for (final (key, _) in parsed(source).select(scope)) key],
          [
            for (final (key, range) in scope)
              if (model(range)) key,
          ],
          reason: source,
        );
      }
    });
  });

  test('*= and ~= agree with a naive search over 2,000 seeded texts', () {
    final random = Random(17);
    // Mostly a, so prefixes repeat and a naive search backs up often.
    String text(int length) => String.fromCharCodes([
      for (var index = 0; index < length; index++)
        'aaaab '.codeUnitAt(random.nextInt(6)),
    ]);
    for (var round = 0; round < 2000; round++) {
      final value = text(random.nextInt(40));
      final part = text(random.nextInt(7));
      final scope = [
        (0, tagged(0, 0, attributes: {'v': Str(Text.of(value))})),
      ];
      final words = value.split(' ');
      for (final (operator, expected) in [
        ('*=', value.contains(part)),
        ('~=', part.isNotEmpty && !part.contains(' ') && words.contains(part)),
      ]) {
        final selector = Selector.parse('[v$operator"$part"]').unwrap();
        expect(
          selector.select(scope).isNotEmpty,
          expected,
          reason: '"$value" $operator "$part"',
        );
      }
    }
  });
}
