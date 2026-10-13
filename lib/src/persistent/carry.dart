import '../range/range.dart';
import 'command.dart';

/// Where [position] is after [move], as an endpoint with [gravity] moves:
/// with the items where it is strictly inside the span, and unchanged by a
/// move to either edge of its span, which leaves everything where it is.
///
/// Internal: shared by `Document.map` and anchors, so the two agree.
int moved(int position, Gravity gravity, Move<Object?> move) {
  final Move(:span, :to) = move;
  if (to == span.start || to == span.end) {
    return position;
  }
  return carried(
    position,
    gravity,
    span,
    to,
    inside: span.start < position && position < span.end,
  );
}

/// Where [position] is once the items in [span] have moved to before
/// [to]: going with them where [inside], and otherwise as a deletion of
/// [span] and an insertion at [to] carry an endpoint with [gravity].
int carried(
  int position,
  Gravity gravity,
  Range span,
  int to, {
  required bool inside,
}) {
  final (start, end, length) = (span.start, span.end, span.length);
  if (inside) {
    return position - start + (to < start ? to : to - length);
  }
  if (to < start) {
    return position < to || (position == to && gravity == Gravity.left)
        ? position
        : position <= start
        ? position + length
        : position;
  }
  return position <= start
      ? position
      : position < to
      ? position - length
      : position == to && gravity == Gravity.left
      ? position - length
      : position;
}
