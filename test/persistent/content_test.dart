import 'dart:math';

import 'package:libara/src/persistent/content.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

void main() {
  group('Content queries', () {
    test('empty has no items', () {
      final content = Content<int>.empty();
      expect(content.length, 0);
      expect(content.items, isEmpty);
      expect(content.item(0), isNull);
    });

    test('of keeps order across many chunks', () {
      final source = List.generate(1000, (index) => index);
      final content = Content.of(source);
      expect(content.length, 1000);
      expect(content.items, source);
    });

    test('item finds every position and is null outside', () {
      final source = List.generate(300, (index) => index * 2);
      final content = Content.of(source);
      for (var position = 0; position < source.length; position++) {
        expect(content.item(position), source[position]);
      }
      expect(content.item(-1), isNull);
      expect(content.item(300), isNull);
    });

    test('slice clamps exactly like Items.slice', () {
      final random = Random(3);
      final source = List.generate(200, (index) => index);
      final content = Content.of(source);
      final items = Items.of(source);
      for (var round = 0; round < 500; round++) {
        final start = random.nextInt(260) - 30;
        final length = random.nextInt(120);
        expect(
          content.slice(start, length),
          items.slice(start, length).items,
          reason: 'slice($start, $length)',
        );
      }
    });
  });

  group('Content edits', () {
    test('insertAll places items at the position', () {
      final content = Content.of([1, 4]).insertAll(1, [2, 3]);
      expect(content.or(Content.empty()).items, [1, 2, 3, 4]);
    });

    test('insertAll at the length appends', () {
      final content = Content.of([1]).insertAll(1, [2]);
      expect(content.or(Content.empty()).items, [1, 2]);
    });

    test('insertAll outside the content is a bounds failure', () {
      expect(
        Content.of([1]).insertAll(2, [9]),
        Failure<Content<int>>.bounds('insert', 2),
      );
      expect(
        Content.of([1]).insertAll(-1, [9]),
        Failure<Content<int>>.bounds('insert', -1),
      );
    });

    test('deleteAll removes the span', () {
      final content = Content.of([0, 1, 2, 3, 4]).deleteAll(span(1, 3));
      expect(content.or(Content.empty()).items, [0, 4]);
    });

    test('deleteAll past the end is a bounds failure', () {
      expect(
        Content.of([0, 1, 2]).deleteAll(span(2, 2)),
        Failure<Content<int>>.bounds('delete', 4),
      );
    });

    test('earlier content is unchanged by ten further edits', () {
      final original = Content.of(List.generate(200, (index) => index));
      var content = original;
      for (var round = 0; round < 10; round++) {
        content = content.insertAll(round * 7, [-round]).or(content);
        content = content.deleteAll(span(round * 3, 2)).or(content);
      }
      expect(original.items, List.generate(200, (index) => index));
      expect(content.items, isNot(original.items));
    });
  });

  group('small inserts fill neighbouring chunks', () {
    test('10,000 single appends use one node per full chunk', () {
      var content = const Content<int>.empty();
      for (var index = 0; index < 10000; index++) {
        content = content.insertAll(index, [index]).unwrap();
      }
      expect(content.items, List.generate(10000, (index) => index));
      expect(content.nodes, lessThanOrEqualTo((10000 / 32).ceil()));
      expect(content.check(), const Success<void>(null));
    });

    test('an insert inside a chunk with room adds no node', () {
      final content = Content.of(List.generate(10, (index) => index));
      final inserted = content.insertAll(4, [-1, -2]).unwrap();
      expect(inserted.items, [0, 1, 2, 3, -1, -2, 4, 5, 6, 7, 8, 9]);
      expect(inserted.nodes, content.nodes);
    });

    test('an insert too large for the chunk still splits', () {
      final content = Content.of(List.generate(60, (index) => index));
      final added = List.generate(10, (index) => -index);
      final inserted = content.insertAll(30, added).unwrap();
      expect(inserted.items, [
        ...List.generate(30, (index) => index),
        ...added,
        ...List.generate(30, (index) => index + 30),
      ]);
      expect(inserted.check(), const Success<void>(null));
    });
  });

  test('agrees with Items over 200 seeded random scripts', () {
    final random = Random(42);
    for (var script = 0; script < 200; script++) {
      final start = List.generate(
        random.nextInt(150),
        (_) => random.nextInt(1000),
      );
      var content = Content.of(start);
      var model = Items.of(start);
      for (var step = 0; step < 40; step++) {
        if (model.length > 0 && random.nextBool()) {
          final from = random.nextInt(model.length);
          final count = 1 + random.nextInt(min(10, model.length - from));
          content = content.deleteAll(span(from, count)).or(content);
          model = Items.of([
            ...model.items.take(from),
            ...model.items.skip(from + count),
          ]);
        } else {
          final at = random.nextInt(model.length + 1);
          final added = List.generate(
            1 + random.nextInt(80),
            (_) => random.nextInt(1000),
          );
          content = content.insertAll(at, added).or(content);
          model = Items.of([
            ...model.items.take(at),
            ...added,
            ...model.items.skip(at),
          ]);
        }
        expect(
          content.length,
          model.length,
          reason: 'script $script step $step',
        );
        expect(content.items, model.items, reason: 'script $script step $step');
        expect(
          content.check(),
          const Success<void>(null),
          reason: 'script $script step $step',
        );
      }
    }
  });
}
