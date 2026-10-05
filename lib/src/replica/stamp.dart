import 'dart:math';

import '../sequence/sequence.dart';

/// A hybrid logical clock timestamp: the id of an operation and its place
/// in the canonical order.
///
/// Stamps order by [time], then [count], then [replica] by code unit. The
/// replica id is part of the stamp, so two replicas never make equal ones.
final class Stamp implements Comparable<Stamp> {
  /// The stamp at [time] with [count], made by [replica].
  const Stamp(this.time, this.count, this.replica);

  /// Milliseconds since the epoch, from the clock of the replica that made
  /// the stamp, or later when it had already seen a later stamp.
  final int time;

  /// Orders stamps made at one [time].
  final int count;

  /// The id of the replica that made the stamp.
  final String replica;

  @override
  int compareTo(Stamp other) => time != other.time
      ? time.compareTo(other.time)
      : count != other.count
      ? count.compareTo(other.count)
      : replica.compareTo(other.replica);

  @override
  bool operator ==(Object other) =>
      other is Stamp &&
      other.time == time &&
      other.count == count &&
      other.replica == replica;

  @override
  int get hashCode => Object.hash(time, count, replica);

  @override
  String toString() => '$time.$count@$replica';
}

/// The durable identity of a replicated marker: the [stamp] of the
/// operation whose `Mark` created it, and that `Mark`'s [index] among the
/// operation's commands.
final class Key {
  /// The key of the `Mark` at [index] in the operation stamped [stamp].
  const Key(this.stamp, this.index);

  /// The stamp of the operation that marked the range.
  final Stamp stamp;

  /// The place of the `Mark` among the operation's commands, from 0.
  final int index;

  @override
  bool operator ==(Object other) =>
      other is Key && other.stamp == stamp && other.index == index;

  @override
  int get hashCode => Object.hash(stamp, index);

  @override
  String toString() => '$stamp#$index';
}

/// The hybrid logical clock of one replica: makes stamps that strictly
/// increase and exceed every stamp the replica has seen.
///
/// Immutable: [tick] and [take] return a new clock.
final class Clock {
  /// A clock for [replica] reading physical time from [now], accepting
  /// stamps at most [skew] milliseconds ahead of it.
  const Clock(this.replica, this.now, this.skew) : latest = null;

  const Clock._(this.replica, this.now, this.skew, this.latest);

  /// The id of the replica the clock makes stamps for.
  final String replica;

  /// Physical time in milliseconds since the epoch.
  final int Function() now;

  /// How far ahead of [now], in milliseconds, a received stamp may be.
  final int skew;

  /// The greatest stamp made or taken in, or `null` before the first.
  final Stamp? latest;

  /// A new stamp, greater than [latest], and the clock that made it.
  ///
  /// Its time is the later of [now] and the latest stamp's, so it never
  /// goes back with the physical clock; at the latest stamp's time, the
  /// count goes up by one.
  (Clock, Stamp) tick() {
    final last = latest;
    final time = last == null ? now() : max(now(), last.time);
    final count = last != null && time == last.time ? last.count + 1 : 0;
    final stamp = Stamp(time, count, replica);
    return (Clock._(replica, now, skew, stamp), stamp);
  }

  /// This clock having seen [stamp], so later stamps exceed it.
  Clock take(Stamp stamp) {
    final last = latest;
    return last != null && last.compareTo(stamp) >= 0
        ? this
        : Clock._(replica, now, skew, stamp);
  }

  /// A [Kind.invalid] failure when [stamp] is more than [skew] ahead of
  /// [now], saying by how much. A later check of the same stamp passes once
  /// the physical clock catches up.
  Result<void> check(Stamp stamp) {
    final ahead = stamp.time - now();
    return ahead > skew
        ? Failure(
            Kind.invalid,
            'replica: stamp $stamp is ${ahead}ms ahead of the clock, more '
            'than the ${skew}ms skew allowed',
          )
        : const Success(null);
  }
}
