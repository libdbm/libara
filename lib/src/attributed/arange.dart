import '../range/range.dart';
import '../sequence/sequence.dart';
import 'attribute.dart';
import 'value.dart';

/// A [Range] with a set of named attributes: the ARANGE data type of
/// Attributed Range Algebra.
///
/// Attributes are immutable. Every edit returns a new range.
final class ARange extends Range {
  ARange._(this.start, this.length, Map<String, Value> attributes)
    : attributes = Map.unmodifiable(attributes);

  /// An attributed range at the position of [range].
  ///
  /// The map is copied, so later changes to the argument have no effect.
  factory ARange.from(Range range, Map<String, Value> attributes) =>
      ARange._(range.start, range.length, attributes);

  /// A range of [length] items from [start] carrying [attributes]: a
  /// [Kind.invalid] failure for a negative [start] or [length].
  ///
  /// The map is copied, so later changes to the argument have no effect.
  static Result<ARange> create(
    int start,
    int length, {
    Map<String, Value> attributes = const {},
  }) => Range.create(
    start,
    length,
  ).map((range) => ARange.from(range, attributes));

  @override
  final int start;

  @override
  final int length;

  /// The attributes by name. Writing to this map throws.
  final Map<String, Value> attributes;

  /// The names of every attribute, in no guaranteed order.
  Iterable<String> get names => attributes.keys;

  /// Every attribute, in no guaranteed order.
  Iterable<Attribute> get all =>
      attributes.entries.map((entry) => Attribute(entry.key, entry.value));

  /// Whether an attribute called [name] is present: the paper's
  /// HasAttribute.
  ///
  /// An attribute whose value is [Nil] is present.
  bool has(String name) => attributes.containsKey(name);

  /// The value of the attribute called [name], or `null` when absent.
  Value? get(String name) => attributes[name];

  /// A copy with the attribute [name] set to [value], replacing any
  /// existing value.
  ARange set(String name, Value value) =>
      ARange._(start, length, {...attributes, name: value});

  /// A copy without the attribute [name]. Unchanged when it is absent.
  ARange remove(String name) =>
      has(name) ? ARange._(start, length, {...attributes}..remove(name)) : this;

  /// This range moved by [delta] positions, keeping every attribute.
  ///
  /// A negative resulting start is a [Kind.bounds] failure.
  @override
  Result<ARange> move(int delta) =>
      super.move(delta).map((moved) => ARange.from(moved, attributes));

  /// This range with its length changed by [delta], keeping every
  /// attribute.
  ///
  /// A negative resulting length is a [Kind.bounds] failure.
  @override
  Result<ARange> resize(int delta) =>
      super.resize(delta).map((resized) => ARange.from(resized, attributes));

  /// Whether [other] has the same position and equal attributes: the
  /// paper's Equals.
  ///
  /// Never equal to a plain [Range]; use [same] to compare positions.
  @override
  bool operator ==(Object other) =>
      other is ARange &&
      other.start == start &&
      other.length == length &&
      alike(attributes, other.attributes);

  @override
  int get hashCode => Object.hash(
    start,
    length,
    Object.hashAllUnordered(
      attributes.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );

  /// The paper's notation with attributes in name order, for example
  /// `{0,5,label:P,type:header}`.
  @override
  String toString() {
    final sorted = names.toList()..sort();
    final parts = [
      '$start',
      '$length',
      for (final name in sorted) '$name:${attributes[name]}',
    ];
    return '{${parts.join(',')}}';
  }
}

/// Whether [a] and [b] hold the same attributes, as [ARange] equality
/// compares them. For the library; hidden from the public `libara` library.
bool alike(Map<String, Value> a, Map<String, Value> b) =>
    a.length == b.length &&
    a.entries.every((entry) => b[entry.key] == entry.value);
