/// Layered benchmarks: keystroke time in the XML example along two axes,
/// the number of elements at a fixed nesting depth and the nesting depth
/// at a fixed number of elements, always typing into an element of fixed
/// size; a long typing session; and `extent` against depth, over a chain
/// of single ranges and over ranges shared between layers.
///
/// Library time is a keystroke's time less the grammar's, measured by
/// [Timed]. The budget the test checks is for library time.
///
/// Baseline at `5e45cf6`, local JIT, median per keystroke:
///
/// | Case | Total | Grammar | Library |
/// |---|---|---|---|
/// | 1,000 elements, depth 2 | 5.7ms | 3.6ms | 2.1ms |
/// | 10,000 elements, depth 2 | 115.7ms | 67.7ms | 48.4ms |
/// | 30,000 elements, depth 2 | 399.0ms | 262.9ms | 143.1ms |
/// | 1,000 elements, depth 8 | 5.9ms | 3.7ms | 2.2ms |
/// | 1,000 elements, depth 32 | 6.1ms | 3.9ms | 2.2ms |
///
/// The session of 3,000 keystrokes into one text run of 200 elements took
/// about 1ms per keystroke throughout, with no growth from label length.
///
/// After local re-derivation, library time was about 0.1ms per keystroke
/// in every case, from 1,000 to 30,000 elements and from depth 2 to 32,
/// and the XML grammar's under 0.1ms.
@Tags(['benchmark'])
library;

import 'dart:math';

import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/layered/layered.dart';
import 'package:libara/src/persistent/command.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../../example/xml/xml.dart';
import '../support.dart';

/// Markup for [count] elements, the middle one of them inside [depth]
/// nested elements, with `@` marking where to type.
///
/// Every element but the nesting ones is `<p>text</p>`, so the element
/// typed into is the same size whatever the count and depth.
String markup(int count, int depth) {
  final buffer = StringBuffer('<doc>');
  for (var index = 0; index < count; index++) {
    if (index == count ~/ 2) {
      buffer
        ..write('<n>' * depth)
        ..write('<p>te@xt</p>')
        ..write('</n>' * depth);
    } else {
      buffer.write('<p>text $index</p>');
    }
  }
  buffer.write('</doc>');
  return buffer.toString();
}

/// Median library and grammar time, in microseconds, of [rounds]
/// keystrokes typed one after another where [source] has `@`, after
/// [warm] keystrokes of warm-up.
({int total, int grammar, int library}) keystrokes(
  String source, {
  int warm = 5,
  int rounds = 15,
}) {
  final at = source.indexOf('@');
  final grammar = Timed();
  var document = Layered.of(
    Text.of(source.replaceFirst('@', '')),
    grammar,
  ).unwrap();
  final watch = Stopwatch();
  final totals = <int>[];
  final grammars = <int>[];
  for (var round = 0; round < warm + rounds; round++) {
    grammar.watch.reset();
    watch
      ..reset()
      ..start();
    document = document
        .apply(Edit(1, Insert(at + round, Text.of('x'))))
        .unwrap()
        .document;
    watch.stop();
    if (round >= warm) {
      totals.add(watch.elapsedMicroseconds);
      grammars.add(grammar.watch.elapsedMicroseconds);
    }
  }
  int median(List<int> values) => (values.toList()..sort())[values.length ~/ 2];
  final libraries = [
    for (var index = 0; index < totals.length; index++)
      totals[index] - grammars[index],
  ];
  return (
    total: median(totals),
    grammar: median(grammars),
    library: median(libraries),
  );
}

/// [time] as milliseconds for a report.
String ms(int time) => '${(time / 1000).toStringAsFixed(1)}ms';

