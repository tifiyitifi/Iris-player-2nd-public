import 'package:drift/drift.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Schema v54: the use/exclude polarity of a Virtual Merge rule.
///
/// A rule already had an `enabled` switch; this column adds the second,
/// independent state the folder toggle needs: when enabled, does the rule USE
/// or NOT USE virtual merging for the directories it matches? Existing rows are
/// all inclusion rules, so the SQL default `use` preserves their behaviour
/// without a backfill.
class MigrationV54 {
  final AppDatabase db;

  MigrationV54(this.db);

  Future<void> run(Migrator m) async {
    try {
      final cols = await _columnNames('vm_rules');
      // A hand-built / partially migrated database may not have the table yet;
      // drift's own migrations create it later in the chain.
      if (cols == null) return;
      if (cols.contains('use_mode')) return;
      _log.i('MigrationV54: adding vm_rules.use_mode');
      await m.addColumn(db.vmRulesTable, db.vmRulesTable.useMode);
    } catch (e) {
      // Never swallow: a half-applied schema must abort the open so the next
      // launch retries instead of running on a shape the code cannot read.
      _log.e('MigrationV54 failed', e);
      rethrow;
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
