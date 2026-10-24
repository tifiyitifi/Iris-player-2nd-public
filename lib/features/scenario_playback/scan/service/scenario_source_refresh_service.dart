import 'dart:async';

import 'package:flutter/material.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/media_library/scan/service/recursive_scan_service.dart';
import 'package:iris/features/media_library/scan/service/scan_preflight.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart'
    show ScanPhase;
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/features/media_library/scan/view/scan_options_dialog.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/features/scenario_playback/actions/explicit_file_probe.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_explicit_item.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/scan/model/scenario_source_refresh_state.dart';
import 'package:iris/features/scenario_playback/scan/store/scenario_source_refresh_store.dart';
import 'package:iris/features/scenario_playback/scan/view/scenario_source_refresh_summary_dialog.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/service/vm_membership_pin.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

final areaKeyLog = AreaKeyLog(LogKeys.legacyScenario);

/// Input to one scenario-source refresh run, resolved before any IO starts.
///
/// Extracted as a plain value object so the planner is unit-testable without
/// an AppDatabase: [planSourceRefresh] turns the persisted source rows into a
/// list of these.
class ScenarioSourceRefreshUnitSpec {
  const ScenarioSourceRefreshUnitSpec({
    required this.storage,
    required this.rootPaths,
    required this.directories,
    required this.explicitItems,
    required this.explicitProbeTargets,
    required this.weight,
  });

  final Storage storage;

  /// Merged, ancestor-collapsed scan roots (canonical form) for this storage.
  final List<String> rootPaths;

  /// Every source row on this storage (used for coverage bookkeeping).
  final List<ScenarioSource> directories;

  /// Explicit single-file picks that live on this storage (only the direct
  /// file itself is existence-checked — never its parent subtree).
  final List<ScenarioExplicitItem> explicitItems;

  /// Explicit items the source scan will NOT re-probe, i.e. the ones whose
  /// canonical path falls outside every [rootPaths] entry.
  ///
  /// The directory scan re-probes everything under its roots, so re-probing a
  /// covered item would be duplicate work. Anything outside — including EVERY
  /// item of an explicit-only storage (no roots at all) — is refreshed by a
  /// targeted per-file probe instead, so "Rescan source" really does update
  /// every row the queue shows.
  final List<ScenarioExplicitItem> explicitProbeTargets;

  /// Work weight used for the batch progress bar.
  final int weight;
}

/// Result of [planSourceRefresh]: the ordered storage units plus the number of
/// duplicate source rows that were collapsed while planning.
class ScenarioSourceRefreshPlan {
  const ScenarioSourceRefreshPlan({
    required this.units,
    required this.dedupedSources,
  });

  final List<ScenarioSourceRefreshUnitSpec> units;
  final int dedupedSources;
}

/// Collapses the scan roots of one storage: an ancestor path fully covers its
/// descendants, so only the shortest roots survive (canonicalized, sorted).
///
/// A root of `''` (whole storage) collapses everything. Both `a` and `a/b`
/// present → `a` wins; a recursive ancestor also covers non-recursive children.
/// Returns the merged roots in ascending length order.
List<String> collapseRootPaths(Iterable<String> rawPaths) {
  final canonical = rawPaths
      .map(canonicalDbPath)
      .where((p) => p.isNotEmpty)
      .toSet()
      .toList()
    ..sort((a, b) => a.length.compareTo(b.length));

  final kept = <String>[];
  for (final path in canonical) {
    final covered = kept.any(
      (k) => path == k || path.startsWith('$k/'),
    );
    if (!covered) kept.add(path);
  }
  return kept;
}

