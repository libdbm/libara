/// Selection over the persistent scale document, run on demand with
/// `dart test --tags scale --run-skipped test/selector`.
@Tags(['scale'])
library;

import 'package:libara/src/selector/selector.dart';
import 'package:test/test.dart';

import '../persistent/html.dart';
import '../persistent/scale_test.dart' show Marked;
import '../support.dart';

/// [time] microseconds as milliseconds.
String ms(int time) => '${(time / 1000).toStringAsFixed(1)}ms';

void main() {
  test('selects over 100,000 elements and their tags', () {
    final marked = Marked(Html.generate(seed: 2, target: 100000));
    final scope = marked.document.markers;
    for (final source in [
      'li',
      'section p > b',
      'ul > li',
      'div:has(> p)',
      '[name]:crosses([name])',
    ]) {
      final selector = Selector.parse(source).unwrap();
      final watch = Stopwatch()..start();
      final found = marked.document.select(selector);
      final time = watch.elapsedMicroseconds;
      expect(found.length, selector.select(scope).length);
      print(
        '$source over ${scope.length} ranges: ${found.length} found '
        'in ${ms(time)}',
      );
    }
  });
}
