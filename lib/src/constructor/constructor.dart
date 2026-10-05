/// The constructor module: [Constructor] and the ways to compose them.
library;

import '../range/range.dart';
import '../sequence/sequence.dart';

export 'regex.dart';

/// A range constructor: a pure function from a sequence to the ranges it
/// finds in it.
///
/// Given equal inputs a constructor returns equal ranges, and it never
/// modifies its input. The composition helpers copy their parts when they are
/// called, so changing the caller's collection afterwards has no effect.
/// Input the constructor cannot read, such as an invalid code point for
/// [regex], is a [Failure]; a composition fails with its first failing
/// part.
typedef Constructor<T> = Result<Ranges> Function(Sequence<T> input);

/// A constructor that runs every one of [parts], drops exact duplicates,
/// and returns the rest in start order: the paper's Union of constructors.
///
/// Ranges at the same position with different attributes are all kept, so
/// ambiguous, overlapping patterns can run side by side.
Constructor<T> union<T>(Iterable<Constructor<T>> parts) {
  final frozen = List<Constructor<T>>.unmodifiable(parts);
  return (input) =>
      _run(frozen, input).map((ranges) => ranges.unique().startOrder());
}

/// A constructor that runs every one of [parts] and keeps every range, in
/// the order of the parts, duplicates included.
Constructor<T> concat<T>(Iterable<Constructor<T>> parts) {
  final frozen = List<Constructor<T>>.unmodifiable(parts);
  return (input) => _run(frozen, input);
}

/// A constructor that runs [below], then derives a second layer from its
/// ranges with [above].
///
/// The ranges [above] returns index into the lower layer, not into the
/// input: range `{0,4}` means the first four lower ranges. This is how an
/// application layer is built from a lexical one.
Constructor<T> layer<T>(Constructor<T> below, Ranges Function(Ranges) above) =>
    (input) => below(input).map(above);

/// The ranges of every part in order, or the first part's failure.
Result<Ranges> _run<T>(Iterable<Constructor<T>> parts, Sequence<T> input) {
  final found = <Range>[];
  for (final part in parts) {
    switch (part(input)) {
      case Success(:final value):
        found.addAll(value.items);
      case final Failure<Ranges> failure:
        return failure;
    }
  }
  return Success(Ranges.of(found));
}
