import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/media_library/scan/service/recursive_scan_service.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/features/media_library/scan/view/scan_options_dialog.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/features/scenario_playback/actions/explicit_file_probe.dart';
import 'package:iris/features/scenario_playback/actions/media_revision_actions.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/dialogs/show_rescan_folder_dialog.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

final _log = AreaKeyLog(LogKeys.legacyScenario);

/// Pure root derivations for the per-row rescan trio.
///
/// Extracted so the three scopes are unit-testable without a database, a
/// scenario, or a live filesystem. All paths are the DOMAIN form (storage-base
/// inclusive, canonical) — the form `RecursiveScanService` expects for roots
/// and `Storage.getFilesDetailed` expects for listing.
abstract final class ScenarioRescanTargets {
  const ScenarioRescanTargets._();

  /// Containing-directory root of a file [path].
  ///
  /// A file directly under the storage base yields the base segments (an empty
  /// list for a base-less remote storage, which the scan service reads as the
  /// storage root).
  static List<String> parentRoot(List<String> path) =>
      path.length <= 1 ? const <String>[] : path.sublist(0, path.length - 1);

  /// Scan root of a scenario [source].
  ///
  /// A source path may be stored storage-RELATIVE (the model's canonical form,
  /// written by the rescan trio and the media-library import) or
  /// base-INCLUSIVE/absolute (legacy rows and drag-drop/override selections).
  /// `RecursiveScanService` always expects the absolute domain form, so the
  /// stored path is absolutized here; an empty path means "the whole storage".
  static String sourceRoot(ScenarioSource source, Storage storage) =>
      source.path.trim().isEmpty
          ? storage.basePath.join('/')
          : StoragePathCodec.absolutize(
              source.storageId, canonicalDbPath(source.path));

  /// Whether [sources] already put the folder [folderRel] (storage-relative,
  /// '' = storage root) into the queue — i.e. the folder's own files resolve
  /// through an existing source, so a rescan needs no source change.
  ///
  /// A folder source covers: an exact path match (recursive or not), or any
  /// descendant of a RECURSIVE source; a whole-storage recursive source covers
  /// everything. File sources never cover a folder.
  ///
  /// [foldCase] enables case-insensitive comparison for a Windows drive-letter /
  /// UNC (SMB) storage, matching the gate's ancestor test; POSIX/SAF/remote
  /// paths stay byte-exact.
  static bool folderCovered({
    required List<ScenarioSource> sources,
    required String storageId,
    required String folderRel,
    bool foldCase = false,
  }) {
    String norm(String s) => foldCase ? s.toLowerCase() : s;
    // Normalize BOTH sides to the storage-relative form: source rows may hold a
    // base-inclusive path (drag-drop/override selections and legacy rows) while
    // [folderRel] is always storage-relative. Comparing raw forms makes an
    // already-sourced folder look uncovered (duplicate source + repeated prompt).
    final rel =
        norm(StoragePathCodec.relativize(storageId, canonicalDbPath(folderRel)));
    for (final source in sources) {
      if (source.sourceKind != ScenarioSourceKind.folder) continue;
      if (source.storageId != storageId) continue;
      final path = norm(StoragePathCodec.relativize(
          source.storageId, canonicalDbPath(source.path)));
      if (path.isEmpty) {
        // Whole-storage scope: recursive covers everything; a non-recursive
        // root source only covers files directly at the storage root.
        if (source.recursive || rel.isEmpty) return true;
        continue;
      }
      if (source.recursive) {
        if (rel == path || rel.startsWith('$path/')) return true;
      } else if (rel == path) {
        return true;
      }
    }
    return false;
  }
}

/// The scenario queue row's three rescan scopes (desktop context/trailing menu).
///
/// Each scope funnels its media-node change through [MediaRevisionActions] so
/// the derived queue index is invalidated exactly like a full source refresh.
/// The single-file scope re-probes metadata and existence-checks the file
/// (removing the node when it is genuinely gone); the directory/source scopes
/// reuse the generic [RecursiveScanService].
abstract final class ScenarioMediaRescanActions {
  const ScenarioMediaRescanActions._();

