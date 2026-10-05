/// The category of an expected failure.
enum Kind {
  /// A position or length outside the valid range.
  bounds,

  /// Something that was looked up does not exist.
  missing,

  /// An argument that is well-typed but not acceptable.
  invalid,

  /// Source text that could not be parsed.
  syntax,

  /// An error raised while evaluating an expression.
  runtime,
}

/// The outcome of an operation that can fail in an expected way.
///
/// Expected outcomes are values, never exceptions. A [Result] is either a
/// [Success] carrying a value or a [Failure] carrying a [Kind] and message.
sealed class Result<T> {
  const Result();

  /// Applies [transform] to the value of a [Success]; a [Failure] is kept.
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
    Success(:final value) => Success(transform(value)),
    Failure(:final kind, :final message) => Failure(kind, message),
  };

  /// Applies [next] to the value of a [Success]; a [Failure] is kept.
  Result<R> flatMap<R>(Result<R> Function(T value) next) => switch (this) {
    Success(:final value) => next(value),
    Failure(:final kind, :final message) => Failure(kind, message),
  };

  /// Reduces both cases to a single value.
  R fold<R>(
    R Function(T value) onSuccess,
    R Function(Failure<T> failure) onFailure,
  ) => switch (this) {
    Success(:final value) => onSuccess(value),
    final Failure<T> failure => onFailure(failure),
  };
}

/// [Result]'s `or`, as an extension so that it binds to the static type.
///
/// As an instance method, `T fallback` would be checked against the runtime
/// type argument: a `Result<int>` held as a `Result<num>` would throw for a
/// `double` fallback. An extension checks against the static type instead.
extension Fallback<T> on Result<T> {
  /// The value of a [Success], or [fallback] for a [Failure].
  T or(T fallback) => switch (this) {
    Success(:final value) => value,
    Failure() => fallback,
  };
}

/// A [Result] carrying a value.
final class Success<T> extends Result<T> {
  /// Wraps [value].
  const Success(this.value);

  /// The value produced by the operation.
  final T value;

  /// Whether [other] is a success with an equal value.
  ///
  /// The type argument is not compared, so equality is symmetric when one
  /// side is held through a wider type.
  @override
  bool operator ==(Object other) => other is Success && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Success($value)';
}

/// A [Result] describing why the operation did not produce a value.
final class Failure<T> extends Result<T> {
  /// A failure of the given [kind] with a human readable [message].
  const Failure(this.kind, this.message);

  /// A [Kind.bounds] failure for [operation] at [position].
  Failure.bounds(String operation, int position)
    : this(Kind.bounds, '$operation: position $position is out of bounds');

  /// The category of the failure.
  final Kind kind;

  /// What went wrong, for logs and messages.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is Failure && other.kind == kind && other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'Failure(${kind.name}: $message)';
}
