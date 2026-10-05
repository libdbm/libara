import '../sequence/sequence.dart';

/// The value of an attribute on an attributed range.
///
/// Values are scalar: text, integers, booleans, and [Nil]. Sequence and
/// range values are deliberately excluded from this version.
sealed class Value {
  const Value();

  /// Converts a Dart [String], [int], [bool], or `null`.
  ///
  /// Any other type is a [Kind.invalid] failure.
  static Result<Value> of(Object? source) => switch (source) {
    final String text => Success(Str(Text.of(text))),
    final int number => Success(Num(number)),
    final bool flag => Success(Bool(flag)),
    null => const Success(Nil()),
    _ => Failure(
      Kind.invalid,
      'value: ${source.runtimeType} is not a String, int, bool, or null',
    ),
  };
}

/// A text value, held as Unicode code points.
final class Str extends Value {
  /// Wraps [value].
  const Str(this.value);

  /// The text.
  final Text value;

  @override
  bool operator ==(Object other) => other is Str && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value.toString();
}

/// An integer value.
final class Num extends Value {
  /// Wraps [value].
  const Num(this.value);

  /// The integer.
  final int value;

  @override
  bool operator ==(Object other) => other is Num && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '$value';
}

/// A boolean value.
final class Bool extends Value {
  /// Wraps [value].
  const Bool(this.value);

  /// The boolean.
  final bool value;

  @override
  bool operator ==(Object other) => other is Bool && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '$value';
}

/// The absence of a value, present as an attribute.
///
/// Named `Nil` so that it does not shadow `Null` from `dart:core`.
final class Nil extends Value {
  /// The only value of this case.
  const Nil();

  @override
  bool operator ==(Object other) => other is Nil;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'null';
}
