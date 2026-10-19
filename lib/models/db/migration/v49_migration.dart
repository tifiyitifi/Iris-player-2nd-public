import 'package:drift/drift.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Schema v49: retire the scenario TAG SOURCE.
///
/// A tag membership is no longer a scenario SOURCE kind — it is a VIEW over a
/// scenario (`TagViewResolver`), shared by the foreground tag play and 副音. The
/// leftover `tag:<id>` sentinel source rows (the reserved 「副音备选」 default and
/// the concrete tag sources earlier builds could carry) are deleted here, and
/// the now-unused `tag_id` column is dropped.
///
/// Re-entrant: the row delete is unconditional and the column drop is guarded
/// by `PRAGMA table_info`. A database already at this schema (or a fresh
/// install, which creates the table without the column) is a no-op.
class MigrationV49 {
  final AppDatabase db;

  MigrationV49(this.db);

  static const _table = 'scenario_sources';
  static const _column = 'tag_id';

  Future<void> run(Migrator m) async {
    if (!await _tableExists(_table)) return;

    // Old builds stored a tag source's identity in storage_id as `tag:<id>`
    // (and the reserved tag as ''). Delete by KIND, not by sentinel shape, so
    // the removal is exact.
    //
    // Case-insensitive on purpose: `textEnum` writes the enum's lowercase
    // `name`, but any other spelling left in the column would fail the
    // `values.byName` decode at READ time (an unknown enum value throws), so it
    // has to be taken out here instead of surfacing as a broken scenario later.
    await db.customStatement(
      "DELETE FROM $_table WHERE source_kind IS NOT NULL "
      "AND lower(source_kind) = 'tag'",
    );

    final columns = await _columnNames(_table);
    if (columns.contains(_column)) {
      try {
        await db.customStatement('ALTER TABLE $_table DROP COLUMN $_column');
        _log.i('MigrationV49: dropped $_table.$_column');
      } catch (e) {
        // SQLite < 3.35 cannot DROP COLUMN. The column is no longer read or
        // written by the app, so leaving it in place is harmless — the schema
        // version still advances.
        _log.w('MigrationV49: could not drop $_table.$_column ($e); '
            'leaving the unused column in place');
      }
    }
    _log.i('MigrationV49: retired tag scenario sources');
  }

  Future<bool> _tableExists(String name) async {
    final rows = await db.customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(name)],
    ).get();
    return rows.isNotEmpty;
  }

  Future<Set<String>> _columnNames(String table) async {
    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    return {for (final r in rows) r.read<String>('name')};
  }
}
