import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/persistent/persistent.dart';
import 'package:libara/src/replica/replica.dart';
import 'package:test/test.dart';

import '../support.dart';
import 'model.dart';

/// The time every replica in a test reads.
var now = 1;

/// A replica with [id] reading [now].
Replica<int> replica(String id) =>
    Replica.create<int>(id, clock: () => now).unwrap();

/// [replica] after committing [commands] at time [time], and the operation.
(Replica<int>, Operation<int>) commit(
  Replica<int> replica,
  int time,
  List<Command<int>> commands,
) {
  now = time;
  return replica.commit(commands).unwrap();
}

/// [replica] after receiving each of [operations] in order, checking each
/// time that the returned commands turn the previous document into the new
/// one, items and ranges alike.
Replica<int> receive(Replica<int> replica, List<Operation<int>> operations) =>
    operations.fold(replica, (held, operation) {
      final before = held.document;
      final (next, commands) = held.receive(operation).unwrap();
      final moved = before.transact(commands).unwrap();
      expect(moved.items.toList(), next.document.items.toList());
      expect(ranges(moved), ranges(next.document));
      return next;
    });

/// Each marked range of [document] with its gravities, by marker.
Map<Marker, (ARange, Gravity, Gravity)> ranges(Document<int> document) => {
  for (final (marker, range) in document.markers)
    marker: (
      range,
      document.gravity(marker)!.start,
      document.gravity(marker)!.end,
    ),
};

/// The document of [replica] as text.
String text(Replica<int> replica) =>
    String.fromCharCodes(replica.document.items);

/// Expects [replica] to hold what [model] holds: equal items, and each
/// of the model's ranges under the same key, with the same range,
/// attributes, and gravities.
void agrees(Replica<int> replica, Model<int> model, {String reason = ''}) {
  expect(
    replica.document.items.toList(),
    model.document.items.toList(),
    reason: reason,
  );
  expect(
    replica.document.markers,
    hasLength(model.document.markers.length),
    reason: reason,
  );
  for (final MapEntry(:key, value: marker) in model.markers.entries) {
    final range = model.document.resolve(marker);
    final mine = replica.marker(key);
    if (range == null) {
      expect(
        mine == null ? null : replica.document.resolve(mine),
        isNull,
        reason: '$reason $key',
      );
      continue;
    }
    expect(mine, isNotNull, reason: '$reason $key');
    expect(replica.document.resolve(mine!), range, reason: '$reason $key');
    expect(
      replica.document.gravity(mine),
      model.document.gravity(marker),
      reason: '$reason $key',
    );
  }
}