/// Whether [filePath] lies at or below [rootPath], comparing PATH SEGMENTS.
///
/// A plain string prefix is not enough: the root `…/20260610/001` must not
/// claim `…/20260610/0010/…` or `…/20260610/001-backup/…`. An empty root is the
/// storage root and covers everything.
///
/// [foldCase] mirrors the platform's filesystem semantics (Windows drive / UNC
/// / SMB shares fold, POSIX/SAF/remote do not).
bool pathInsideRoot({
  required String filePath,
  required String rootPath,
  bool foldCase = false,
}) {
  String norm(String p) {
    // Backslashes arrive from legacy / drag-drop absolute Windows forms; the
    // canonical DOMAIN form is forward-slash, so fold the separator before
    // comparing (`canonicalDbPath` itself never rewrites `\`).
    final canonical = canonicalDbPath(p.replaceAll('\\', '/'));
    return foldCase ? canonical.toLowerCase() : canonical;
  }

  final file = norm(filePath);
  final root = norm(rootPath);
  if (root.isEmpty) return true;
  return file == root || file.startsWith('$root/');
}

/// Plans a refresh run from persisted sources + explicit items.
///
/// Pure logic (no IO): groups by storageId, drops sources whose storage is no
/// longer present, collapses covered roots and derives a weight per storage
/// from its pre-scan node aggregates. Dedup accounting is done by the caller
/// before this runs (the DB transaction owns it).
ScenarioSourceRefreshPlan planSourceRefresh({
  required List<ScenarioSource> sources,
  required List<ScenarioExplicitItem> explicitItems,
  required Map<String, Storage> storageById,
  required Map<String, int> nodeWeightByStorage,
}) {
  // Group sources by storage, keeping only live storages.
  final dirsByStorage = <String, List<ScenarioSource>>{};
  final filesByStorage = <String, List<ScenarioSource>>{};
  final seen = <String>{};
  var dropped = 0;
  for (final s in sources) {
    if (!storageById.containsKey(s.storageId)) {
      dropped++;
      continue;
    }
    final key = '${s.storageId}|${canonicalKey(s.storageId, s.path)}';
    if (!seen.add(key)) {
      dropped++;
      continue;
    }
    if (s.sourceKind.name == 'file') {
      filesByStorage.putIfAbsent(s.storageId, () => []).add(s);
    } else {
      dirsByStorage.putIfAbsent(s.storageId, () => []).add(s);
    }
  }

  // Explicit items grouped by storage (only live storages).
  final explicitByStorage = <String, List<ScenarioExplicitItem>>{};
  for (final e in explicitItems) {
    if (!storageById.containsKey(e.storageId)) continue;
    explicitByStorage.putIfAbsent(e.storageId, () => []).add(e);
  }

  final storageIds = <String>{
    ...dirsByStorage.keys,
    ...filesByStorage.keys,
    ...explicitByStorage.keys,
  }.toList()
    ..sort();

  final units = <ScenarioSourceRefreshUnitSpec>[];
  for (final id in storageIds) {
    final storage = storageById[id]!;
    final dirs = dirsByStorage[id] ?? const <ScenarioSource>[];
    final files = filesByStorage[id] ?? const <ScenarioSource>[];
    final explicit = explicitByStorage[id] ?? const <ScenarioExplicitItem>[];

    // Directory roots: empty path = storage root (whole storage). A stored
    // source path may be storage-RELATIVE (model-canonical) or base-INCLUSIVE
    // (legacy/drag-drop); the scan service expects the absolute domain form, so
    // non-empty roots are absolutized here (empty stays '' so the whole-storage
    // marker survives to [hasWholeStorageSource]).
    final dirRoots = dirs
        .map((s) => s.path.trim().isEmpty
            ? ''
            : StoragePathCodec.absolutize(
                s.storageId, canonicalDbPath(s.path)))
        .toList();
    final fileParents = <String>[];
    for (final f in files) {
      final parent = _parentOf(f.path);
      fileParents.add(parent.isEmpty
          ? ''
          : StoragePathCodec.absolutize(f.storageId, parent));
    }
    final roots = collapseRootPaths([...dirRoots, ...fileParents]);
    // A whole-storage source collapses to the storage base path. An
    // explicit-ONLY storage (no source rows) yields NO scan roots: the
    // explicit single files are existence-checked directly, never their
    // parent subtree (spec: "对检查直接文件仅检查文件").
    //
    // Note: `collapseRootPaths` drops the empty (whole-storage) marker, so a
    // directory source whose path is '' must be detected BEFORE collapsing to
    // become the storage base path.
    final hasWholeStorageSource = dirRoots.any((p) => p.trim().isEmpty);
    final resolvedRoots = <String>[
      if (hasWholeStorageSource) storage.basePath.join('/'),
      ...roots.map((r) => r.isEmpty ? storage.basePath.join('/') : r),
    ];

    units.add(ScenarioSourceRefreshUnitSpec(
      storage: storage,
      rootPaths: resolvedRoots,
      directories: dirs,
      explicitItems: explicit,
      explicitProbeTargets: explicitItemsOutsideRoots(
        explicitItems: explicit,
        rootPaths: resolvedRoots,
        foldCase: storage.type == StorageType.network ||
            pathRidesCaseInsensitiveFs(storage.basePath.join('/')),
      ),
      weight: (nodeWeightByStorage[id] ?? 1).clamp(1, 1 << 30),
    ));
  }

  return ScenarioSourceRefreshPlan(units: units, dedupedSources: dropped);
}

