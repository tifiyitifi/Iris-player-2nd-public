import 'package:drift/drift.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Schema v48: drop the retired `bg_source_rules` table.
///
/// 副音 no longer has its own candidate-source rules: it resolves its pool from
/// the reserved 「副音备选」tag (a tag VIEW, shared with the foreground tag play),
/// so the rule table has no reader or writer.
///
/// The old rules are NOT migrated: the per-tag source model they fed was retired
/// with the tag source (see `MigrationV49`), and 副音's only candidate source is
/// now the single reserved tag. The user-visible consequence is stated in the
/// changelog.
///
/// This reads the legacy table only. The still-older KV JSON rules
/// (`BackgroundPlaybackState.sources`) are unreachable from a migration and are
/// NOT recovered.
class MigrationV48 {
  final AppDatabase db;

  MigrationV48(this.db);

  static const _table = 'bg_source_rules';

  Future<void> run(Migrator m) async {
    await db.customStatement('DROP TABLE IF EXISTS $_table');
    _log.i('MigrationV48: dropped $_table');
  }
}
