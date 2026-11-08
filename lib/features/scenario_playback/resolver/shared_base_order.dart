import 'dart:typed_data';

import 'package:iris/features/scenario_playback/resolver/base_order_view.dart';
import 'package:iris/features/scenario_playback/resolver/bit_vector.dart';

/// One scenario source's selection, expressed as a membership bitmap over a
/// SHARED media order.
///
/// [order] is the shared order's node-id sequence; [bits] marks the positions
/// this source selects. The source's ordered files are then
/// `order[bits.select(k)]` for `k in [0, bits.count)` — a rank/select lookup,
/// with no per-scenario copy of the sequence.
class SharedOrderSlice {
  SharedOrderSlice({
    required this.orderKey,
    required this.order,
    required this.bits,
  });

  /// Identifies the shared order this slice indexes (see `SharedMediaOrder`).
  final String orderKey;

  /// The shared order's node ids.
  final Int32List order;

  /// Membership over [order]'s positions.
  final BitVector bits;

  int get count => bits.count;

  /// Node id at the [ordinal]-th selected position.
  int nodeIdAt(int ordinal) => order[bits.select(ordinal)];

  /// Builds a slice by testing every position of [order] with [select].
  static SharedOrderSlice of({
    required String orderKey,
    required Int32List order,
    required bool Function(int nodeId) select,
  }) {
    final b = BitVectorBuilder(order.length);
    for (var i = 0; i < order.length; i++) {
      if (select(order[i])) b.set(i);
    }
    return SharedOrderSlice(orderKey: orderKey, order: order, bits: b.build());
  }
}

/// A scenario's base order expressed over shared-order slices plus an ACCEPTED
/// bitmap over the concatenated virtual space (exclusion + dedup applied).
///
/// The v43 index stored this as one row per accepted element. Here the order is
/// reconstructed instead: accepted rank → virtual index ([accepted] select) →
/// slice (cumulative offsets) → shared position (slice select) → node id. The
/// per-scenario footprint is the slices' bitmaps + [accepted], not the sequence.
class SharedBaseOrder implements BaseOrderView {
  SharedBaseOrder({required this.slices, required this.accepted}) {
    var offset = 0;
    for (final s in slices) {
      _offsets.add(offset);
      offset += s.count;
    }
    _virtualSize = offset;
  }

  /// The scenario's sources, in sortOrder.
  final List<SharedOrderSlice> slices;

  /// Membership over the concatenated virtual space (sum of slice counts).
  final BitVector accepted;

  final List<int> _offsets = [];
  late final int _virtualSize;

  @override
  int get virtualSize => _virtualSize;

  /// Number of ACCEPTED base elements (the queue's index space).
  @override
  int get count => accepted.count;

  /// Node id at [acceptedRank], or null when out of range.
  @override
  int? nodeIdAt(int acceptedRank) {
    if (acceptedRank < 0 || acceptedRank >= count) return null;
    return _nodeIdAtVirtual(accepted.select(acceptedRank));
  }

  /// The whole accepted order (parity/debug; the read path uses [nodeIdAt]).
  Int32List materialize() {
    final out = Int32List(count);
    var r = 0;
    var v = accepted.nextSetBit(0);
    while (v >= 0) {
      out[r++] = _nodeIdAtVirtual(v);
      v = accepted.nextSetBit(v + 1);
    }
    return out;
  }

  /// The ACCEPTED rank of [position] in [slice]'s order, or null when that
  /// position is not a member of this scenario or was filtered out (exclusion /
  /// dedup).
  ///
  /// Occurrence recovery locates a node by scanning a slice's order for its id
  /// and then asking this: it needs the rank without materializing the whole
  /// accepted order, which at 500k would be a 2 MB allocation per call.
  int? acceptedRankAtPosition(SharedOrderSlice slice, int position) {
    if (position < 0 || position >= slice.order.length) return null;
    if (!slice.bits[position]) return null;
    final sliceIndex = slices.indexOf(slice);
    if (sliceIndex < 0) return null;
    final virtualIndex = _offsets[sliceIndex] + slice.bits.rank(position);
    if (virtualIndex >= accepted.length || !accepted[virtualIndex]) return null;
    return accepted.rank(virtualIndex);
  }

  @override
  Iterable<int> acceptedRanksOfNode(int nodeId) sync* {
    // Same lookup the v43 query did, expressed against the shared orders: find
    // the node in a slice's order, then map that position to its accepted rank.
    // A node can legitimately appear twice (overlapping sources with
    // `allowDuplicate`), so every hit is visited — occurrence recovery needs all
    // of them.
    for (final slice in slices) {
      final order = slice.order;
      for (var position = 0; position < order.length; position++) {
        if (order[position] != nodeId) continue;
        final rank = acceptedRankAtPosition(slice, position);
        if (rank != null) yield rank;
      }
    }
  }

  int _nodeIdAtVirtual(int virtualIndex) {
    // Largest slice whose offset is <= virtualIndex.
    var lo = 0;
    var hi = _offsets.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_offsets[mid] <= virtualIndex) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return slices[lo].nodeIdAt(virtualIndex - _offsets[lo]);
  }

  /// Builds the accepted bitmap by walking the virtual space once (the build
  /// cost is the same single pass the resolver already makes).
  ///
  /// [isExcluded] drops a node (the scenario's exclusion rules); [dedupKey]
  /// keeps only the FIRST element of each key — pass the canonical mediaKey, NOT
  /// the node id, so two linked rows of the same file still collapse (that is
  /// what the resolver's dedup does). Null [dedupKey] disables dedup.
  static SharedBaseOrder build({
    required List<SharedOrderSlice> slices,
    bool Function(int nodeId)? isExcluded,
    String Function(int nodeId)? dedupKey,
  }) {
    var virtualSize = 0;
    for (final s in slices) {
      virtualSize += s.count;
    }
    final builder = BitVectorBuilder(virtualSize);
    final keyOf = dedupKey;
    final seen = keyOf == null ? null : <String>{};
    var v = 0;
    for (final slice in slices) {
      for (var k = 0; k < slice.count; k++, v++) {
        final id = slice.nodeIdAt(k);
        if (isExcluded != null && isExcluded(id)) continue;
        if (seen != null && !seen.add(keyOf!(id))) continue;
        builder.set(v);
      }
    }
    return SharedBaseOrder(slices: slices, accepted: builder.build());
  }
}
