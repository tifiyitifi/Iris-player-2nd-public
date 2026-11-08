import 'package:drift/drift.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Schema v52: the derived queue index becomes rebuildable in a new format, and
/// the shared-order cache gets an eviction clock.
///
/// Two new columns:
///
/// - `media_orders.last_used_at` — the cache had NO production GC. One key per
///   (storage, sort field, direction, grouping, media-type set) is 4 B per node,
///   so a 500k library that keeps switching sorts reached ~32 MB PER STORAGE and
///   never shrank. The builder now keeps the most recently used few and ranks
///   them by this column.
/// - `scenario_shared_index.element_order` — the element-axis permutation that
///   lets a VM merged row sort by the totals it DISPLAYS (schema-only for now;
///   a scenario without VM rules stores NULL).
///
/// Both steps are re-entrant (`PRAGMA table_info` guard), so a partially applied
/// upgrade can be retried safely.
///
/// The derived rows are then dropped, deliberately:
///
/// - `scenario_shared_index` / `scenario_queue_builds` are a rebuildable cache.
///   Their blobs encode the OLD base-order construction and the OLD order
///   semantics (`0` ranked as a real value), so serving them would keep the bug
///   alive until some unrelated rescan happened to invalidate them.
/// - `media_orders` likewise: every stored order was built with the previous
///   ORDER BY. They are a pure cache (`INSERT OR REPLACE` on the next build), so
///   clearing them costs one rebuild and nothing else. This mirrors v46, which
///   cleared them when the ORDER BY changed.
class MigrationV52 {
  final AppDatabase db;

  MigrationV52(this.db);

  static const String mediaOrdersTable = 'media_orders';
  static const String sharedIndexTable = 'scenario_shared_index';
  static const String queueBuildsTable = 'scenario_queue_builds';

  /// Columns this migration guarantees, exposed so the test can assert them.
  static const String lastUsedAtColumn = 'last_used_at';
  static const String elementOrderColumn = 'element_order';

  Future<void> run(Migrator m) async {
    try {
      await _addColumnIfMissing(
        table: mediaOrdersTable,
        column: lastUsedAtColumn,
        definition: 'INTEGER NOT NULL DEFAULT 0',
      );
      await _addColumnIfMissing(
        table: sharedIndexTable,
        column: elementOrderColumn,
        definition: 'BLOB',
      );

      // Rebuildable cache only — no user data is touched.
      if (await _tableExists(mediaOrdersTable)) {
        await db.customStatement('DELETE FROM $mediaOrdersTable');
      }
      if (await _tableExists(sharedIndexTable)) {
        await db.customStatement('DELETE FROM $sharedIndexTable');
      }
      if (await _tableExists(queueBuildsTable)) {
        await db.customStatement('DELETE FROM $queueBuildsTable');
      }
      _log.i('MigrationV52: derived queue index + shared orders reset '
          'for the v4 global-order rebuild');
    } catch (e) {
      // Never swallow: a half-applied schema must abort the open so the next
      // launch retries instead of running on a shape the code cannot read.
      _log.e('MigrationV52 failed', e);
      rethrow;
    }
  }

  Future<void> _addColumnIfMissing({
    required String table,
    required String column,
    required String definition,
  }) async {
    if (!await _tableExists(table)) return;
    if (await _columnExists(table, column)) return;
    await db.customStatement('ALTER TABLE $table ADD COLUMN $column $definition');
  }

  Future<bool> _tableExists(String name) async {
    final rows = await db.customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(name)],
    ).get();
    return rows.isNotEmpty;
  }

  Future<bool> _columnExists(String table, String column) async {
    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    return rows.any((r) => r.read<String>('name') == column);
  }
}
