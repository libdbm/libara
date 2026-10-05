@TestOn('vm')
library;

import 'dart:convert';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/format/format.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

/// The largest native integer; this file runs only on the VM.
const maximum = 9223372036854775807;

/// A range whose end wraps below its start, as only a subclass can hold.
final class Wrapping extends Range {
  const Wrapping();

  @override
  int get start => maximum;

  @override
  int get length => 1;
}

void main() {
  test('slice clamps a length that would wrap past the end', () {
    expect(Items.of([1, 2, 3]).slice(1, maximum).items, [2, 3]);
    expect(Text.of('abc').slice(1, maximum), Text.of('bc'));
    expect(Document.of(Items.of([1, 2, 3])).slice(1, maximum).items, [2, 3]);
    expect(Items.of([1, 2, 3]).slice(maximum, maximum).items, isEmpty);
  });

  test('create fails when the end would wrap', () {
    expect(Range.create(maximum, 1), invalid);
    expect(ARange.create(maximum, 1), invalid);
    expect(Range.create(maximum, 0).unwrap().end, maximum);
    expect(Range.create(maximum - 1, 1).unwrap().end, maximum);
  });

  test('move and resize fail when the start, length, or end would wrap', () {
    expect(span(maximum - 1, 0).move(2), isA<Failure<Range>>());
    expect(span(1, maximum - 1).move(1), isA<Failure<Range>>());
    expect(span(1, maximum - 1).resize(1), isA<Failure<Range>>());
    expect(span(0, maximum).resize(1), isA<Failure<Range>>());
  });

  test('edits with a wrapping span are bounds failures', () {
    final document = Document.of(Text.of('abc'));
    const wrapping = Wrapping();
    expect(document.apply(Delete<int>(wrapping)), isA<Failure<Object?>>());
    expect(
      document.apply(Replace(wrapping, Text.of('x'))),
      isA<Failure<Object?>>(),
    );
    expect(
      document.apply(Mark<int>(ARange.from(wrapping, const {}))),
      isA<Failure<Object?>>(),
    );
  });

  test('loading a saved range that would wrap fails', () {
    final document = Document.of(Text.of('abc'))
        .apply(Mark<int>(tagged(0, 1)))
        .unwrap();
    final saved = jsonDecode(
      jsonEncode(JSONFormat(text).encode(document).unwrap()),
    ) as Map<String, Object?>;
    ((saved['markers']! as List).first as Map<String, Object?>)['range'] = [
      maximum,
      1,
    ];
    expect(JSONFormat(text).decode(saved), invalid);
  });
}
