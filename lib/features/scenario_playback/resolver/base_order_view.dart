import 'dart:typed_data';

import 'package:iris/features/scenario_playback/resolver/bit_vector.dart';
import 'package:iris/features/scenario_playback/resolver/merged_order_codec.dart';

/// The READ side of a scenario's base order.
///
/// Two representations implement it and both are looked up the same way by the
/// overlay and the row source, so a page read cannot tell (and cannot behave
/// differently) which one served it:
///
///  - [SharedBaseOrder] — one storage's shared order plus a membership bitmap
///    (the `kind 0` case: a single source with no explicit item or placeholder);
///  - `MergedBaseOrder` — a globally sorted base order over several streams,
///    stored as a [MergedOrder] (the `kind 1` case).
abstract class BaseOrderView {
  /// Length of the VIRTUAL space: every element the scenario's segments
  /// produced, including the ones exclusion/dedup filtered out and the
  /// placeholder tail.
  int get virtualSize;

  /// Number of ACCEPTED elements — the queue's rank space.
  int get count;

  /// Node id at [acceptedRank], or null when that rank is a placeholder row or
  /// out of range.
  int? nodeIdAt(int acceptedRank);

  /// Every accepted rank whose node id is [nodeId], in ascending base order.
  ///
  /// More than one rank can match: overlapping sources (and `allowDuplicate`)
  /// put the same node at two ranks, which is exactly what occurrence recovery
  /// needs to tell apart (`occurrenceIndex` 0 vs 1). Absorbed ranks ARE included
  /// — the caller owns the absorbed/occurrence filtering, so the view stays a
  /// pure order.
  Iterable<int> acceptedRanksOfNode(int nodeId);
}

/// A base order over multiple ORDERED STREAMS, merged globally.
///
/// [order] is the persisted interleaving: entry `i` of the accepted virtual
/// space is `(stream, rank)`, and the node id is `orders[stream][rank]`. The
/// last [placeholderCount] virtual slots are placeholder rows with no node.
class MergedBaseOrder implements BaseOrderView {
  MergedBaseOrder({
    required this.order,
    required this.orders,
    required this.accepted,
    required this.placeholderCount,
  })  : assert(orders.length == order.streamCount),
        assert(accepted.length >= order.length),
        assert(placeholderCount == accepted.length - order.length);

  final MergedOrder order;

  /// The streams' shared orders, in `order.streams` order.
  final List<Int32List> orders;

  /// Membership over the virtual space (stream entries, then placeholders).
  final BitVector accepted;

  /// Placeholder rows appended after the merged segment.
  final int placeholderCount;

  @override
  int get virtualSize => accepted.length;

  @override
  int get count => accepted.count;

  @override
  int? nodeIdAt(int acceptedRank) {
    if (acceptedRank < 0 || acceptedRank >= count) return null;
    final virtual = accepted.select(acceptedRank);
    if (virtual < 0 || virtual >= order.length) return null; // placeholder row
    final entry = order.at(virtual);
    // Defensive: a rank outside its order cannot be served, and throwing here
    // would fail a whole page instead of the row (decode already bounds it).
    if (entry.stream < 0 || entry.stream >= orders.length) return null;
    final ids = orders[entry.stream];
    if (entry.rank < 0 || entry.rank >= ids.length) return null;
    return ids[entry.rank];
  }

  @override
  Iterable<int> acceptedRanksOfNode(int nodeId) {
    // A full sequential pass: occurrence recovery is a locate, not a page read,
    // and the merged blob decodes stream-wise, so one pass beats `at` per entry.
    final hits = <int>[];
    order.forEach((index, stream, rank) {
      if (orders[stream][rank] != nodeId) return;
      if (!accepted[index]) return;
      hits.add(index);
    });
    // `forEach` visits ascending indices, so `accepted.rank` is non-decreasing.
    return [for (final virtual in hits) accepted.rank(virtual)];
  }
}