void main() {
  test('keystroke time against the number of elements', () {
    final times = {
      for (final count in [1000, 10000, 30000])
        count: keystrokes(markup(count, 2)),
    };
    for (final MapEntry(key: count, value: time) in times.entries) {
      print(
        '$count elements, depth 2: total ${ms(time.total)}, '
        'grammar ${ms(time.grammar)}, library ${ms(time.library)}',
      );
    }
    // The budget: at most 2ms at 10,000 elements, and
    // no growth from 1,000 to 30,000 beyond 1.5x; a floor of 200us keeps
    // timer noise out of the ratio.
    expect(times[10000]!.library, lessThan(2000));
    expect(
      times[30000]!.library,
      lessThan(1.5 * max(200, times[1000]!.library)),
    );
    // The XML grammar reads only the regions an edit affects, so its time
    // stays flat; a floor of 100us keeps timer noise out.
    expect(times[30000]!.grammar, lessThan(5 * max(100, times[1000]!.grammar)));
  });

  test('keystroke time against nesting depth', () {
    final times = {
      for (final depth in [2, 8, 32]) depth: keystrokes(markup(1000, depth)),
    };
    for (final MapEntry(key: depth, value: time) in times.entries) {
      print(
        '1000 elements, depth $depth: total ${ms(time.total)}, '
        'grammar ${ms(time.grammar)}, library ${ms(time.library)}',
      );
    }
    // At most linear in depth, 16 times the depth from 2 to 32, and within
    // a few milliseconds; a floor of 200us keeps timer noise out.
    expect(times[32]!.library, lessThan(16 * max(200, times[2]!.library)));
    expect(times[32]!.library, lessThan(3000));
  });

  test('identical ranges are matched in time linear in their number', () {
    /// Microseconds to type one item into text holding [count] identical
    /// ranges, all derived again.
    int time(int count) {
      var document = Layered.of(Text.of('ab'), Copies(count)).unwrap();
      final watch = Stopwatch();
      final times = <int>[];
      for (var round = 0; round < 7; round++) {
        watch
          ..reset()
          ..start();
        document = document
            .apply(Edit(1, Insert(1, Text.of('x'))))
            .unwrap()
            .document;
        watch.stop();
        times.add(watch.elapsedMicroseconds);
      }
      return (times..sort())[times.length ~/ 2];
    }

    final (small, large) = (time(2000), time(16000));
    print('identical ranges, 2,000: ${ms(small)}, 16,000: ${ms(large)}');
    // Linear is 8 times; taking matches from the front of a list was more.
    expect(large, lessThan(12 * small));
  });

  test('new ranges among kept ones are spliced in time linear in their '
      'number', () {
    /// Microseconds to splice [count] new ranges into a run of [count] kept
    /// ones, one before each: the reconciliation step after the grammar has
    /// answered, without the marking around it.
    int time(int count) {
      final run = [
        for (var index = 0; index < count; index++)
          (Marker(), tagged(index, 1)),
      ];
      final wanted = [
        for (var index = 0; index < count; index++) ...[
          tagged(index, 0),
          tagged(index, 1),
        ],
      ];
      final matched = [
        for (var index = 0; index < count; index++) ...[null, index],
      ];
      final created = [for (var index = 0; index < count; index++) Marker()];
      final watch = Stopwatch();
      final times = <int>[];
      for (var round = 0; round < 7; round++) {
        watch
          ..reset()
          ..start();
        spliced(run, wanted, matched, const {}, created, span(0, count), 0);
        watch.stop();
        times.add(watch.elapsedMicroseconds);
      }
      return (times..sort())[times.length ~/ 2];
    }

    time(4000);
    final (small, large) = (time(4000), time(32000));
    print('spliced among kept, 4,000: ${ms(small)}, 32,000: ${ms(large)}');
    // Linear is 8 times; inserting each new range into the list of kept
    // ones was about 56.
    expect(large, lessThan(12 * max(200, small)));
  });

  test('a structural edit settles duplicate ranges in time near linear in '
      'their number', () {
    /// Microseconds for one structural edit over [count] ranges at one
    /// position, removing half of them, updating the rest, and creating as
    /// many again, each at a position of its own.
    int time(int count) {
      final grammar = Bulk(count);
      final document = Layered.of(Text.of('a' * count), grammar).unwrap();
      final edit = Edit<int>(
        2,
        Update<Object?>(document.markers(2).first.$1, {'n': const Num(1)}),
      );
      final watch = Stopwatch();
      final times = <int>[];
      for (var round = 0; round < 5; round++) {
        watch
          ..reset()
          ..start();
        document.apply(edit).unwrap();
        watch.stop();
        times.add(watch.elapsedMicroseconds);
      }
      return (times..sort())[times.length ~/ 2];
    }

    time(2000);
    final (small, large) = (time(2000), time(16000));
    print('settled duplicates, 2,000: ${ms(small)}, 16,000: ${ms(large)}');
    // Linear is 8 times and n log n about 10; scanning duplicates,
    // removals, and placements for each range was about 44.
    expect(large, lessThan(16 * small));
  });

  test('diagnostics away from an edit cost it nothing', () {
    /// Microseconds to type into an element before [count] diagnostics,
    /// none touching it or each other.
    int time(int count) {
      var document = Layered.of(
        Text.of('<p>text</p>${'<!x><b/>' * count}'),
        XML(),
      ).unwrap();
      final watch = Stopwatch();
      final times = <int>[];
      for (var round = 0; round < 9; round++) {
        watch
          ..reset()
          ..start();
        document = document
            .apply(Edit(1, Insert(5, Text.of('x'))))
            .unwrap()
            .document;
        watch.stop();
        times.add(watch.elapsedMicroseconds);
      }
      return (times..sort())[times.length ~/ 2];
    }

    time(1000);
    final (small, large) = (time(1000), time(8000));
    print('distant diagnostics, 1,000: ${ms(small)}, 8,000: ${ms(large)}');
    // Flat; checking every diagnostic on each edit was linear in them.
    expect(large, lessThan(2 * max(200, small)));
  });

  test('a chain of touching diagnostics is widened over in time linear in '
      'its length', () {
    /// Microseconds to type into the first of [count] diagnostics, each
    /// touching the next, so the region widens over all of them.
    int time(int count) {
      var document = Layered.of(
        Text.of('<p>t</p>${'<!x>' * count}'),
        XML(),
      ).unwrap();
      final watch = Stopwatch();
      final times = <int>[];
      for (var round = 0; round < 5; round++) {
        watch
          ..reset()
          ..start();
        document = document
            .apply(Edit(1, Insert(10, Text.of('y'))))
            .unwrap()
            .document;
        watch.stop();
        times.add(watch.elapsedMicroseconds);
      }
      return (times..sort())[times.length ~/ 2];
    }

    time(1000);
    final (small, large) = (time(1000), time(8000));
    print('chained diagnostics, 1,000: ${ms(small)}, 8,000: ${ms(large)}');
    // Linear is 8 times; checking every diagnostic in every widening round
    // was quadratic.
    expect(large, lessThan(12 * small));
  });

  test('a transaction maps its regions in time linear in its edits', () {
    /// Milliseconds for one transaction of [count] keystrokes.
    int time(int count) {
      final document = Layered.of(
        Text.of('<a><p>text</p></a>'),
        XML(),
      ).unwrap();
      final edits = [
        for (var index = 0; index < count; index++)
          Edit<int>(1, Insert(7, Text.of('x'))),
      ];
      final watch = Stopwatch()..start();
      document.transact(edits).unwrap();
      return watch.elapsedMilliseconds;
    }

    time(500);
    final (small, large) = (time(250), time(2000));
    print('transaction of 250 edits: ${small}ms, of 2,000: ${large}ms');
    // Linear is 8 times; carrying each region through every later
    // command was about 64.
    expect(large, lessThan(16 * max(10, small)));
  });

  test('a transaction gathers its changes in time linear in its edits', () {
    /// Milliseconds for one transaction of [count] edits that type a
    /// character and delete it again, so the document keeps its size and
    /// each edit costs the same.
    int time(int count) {
      final document = Layered.of(
        Text.of('<a><p>text</p></a>'),
        XML(),
      ).unwrap();
      final edits = [
        for (var index = 0; index < count; index++)
          index.isEven
              ? Edit<int>(1, Insert(7, Text.of('x')))
              : Edit<int>(1, Delete<int>(span(7, 1))),
      ];
      final watch = Stopwatch()..start();
      document.transact(edits).unwrap();
      return watch.elapsedMilliseconds;
    }

    time(2000);
    final (small, large) = (time(2000), time(16000));
    print('transaction of 2,000 edits: ${small}ms, of 16,000: ${large}ms');
    // Linear is 8 times; copying every change gathered so far for each edit
    // was about 18.
    expect(large, lessThan(12 * max(10, small)));
  });

  test('a long typing session does not slow down', () {
    final source = markup(200, 2);
    final at = source.indexOf('@');
    var document = Layered.of(
      Text.of(source.replaceFirst('@', '')),
      XML(),
    ).unwrap();
    final watch = Stopwatch();
    final rounds = <int>[];
    for (var round = 0; round < 6; round++) {
      watch
        ..reset()
        ..start();
      for (var index = 0; index < 500; index++) {
        document = document
            .apply(Edit(1, Insert(at, Text.of('x'))))
            .unwrap()
            .document;
      }
      watch.stop();
      rounds.add(watch.elapsedMicroseconds ~/ 500);
    }
    print('per keystroke, each 500 of 3,000: ${rounds.map(ms).join(', ')}');
    expect(rounds.last, lessThan(3 * rounds[1]));
  });

  test('extent of a range covering one item is linear in depth', () {
    final shallow = projection(
      Layered.of(Text.of('a'), Chain(10)).unwrap(),
      10,
    );
    final deep = projection(Layered.of(Text.of('a'), Chain(20)).unwrap(), 20);
    printOnFailure('depth 10: $shallow us, depth 20: $deep us');
    // Linear in depth doubles the time; the doubled recursion multiplied it
    // by about 1,000.
    expect(deep, lessThan(10 * (shallow < 1 ? 1 : shallow)));
  });

  test('extent of ranges shared between layers is linear in depth', () {
    final document = Layered.of(Text.of('ab'), Diamond(20)).unwrap();
    expect(document.extent(20, document.markers(20).first.$1), span(0, 2));
    final shallow = projection(
      Layered.of(Text.of('ab'), Diamond(10)).unwrap(),
      10,
    );
    final deep = projection(document, 20);
    printOnFailure('depth 10: $shallow us, depth 20: $deep us');
    // Each layer's two ranges cover the same two below, so projecting each
    // once is linear in depth, and projecting each path is exponential.
    expect(deep, lessThan(10 * (shallow < 1 ? 1 : shallow)));
  });
}

