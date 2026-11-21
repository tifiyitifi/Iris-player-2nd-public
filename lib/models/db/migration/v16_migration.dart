import 'package:drift/drift.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Schema v16: Virtual Merge resume-anchor state.
///
/// Creates `virtual_media_states` when missing (fresh installs get it via
/// onCreate). Re-entrant.
///
/// History note: v16 originally also created `virtual_media_rules`; that
/// table was abandoned by the v2 redesign (schema v18 replaces it with
/// `vm_rules`). Existing databases keep the leftover `virtual_media_rules`
/// table untouched — it is simply never read again.
class MigrationV16 {
  final AppDatabase db;

  MigrationV16(this.db);

  Future<void> run(Migrator m) async {
    await _createIfAbsent(
        'virtual_media_states', db.virtualMediaStatesTable, m);
  }

  Future<void> _createIfAbsent(
      String name, TableInfo<Table, dynamic> table, Migrator m) async {
    final rows = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: <Variable>[Variable.withString(name)],
    ).get();
    if (rows.isNotEmpty) return;
    _log.i('MigrationV16: creating $name');
    await m.createTable(table);
  }
}
