import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/model/db/dao/media_order_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_shared_index_dao.dart';
import 'package:iris/features/scenario_playback/resolver/base_order_view.dart';
import 'package:iris/features/scenario_playback/resolver/shared_base_order.dart';
import 'package:iris/features/scenario_playback/resolver/shared_index_codec.dart';
import 'package:iris/features/scenario_playback/resolver/shared_row_overlay.dart';

/// Read-side reconstruction of a persisted shared index, supporting BOTH stored
/// shapes:
///
///  - `SingleBaseOrder` — one storage's shared order + a membership bitmap (the
///    single-source scenario, byte-identical to the v44 form);
///  - `MultiBaseOrder` — the global interleave of the storages' shared orders.
///
/// Tests use it instead of always assuming the bitmap form, so a scenario that
/// legitimately switched shape is still decoded the way the app decodes it.
Future<({BaseOrderView base, SharedRowOverlay overlay})> decodeSharedIndex({
  required ScenarioSharedIndexBlobs blobs,
  required MediaOrderDao orderDao,
}) async {
  final accepted = SharedIndexCodec.decodeBitmap(blobs.accepted);
  final stored = SharedIndexCodec.decodeSlices(blobs.slices);
  final BaseOrderView base;
  if (stored is MultiBaseOrder) {
    final orders = <Int32List>[];
    for (final stream in stored.order.streams) {
      final order = await orderDao.read(stream.orderKey, mediaRev: stream.mediaRev);
      expect(order, isNotNull,
          reason: 'order ${stream.orderKey} must be cached');
      orders.add(order!);
    }
    base = MergedBaseOrder(
      order: stored.order,
      orders: orders,
      accepted: accepted,
      placeholderCount: accepted.length - stored.order.length,
    );
  } else {
    final slices = <SharedOrderSlice>[];
    for (final s in (stored as SingleBaseOrder).slices) {
      final order = await orderDao.read(s.orderKey, mediaRev: s.mediaRev);
      expect(order, isNotNull, reason: 'order ${s.orderKey} must be cached');
      slices.add(
          SharedOrderSlice(orderKey: s.orderKey, order: order!, bits: s.bits));
    }
    base = SharedBaseOrder(slices: slices, accepted: accepted);
  }
  return (
    base: base,
    overlay: SharedRowOverlay(
      baseCount: blobs.baseCount,
      absorbed: SharedIndexCodec.decodeBitmap(blobs.absorbed),
      groupRows: SharedIndexCodec.decodeGroups(blobs.groupRows),
      placeholders: SharedIndexCodec.decodePlaceholders(blobs.placeholders),
      occurrence: SharedIndexCodec.decodeIntMap(blobs.occurrence),
      flags: SharedIndexCodec.decodeIntMap(blobs.flags),
    ),
  );
}