/// The median time, in microseconds, to project the first range of layer
/// [depth] of [document].
double projection(Layered<int> document, int depth) {
  final (marker, _) = document.markers(depth).first;
  for (var round = 0; round < 100; round++) {
    document.extent(depth, marker);
  }
  final watch = Stopwatch();
  final times = <int>[];
  for (var round = 0; round < 200; round++) {
    watch
      ..reset()
      ..start();
    document.extent(depth, marker);
    watch.stop();
    times.add(watch.elapsedMicroseconds);
  }
  times.sort();
  return times[times.length ~/ 2].toDouble();
}

/// A grammar of [depth] layers over one item: every layer above the first
/// holds one range over the single item below it.
final class Chain implements Grammar<int> {
  /// A chain of [depth] layers.
  Chain(this.depth);

  @override
  final int depth;

  @override
  Derived derive(Layered<int> document, int layer, Range region) => (
    ranges: region.length == 1 ? [tagged(0, 1)] : const [],
    diagnostics: const [],
  );

  @override
  Range affected(Layered<int> document, int layer, Range changed) => span(0, 1);

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) =>
      Failure(Kind.invalid, 'chain: no structural edits');

  /// Every range is markup, so only an edit changing none is valid.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      kept(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}

/// A grammar of [depth] layers over two items: every layer above the first
/// holds two identical ranges, each over both items below it.
final class Diamond implements Grammar<int> {
  /// A diamond of [depth] layers.
  Diamond(this.depth);