/// The explicit items a source scan will NOT reach, i.e. the ones outside every
/// scan root (see [ScenarioSourceRefreshUnitSpec.explicitProbeTargets]).
///
/// No roots (an explicit-only storage) means nothing is covered, so every item
/// is returned.
List<ScenarioExplicitItem> explicitItemsOutsideRoots({
  required List<ScenarioExplicitItem> explicitItems,
  required List<String> rootPaths,
  bool foldCase = false,
}) =>
    [
      for (final item in explicitItems)
        if (!rootPaths.any((root) => pathInsideRoot(
              filePath: item.path,
              rootPath: root,
              foldCase: foldCase,
            )))
          item,
    ];

String _parentOf(String path) {
  final canonical = canonicalDbPath(path);
  final idx = canonical.lastIndexOf('/');
  return idx <= 0 ? '' : canonical.substring(0, idx);
}

/// Orchestrates the "扫描更新源数据" action for ONE scenario.
///
/// Reuses the generic [RecursiveScanService] per storage (incremental diff,
/// offline-safe deletes, optional probe) while owning the CROSS-storage batch:
/// it preflights each remote storage, scans them sequentially, existence-checks
/// explicit single files against their parent listings, then refreshes the
/// resolved queue exactly once.
class ScenarioSourceRefreshService {
  ScenarioSourceRefreshService({this.listDir, this.probeExplicit});

  /// Listing seam for tests (defaults to the storage's detailed listing).
  final Future<FileListResult> Function(Storage storage, List<String> path)?
      listDir;

  /// Targeted explicit-item probe seam (defaults to
  /// [probeExplicitFilesDetailed]).
  ///
  /// Exists so the "source refresh also refreshes manually added items" pass
  /// can be asserted without touching the filesystem or the Shell probe.
  final Future<ExplicitProbeOutcome> Function(
      List<ExplicitFileProbeTarget> targets)? probeExplicit;

