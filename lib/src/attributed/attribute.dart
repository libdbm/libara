import 'value.dart';

/// A named [Value]: the ATTRIBUTE data type of Attributed Range Algebra.
final class Attribute {
  /// The attribute [name] with [value].
  const Attribute(this.name, this.value);

  /// The key of this attribute on its range.
  final String name;

  /// The value of this attribute.
  final Value value;

  /// Whether [other] is this very attribute: the paper's Same.
  ///
  /// Two attributes can be equal without being the same.
  bool same(Attribute other) => identical(this, other);

  /// Whether [other] has an equal name and value: the paper's Equals.
  @override
  bool operator ==(Object other) =>
      other is Attribute && other.name == name && other.value == value;

  @override
  int get hashCode => Object.hash(name, value);

  /// The paper's notation, for example `type:header`.
  @override
  String toString() => '$name:$value';
}