  @override
  final int depth;

  @override
  Derived derive(Layered<int> document, int layer, Range region) => (
    ranges: region.length == 2 ? [tagged(0, 2), tagged(0, 2)] : const [],
    diagnostics: const [],
  );

  @override
  Range affected(Layered<int> document, int layer, Range changed) => span(0, 2);

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) =>
      Failure(Kind.invalid, 'diamond: no structural edits');

  /// Every range is markup, so only an edit changing none is valid.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      kept(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}

/// The XML grammar, with the time spent in it measured by [watch].
final class Timed implements Grammar<int> {
  /// Measures the time spent in its grammar calls.
  final Stopwatch watch = Stopwatch();

  static const _xml = XML();

  /// [call], timed.
  R _timed<R>(R Function() call) {
    watch.start();
    try {
      return call();
    } finally {
      watch.stop();
    }
  }

  @override
  int get depth => _xml.depth;

  @override
  Derived derive(Layered<int> document, int layer, Range region) =>
      _timed(() => _xml.derive(document, layer, region));

  @override
  Range affected(Layered<int> document, int layer, Range changed) =>
      _timed(() => _xml.affected(document, layer, changed));

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) =>
      _timed(() => _xml.edit(document, change));

  /// As the XML grammar decides.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      _xml.valid(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}

