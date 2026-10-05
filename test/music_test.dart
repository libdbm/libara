import 'dart:async';

import 'package:test/test.dart';

import '../example/music/main.dart' as music;

void main() {
  test('the music example prints what doc/example.md says it prints', () {
    final lines = <String>[];
    runZoned(
      music.main,
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => lines.add(line),
      ),
    );
    expect(lines, [
      'tune: r4 G2 A2 B4 A2 G2 A6 r2 r4 B2 C2 D4 C2 B2 G8',
      '  {0,3,number:1,type:bar}',
      '  {1,6,type:phrase}',
      '  {3,3,number:2,type:bar}',
      '  {6,2,number:3,type:bar}',
      '  {8,3,number:4,type:bar}',
      '  {9,6,type:phrase}',
      '  {11,3,number:5,type:bar}',
      '  {14,1,number:6,type:bar}',
      'bars inside a phrase: [2, 5, 6]',
      'bars a phrase crosses: [1, 3, 4]',
      'with a grace note: r4 G2 A2 B4 C1 A2 G2 A6 r2 r4 B2 C2 D4 C2 B2 G8',
      'first phrase: {1,7,type:phrase}',
      'at the grace note: [{1,7,type:phrase}, {3,4,number:2,type:bar}]',
      'bar 2: {3,4,number:2,type:bar} holds 9 eighths',
      'undo: r4 G2 A2 B4 A2 G2 A6 r2 r4 B2 C2 D4 C2 B2 G8',
    ]);
  });
}
