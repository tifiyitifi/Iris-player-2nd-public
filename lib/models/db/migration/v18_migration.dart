import 'package:drift/drift.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Schema v18: Virtual Merge rule model v2.
///
/// - Creates `vm_rules` (simplified v2 rule schema) when missing; fresh
///   installs get it via onCreate. Re-entrant.
/// - The v1 `virtual_media_rules` table is deliberately NOT migrated:
///   the rule model changed shape (priority/excludes/templates dropped),
///   the mapping is lossy, and the feature is young. The old table stays
///   in the database as a dead leftover and is never read again. The
///   default `_dirs_as_virtual` rule is re-seeded by
///   [VirtualMediaBootstrap] (AUX-marker guarded, no resurrection).
/// - Clears `virtual_media_states`: the v1 scopeKey format
///   (`rule|root|#chunk` with v1 chunk numbering) can never match a v2
///   group key, so stale anchors are pure garbage.
class MigrationV18 {
  final AppDatabase db;

  MigrationV18(this.db);

  Future<void> run(Migrator m) async {
    final rows = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: <Variable>[Variable.withString('vm_rules')],
    ).get();
    if (rows.isEmpty) {
      _log.i('MigrationV18: creating vm_rules');
      await m.createTable(db.vmRulesTable);
    }

    _log.i('MigrationV18: clearing obsolete virtual_media_states anchors');
    await db.customStatement('DELETE FROM virtual_media_states');
  }
}
