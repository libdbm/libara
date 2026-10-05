import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

/// Test access to the value of a [Result] that must have succeeded.
extension Unwrap<T> on Result<T> {
  /// The value of a [Success], failing the test on a [Failure].
  T unwrap() => switch (this) {
    Success(:final value) => value,
    Failure(:final message) => fail(message),
  };
}

/// Matches a [Kind.invalid] failure.
final invalid = isA<Failure<Object?>>().having(
  (failure) => failure.kind,
  'kind',
  Kind.invalid,
);

/// The range of [length] items from [start], which must be valid.
Range span(int start, int length) => Range.create(start, length).unwrap();

/// The attributed range of [length] items from [start] carrying
/// [attributes], which must be valid.
ARange tagged(
  int start,
  int length, {
  Map<String, Value> attributes = const {},
}) => ARange.create(start, length, attributes: attributes).unwrap();
