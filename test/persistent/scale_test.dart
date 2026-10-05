@Tags(['scale'])
library;

import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/constructor/constructor.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/persistent/document.dart';
import 'package:libara/src/persistent/endpoints.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'html.dart';

/// A generated document with every element and tag marked.
final class Marked {
  Marked(this.html) {
    final watch = Stopwatch()..start();
    var built = Document.of(Text.of(html.text));
    final sorted = [...html.elements]
      ..sort((a, b) => a.start.compareTo(b.start));
    for (final element in sorted) {
      // Elements grow with edits inside them; tags never absorb an edit.
      final whole = Mark<int>(
        tagged(
          element.start,
          element.end - element.start,
          attributes: {'name': Value.of(element.name).unwrap()},
        ),
      );
      final open = Mark<int>(
        tagged(element.start, element.open),
        end: Gravity.left,
      );
      final close = Mark<int>(
        tagged(element.end - element.close, element.close),
        end: Gravity.left,
      );
      for (final mark in [whole, open, close]) {
        built = built.apply(mark).or(built);
      }
      marks.add((element, whole, open, close));
    }
    document = built;
    build = watch.elapsedMicroseconds;
  }

  final Html html;
  final marks = <(Element, Mark<int>, Mark<int>, Mark<int>)>[];
  late final Document<int> document;
  late final int build;

  int get ranges => marks.length * 3;

  /// The deepest element of the nested chain.
  Element get deepest =>
      html.elements.reduce((a, b) => a.depth >= b.depth ? a : b);
}

/// The median time in microseconds of [rounds] calls of [action], after as
/// many calls to warm up.
int median(int rounds, void Function(int round) action) {
  for (var round = 0; round < rounds; round++) {
    action(round);
  }
  final times = <int>[];
  final watch = Stopwatch();
  for (var round = 0; round < rounds; round++) {
    watch
      ..reset()
      ..start();
    action(round);
    watch.stop();
    times.add(watch.elapsedMicroseconds);
  }
  times.sort();
  return times[times.length ~/ 2];
}

/// Where a position ends up after inserting [count] items at [at], for the
/// given gravity.
int shifted(int position, int at, int count, Gravity gravity) =>
    position > at || position == at && gravity == Gravity.right
    ? position + count
    : position;

