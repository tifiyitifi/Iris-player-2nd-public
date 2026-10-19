import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/utils/platform.dart';
import 'package:saf_util/saf_util.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// One-time background repair for SAF media rows created before schema v23
/// (no persisted `uri` column).
///
/// media_nodes rows under an Android SAF storage keep their storage-relative
/// path (`content://<authority>/tree/<id>/rel1/.../file.mp4`) but may have a
/// NULL `uri`. Playback/probe of those rows needs the real content://
/// document URI; re-resolve each file through the SAF provider by descending
/// its relative path (`SafUtil().child(treeUri, relativeNames)`), then store
/// the resulting document URI.
///
/// Best-effort by design: permission loss / provider absence / renames leave
/// rows NULL and they are re-fixed on next browse/scan (both paths persist
/// the uri). Runs once per startup, chunked, and only when SAF storages
/// exist. Never throws into startup.
Future<void> backfillSafMediaUris() async {
  if (!isAndroid) return;
  try {
    // StorageStore loads asynchronously during construction; give it a few
    // frames to settle before reading the storage list.
    for (var i = 0; i < 50 && !useStorageStore().loaded; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!useStorageStore().loaded) return;

    final dao = DbModule.mediaNodesDao;
    final safStorages = useStorageStore()
        .state
        .storages
        .where((s) =>
            s.basePath.isNotEmpty &&
            s.basePath[0].startsWith('content://'))
        .toList();
    if (safStorages.isEmpty) return;

    _log.i('backfillSafMediaUris: ${safStorages.length} SAF storage(s)');
    for (final storage in safStorages) {
      await _backfillStorage(dao, storage);
    }
  } catch (e) {
    _log.w('backfillSafMediaUris failed: $e');
  }
}

/// One row handed to [runSafBackfillLoop]: its storage-relative path and name.
typedef SafBackfillRow = ({String path, String name});

/// Fetches the next chunk of un-healed rows (empty when none are left).
typedef SafBackfillFetch = Future<List<SafBackfillRow>> Function();

/// Attempts to heal one row; `true` only when a URI was actually persisted.
typedef SafBackfillHeal = Future<bool> Function(SafBackfillRow row);

/// The chunked backfill loop, extracted from the DB/SAF calls so its
/// termination contract is unit-testable.
///
/// Terminates on a chunk that came back short, or on a round that healed
/// NOTHING. The brake must be the round's OWN progress: a lifetime-healed
/// counter kept a full chunk of permanently un-healable rows (renamed /
/// deleted / permission revoked) fetching the same batch forever once any
/// earlier round had healed a row.
Future<({int done, int healed})> runSafBackfillLoop({
  required SafBackfillFetch fetch,
  required SafBackfillHeal heal,
  int limit = 200,
}) async {
  final int chunk = limit <= 0 ? 1 : limit;
  var done = 0;
  var healedTotal = 0;
  while (true) {
    final rows = await fetch();
    if (rows.isEmpty) break;
    var healedThisRound = 0;
    for (final row in rows) {
      final ok = await heal(row);
      if (ok) healedThisRound++;
      done++;
      // Pace the channel: one provider round-trip per file already yields
      // often; yield every 20 to keep the raster thread responsive.
      if (done % 20 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    healedTotal += healedThisRound;
    // Rows that could not be resolved (renamed/deleted/revoked) stay NULL; a
    // round that healed nothing can only repeat itself, so stop it.
    if (healedThisRound == 0 || rows.length < chunk) break;
  }
  return (done: done, healed: healedTotal);
}

Future<void> _backfillStorage(MediaNodesDao dao, Storage storage) async {
  final treeUri = storage.basePath[0];
  final stats = await runSafBackfillLoop(
    fetch: () => dao.listSafFilesMissingUri(storage.id, treeUri, limit: 200),
    heal: (row) async {
      final segments = safSegmentsOf(row.path);
      final relative =
          segments.length <= 1 ? <String>[] : segments.sublist(1);
      if (relative.isEmpty) return false;
      try {
        final doc = await SafUtil().child(treeUri, relative);
        if (doc != null && !doc.isDir) {
          await dao.setNodeUri(storage.id, row.path, doc.uri);
          return true;
        }
      } catch (_) {
        // Unreadable file / revoked permission: leave NULL for next browse.
      }
      return false;
    },
  );
  if (stats.done > 0) {
    _log.i('backfillSafMediaUris storage=${storage.id} '
        'done=${stats.done} healed=${stats.healed}');
  }
}
