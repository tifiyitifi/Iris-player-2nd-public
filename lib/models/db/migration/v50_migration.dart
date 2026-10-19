import 'package:drift/drift.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Schema v50: persist external subtitle associations on `media_nodes`.
///
/// Subtitles pair a video with its sibling `.ass/.srt/.vtt/.sub` files
/// (`getSubtitleMap`) and were computed from every storage listing — but thrown
/// away on write, so every DB-resolved entry (scenario / tag / play queue /
/// library tab) reached the player with `FileItem.subtitles` empty: the track
/// panel offered no external track and no auto-selection happened, while the
/// same file played from the storage browser (a live listing) was fine.
///
/// `subtitles_json` keeps the associations (NULL = unknown, `'[]'` = known
/// none) and the scan/sync re-enrich each row exactly once — see the scan's
/// unchanged-file skip predicate.
///
/// Re-entrant: a database already carrying the column (or a fresh install, where
/// `createAll()` created it) is a no-op.
class MigrationV50 {
  final AppDatabase db;

  MigrationV50(this.db);

  static const _table = 'media_nodes';
  static const _column = 'subtitles_json';

  Future<void> run(Migrator m) async {
    if (!await _tableExists(_table)) return;

    final columns = await _columnNames(_table);
    if (columns.contains(_column)) {
      _log.i('MigrationV50: $_table.$_column already present');
      return;
    }

    await m.addColumn(db.mediaNodesTable, db.mediaNodesTable.subtitlesJson);
    _log.i('MigrationV50: added $_table.$_column');
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