/// A grammar of depth 2 whose layer 2 is [count] identical ranges over the
/// first item, derived again over the whole text on every edit.
final class Copies implements Grammar<int> {
  /// [count] identical ranges.
  Copies(this.count);

  /// How many identical ranges layer 2 holds.
  final int count;

  @override
  int get depth => 2;

  @override
  Derived derive(Layered<int> document, int layer, Range region) => (
    ranges: region.start == 0 && region.length > 0
        ? List.filled(count, tagged(0, 1))
        : const [],
    diagnostics: const [],
  );

  @override
  Range affected(Layered<int> document, int layer, Range changed) =>
      span(0, document.items.length);

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) =>
      Failure(Kind.invalid, 'copies: no structural edits');

  /// Every range is markup, so only an edit changing none is valid.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      kept(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}

/// A grammar of depth 2 whose layer 2 holds [count] identical ranges over
/// the first item. Any structural edit removes the first half of them,
/// updates the rest, and creates as many new ones as it removes, one over
/// each item after the first, so no two share a position.
final class Bulk implements Grammar<int> {
  /// [count] identical ranges.
  Bulk(this.count);

  /// How many identical ranges layer 2 holds.
  final int count;

  @override
  int get depth => 2;

  @override
  Derived derive(Layered<int> document, int layer, Range region) => (
    ranges: region.start == 0 && region.length > 0
        ? List.filled(count, tagged(0, 1))
        : const [],
    diagnostics: const [],
  );

  @override
  Range affected(Layered<int> document, int layer, Range changed) =>
      span(0, document.items.length);

  @override
  Result<Derivation<int>> edit(Layered<int> document, Edit<int> change) {
    final markers = [for (final (marker, _) in document.markers(2)) marker];
    final half = markers.length ~/ 2;
    return Success((
      below: const [],
      created: [
        for (var index = 1; index <= half; index++)
          (Marker(), tagged(index, 1)),
      ],
      removed: markers.sublist(0, half),
      updated: {
        for (final marker in markers.sublist(half)) marker: {'n': const Num(1)},
      },
    ));
  }

  /// Every range is markup, so only an edit changing none is valid.
  @override
  Result<Change<int>> valid(Layered<int> document, Edit<int> change) =>
      kept(document, change);

  @override
  List<int> escaped(List<int> text, {bool raw = false}) => text;

  @override
  Crossing crossing(Layered<int> document, int layer, ARange range) =>
      Crossing.refuse;
}