void main() {
  final small = Marked(Html.generate(seed: 1, target: 10000));
  final large = Marked(Html.generate(seed: 2, target: 100000));
  final report = <String>[];

  tearDownAll(() {
    // Printed so the measurements are visible when the tests are run.
    print(report.join('\n'));
  });

  for (final (name, marked) in [('10k', small), ('100k', large)]) {
    group('$name elements', () {
      test('every marker resolves to its generated span', () {
        final document = marked.document;
        expect(document.ranges.length, marked.ranges);
        for (final (element, whole, open, close) in marked.marks) {
          expect(
            document
                .resolve(whole.marker)!
                .same(span(element.start, element.end - element.start)),
            isTrue,
          );
          expect(
            document
                .resolve(open.marker)!
                .same(span(element.start, element.open)),
            isTrue,
          );
          expect(
            document
                .resolve(close.marker)!
                .same(span(element.end - element.close, element.close)),
            isTrue,
          );
        }
        final average = marked.build / marked.ranges;
        report.add(
          '$name: ${marked.html.text.length} chars, ${marked.ranges} ranges, '
          'marked in ${marked.build ~/ 1000}ms (${average.toStringAsFixed(1)}us per range)',
        );
        expect(average, lessThan(100));
      });

      test('one insertion moves every range correctly', () {
        final document = marked.document;
        final at = marked.deepest.start + marked.deepest.open;
        final after = document.apply(Insert(at, Text.of('xyz'))).or(document);
        for (final (_, whole, open, close) in marked.marks) {
          for (final (mark, end) in [
            (whole, Gravity.right),
            (open, Gravity.left),
            (close, Gravity.left),
          ]) {
            final before = document.resolve(mark.marker)!;
            final moved = after.resolve(mark.marker)!;
            expect(moved.start, shifted(before.start, at, 3, Gravity.right));
            expect(
              moved.end,
              max(moved.start, shifted(before.end, at, 3, end)),
            );
          }
        }
      });

      test('edits stay fast', () {
        final document = marked.document;
        final length = document.length;
        final deep = marked.deepest.start + marked.deepest.open;
        final middle = marked.html.elements[marked.html.elements.length ~/ 2];
        final times = {
          'insert at front': median(
            200,
            (_) => document.apply(Insert(0, Text.of('x'))),
          ),
          'insert in middle': median(
            200,
            (_) => document.apply(Insert(length ~/ 2, Text.of('x'))),
          ),
          'insert in deepest element': median(
            200,
            (_) => document.apply(Insert(deep, Text.of('x'))),
          ),
          'delete an element': median(
            200,
            (_) => document.apply(
              Delete<int>(span(middle.start, middle.end - middle.start)),
            ),
          ),
        };
        for (final MapEntry(key: edit, value: time) in times.entries) {
          report.add('$name: $edit median ${time}us');
          expect(time, lessThan(1000), reason: edit);
        }
      });

      test('typing 1,000 coalesced keystrokes in the deepest element', () {
        final deepest = marked.marks.firstWhere(
          (entry) => identical(entry.$1, marked.deepest),
        );
        var document = marked.document
            .apply(Insert(0, Text.of('')))
            .or(marked.document);
        final version = document.version;
        var at = document.resolve(deepest.$3.marker)!.end;
        final watch = Stopwatch()..start();
        for (var key = 0; key < 1000; key++) {
          document = document
              .apply(Insert(at, Text.of('k')), flatten: true)
              .or(document);
          at++;
        }
        final each = watch.elapsedMicroseconds / 1000;
        report.add('$name: typing ${each.toStringAsFixed(1)}us per keystroke');
        expect(document.version, version);
        final element = document.resolve(deepest.$2.marker)!;
        expect(
          element.length,
          marked.deepest.end - marked.deepest.start + 1000,
        );
        expect(
          document.resolve(deepest.$3.marker)!.length,
          marked.deepest.open,
        );
        expect(each, lessThan(1000));
      });

      test('at finds every enclosing element of the deepest text', () {
        final document = marked.document;
        final position = marked.deepest.start + marked.deepest.open;
        final expected = [
          for (final element in marked.html.elements)
            if (element.start <= position && position < element.end) element,
        ];
        final found = document.at(position);
        final elements = found.items
            .cast<ARange>()
            .where((range) => range.has('name'))
            .length;
        expect(elements, expected.length);
        expect(elements, greaterThan(500));
        final time = median(20, (_) => document.at(position));
        final resolve = median(
          200,
          (round) => document.resolve(
            marked.marks[round * 37 % marked.marks.length].$2.marker,
          ),
        );
        report.add(
          '$name: at() over ${found.length} hits median ${time}us, resolve median ${resolve}us',
        );
      });

      test('a 100-item viewport query costs about a point query', () {
        final document = marked.document;
        final position = marked.deepest.start + marked.deepest.open;
        final viewport = span(position, 100);
        final found = document.overlapping(viewport);
        final expected = [
          for (final range in document.ranges.items)
            if (range.overlaps(viewport)) range,
        ];
        expect(found.items, unorderedEquals(expected));
        final point = median(20, (_) => document.at(position));
        final time = median(20, (_) => document.overlapping(viewport));
        report.add(
          '$name: overlapping() over ${found.length} hits median ${time}us, '
          'at() ${point}us',
        );
        expect(time, lessThan(2 * max(1, point)));
      });

      test('marking every range in one transaction matches one by one', () {
        final commands = [
          for (final (_, whole, open, close) in marked.marks) ...[
            whole,
            open,
            close,
          ],
        ];
        final watch = Stopwatch()..start();
        final bulk = Document.of(Text.of(marked.html.text))
            .transact(commands)
            .unwrap();
        final time = watch.elapsedMicroseconds;
        expect(bulk.ranges, marked.document.ranges);
        for (var index = 0; index < commands.length; index += 97) {
          final marker = commands[index].marker;
          expect(bulk.resolve(marker), marked.document.resolve(marker));
        }
        expect(check(bulk), const Success<void>(null));
        report.add(
          '$name: marked in one transaction in ${time ~/ 1000}ms, '
          'against ${marked.build ~/ 1000}ms one by one',
        );
        expect(time, lessThan(marked.build));
      });

      test('endpoint labels stay short', () {
        var tree = const Endpoints<Object>.empty();
        final sorted = [...marked.html.elements]
          ..sort((a, b) => a.start.compareTo(b.start));
        for (final element in sorted) {
          (tree, _, _) = tree
              .add(Object(), element.start, element.end)
              .unwrap();
        }
        final lengths = [
          for (final entry in tree.entries) entry.label.digits.length,
        ]..sort();
        report.add(
          '$name: label digits median ${lengths[lengths.length ~/ 2]}, max ${lengths.last}',
        );
        // Labels grow with nesting depth, not document size; the deep chain
        // is 500 levels.
        expect(lengths[lengths.length ~/ 2], lessThan(16));
        expect(lengths.last, lessThan(256));
      });

      test('constructors find every tag and rebuild every element', () {
        final text = Text.of(marked.html.text);
        final watch = Stopwatch()..start();
        final tokens = union([
          regex(
            RegExp('<[a-z]+>'),
            attributes: {'type': Value.of('stag').unwrap()},
          ),
          regex(
            RegExp('</[a-z]+>'),
            attributes: {'type': Value.of('etag').unwrap()},
          ),
        ]);
        Ranges pair(Ranges found) {
          final open = <int>[];
          final elements = <Range>[];
          for (final (index, token) in found.items.cast<ARange>().indexed) {
            if (token.get('type') == Value.of('stag').unwrap()) {
              open.add(index);
            } else {
              final start = open.removeLast();
              elements.add(span(start, index - start + 1));
            }
          }
          return Ranges.of(elements);
        }

        final elements = layer(tokens, pair)(text).or(Ranges.empty());
        report.add(
          '$name: constructors found ${elements.length} elements in ${watch.elapsedMilliseconds}ms',
        );
        expect(elements.length, marked.html.elements.length);
      });
    });
  }

  test('edit time grows with the log of the size, not linearly', () {
    int time(Marked marked) =>
        median(400, (_) => marked.document.apply(Insert(0, Text.of('x'))));
    final ratio = time(large) / max(1, time(small));
    report.add(
      'insert at front, 100k over 10k elements: ${ratio.toStringAsFixed(2)}x',
    );
    // Ten times the ranges would cost ten times as much if shifting were
    // linear.
    expect(ratio, lessThan(4));
  });
}
