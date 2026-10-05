import '../format/format.dart';
import '../sequence/sequence.dart';
import 'layered.dart';

/// A layered document as its layer-1 sequence, such as its markup text.
///
/// [encode] gives layer 1, and [decode] derives every layer from a
/// sequence by [grammar], with diagnostics where it does not parse, as
/// [Layered.of] does. Composed with an item format such as [text], a
/// layered document travels as its markup; versions, markers, and
/// attributes the grammar does not derive are not kept.
final class LayeredFormat<T> implements Format<Layered<T>, Sequence<T>> {
  /// The format for layered documents whose layers [grammar] derives.
  const LayeredFormat(this.grammar);

  /// What the decoded layers mean.
  final Grammar<T> grammar;

  /// Layer 1 of [value]. Cannot fail.
  @override
  Result<Sequence<T>> encode(Layered<T> value) => Success(value.items);

  /// Version 0 of a layered document over [form], or the failure
  /// [Layered.of] returns for a grammar whose depth is invalid.
  @override
  Result<Layered<T>> decode(Sequence<T> form) => Layered.of(form, grammar);
}