  /// Entry point. Returns true when a refresh actually ran to completion (the
  /// queue may have been refreshed); false when it was cancelled / refused.
  Future<bool> refreshScenarioSources({
    required BuildContext context,
    required String scenarioId,
  }) async {
    final batchStore = useScenarioSourceRefreshStore();
    final scanStore = useRecursiveScanStore();
    final t = getLocalizations(context);

    // Single-flight: the generic scan store allows exactly one scan at a time.
    if (scanStore.isScanning) {
      if (context.mounted) {
        await _infoDialog(context, t.scn_scan_busy_title, t.scn_scan_busy_body);
      }
      return false;
    }

    final scenarioStore = usePlaybackScenarioStore();
    await scenarioStore.ensureReady();

    // ── 1. Tidy source rows (canonical dedup), scoped to this scenario ──
    final deduped =
        await DbModule.scenarioRepo.dedupeScenarioSources(scenarioId);
    final sources = await DbModule.scenarioRepo.getSources(scenarioId);
    final explicit = await DbModule.scenarioRepo.getExplicitItems(scenarioId);

    // ── 2. Build the storage map from live storages only ──
    final storageStore = useStorageStore();
    final storageById = <String, Storage>{
      for (final s in storageStore.state.storages) s.id: s,
    };

    final nodeWeightByStorage = <String, int>{};
    for (final s in sources) {
      nodeWeightByStorage.putIfAbsent(
        s.storageId,
        () => 1,
      );
    }
    // Seed weights from existing aggregates when an exact/root node is known.
    for (final id in nodeWeightByStorage.keys.toList()) {
      nodeWeightByStorage[id] = await _estimateStorageWeight(id);
    }

    final plan = planSourceRefresh(
      sources: sources,
      explicitItems: explicit,
      storageById: storageById,
      nodeWeightByStorage: nodeWeightByStorage,
    );

    if (plan.units.isEmpty) {
      if (context.mounted) {
        await _infoDialog(context, t.scn_scan_none_title, t.scn_scan_none_body);
      }
      return false;
    }

    // ── 3. Preflight every remote storage up front; unreachable → skipped ──
    final prepared = <_PreparedStorage>[];
    for (var i = 0; i < plan.units.length; i++) {
      if (!context.mounted) return false;
      final unit = plan.units[i];
      final isRemote = unit.storage.type == StorageType.webdav ||
          unit.storage.type == StorageType.ftp;
      if (isRemote) {
        final pre = await prepareStorageForScan(unit.storage);
        if (!pre.ok) {
          storageStore.markDisconnected(unit.storage.id);
          continue;
        }
        storageStore.markConnected(pre.storage!.id);
        prepared.add(_PreparedStorage(i, unit, pre.storage!));
      } else {
        prepared.add(_PreparedStorage(i, unit, unit.storage));
      }
    }

    if (prepared.isEmpty) {
      if (context.mounted) {
        await _infoDialog(
            context, t.scn_scan_all_offline_title, t.scn_scan_all_offline_body);
      }
      return false;
    }

    // ── 4. Scan options (probe default ON, restored from last choice) ──
    if (!context.mounted) return false;
    final probeEnabled = await showScanOptionsDialog(
      context,
      storageType: prepared.first.storage.type,
    );
    if (probeEnabled == null || !context.mounted) return false;

    // ── 5. Run the batch ──
    batchStore.reset();
    batchStore.start([
      for (final unit in plan.units)
        ScenarioSourceRefreshUnit(
          storageId: unit.storage.id,
          storageName: unit.storage.name,
          weight: unit.weight,
        ),
    ]);
    batchStore.recordDedupedSources(deduped);

    // The generic per-scan bar would show one storage's progress and
    // auto-close after each; the batch owns the UI for the whole run.
    scanStore.setOverlaySuppressed(true);

    var missingExplicit = 0;
    var probedExplicit = 0;
    var batchAborted = false;

    // Mirror the generic scan store's per-dir progress into the batch store.
    final progressSub = scanStore.stream.listen((state) {
      if (!batchStore.state.isRunning) return;
      final fraction = state.progressFraction;
      batchStore.updateUnitProgress(
        fraction: fraction,
        currentPath: state.currentScanningPath,
        totalDirs: state.totalDirs,
        scannedDirs: state.scannedDirs,
      );
    });

    try {
      for (final entry in prepared) {
        final unitIndex = entry.index;
        batchStore.beginUnit(unitIndex);

        // A leftover error phase would trigger the generic resume dialog
        // mid-batch; the batch owns its own lifecycle, so reset first.
        if (scanStore.state.phase == ScanPhase.error) {
          await scanStore.resetScan();
        }

        if (!context.mounted) {
          batchAborted = true;
          break;
        }

        // Explicit-only unit: no directory to scan. Go straight to the
        // direct-file existence check (never walk the parent subtree), then
        // refresh the metadata of the files that are still there.
        if (entry.unit.rootPaths.isEmpty) {
          final check = await checkExplicitFiles(entry.unit);
          missingExplicit += check.missing;
          if (probeEnabled) {
            probedExplicit += await probeUncoveredExplicitFiles(
              entry.unit,
              presentPaths: check.presentPaths,
            );
          }
          batchStore.finishUnit(unitIndex);
          continue;
        }

        final service = RecursiveScanService(
          storage: entry.storage,
          scanStore: scanStore,
          nodesDao: DbModule.mediaNodesDao,
          sourcesDao: DbModule.mediaLibSourcesDao,
          probeService: probeEnabled ? createMediaProbeService() : null,
          // Same seam as the explicit-file check, so an end-to-end refresh can
          // run against a fake listing instead of the live filesystem.
          listDir: listDir,
        );
        try {
          // ignore: use_build_context_synchronously
          await service.scanRecursively(
            rootPaths: entry.unit.rootPaths,
            context: context,
          );
        } catch (e, st) {
          areaKeyLog.e('ScenarioSourceRefresh unit failed '
              'storage=${entry.storage.id}: $e\n$st');
        }

        final phase = scanStore.state.phase;
        if (phase == ScanPhase.stopped) {
          // User stopped mid-batch: freeze what we have, keep prior results.
          batchStore.finishUnit(unitIndex);
          batchAborted = true;
          break;
        }

        // Existence-check the explicit single files on this (reachable) storage,
        // then refresh the ones the scan above could not reach.
        final check = await checkExplicitFiles(entry.unit);
        missingExplicit += check.missing;
        if (probeEnabled) {
          probedExplicit += await probeUncoveredExplicitFiles(
            entry.unit,
            presentPaths: check.presentPaths,
          );
        }
        batchStore.finishUnit(unitIndex);
      }
    } finally {
      await progressSub.cancel();
    }

    // The ONE completion surface is the summary dialog below; it is built from
    // this snapshot, so it must be captured before both progress surfaces are
    // torn down.
    var summary = batchStore.state;
    try {
      // Skipped units still advance the batch to 100% (decided, not scanned).
      for (var i = 0; i < plan.units.length; i++) {
        if (!batchStore.state.units[i].finished) {
          batchStore.finishUnit(i, skipped: true);
        }
      }
      batchStore.recordMissingExplicitFiles(missingExplicit);
      batchStore.recordProbedExplicitFiles(probedExplicit);

      // ── 6. Refresh the resolved queue ONCE ──
      // A stopped run keeps whatever each finished storage already wrote (the
      // incremental scan is per-directory atomic); it simply does not signal a
      // queue refresh for a batch it never completed.
      if (batchAborted) {
        batchStore.stop();
      } else {
        // Manual/auto source refresh is one of the four legitimate re-group
        // triggers: drop any delete-time VM boundary freeze so chunks derive
        // fresh from the rescanned content.
        VmMembershipPin.instance.clear();
        await scenarioStore.bumpPlaybackVersion();
        await scenarioStore.bumpSourceScanRevision(
          storages: {for (final e in prepared) e.storage.id},
        );
        batchStore.complete();
      }
      summary = batchStore.state;
    } finally {
      // ── 7. Tear down BOTH progress surfaces, THEN show the dialog ──
      // Releasing the overlay suppression while the generic scan store is
      // still `done` would mount its auto-close countdown underneath the
      // summary dialog; the batch panel would linger behind it too. Resetting
      // both to idle first makes the dialog the single completion surface
      // (the "several popups" regression). Safe here: all media writes and
      // revisions are already committed.
      batchStore.reset();
      await scanStore.resetScan();
      scanStore.setOverlaySuppressed(false);
    }

    if (context.mounted) {
      await showScenarioSourceRefreshSummaryDialog(context, summary);
    }
    return !batchAborted;
  }

