import 'dart:math';

import 'package:libara/src/replica/stamp.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

void main() {
  group('Stamp', () {
    test('orders by time, then count, then replica by code unit', () {
      final stamps = [
        const Stamp(2, 0, 'a'),
        const Stamp(1, 5, 'b'),
        const Stamp(1, 5, 'a'),
        const Stamp(1, 0, 'z'),
        const Stamp(1, 5, 'B'),
      ]..sort();
      expect(stamps, [
        const Stamp(1, 0, 'z'),
        const Stamp(1, 5, 'B'),
        const Stamp(1, 5, 'a'),
        const Stamp(1, 5, 'b'),
        const Stamp(2, 0, 'a'),
      ]);
    });

    test('is equal by value and hashes consistently', () {
      expect(const Stamp(1, 2, 'a'), Stamp(1, 2, 'a' * 1));
      expect(const Stamp(1, 2, 'a').hashCode, Stamp(1, 2, 'a' * 1).hashCode);
      expect(const Stamp(1, 2, 'a'), isNot(const Stamp(1, 2, 'b')));
      expect(const Stamp(1, 2, 'a').toString(), '1.2@a');
    });
  });

  group('Key', () {
    test('is equal by stamp and index and hashes consistently', () {
      const stamp = Stamp(1, 0, 'a');
      expect(const Key(stamp, 2), Key(Stamp(1, 0, 'a' * 1), 2));
      expect(
        const Key(stamp, 2).hashCode,
        Key(Stamp(1, 0, 'a' * 1), 2).hashCode,
      );
      expect(const Key(stamp, 2), isNot(const Key(stamp, 3)));
      expect(const Key(stamp, 2).toString(), '1.0@a#2');
    });
  });

  group('Clock', () {
    test(
      'stamps strictly increase when the clock goes back or stands still',
      () {
        final random = Random(3);
        var time = 1000;
        var clock = Clock('a', () => time, 1000);
        Stamp? last;
        for (var round = 0; round < 1000; round++) {
          time += random.nextInt(5) - 3;
          final (next, stamp) = clock.tick();
          clock = next;
          if (last != null) {
            expect(
              stamp.compareTo(last),
              greaterThan(0),
              reason: '$last $stamp',
            );
          }
          expect(stamp.replica, 'a');
          last = stamp;
        }
      },
    );

    test('a stamp takes the physical time once it passes the latest', () {
      var time = 10;
      final (clock, first) = Clock('a', () => time, 1000).tick();
      expect(first, const Stamp(10, 0, 'a'));
      final (_, second) = clock.tick();
      expect(second, const Stamp(10, 1, 'a'));
      time = 20;
      final (_, third) = clock.tick();
      expect(third, const Stamp(20, 0, 'a'));
    });

    test('stamps made after taking one in exceed it', () {
      const time = 10;
      final clock = Clock('a', () => time, 1000).take(const Stamp(50, 7, 'b'));
      final (next, stamp) = clock.tick();
      expect(stamp, const Stamp(50, 8, 'a'));
      // Taking in an earlier stamp changes nothing.
      expect(next.take(const Stamp(40, 0, 'c')).latest, stamp);
    });

    test(
      'a stamp past the skew fails and passes once the clock catches up',
      () {
        var time = 5000;
        final clock = Clock('a', () => time, 1000);
        const stamp = Stamp(6001, 0, 'b');
        final failed = clock.check(stamp);
        expect(failed, isA<Failure<void>>());
        expect((failed as Failure<void>).kind, Kind.invalid);
        expect(failed.message, contains('1001ms ahead'));
        expect(clock.check(const Stamp(6000, 0, 'b')), isA<Success<void>>());
        time = 5001;
        expect(clock.check(stamp), isA<Success<void>>());
      },
    );
  });
}
