import 'package:flutter/material.dart';
import 'package:iris/features/scenario_playback/actions/scan_play_gate.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/file.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/dialogs/show_append_feedback_dialog.dart';

/// APPEND-style play actions: they ADD files to the SystemPlaying workspace as
/// explicit items WITHOUT clearing the current scope. The workspace keeps its
/// sources/excludes and the appended files join the queue.
class ScenarioAppendActions {
  const ScenarioAppendActions._();

  /// Appends [files] (explicit items) and [directories] (sources) to the
  /// SystemPlayingScenario without clearing the current scope.
  ///
  /// Never overrides: existing sources and explicit items stay; the queue
  /// rebuild is signaled via `bumpPlaybackVersion` (re-resolve) plus
  /// `bumpSourceScanRevision` (in-place re-fetch of an open queue view).
  /// Early-returns ONLY when both lists are empty (v2-D3).
  static Future<void> appendToDefaultScenario(
    List<FileItem> files, {
    List<ScenarioSourceSpec> directories = const [],
  }) async {
    if (files.isEmpty && directories.isEmpty) return;
    final store = usePlaybackScenarioStore();
    final sys = await ensurePlaybackWorkspace();
    await store.addExplicitItemsFor(
      scenarioId: sys.id,
      items: [
        for (final f in files)
          if (f.path.isNotEmpty)
            (
              storageId: f.storageId,
              path: canonicalOccurrencePath(f.path.join('/')),
            ),
      ],
    );
    await store.addSources(
      specs: [
        for (final dir in directories)
          (
            storageId: dir.storageId,
            path: dir.path,
            recursive: dir.recursive,
          ),
      ],
    );
    await store.bumpPlaybackVersion();
    // Appends change the active scenario's resolved queue, so an OPEN queue
    // view must re-fetch in place (sourceScanRevision is the queue's single
    // in-place re-fetch signal; playbackVersion is deliberately ignored).
    // The edit already changed THIS scenario's definition digest, so the
    // refetch signal must not invalidate any other scenario's index.
    await store.notifyQueueRefetch();
  }

  /// Appends [files] + [directories] to the SystemPlaying workspace and shows a
  /// before/after feedback dialog (v14-D2) so the user knows the append landed.
  /// The queue count is the effective resolved total of the SystemPlaying
  /// workspace (`resolvePageFor(page: 0, pageSize: 1).totalItems`), measured
  /// once before and once after the append.
  ///
  /// D16: this variant does NOT early-return on an empty append — the No Media
  /// confirm path relies on the "added 0 items" feedback even when nothing was
  /// appended (the plain variant keeps its early-return).
  ///
  /// [skipGate] is true only on the post-scan resume: the user already chose to
  /// scan, so the append must proceed instead of re-opening the gate.
  static Future<void> appendToDefaultScenarioWithFeedback(
    BuildContext context,
    List<FileItem> files, {
    List<ScenarioSourceSpec> directories = const [],
    bool skipGate = false,
  }) async {
    // Scan gate (files-page / storages-list / lib-tile / lib-content only):
    // a recursive dir that was never fully scanned asks before appending.
    // When the user picks 立即完整扫描, record the pending intent so the append
    // is resumed (same parameters) once the scan completes.
    if (shouldRunScanGate(
      skipGate: skipGate,
      hasRecursiveDirs: directories.isNotEmpty,
    )) {
      final proceed = await ensureDirsScannedWithPendingPlay(
        context,
        directories,
        playOnScanNow: () => appendToDefaultScenarioWithFeedback(
          context,
          files,
          directories: directories,
          skipGate: true,
        ),
      );
      if (!proceed) return;
    }
    final store = usePlaybackScenarioStore();
    // Count on the SAME workspace the append targets: an active independent
    // entry owns its own workspace, so reading SystemPlaying unconditionally
    // produced a misleading 0→0 feedback for independent entries.
    final ws = await ensurePlaybackWorkspace();
    final before = await _effectiveQueueCount(store, ws.id);
    await appendToDefaultScenario(files, directories: directories);
    final after = await _effectiveQueueCount(store, ws.id);
    if (!context.mounted) return;
    await showAppendFeedbackDialog(
      context,
      appended: files,
      beforeCount: before,
      afterCount: after,
      directoryNames: directories
          .map((d) => d.path.isEmpty
              ? getLocalizations(context).vm_title_root_dir
              : d.path)
          .toList(),
    );
  }

  /// Effective resolved queue length of [scenarioId] (0 when it has not been
  /// created yet). Must be the same workspace the append targets.
  static Future<int> _effectiveQueueCount(
    PlaybackScenarioStore store,
    String scenarioId,
  ) async {
    final result =
        await store.resolvePageFor(scenarioId, page: 0, pageSize: 1);
    return result.totalItems;
  }
}