  /// Re-probes the explicit items the source scan does NOT cover.
  ///
  /// Sources refresh their own subtrees; a manually added file outside them
  /// would otherwise keep whatever metadata it had (the field report: 19
  /// "added" rows kept a poisoned duration after "Rescan source" said it ran).
  /// Only files the existence check just confirmed are probed — a missing file
  /// has nothing to probe, and an unreachable parent listing proves nothing.
  ///
  /// Returns the number of files whose row was actually written.
  Future<int> probeUncoveredExplicitFiles(
    ScenarioSourceRefreshUnitSpec unit, {
    required Set<String> presentPaths,
  }) async {
    final present = {for (final p in presentPaths) canonicalDbPath(p)};
    final targets = [
      for (final item in unit.explicitProbeTargets)
        if (present.contains(canonicalDbPath(item.path))) item,
    ];
    if (targets.isEmpty) return 0;
    try {
      final probe = probeExplicit ?? probeExplicitFilesDetailed;
      final outcome = await probe([
        for (final item in targets)
          ExplicitFileProbeTarget(
            storageId: unit.storage.id,
            path: canonicalDbPath(item.path),
            uri: mediaNodePlayableUri(
              unit.storage,
              pathConv(canonicalDbPath(item.path)),
            ),
          ),
      ]);
      return outcome.written;
    } catch (e) {
      // A probe failure only costs the refresh of these rows; the scan itself
      // already succeeded.
      areaKeyLog.w('Explicit probe pass failed: $e');
      return 0;
    }
  }

