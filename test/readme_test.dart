@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import '../example/example.dart' as example;

/// The fenced blocks in README.md, by language.
List<String> blocks(String language) {
  final pattern = RegExp('```$language\\n(.*?)```', dotAll: true);
  return [
    for (final match in pattern.allMatches(
      File('README.md').readAsStringSync(),
    ))
      match[1]!,
  ];
}

void main() {
  test('the README example is example/example.dart', () {
    expect(blocks('dart'), [File('example/example.dart').readAsStringSync()]);
  });

  test('the example prints what the README says it prints', () {
    final lines = <String>[];
    runZoned(
      example.main,
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => lines.add(line),
      ),
    );
    expect('${lines.join('\n')}\n', blocks('text').single);
  });
}
