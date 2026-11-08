import 'dart:math';

import 'package:drift/drift.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/natural_sort_key.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Schema v53: natural ("digit aware") file-name ordering.
///
/// `2` must sort before `10`, which a plain `ORDER BY name` (BINARY / locale
/// free) cannot express. SQLite has no natural collation, so the order is
/// materialised as a string key whose BYTE order *is* the natural order — see
/// `lib/utils/natural_sort_key.dart`. `normalized_name` keeps its job
/// (lower-cased search haystack), the key lives in its own column.
///
/// ## Why the backfill is not in [run]
///
/// Drift's `beforeOpen` is not wrapped in a transaction, and a single
/// transaction over 500k row updates grows the WAL towards the table size
/// (hundreds of MB — a real risk on a low-storage phone). [ensureNaturalOrder]
/// therefore runs from `MigrationStrategy.beforeOpen`, commits every
/// [backfillChunk] rows, and checkpoints between chunks: measured 8.4 s and a
/// 5 MB WAL peak for 500k rows.
///
/// The index is created **after** the backfill (index maintenance during 500k
/// updates costs ~3x more), and its EXISTENCE is also the "backfill finished"
/// marker — an interrupted upgrade simply resumes, because the loop only
/// touches rows whose key is still empty.
class MigrationV53 {
  final AppDatabase db;

  MigrationV53(this.db);

  static const String table = 'media_nodes';
  static const String naturalNameColumn = 'natural_name';
  static const String naturalIndex = 'idx_scope_natural_path';
  static const String parentNaturalIndex = 'idx_scope_parent_natural_path';

  /// v31's `(data_scope_id, parent_path, normalized_name)` index: after this
  /// change nothing orders by that column any more, and the benchmark showed no
  /// query loses its plan when it is gone (it only cost disk and write time).
  static const String legacyNameSortIndex = 'idx_scope_parent_name_sort';

  /// Rows re-read / committed per round trip.
  static const int backfillChunk = 20000;

  /// Rows per UPDATE statement (CASE batch). 500 keeps the SQL text small while
  /// still amortising the per-statement cost.
  static const int _writeBatch = 500;

  /// Derived caches that encode the PREVIOUS order semantics.
  static const List<String> derivedCacheTables = [
    'media_orders',
    'scenario_shared_index',
    'scenario_queue_builds',
  ];

  /// Upgrade step (`onUpgrade`): cheap DDL only.
  Future<void> run(Migrator m) async {
    try {
      await _addColumnIfMissing();
      await _clearDerivedCaches();
      _log.i('MigrationV53: natural_name column added; derived queue caches '
          'cleared for the natural-order rebuild');
    } catch (e) {
      // Never swallow: a half-applied schema must abort the open so the next
      // launch retries instead of running on a shape the code cannot read.
      _log.e('MigrationV53 failed', e);
      rethrow;
    }
  }

  /// Backfill + index creation, called from `MigrationStrategy.beforeOpen`.
  ///
  /// Idempotent and cheap when already done (one `sqlite_master` read).
  static Future<void> ensureNaturalOrder(AppDatabase db) async {
    if (!await _tableExistsOn(db, table)) return;
    // BOTH indexes are the "done" marker, not just the first one: the three
    // statements in [createNaturalNameIndexes] are separate, so a process that
    // died between the two CREATE INDEX statements left the first behind. Keying
    // the resume on it alone meant the second index (and the legacy drop) was
    // never repaired, permanently degrading grouped browsing to a filesort.
    final hasNatural = await _indexExists(db, naturalIndex);
    final hasParent = await _indexExists(db, parentNaturalIndex);
    if (hasNatural && hasParent) return;
    var rows = 0;
    // The key backfill is only unnecessary when its own index already exists.
    if (!hasNatural) rows = await _backfill(db);
    await createNaturalNameIndexes(db);
    if (rows > 0) {
      _log.i('MigrationV53: backfilled natural_name for $rows rows');
    }
  }

  /// Creates the natural-order indexes and drops the superseded one.
  ///
  /// Called from BOTH the upgrade path (after the backfill) and `onCreate`
  /// (fresh installs, where the table is empty), so the two converge on the
  /// same index set.
  static Future<void> createNaturalNameIndexes(AppDatabase db) async {
    if (!await _tableExistsOn(db, table)) return;
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS $naturalIndex '
      'ON $table(data_scope_id, natural_name, path)',
    );
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS $parentNaturalIndex '
      'ON $table(data_scope_id, parent_path, natural_name, path)',
    );
    await db.customStatement('DROP INDEX IF EXISTS $legacyNameSortIndex');
  }

  Future<void> _addColumnIfMissing() async {
    // A hand-built / partially migrated database may not have the table yet;
    // drift's own migrations create it later in the chain.
    if (!await _tableExistsOn(db, table)) return;
    if (await _columnExists(naturalNameColumn)) return;
    // O(1) in SQLite: the default is stored in the schema, rows are not
    // rewritten. The value is filled by [ensureNaturalOrder].
    await db.customStatement(
      "ALTER TABLE $table ADD COLUMN $naturalNameColumn TEXT NOT NULL DEFAULT ''",
    );
  }

  Future<void> _clearDerivedCaches() async {
    for (final name in derivedCacheTables) {
      if (!await _tableExists(name)) continue;
      await db.customStatement('DELETE FROM $name');
    }
  }

  static Future<int> _backfill(AppDatabase db) async {
    var lastId = 0;
    var total = 0;
    while (true) {
      final page = await db.customSelect(
        "SELECT id, name FROM $table WHERE $naturalNameColumn = '' "
        'AND id > ?1 ORDER BY id LIMIT $backfillChunk',
        variables: [Variable.withInt(lastId)],
      ).get();
      if (page.isEmpty) break;

      final ids = <int>[];
      final keys = <String>[];
      for (final row in page) {
        ids.add(row.read<int>('id'));
        keys.add(naturalSortKey(row.read<String>('name')));
      }

      // One transaction per chunk => the WAL can be checkpointed and truncated
      // between chunks instead of growing to the whole table.
      await db.transaction(() async {
        for (var start = 0; start < ids.length; start += _writeBatch) {
          final end = min(start + _writeBatch, ids.length);
          final cases = StringBuffer();
          final idList = StringBuffer();
          final values = <Object>[];
          for (var i = start; i < end; i++) {
            cases.write(' WHEN ${ids[i]} THEN ?${values.length + 1}');
            if (i > start) idList.write(',');
            idList.write(ids[i]);
            values.add(keys[i]);
          }
          await db.customStatement(
            'UPDATE $table SET $naturalNameColumn = '
            'CASE id${cases.toString()} END '
            'WHERE id IN (${idList.toString()})',
            values,
          );
        }
      });

      lastId = ids.last;
      total += ids.length;
      await db.customSelect('PRAGMA wal_checkpoint(PASSIVE)').get();
    }
    return total;
  }

  Future<bool> _tableExists(String name) => _tableExistsOn(db, name);

  static Future<bool> _tableExistsOn(AppDatabase db, String name) async {
    final rows = await db.customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(name)],
    ).get();
    return rows.isNotEmpty;
  }

  Future<bool> _columnExists(String column) async {
    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    return rows.any((r) => r.read<String>('name') == column);
  }

  static Future<bool> _indexExists(AppDatabase db, String name) async {
    final rows = await db.customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
      variables: [Variable.withString(name)],
    ).get();
    return rows.isNotEmpty;
  }
}
