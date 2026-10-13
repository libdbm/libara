import '../attributed/attributed.dart';
import '../persistent/persistent.dart';
import '../range/range.dart';
import '../sequence/sequence.dart';
import 'layered.dart';

/// What a layered document's layers mean: how each layer is derived from
/// the one below, and which edits keep the markup legal.
///
/// The caller supplies a grammar, so libara stays free of any particular
/// markup language.
abstract interface class Grammar<T> {
  /// The number of layers, at least 1.
  int get depth;

  /// Layer [layer]'s ranges over [region] of the layer below's items, in
  /// absolute positions and in any order, and where layer [layer] cannot
  /// be derived over [region], each with a `message` attribute.
  ///
  /// Cannot fail: what does not parse is reported in `diagnostics`.
  Derived derive(Layered<T> document, int layer, Range region);

  /// The region of the layer below [layer] to derive again when [changed]
  /// items of it changed: at least [changed], usually the smallest
  /// enclosing unit. The whole layer is always a correct answer.
  ///
  /// The region must take in every layer-[layer] range that may change,
  /// including one that starts or ends at an end of [changed]: a range
  /// grows only for items inserted strictly inside it, so items inserted
  /// at its ends lie outside it until it is derived again. The layered
  /// document widens the region itself to take in diagnostics that overlap
  /// or touch it and ranges that cross its ends.
  Range affected(Layered<T> document, int layer, Range changed);

  /// The edits one layer down, and the ranges of the edited layer they
  /// create, remove, and update, that carry out a structural [change], or a
  /// [Kind.invalid] failure when it would break the grammar.
  Result<Derivation<T>> edit(Layered<T> document, Edit<T> change);

  /// The change a text [change], at layer 1, makes to [document] where it
  /// leaves the markup and its diagnostics as they stand, or a
  /// [Kind.invalid] failure saying what it would make of them.
  ///
  /// A layered document accepts every text edit and reports what does not
  /// parse as diagnostics, which is what a caller editing the markup
  /// itself wants. A caller editing only the words asks here first.
  ///
  /// The markup stands when its ranges, in order, are the same before and
  /// after the edit, each by its attributes and the text it covers. The
  /// diagnostics stand when, at each layer, they are the same in order, each
  /// by its message and what lies under it. A diagnostic is a range of its
  /// own over the markup, and what lies under it may start inside one unit
  /// of the grammar and end inside another. Counting is not enough, since
  /// one range may have become another; nor is any one marker, since
  /// deriving again may mark an unchanged range afresh. Any other edit,
  /// including one to a layer above 1, is a [Kind.invalid] failure.
  /// Annotations, added by [Edit.annotation], are neither markup nor
  /// diagnostics: the grammar cannot see them, so it decides the same with
  /// or without them. [kept] carries out this check, and a grammar's
  /// `valid` calls it, saying only which of its ranges are text.
  Result<Change<T>> valid(Layered<T> document, Edit<T> change);

  /// How [text] is written as text alone, so that it is read back as text
  /// and no markup, and as the same text where the syntax resolves what it
  /// escapes; with [raw], [text] as it stands, for a caller writing the
  /// markup itself.
  List<T> escaped(List<T> text, {bool raw = false});

  /// What a [Move] does with [range], a layer-[layer] range of [document]
  /// with one end inside the items moved and one outside them: cut back to
  /// the part outside, carried along with the items, or refused.
  Crossing crossing(Layered<T> document, int layer, ARange range);
}

/// What a grammar derives for one layer over a region: the layer's
/// `ranges`, and its `diagnostics`, where it cannot be derived.
typedef Derived = ({List<ARange> ranges, List<ARange> diagnostics});

/// How a grammar carries out a structural edit, which the layered document
/// applies.
///
/// `below` holds edits at the layer below, applied first; `created` the
/// edited layer's new ranges, positioned after `below` applies; `removed`
/// the ranges it takes away; and `updated` new attributes for ranges that
/// keep their markers.
typedef Derivation<T> = ({
  List<Edit<T>> below,
  List<(Marker, ARange)> created,
  List<Marker> removed,
  Map<Marker, Map<String, Value>> updated,
});