  /// Test seam for the file existence-check listing.
  ///
  /// Defaults to `Storage.getFilesDetailed`; overriding lets the file scope be
  /// exercised against a fake directory without touching the filesystem.
  @visibleForTesting
  static Future<FileListResult> Function(Storage storage, List<String> path)?
      debugListDirOverride;

  /// Test seam for the metadata probe (defaults to [probeExplicitFiles]).
  @visibleForTesting
  static Future<Set<String>> Function(List<ExplicitFileProbeTarget> targets)?
      debugProbeOverride;

  /// Whether [name] appears among the directory [listed] entries (files only).
  ///
  /// Comparison is case-SENSITIVE unless [foldCase] (a Windows drive-letter /
  /// UNC or SMB target). On a case-sensitive filesystem a case-only rename
  /// leaves a genuinely different name, so a folded compare there would keep the
  /// stale node forever — the opposite of this scope's job. Pure/testable.
  @visibleForTesting
  static bool filePresent({
    required List<FileItem> listed,
    required String name,
    required bool foldCase,
  }) =>
      listed.any(
        (f) =>
            !f.isDir &&
            (f.name == name ||
                (foldCase && f.name.toLowerCase() == name.toLowerCase())),
      );

  /// Whether this storage compares names case-insensitively.
  ///
  /// A Windows network (SMB/UNC) share always folds; a filesystem path folds
  /// only for the drive-letter / UNC form ([pathRidesCaseInsensitiveFs]).
  /// Android internal/SD, SAF tree URIs and remote servers stay case-sensitive.
  @visibleForTesting
  static bool foldsCaseFor(Storage storage, List<String> path) =>
      storage.type == StorageType.network ||
      pathRidesCaseInsensitiveFs(path.join('/'));

  /// ① Rescan one file: existence-check it, delete the node when it is gone,
  /// otherwise re-probe duration/resolution and write it back.
  static Future<void> rescanFile(
    BuildContext context,
    EffectivePlaybackItem item,
  ) async {
    final storage = useStorageStore().findById(item.media.storageId);
    final path = _pathOf(item);
    if (storage == null || path.isEmpty) return;
    final t = getLocalizations(context);

    final parent = ScenarioRescanTargets.parentRoot(path);
    final List<FileItem> listed;
    try {
      final lister = debugListDirOverride ??
          (Storage s, List<String> p) => s.getFilesDetailed(p);
      final result = await lister(storage, parent);
      if (result.hasError) {
        if (context.mounted) await _offline(context, t);
        return;
      }
      listed = result.items;
    } catch (e) {
      _log.w('rescanFile listing failed at ${parent.join('/')}: $e');
      if (context.mounted) await _offline(context, t);
      return;
    }

    final present = filePresent(
      listed: listed,
      name: path.last,
      foldCase: foldsCaseFor(storage, path),
    );
    if (!present) {
      // Genuinely gone: remove the stale node, then inform (never delete on a
      // failed listing — that branch returned above).
      try {
        await DbModule.mediaNodesDao
            .batchDeleteByPaths(storage.id, [canonicalDbPath(path.join('/'))]);
      } catch (e) {
        _log.w('rescanFile delete failed: $e');
      }
      await MediaRevisionActions.mediaNodesChanged([storage.id]);
      if (context.mounted) {
        await _info(
          context,
          t.scn_rescan_file_missing_title,
          t.scn_rescan_file_missing_body,
        );
      }
      return;
    }

    final uri = mediaNodePlayableUri(
      storage,
      path,
      uri: item.media.maybeMap(file: (f) => f.uri, orElse: () => null),
    );
    final probe = debugProbeOverride ?? probeExplicitFiles;
    final touched = await probe([
      ExplicitFileProbeTarget(
        storageId: storage.id,
        path: canonicalDbPath(path.join('/')),
        uri: uri,
      ),
    ]);
    if (touched.isNotEmpty) {
      await MediaRevisionActions.mediaNodesChanged(touched);
    }
  }

