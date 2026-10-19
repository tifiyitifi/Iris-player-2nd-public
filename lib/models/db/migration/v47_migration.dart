import 'package:drift/drift.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Schema v47: `scenario_sources.tag_id` — the (now retired) tag source kind.
///
/// HISTORICAL: v47 added the column so 副音 could reuse the scenario mechanism
/// with a library-tag default source. That source kind was retired again in v49
/// (tag membership is a tag VIEW now), which drops the column; the step is kept
/// so the migration chain still runs in order for an older database.
///
/// Re-entrant: the column is added only when missing (guarded via
/// PRAGMA table_info).
class MigrationV47 {
  final AppDatabase db;

  MigrationV47(this.db);

  static const _table = 'scenario_sources';
  static const _column = 'tag_id';
  static const _columnType = 'INTEGER NULL';

  Future<void> run(Migrator m) async {
    final columns = await _columnNames(_table);
    if (columns == null) {
      // Table itself absent (fresh installs create it with the column via
      // onCreate); nothing to upgrade here.
      return;
    }
    if (columns.contains(_column)) return;
    _log.i('MigrationV47: adding $_table.$_column');
    await db.customStatement(
      'ALTER TABLE $_table ADD COLUMN $_column $_columnType',
    );
  }

  Future<Set<String>?> _columnNames(String table) async {
    final tables = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: <Variable>[Variable.withString(table)],
    ).get();
    if (tables.isEmpty) return null;

    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    return rows.map((row) => row.read<String>('name')).toSet();
  }
}
