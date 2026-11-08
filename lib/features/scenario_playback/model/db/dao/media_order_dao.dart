import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:iris/features/scenario_playback/model/db/adapters/int32_blob_codec.dart';
import 'package:iris/features/scenario_playback/model/db/tables/media_orders_table.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';

part 'media_order_dao.g.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Persistence for the shared media orders (schema v44).
///
/// These are a rebuildable cache keyed by `SharedMediaOrder.orderKey`; the
/// revision guard makes a stale order look absent so the caller rebuilds.
@DriftAccessor(tables: [MediaOrdersTable])
class MediaOrderDao extends DatabaseAccessor<AppDatabase>
    with _$MediaOrderDaoMixin {
  MediaOrderDao(super.db);

  /// The stored order for [orderKey], or null when absent OR built against a
  /// different [mediaRev] — a stale order must be rebuilt, never served.
  ///
  /// A stale row is NOT deleted here, deliberately: this is a READ. The read
  /// side passes the revision stamped into a persisted index
  /// (`MergedOrderStream.mediaRev` / `SharedOrderSlice.mediaRev`), which may be
  /// older than the storage's current revision while a live scenario still
  /// resolves that index. Deleting on mismatch removed the CURRENT row that
  /// other scenarios were serving, forcing every one of them to rebuild. Dead
  /// rows are GC'd where the current revision is known —
  /// [pruneStale] on the build path.
  ///
  /// A hit still refreshes `last_used_at`, which is what the LRU prune ranks by.
  Future<Int32List?> read(String orderKey, {required int mediaRev}) async {
    final row = await customSelect(
      'SELECT media_rev, ids FROM media_orders WHERE order_key = ?',
      variables: [Variable.withString(orderKey)],
    ).getSingleOrNull();
    if (row == null) return null;
    if (row.read<int>('media_rev') != mediaRev) return null;
    await _touch(orderKey);
    return Int32BlobCodec.decode(row.read<Uint8List>('ids'));
  }

  Future<void> _touch(String orderKey) async {
    try {
      await customUpdate(
        'UPDATE media_orders SET last_used_at = ? WHERE order_key = ?',
        variables: [
          Variable.withInt(DateTime.now().millisecondsSinceEpoch),
          Variable.withString(orderKey),
        ],
        updates: {mediaOrdersTable},
      );
    } catch (e) {
      // Touching is pure bookkeeping; never fail a read over it.
      _log.w('media_orders touch failed ($orderKey): $e');
    }
  }

  Future<void> write(
    String orderKey, {
    required int mediaRev,
    required Int32List ids,
  }) async {
    await customInsert(
      'INSERT OR REPLACE INTO media_orders '
      '(order_key, media_rev, n, ids, last_used_at) '
      'VALUES (?, ?, ?, ?, ?)',
      variables: [
        Variable.withString(orderKey),
        Variable.withInt(mediaRev),
        Variable.withInt(ids.length),
        Variable.withBlob(Int32BlobCodec.encode(ids)),
        Variable.withInt(DateTime.now().millisecondsSinceEpoch),
      ],
    );
  }

  /// Deletes every order of one scope that was built against a different media
  /// revision (they can never be served again).
  Future<int> pruneStale({
    required String keyPrefix,
    required int currentRev,
  }) async {
    return customUpdate(
      'DELETE FROM media_orders WHERE order_key LIKE ? ESCAPE ? '
      'AND media_rev != ?',
      variables: [
        Variable.withString('${_escapeLike(keyPrefix)}%'),
        Variable.withString(r'\'),
        Variable.withInt(currentRev),
      ],
      updates: {mediaOrdersTable},
    );
  }

  /// Keeps the [keep] most recently used orders of one scope, drops the rest.
  ///
  /// The bound stops the cache from growing to every
  /// (field × direction × grouping × media-type) combination the user can
  /// produce: 16 keys × 4 B/item is ~32 MB at 500k, per storage.
  ///
  /// [keep] MUST cover the LIVE key space of the scope. An evicted order is not
  /// merely rebuilt: the read side resolves a live build's blob against its
  /// orders and, on a miss, degrades that scenario to the legacy walk for the
  /// rest of the session (the build signature is unchanged, so nothing
  /// re-triggers a build). A too-small cap therefore made building one scenario
  /// silently demote another — 4 was small enough that two scenarios sorted
  /// differently (×asc/desc ×grouped, and per media-type set) could exceed it.
  /// [defaultKeep] covers the bounded axes of `SharedMediaOrder.orderKey`.
  Future<int> pruneToRecent({
    required String keyPrefix,
    int keep = defaultKeep,
  }) async {
    return customUpdate(
      'DELETE FROM media_orders WHERE order_key LIKE ? ESCAPE ? AND order_key NOT IN '
      '(SELECT order_key FROM media_orders WHERE order_key LIKE ? ESCAPE ? '
      'ORDER BY last_used_at DESC, order_key ASC LIMIT ?)',
      variables: [
        Variable.withString('${_escapeLike(keyPrefix)}%'),
        Variable.withString(r'\'),
        Variable.withString('${_escapeLike(keyPrefix)}%'),
        Variable.withString(r'\'),
        Variable.withInt(keep < 1 ? 1 : keep),
      ],
      updates: {mediaOrdersTable},
    );
  }

  /// Last-resort bound of [pruneToRecent] (the realistic live key space).
  static const int defaultKeep = 16;

  static String _escapeLike(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

  /// Removes one stored order (named to avoid Drift's `delete(Table)`).
  Future<void> deleteOrder(String orderKey) async {
    await customUpdate(
      'DELETE FROM media_orders WHERE order_key = ?',
      variables: [Variable.withString(orderKey)],
      updates: {mediaOrdersTable},
    );
  }

  /// Drops every stored order (a media rescan invalidates all of them).
  Future<void> clearAll() async {
    await customUpdate('DELETE FROM media_orders',
        updates: {mediaOrdersTable});
  }

  Future<int> count() async {
    final row =
        await customSelect('SELECT COUNT(*) AS c FROM media_orders').getSingle();
    return row.read<int>('c');
  }
}
