import 'package:drift/drift.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Schema v51: give a SAF single-picked file its own `media_nodes` identity.
///
/// A SAF single-picked file (`ACTION_OPEN_DOCUMENT`) is not under a tree, so it
/// has no segment path; older rows stored `path = ''` and kept the document uri
/// in the `uri` column. `UNIQUE(data_scope_id, path)` then collapsed every
/// single pick of one storage onto a single row: a second pick OVERWROTE the
/// first, and a duration write-back could only ever address whichever pick owned
/// the empty path.
///
/// Writers now store the uri as the canonical `path`
/// (`MediaNodeDriftAdapter.canonicalFilePath`). This migration brings existing
/// rows onto that form so the unique key (and every path-keyed lookup) can tell
/// the single picks apart.
///
/// Re-entrant: a row already carrying its uri as the path is untouched (the
/// UPDATE matches its own value), and a duplicate left at `path = ''` next to an
/// already-migrated row is deleted rather than colliding.
class MigrationV51 {
  final AppDatabase db;

  MigrationV51(this.db);

  static const _table = 'media_nodes';

  Future<void> run(Migrator m) async {
    if (!await _tableExists(_table)) return;

    // The empty-path file rows that carry their identity in `uri`. Read as raw
    // rows so the canonicalization stays in Dart (`canonicalDbPath`), matching
    // exactly what the writer produces. The data columns are read too: when a
    // row already sits at the target path, this legacy row is about to be
    // deleted, and deleting it without merging loses any progress/probe data
    // only it carried (its empty path is exactly where the old writer put it).
    final rows = await db
        .customSelect(
          "SELECT id, data_scope_id, uri, duration_ms, width, height, "
          "pixel_count, size_in_bytes, subtitles_json, playback_position_ms, "
          "playback_completed, last_played_at, play_count, "
          "history_restore_budget "
          "FROM $_table "
          "WHERE node_kind = 'file' AND path = '' "
          "AND uri IS NOT NULL AND uri <> ''",
        )
        .get();
    if (rows.isEmpty) {
      _log.i('MigrationV51: no empty-path SAF file rows to re-key');
      return;
    }

    var moved = 0;
    var deduped = 0;
    await db.transaction(() async {
      for (final row in rows) {
        final id = row.read<int>('id');
        final scope = row.read<String?>('data_scope_id');
        final uri = row.read<String>('uri');
        final target = canonicalDbPath(uri);
        if (target.isEmpty) continue;

        // A row already sitting at the target path (an earlier run, or a sibling
        // written by a lane that already used the uri) wins its identity: merge
        // this legacy row's data into it, then drop the duplicate instead of
        // tripping the unique key. Keeping the target's `name` matches the write
        // lane that owns the canonical path.
        final sameScope =
            scope == null ? 'data_scope_id IS NULL' : 'data_scope_id = ?';
        final existing = await db.customSelect(
          "SELECT * FROM $_table WHERE path = ? AND $sameScope",
          variables: [
            Variable.withString(target),
            if (scope != null) Variable.withString(scope),
          ],
        ).get();
        if (existing.isNotEmpty) {
          await _mergeLegacyRow(existing.single, row);
          await db.customStatement(
            'DELETE FROM $_table WHERE id = ?',
            [id],
          );
          deduped++;
          continue;
        }

        await db.customStatement(
          'UPDATE $_table SET path = ? WHERE id = ?',
          [target, id],
        );
        moved++;
      }
    });
    _log.i('MigrationV51: re-keyed $moved SAF file row(s), '
        'merged and dropped $deduped duplicate(s)');
  }

  /// Merges the data only [legacy] carries into the surviving [target] row.
  ///
  /// Every content column takes the target's non-null value first (its path is
  /// the surviving identity); the playback triple comes from whichever row was
  /// played LAST, so a newer legacy progress is not replaced by a stale target
  /// one. `play_count` is a lifetime counter, so it takes the maximum.
  Future<void> _mergeLegacyRow(QueryRow target, QueryRow legacy) async {
    T? pick<T>(String column) {
      final preferred = target.read<T?>(column);
      return preferred ?? legacy.read<T?>(column);
    }

    final int? durationMs = pick<int>('duration_ms');
    final int? width = pick<int>('width');
    final int? height = pick<int>('height');
    final int? storedPixels = pick<int>('pixel_count');
    final int? pixelCount =
        (width != null && height != null) ? width * height : storedPixels;
    final int? sizeInBytes = pick<int>('size_in_bytes');
    final String? subtitles = _pickSubtitles(
      target.read<String?>('subtitles_json'),
      legacy.read<String?>('subtitles_json'),
    );

    final int? targetPlayedAt = target.read<int?>('last_played_at');
    final int? legacyPlayedAt = legacy.read<int?>('last_played_at');
    final bool legacyIsNewer = legacyPlayedAt != null &&
        (targetPlayedAt == null || legacyPlayedAt > targetPlayedAt);
    final QueryRow progress = legacyIsNewer ? legacy : target;
    final QueryRow fallback = legacyIsNewer ? target : legacy;
    int? progressInt(String column) =>
        progress.read<int?>(column) ?? fallback.read<int?>(column);

    final int? positionMs = progressInt('playback_position_ms');
    final int? lastPlayedAt = progressInt('last_played_at');
    final int? historyBudget = progressInt('history_restore_budget');
    final bool completed = (progress.read<int?>('playback_completed') ?? 0) != 0;
    final int playCount = [
      target.read<int?>('play_count') ?? 0,
      legacy.read<int?>('play_count') ?? 0,
    ].reduce((a, b) => a > b ? a : b);

    final String? uri =
        target.read<String?>('uri') ?? legacy.read<String?>('uri');

    await db.customStatement(
      'UPDATE $_table SET duration_ms = ?, width = ?, height = ?, '
      'pixel_count = ?, size_in_bytes = ?, subtitles_json = ?, uri = ?, '
      'playback_position_ms = ?, playback_completed = ?, last_played_at = ?, '
      'play_count = ?, history_restore_budget = ? WHERE id = ?',
      [
        durationMs,
        width,
        height,
        pixelCount,
        sizeInBytes,
        subtitles,
        uri,
        positionMs,
        completed ? 1 : 0,
        lastPlayedAt,
        playCount,
        historyBudget,
        target.read<int>('id'),
      ],
    );
  }

  /// Subtitle associations are "known" data: a non-empty legacy list beats an
  /// empty target list, but an unknown (NULL) target does not beat a known one.
  static String? _pickSubtitles(String? target, String? legacy) {
    if (target == null) return legacy;
    if (target == '[]' && legacy != null && legacy != '[]') return legacy;
    return target;
  }

  Future<bool> _tableExists(String name) async {
    final rows = await db.customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(name)],
    ).get();
    return rows.isNotEmpty;
  }
}
