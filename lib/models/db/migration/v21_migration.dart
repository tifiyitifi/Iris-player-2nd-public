import 'package:drift/drift.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Schema v21: virtual-media per-scenario progress + player title separator.
///
/// - Creates `vm_progress` table (scenarioId/tagId/scopeKey → segmentKey+pos)
///   for PotPlayer-style “whole virtual merge as one file” resume.
/// - Adds `vm_rules.playerTitleSeparator` (TEXT DEFAULT ':') for the
///   configurable player title “目录:序号/总数:原名” separator.
/// Re-entrant: checks column/table existence before mutating.
class MigrationV21 {
  final AppDatabase db;
  MigrationV21(this.db);

  Future<void> run(Migrator m) async {
    // Canonical path: let Drift create the table from VmProgressTable so
    // column types (dateTime etc.) always match the accessors. Raw SQL
    // previously created updated_at as TEXT, disagreeing with Drift's
    // dateTime mapping on read/write.
    final hasVmProgress = await _hasTable('vm_progress');
    if (hasVmProgress != true) {
      _log.i('MigrationV21: creating vm_progress');
      try {
        await m.createTable(db.vmProgressTable);
      } catch (e) {
        // Do NOT swallow: drift only rolls the schema version back when
        // onUpgrade throws. A swallowed failure would stamp v21 with the table
        // missing, and no later open would ever retry.
        _log.e('MigrationV21: vm_progress create failed', e);
        rethrow;
      }
    }

    // New column on existing rules table.
    final cols = await _columnNames('vm_rules');
    if (cols != null && !cols.contains('player_title_separator')) {
      _log.i('MigrationV21: adding vm_rules.player_title_separator');
      try {
        await db.customStatement(
            "ALTER TABLE vm_rules ADD COLUMN player_title_separator TEXT NOT NULL DEFAULT ':'");
      } catch (e) {
        // Do NOT swallow: a missing column while the version advances would
        // break the player-title separator. Rethrowing rolls the migration back
        // so the next open retries.
        _log.e('MigrationV21: addColumn failed', e);
        rethrow;
      }
    }
  }

  Future<bool?> _hasTable(String name) async {
    try {
      final rows = await db.customSelect(
        'SELECT name FROM sqlite_master WHERE type = ? AND name = ?',
        variables: <Variable>[
          Variable.withString('table'),
          Variable.withString(name)
        ],
      ).get();
      return rows.isNotEmpty;
    } catch (e) {
      // A failed existence probe is an infrastructure failure, not evidence the
      // table is absent; rethrow so the open retries instead of acting on a
      // guess (which would surface as a misleading secondary error).
      _log.e('MigrationV21: sqlite_master probe failed', e);
      rethrow;
    }
  }

  Future<Set<String>?> _columnNames(String table) async {
    final tables = await db.customSelect(
      'SELECT name FROM sqlite_master WHERE type = ? AND name = ?',
      variables: <Variable>[
        Variable.withString('table'),
        Variable.withString(table)
      ],
    ).get();
    if (tables.isEmpty) return null;
    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    return rows.map((r) => r.read<String>('name')).toSet();
  }
}