  /// Existence-check explicit single files: list each file's PARENT directory
  /// and delete the media node only when the listing succeeded and the file is
  /// genuinely absent. Failed listings never delete (offline-safe).
  ///
  /// Returns the number of files confirmed missing (and removed) plus the
  /// canonical paths confirmed present (the only ones worth probing).
  Future<({int missing, Set<String> presentPaths})> checkExplicitFiles(
      ScenarioSourceRefreshUnitSpec unit) async {
    if (unit.explicitItems.isEmpty) {
      return (missing: 0, presentPaths: const <String>{});
    }
    final byParent = <String, List<ScenarioExplicitItem>>{};
    for (final item in unit.explicitItems) {
      byParent.putIfAbsent(_parentOf(item.path), () => []).add(item);
    }

    final presentPaths = <String>{};
    var missing = 0;
    for (final entry in byParent.entries) {
      final parent = entry.key;
      final items = entry.value;
      final segments = parent.isEmpty
          ? <String>[]
          : (isSafPath(parent) ? safSegmentsOf(parent) : parent.split('/'));

      List<FileItem> listed;
      try {
        final lister =
            listDir ?? (Storage s, List<String> p) => s.getFilesDetailed(p);
        final result = await lister(unit.storage, segments);
        if (result.hasError) continue; // offline/failed → never delete
        listed = result.items;
      } catch (e) {
        areaKeyLog.e('Explicit check listing failed at $parent: $e');
        continue;
      }

      final present = <String>{
        for (final f in listed) f.name.toLowerCase(),
      };

      final toDelete = <String>[];
      for (final item in items) {
        final name = canonicalDbPath(item.path).split('/').last;
        if (!present.contains(name.toLowerCase())) {
          toDelete.add(item.path);
          missing++;
        } else {
          presentPaths.add(canonicalDbPath(item.path));
        }
      }
      if (toDelete.isNotEmpty) {
        try {
          await DbModule.mediaNodesDao
              .batchDeleteByPaths(unit.storage.id, toDelete);
        } catch (e) {
          areaKeyLog.e('Explicit node cleanup failed: $e');
        }
      }
    }
    return (missing: missing, presentPaths: presentPaths);
  }

  /// Best-effort weight estimate for one storage, from the top-level node
  /// aggregates already in the DB (total item count of every root-level node).
  /// Falls back to 1 when the storage was never scanned.
  Future<int> _estimateStorageWeight(String storageId) async {
    try {
      final roots = await DbModule.mediaNodesDao.getRootLevelNodes(storageId);
      var total = 0;
      for (final node in roots) {
        total += node.totalItemCount;
      }
      return total.clamp(1, 1 << 30);
    } catch (_) {
      return 1;
    }
  }

  Future<void> _infoDialog(BuildContext context, String title, String body) {
    return showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(getLocalizations(dialogCtx).close),
          ),
        ],
      ),
    );
  }
}

class _PreparedStorage {
  const _PreparedStorage(this.index, this.unit, this.storage);
  final int index;
  final ScenarioSourceRefreshUnitSpec unit;
  final Storage storage;
}
