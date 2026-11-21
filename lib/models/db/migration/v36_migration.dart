import 'package:drift/drift.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Schema v36: per-file exclusion rules for virtual merge.
///
/// Adds three `vm_rules` columns backing the new editor switches:
/// `use_exclude_overlong` (exclude single videos longer than the threshold),
/// `max_single_duration_minutes` (threshold, default 35) and
/// `skip_single_segment` (do not virtualize a one-file chunk). SQL defaults
/// match the domain defaults so existing rows pick up the new behavior.
class MigrationV36 {
  final AppDatabase db;

  MigrationV36(this.db);

  Future<void> run(Migrator m) async {
    final cols = await _columnNames('vm_rules');
    if (cols == null) return;
    if (!cols.contains('use_exclude_overlong')) {
      _log.i('MigrationV36: adding vm_rules.use_exclude_overlong');
      await m.addColumn(db.vmRulesTable, db.vmRulesTable.useExcludeOverlong);
    }
    if (!cols.contains('max_single_duration_minutes')) {
      _log.i('MigrationV36: adding vm_rules.max_single_duration_minutes');
      await m.addColumn(
          db.vmRulesTable, db.vmRulesTable.maxSingleDurationMinutes);
    }
    if (!cols.contains('skip_single_segment')) {
      _log.i('MigrationV36: adding vm_rules.skip_single_segment');
      await m.addColumn(db.vmRulesTable, db.vmRulesTable.skipSingleSegment);
    }
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
