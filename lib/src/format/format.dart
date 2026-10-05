/// The format module: [Format], a two-way mapping between a value and a
/// serialized form, and [JSONFormat] for documents.
library;

import 'dart:math';

import '../attributed/attributed.dart';
import '../persistent/persistent.dart';
import '../range/range.dart';
import '../sequence/sequence.dart';

part 'json.dart';

/// A two-way mapping between values of [D] and a serialized form [S].
///
/// [decode] of what [encode] gives returns an equal value, apart from what
/// a format documents it does not keep. Named `Format` rather than `Codec`,
/// which `dart:convert` exports.
abstract interface class Format<D, S> {
  /// [value] in its serialized form, or a failure for a value this format
  /// cannot hold.
  Result<S> encode(D value);

  /// The value [form] holds, or a failure for a form this format cannot
  /// read.
  Result<D> decode(S form);
}

/// Code points as a JSON string: the item format for text.
///
/// Lone surrogates travel as they are, but a high surrogate followed by a
/// low one would read back as a single character, so encoding one is a
/// [Kind.invalid] failure.
const Format<Sequence<int>, Object?> text = _Text();

final class _Text implements Format<Sequence<int>, Object?> {
  const _Text();

  @override
  Result<Object?> encode(Sequence<int> value) => _string(value.items);

  @override
  Result<Sequence<int>> decode(Object? form) => form is String
      ? Success(Text.of(form))
      : const Failure(Kind.syntax, 'expected a string');
}
