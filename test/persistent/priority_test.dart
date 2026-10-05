import 'package:libara/src/persistent/priority.dart';
import 'package:test/test.dart';

/// [mix] computed with exact integers, the same on every platform.
int reference(int value) {
  final mask = BigInt.from(0xFFFFFFFF);
  var hashed = BigInt.from(value);
  hashed = ((hashed ^ (hashed >> 16)) * BigInt.from(0x85EBCA6B)) & mask;
  hashed = ((hashed ^ (hashed >> 13)) * BigInt.from(0xC2B2AE35)) & mask;
  return ((hashed ^ (hashed >> 16)) & BigInt.from(0x7FFFFFFF)).toInt();
}

void main() {
  test('mix matches exact 32-bit arithmetic for 1,000 counter values', () {
    var counter = 0x2545F491;
    for (var round = 0; round < 1000; round++) {
      counter = (counter + 0x9E3779B9) & 0xFFFFFFFF;
      expect(mix(counter), reference(counter), reason: 'round $round');
    }
  });

  test('mix gives a non-negative 31-bit integer at the extremes', () {
    for (final value in [0, 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF]) {
      expect(mix(value), reference(value), reason: '$value');
      expect(mix(value), inInclusiveRange(0, 0x7FFFFFFF));
    }
  });
}
