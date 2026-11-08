import 'package:drift/drift.dart';
import 'package:iris/features/media_library/model/db/tables/scan_queue_table.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/storage_scope.dart';
import 'package:iris/utils/path_prefix_remap.dart';

part 'scan_queue_dao.g.dart';

@DriftAccessor(tables: [ScanQueueTable])
class ScanQueueDao extends DatabaseAccessor<AppDatabase>
    with _$ScanQueueDaoMixin {
  ScanQueueDao(super.db);

  Future<void> clearForStorage(String storageId) async {
    await customUpdate(
      'DELETE FROM scan_queue WHERE data_scope_id = ?',
      variables: [Variable.withString(StorageScope.of(storageId))],
      updates: {scanQueueTable},
    );
  }

  /// Deletes a scope's queued rows by canonical scope id (no translation).
  Future<void> clearByScopeId(String scopeId) async {
    await customUpdate(
      'DELETE FROM scan_queue WHERE data_scope_id = ?',
      variables: [Variable.withString(scopeId)],
      updates: {scanQueueTable},
    );
  }

  /// Re-points a scope's queued rows to a surviving owner entry (see
  /// `MediaNodesDao.reassignStorageIdForScope`).
  Future<void> reassignStorageIdForScope({
    required String scopeId,
    required String newStorageId,
  }) async {
    await customUpdate(
      'UPDATE scan_queue SET storage_id = ? WHERE data_scope_id = ?',
      variables: [
        Variable.withString(newStorageId),
        Variable.withString(scopeId),
      ],
      updates: {scanQueueTable},
    );
  }

  /// Rewrites the leading [oldBase] of every queued row's `path` under
  /// [storageId] to [newBase] (drive-letter reassignment).
  Future<int> remapPathPrefix({
    required String storageId,
    required String oldBase,
    required String newBase,
  }) async {
    final query = buildPathPrefixRemap(
      table: 'scan_queue',
      keyColumn: 'data_scope_id',
      keyValue: StorageScope.of(storageId),
      oldBase: oldBase,
      newBase: newBase,
    );
    return customUpdate(
      query.sql,
      variables: query.variables,
      updates: {scanQueueTable},
    );
  }

  Future<void> enqueue(String storageId, List<String> paths, int depth) async {
    if (paths.isEmpty) return;
    final scopeId = StorageScope.of(storageId);
    await batch((b) {
      for (final p in paths) {
        b.insert(
          scanQueueTable,
          ScanQueueTableCompanion.insert(
            storageId: storageId,
            dataScopeId: Value(scopeId),
            path: p,
            depth: depth,
            status: const Value('pending'),
          ),
          onConflict: DoNothing(target: [scanQueueTable.dataScopeId, scanQueueTable.path]),
        );
      }
    });
  }

  Future<void> markStatus(String storageId, String path, String status) async {
    await customUpdate(
      'UPDATE scan_queue SET status = ?, updated_at = ? WHERE data_scope_id = ? AND path = ?',
      variables: [
        Variable.withString(status),
        Variable.withString(DateTime.now().toIso8601String()),
        Variable.withString(StorageScope.of(storageId)),
        Variable.withString(path),
      ],
      updates: {scanQueueTable},
    );
  }

  /// Marks many paths `done` in ONE statement.
  ///
  /// The scan's per-directory bookkeeping used to be one UPDATE (one
  /// transaction) per directory, which a 34k-directory phone volume turns into
  /// 34k commits. Chunked for the same SQLite variable limit as the node deletes.
  Future<void> markDoneBatch(String storageId, List<String> paths) async {
    if (paths.isEmpty) return;
    const chunkSize = 900;
    final updatedAt = DateTime.now().toIso8601String();
    for (var i = 0; i < paths.length; i += chunkSize) {
      final chunk = paths.sublist(
        i,
        i + chunkSize > paths.length ? paths.length : i + chunkSize,
      );
      await customUpdate(
        'UPDATE scan_queue SET status = ?, updated_at = ? '
        'WHERE data_scope_id = ? AND path IN (${List.filled(chunk.length, '?').join(',')})',
        variables: [
          Variable.withString('done'),
          Variable.withString(updatedAt),
          Variable.withString(StorageScope.of(storageId)),
          for (final path in chunk) Variable.withString(path),
        ],
        updates: {scanQueueTable},
      );
    }
  }

  Future<List<String>> getPendingPaths(String storageId) async {
    final rows = await customSelect(
      'SELECT path FROM scan_queue WHERE data_scope_id = ? AND status = ?',
      variables: [
        Variable.withString(StorageScope.of(storageId)),
        Variable.withString('pending')
      ],
      readsFrom: {scanQueueTable},
    ).get();
    return rows.map((r) => r.read<String>('path')).toList();
  }

  Future<int> countAll(String storageId) async {
    final rows = await customSelect(
      'SELECT COUNT(*) as cnt FROM scan_queue WHERE data_scope_id = ?',
      variables: [Variable.withString(StorageScope.of(storageId))],
      readsFrom: {scanQueueTable},
    ).getSingle();
    return rows.read<int>('cnt');
  }

  Future<Map<int, List<String>>> loadDepthPaths(String storageId) async {
    final rows = await customSelect(
      'SELECT path, depth FROM scan_queue WHERE data_scope_id = ? AND status IN (?, ?)',
      variables: [
        Variable.withString(StorageScope.of(storageId)),
        Variable.withString('pending'),
        Variable.withString('scanning')
      ],
      readsFrom: {scanQueueTable},
    ).get();
    final map = <int, List<String>>{};
    for (final r in rows) {
      final depth = r.read<int>('depth');
      final path = r.read<String>('path');
      map.putIfAbsent(depth, () => []).add(path);
    }
    return map;
  }
}