  /// ② Rescan the folder containing the file.
  ///
  /// If the folder is already one of the queue's sources this is a plain
  /// rescan. Otherwise the user is asked (one dialog, probe choice folded in)
  /// whether the folder should join the sources — recursively, this level
  /// only — or the scan should stay list-neutral.
  static Future<void> rescanDirectory(
    BuildContext context,
    EffectivePlaybackItem item,
  ) async {
    final storage = useStorageStore().findById(item.media.storageId);
    final path = _pathOf(item);
    if (storage == null || path.isEmpty) return;
    final root = ScenarioRescanTargets.parentRoot(path).join('/');
    final folderRel =
        relativeToStoragePath(root, [storage.basePath.join('/')]);

    final store = usePlaybackScenarioStore();
    final sources = await store.getSources(item.scenarioId);
    if (!context.mounted) return;

    if (ScenarioRescanTargets.folderCovered(
      sources: sources,
      storageId: storage.id,
      folderRel: folderRel,
      foldCase: foldsCaseFor(storage, path),
    )) {
      // Already sourced — a plain rescan; the scan probe stays the only prompt.
      await _runScan(context: context, storage: storage, root: root);
      return;
    }

    final choice = await showRescanFolderDialog(
      context,
      storageType: storage.type,
      folderName: folderRel.isEmpty ? storage.name : folderRel,
    );
    if (choice == null || !context.mounted) return;

    await _runScan(
      context: context,
      storage: storage,
      root: root,
      probeEnabled: choice.probe,
    );
    if (choice.policy == RescanFolderPolicy.scanOnly) return;
    if (!context.mounted) return;

    await store.addSourceFor(
      item.scenarioId,
      storageId: storage.id,
      path: folderRel,
      recursive: choice.policy == RescanFolderPolicy.addRecursive,
    );
    await store.notifyDefinitionChanged();
  }

  /// ③ Rescan the scenario source that produced the file.
  ///
  /// A single-file source degrades to the file scope; a folder / whole-storage
  /// source scans its saved path (empty = storage base).
  static Future<void> rescanSource(
    BuildContext context,
    EffectivePlaybackItem item,
  ) async {
    final origin = item.origins.isEmpty ? null : item.origins.first;
    if (origin == null) return;
    final sources = await usePlaybackScenarioStore().getSources(item.scenarioId);
    final source = sources.firstWhereOrNull((s) => s.id == origin.sourceId);
    if (source == null || !context.mounted) return;
    if (source.sourceKind == ScenarioSourceKind.file) {
      await rescanFile(context, item);
      return;
    }
    final storage = useStorageStore().findById(source.storageId);
    if (storage == null) return;
    await _runScan(
      context: context,
      storage: storage,
      root: ScenarioRescanTargets.sourceRoot(source, storage),
    );
  }

  /// Shared directory scan: ask for probe options, then walk [root] with the
  /// generic service and announce the storage change.
  ///
  /// [probeEnabled] folds the probe choice in from the merged rescan dialog;
  /// when null the standalone scan-options prompt is shown (the folder was
  /// already sourced, so there is nothing else to ask).
  static Future<void> _runScan({
    required BuildContext context,
    required Storage storage,
    required String root,
    bool? probeEnabled,
  }) async {
    final probe = probeEnabled ??
        await showScanOptionsDialog(context, storageType: storage.type);
    if (probe == null || !context.mounted) return;
    final service = RecursiveScanService(
      storage: storage,
      scanStore: useRecursiveScanStore(),
      nodesDao: DbModule.mediaNodesDao,
      sourcesDao: DbModule.mediaLibSourcesDao,
      probeService: probe ? createMediaProbeService() : null,
    );
    await service.scanRecursively(rootPaths: [root], context: context);
    await MediaRevisionActions.mediaNodesChanged([storage.id]);
  }

  /// Storage-relative? No — the DOMAIN path segments carried by the row's
  /// media node (storage-base inclusive canonical form).
  static List<String> _pathOf(EffectivePlaybackItem item) =>
      item.media.maybeMap(file: (f) => f.path, orElse: () => const <String>[]);

  static Future<void> _offline(
    BuildContext context,
    AppLocalizations t,
  ) async {
    if (!context.mounted) return;
    await _info(context, t.scn_rescan_offline_title, t.scn_rescan_offline_body);
  }

  static Future<void> _info(
    BuildContext context,
    String title,
    String body,
  ) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(getLocalizations(ctx).close),
          ),
        ],
      ),
    );
  }
}
