import 'package:iris/models/db/db_module.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Rewrites every persisted path that begins with a storage's old base path to
/// its new base path.
///
/// This is the "same physical disk, new drive letter" repair. Instead of a full
/// rescan — which re-lists the filesystem, re-probes every file and can lose
/// playback progress — only the leading prefix of each path column changes.
/// Probe data, directory aggregates and `media_nodes.playback_*` columns ride
/// along on the same rows.
///
/// Covered tables (all carry a storage-base-inclusive path):
/// `media_nodes` (path + parent_path), `scan_states`, `scan_queue`,
/// `scenario_sources`, `scenario_explicit_items`, `scenario_excludes`,
/// `video_tag_members`, `media_lib_sources`.
///
/// Favorites and the history store are owned by their Zustand stores, not the
/// DB, and are remapped by the caller alongside this call.
class PathPrefixRemapService {
  const PathPrefixRemapService();

  /// True when a prefix rewrite is meaningful (both bases non-empty and
  /// different). A same-base or empty-base call is a no-op.
  static bool canRemap(String oldBase, String newBase) =>
      oldBase.isNotEmpty && newBase.isNotEmpty && oldBase != newBase;

  /// Applies the rewrite for one storage in a single transaction.
  Future<void> remap({
    required String storageId,
    required String oldBase,
    required String newBase,
  }) async {
    if (!canRemap(oldBase, newBase)) return;
    try {
      await DbModule.mediaNodesDao.attachedDatabase.transaction(() async {
        await DbModule.mediaNodesDao.remapPathPrefix(
            storageId: storageId, oldBase: oldBase, newBase: newBase);
        // External subtitles are stored as ABSOLUTE snapshots inside the row
        // (the video path is rebuilt from the storage at open time). The path
        // rewrite above does not touch that JSON, so remap it explicitly.
        await DbModule.mediaNodesDao.remapSubtitleUris(
            storageId: storageId, oldBase: oldBase, newBase: newBase);
        await DbModule.scanStatesDao.remapPathPrefix(
            storageId: storageId, oldBase: oldBase, newBase: newBase);
        await DbModule.scanQueueDao.remapPathPrefix(
            storageId: storageId, oldBase: oldBase, newBase: newBase);
        await DbModule.scenarioSourcesDao.remapPathPrefix(
            storageId: storageId, oldBase: oldBase, newBase: newBase);
        await DbModule.scenarioExplicitItemsDao.remapPathPrefix(
            storageId: storageId, oldBase: oldBase, newBase: newBase);
        await DbModule.scenarioExcludesDao.remapPathPrefix(
            storageId: storageId, oldBase: oldBase, newBase: newBase);
        await DbModule.videoTagMembersDao.remapPathPrefix(
            storageId: storageId, oldBase: oldBase, newBase: newBase);
        await DbModule.mediaLibSourcesDao.remapPathPrefix(
            storageId: storageId, oldBase: oldBase, newBase: newBase);
      });
    } catch (e, s) {
      // Never abort the storage update: an unmatched/partially-applied prefix
      // is recoverable by a rescan, whereas a failed mount reconciliation would
      // leave the user with a broken entry.
      _log.e('PathPrefixRemapService.remap failed for $storageId '
          '($oldBase -> $newBase): $e\n$s');
    }
  }

  /// Canonical base form used as the stored-path prefix (e.g. `D:`).
  static String baseOf(List<String> basePath) => canonicalDbPath(basePath.join('/'));
}
