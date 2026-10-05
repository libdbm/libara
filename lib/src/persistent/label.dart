import 'dart:math';

import '../sequence/sequence.dart';

/// A stable position in an ordering: a fraction in (0, 1) written as digits
/// in base [base].
///
/// A new label can always be made between any two others, so every endpoint
/// in a document gets a label when it is created that stays consistent with
/// the order of endpoints forever. A label never ends in a zero digit, which
/// makes comparing digit lists the same as comparing the fractions.
final class Label implements Comparable<Label> {
  Label._(List<int> digits) : digits = List.unmodifiable(digits);

  /// A label with the given [digits], each in `0 <= digit < base`.
  ///
  /// An empty list, a trailing zero digit, or a digit outside the base is a
  /// [Kind.invalid] failure.
  static Result<Label> of(List<int> digits) {
    if (digits.isEmpty || digits.last == 0) {
      return Failure(
        Kind.invalid,
        'label: $digits must end in a non-zero digit',
      );
    }
    if (digits.any((digit) => digit < 0 || digit >= base)) {
      return Failure(Kind.invalid, 'label: $digits must be in 0 <= d < $base');
    }
    return Success(Label._(digits));
  }

  /// A label strictly between [lower] and [upper].
  ///
  /// A `null` bound is open: `null` as [lower] means 0 and as [upper] means
  /// 1. Bounds that are not strictly ordered are a [Kind.invalid] failure.
  ///
  /// Between two bounds the label takes the midpoint of the gap. With one
  /// bound open it steps from the other, so labels made one after another
  /// at an open end, as appending or prepending ranges does, share a
  /// digit's whole range instead of halving it each time. Below an open
  /// lower bound it steps by two, leaving room for the end of a range
  /// marked before every other endpoint.
  static Result<Label> between(Label? lower, Label? upper) {
    if (lower != null && upper != null && lower.compareTo(upper) >= 0) {
      return Failure(Kind.invalid, 'label: $lower is not below $upper');
    }
    final low = lower?.digits ?? const <int>[];
    final high = upper?.digits;
    final digits = <int>[];
    var index = 0;
    // Copy the shared prefix. The bounds differ somewhere, so this ends.
    while (true) {
      final x = index < low.length ? low[index] : 0;
      final y = high == null ? base : (index < high.length ? high[index] : 0);
      if (x == y) {
        digits.add(x);
        index++;
        continue;
      }
      if (y - x > 1) {
        digits.add(
          upper == null
              ? x + 1
              : lower == null
              ? (y > 2 ? y - 2 : y - 1)
              : (x + y) ~/ 2,
        );
        return Success(Label._(digits));
      }
      // No room at this digit: keep the lower digit, then anything above
      // the rest of the lower bound is also below the upper bound.
      digits.add(x);
      index++;
      break;
    }
    while (true) {
      final x = index < low.length ? low[index] : 0;
      if (x < base - 1) {
        digits.add(
          upper == null
              ? x + 1
              : lower == null
              ? base - 2
              : (x + base + 1) ~/ 2,
        );
        return Success(Label._(digits));
      }
      digits.add(x);
      index++;
    }
  }

  /// [count] labels in increasing order, spaced evenly over (0, 1) with as
  /// few digits as the count allows: one digit for fewer than [base].
  static List<Label> spread(int count) {
    var size = 1;
    var space = base;
    while (space <= count) {
      size++;
      space *= base;
    }
    final step = space ~/ (count + 1);
    return [
      for (var index = 1; index <= count; index++) _spaced(index * step, size),
    ];
  }

  /// The label for [value] written as [size] digits, trailing zeros
  /// dropped. [value] is positive, so some digit is not zero.
  static Label _spaced(int value, int size) {
    final digits = List.filled(size, 0, growable: true);
    var rest = value;
    for (var index = size - 1; index >= 0; index--) {
      digits[index] = rest % base;
      rest ~/= base;
    }
    while (digits.last == 0) {
      digits.removeLast();
    }
    return Label._(digits);
  }

  /// The number base of each digit.
  static const base = 1 << 16;

  /// The digits, most significant first.
  final List<int> digits;

  @override
  int compareTo(Label other) {
    final shared = min(digits.length, other.digits.length);
    for (var index = 0; index < shared; index++) {
      final difference = digits[index] - other.digits[index];
      if (difference != 0) {
        return difference;
      }
    }
    return digits.length - other.digits.length;
  }

  @override
  bool operator ==(Object other) => other is Label && compareTo(other) == 0;

  @override
  int get hashCode => Object.hashAll(digits);

  @override
  String toString() => 'Label(${digits.join('.')})';
}
