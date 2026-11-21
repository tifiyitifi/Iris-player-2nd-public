import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:iris/features/meta_settings/engine/playback_resume.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_sort_spec.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider.dart'
    show PlaybackEntry;
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/dialogs/show_override_confirm_dialog.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/playback/vm_session_launcher.dart';
import 'package:iris/features/virtual_media/resolver/vm_preflight.dart';
import 'package:iris/features/virtual_media/scan/vm_scan_facade.dart';
import 'package:iris/features/virtual_media/service/vm_duration_scan.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/service/vm_preflight_coordinator.dart';
import 'package:iris/features/virtual_media/service/vm_pseudo_play_harvest.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';

/// RESOLVED-item play actions: playback of a queue item that is resolved in a
/// given scenario, plus workspace resume/current-play helpers. These never
/// clear the workspace by themselves — an Override happens only through the
/// explicit confirm dialog (B2).
class ScenarioResolvedActions {
  const ScenarioResolvedActions._();

  /// Restores the last playing item into the player on app start.
  ///
  /// Autoplay follows the `playback.resumeOnStartup` policy via
  /// [resolveResumeOnStartup] — never [AppState.autoPlay], which the loader
  /// force-normalizes to false (it is the session play-intent latch, not a
  /// startup policy; reading it here silently produced paused cold starts).
  ///
  /// [store] and [provider] are test seams; production resolves the global
  /// singletons.
  static Future<void> resumeScenarioPlayback({
    PlaybackScenarioStore? store,
    ScenarioPlaybackProvider? provider,
  }) async {
    final app = useAppStore();
    final scenarioStore = store ?? usePlaybackScenarioStore();
    final scenarioProvider = provider ?? PlaybackProviderRegistry.scenario;
    if (app.state.useLegacyStoragePersistence ||
        !app.state.useScenarioDrivenPlayback) {
      return;
    }
    await app.initialized;
    // `initialized` alone races the active-selection restore (onReady's
    // refreshScenarios) — see [PlaybackScenarioStore.ensureReady].
    await scenarioStore.ensureReady();

    // Locate the persisted item by its bounded ordering hint FIRST and recover
    // the entry from that index; the unbounded occurrence walk (`current()`)
    // is only the fallback when no index can be established (absent, or beyond
    // the bounded locate scan). Previously the walk always ran first, then the
    // locate re-walked — three O(position) passes per cold start.
    final index = await scenarioProvider.establishCurrentPosition();
    PlaybackEntry? current;
    if (index != null) {
      current = await scenarioProvider.itemAt(index);
    }
    current ??= await scenarioProvider.current();
    if (current == null) {
      // Empty context: unload any stale media loaded from the persisted queue
      // so a cold start on an empty scenario never resumes the wrong video.
      await _clearPlayerFeed();
      return;
    }
    final autoplay = resolveResumeOnStartup(
      app.state,
      metadataEnabled:
          app.state.useMetadataSettings && MetaSettingsModule.ready,
    );
    // The persisted occurrence may sit INSIDE a merged group: rebuild the
    // virtual session (slider, prev/next, timeline all follow the virtual
    // body) instead of degrading to the single representative file.
    if (await _restoreVirtualSession(current, autoplay: autoplay)) return;
    await scenarioProvider.advanceEntry(current, autoplay: autoplay);
  }

  /// Rebuilds the virtual-media session for a resumed [entry].
  ///
  /// Mirrors `ScenarioPlaybackProvider.play`'s merge branch (shared decision
  /// via [planVmSessionStart]), then lands on the group's most-recently-watched
  /// file (its own saved position). Returns true when a session was restored;
  /// any failure (no covering rule, preflight-degraded member, no progress,
  /// vanished rows) returns false so the caller falls back to the ordinary
  /// single-file feed.
  static Future<bool> _restoreVirtualSession(
    PlaybackEntry entry, {
    required bool autoplay,
  }) async {
    try {
      final scenarioStore = usePlaybackScenarioStore();
      final scenarioId = scenarioStore.state.activeScenarioId;
      if (scenarioId == null) return false;
      if (await VirtualMediaService.instance
              .coveringRuleFor(entry.storageId, entry.path) ==
          null) {
        return false;
      }
      // Scenario-order groups (same derivation as the displayed overlay):
      // base-order grouping could disagree with the list and open the wrong
      // segment / degrade the merged body to a single file.
      final groups = await scenarioStore.resolver.resolveVmGroupsFor(
        scenarioId,
        playbackVersion: scenarioStore.state.playbackVersion,
      );
      final vmGroup =
          groups.byKey[canonicalKey(entry.storageId, entry.path)];
      if (vmGroup == null) return false;
      // Resume the group at its MOST-RECENTLY-WATCHED segment — the same
      // contract a queue-row tap follows (`resolveVmResumeByProgress`), so a
      // restart lands on the physical file the user was actually watching
      // instead of the group's first member. The legacy per-file pre-write
      // (`vm-prewrite`) keeps `lastPlayedAt` on every fed segment, so the
      // recency lookup finds exactly the segment the session was left on. The
      // persisted occurrence still rides along as the bookmark: it pins the
      // COPY when the group holds a duplicated file (scenario `allowDuplicate`).
      final progressByKey = await loadSegmentProgress(vmGroup);
      final plan = planVmSessionStartFromGroups(
        storageId: entry.storageId,
        path: entry.path,
        groups: groups,
        progressByKey: progressByKey,
        targetMediaKey: canonicalKey(entry.storageId, entry.path),
        targetOccurrenceIndex: entry.occurrenceIndex,
        preferRecency: true,
      );
      if (plan == null) return false;
      await VirtualMediaController.instance.startSession(
        queue: plan.queue,
        queueIndex: plan.queueIndex,
        segmentIndex: plan.segmentIndex,
        initialLocalMs: plan.initialLocalMs,
        autoplay: autoplay,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Switches the player to [scenarioId]'s OWN playback context.
  ///
  /// Each scenario (SystemPlaying / each independent entry workspace) keeps its
  /// own queue and its own "current video"; this funnel activates the scenario,
  /// restores that current item (falling back to the first effective item) and
  /// feeds the player. When the scenario is EMPTY the player is unloaded to a
  /// blank state instead of continuing the PREVIOUS scenario's media — true
  /// context isolation. Progress stays global per file, so the same media in two
  /// scenarios resumes from the same position.
  static Future<void> switchPlaybackContext(
    String scenarioId, {
    bool autoplay = true,

    /// Test seam; production resolves the global singleton.
    ScenarioPlaybackProvider? provider,
  }) async {
    final store = usePlaybackScenarioStore();
    final exists = await store.getScenario(scenarioId);
    if (exists == null) {
      await _clearPlayerFeed();
      return;
    }
    if (store.state.activeScenarioId != scenarioId) {
      await store.setActiveScenario(scenarioId);
    }
    final scenarioProvider = provider ?? PlaybackProviderRegistry.scenario;
    var entry = await scenarioProvider.current();
    entry ??= await scenarioProvider.itemAt(0);
    if (entry != null) {
      await scenarioProvider.play(entry, autoplay: autoplay);
    } else {
      await _clearPlayerFeed();
    }
  }

  /// Unloads the player feed for an empty context WITHOUT touching any
  /// scenario progress (unlike [PlaybackProviderRegistry.stop], which resets
  /// the current file's resume state).
  static Future<void> _clearPlayerFeed() async {
    await useAppStore().updateAutoPlay(false);
    await usePlayQueueStore().clear();
  }

  /// Starts playback of the SystemPlaying workspace from its current item
  /// (resuming the scenario's last position), falling back to the first
  /// effective item when none is current. Used by the scenario tab Play
  /// actions so Override/System Play start playback even when the player was
  /// paused or stopped (advanceEntry forces autoplay).
  ///
  /// [scenarioId] targets a specific workspace instead of SystemPlaying — used
  /// when an app entry owns its OWN workspace (override targets that workspace,
  /// so playback must feed it, not SystemPlaying).
  static Future<void> playCurrentWorkspace({String? scenarioId}) async {
    final store = usePlaybackScenarioStore();
    final target = scenarioId == null
        ? store.systemPlayingScenario
        : store.state.scenarios.firstWhereOrNull((s) => s.id == scenarioId);
    if (target == null) return;
    if (store.state.activeScenarioId != target.id) {
      await store.setActiveScenario(target.id);
    }
    final provider = PlaybackProviderRegistry.scenario;
    var entry = await provider.current();
    entry ??= await provider.itemAt(0);
    if (entry != null) {
      await provider.play(entry);
    }
  }

  /// Plays a resolved effective item through the SystemPlaying workspace,
  /// mirroring a files-paged tap (sources-list / Layer-2 media tap).
  ///
  /// When the workspace already represents [scenarioId] — it IS the workspace,
  /// or its `originScenarioId == scenarioId` with an unmodified version (no
  /// conflict) — the item plays directly. Otherwise a destructive Override
  /// confirm is shown first (B2/D2/E1), the workspace is replaced from the
  /// scenario, then playback starts. In both cases the calling popup is popped
  /// once playback begins.
  static Future<void> playResolvedItem(
    BuildContext context, {
    required PlaybackScenarioStore store,
    required String scenarioId,
    required EffectivePlaybackItem item,
    ScenarioSortSpec? previewSort,
    bool forceConfirmIfNotPlaying = false,

    /// When set and [item] is a virtual-merged representative whose group
    /// contains this file, the VM session opens on THAT child segment instead
    /// of the group's most-recently-watched one (expandable row child tap).
    String? vmStartMediaKey,

    /// Occurrence of [vmStartMediaKey] inside the group, so a duplicated file
    /// opens the tapped occurrence instead of the first one.
    int? vmStartOccurrenceIndex,

    /// Called INSTEAD of popping the calling popup once playback starts. Used
    /// by the Preview page to choose its post-play behavior: a no-op keeps the
    /// preview open (stay mode), while the close callback resets the browser
    /// open mode and pops the whole StoragesDb (queue-style).
    VoidCallback? onExitAfterPlay,
  }) async {
    // Capture the navigator before any await so no `context.mounted` guard is
    // needed downstream (dialog via navigator.context, pop via navigator.pop).
    final navigator = Navigator.of(context);

    // The direct/override decision must target the CURRENT playback context
    // (an active independent entry's workspace, else SystemPlaying).
    final sys = currentPlaybackWorkspace(store);

    var direct = false;
    if (sys != null) {
      if (sys.id == scenarioId) {
        direct = true;
      } else {
        final wsState = await store.getState(sys.id);
        final originId = wsState?.originScenarioId;
        final importVersion = wsState?.importVersion;
        final current =
            store.state.scenarios.firstWhereOrNull((c) => c.id == scenarioId);
        final versionConflict =
            importVersion != null && (current?.version ?? 0) > importVersion;
        direct = originId == scenarioId && !versionConflict;
      }
    }

    final needConfirm = !direct ||
        (forceConfirmIfNotPlaying && sys != null && sys.id != scenarioId);
    if (needConfirm) {
      final name = store.state.scenarios
          .firstWhereOrNull((c) => c.id == scenarioId)
          ?.name;
      final ok = await showOverrideConfirmDialog(
        navigator,
        sourceScenarioName: name ?? 'this scenario',
      );
      if (!ok) return;
    }

    await _applyScenarioAndPlay(
      navigator,
      store: store,
      scenarioId: scenarioId,
      item: item,
      previewSort: previewSort,
      vmStartMediaKey: vmStartMediaKey,
      vmStartOccurrenceIndex: vmStartOccurrenceIndex,
      direct: direct,
      onExitAfterPlay: onExitAfterPlay,
    );
  }

  /// Executes the workspace mutation + playback sequence for [playResolvedItem]
  /// without touching BuildContext: ensures the systemPlaying workspace,
  /// overrides it from [scenarioId] when [direct] is false, applies
  /// [previewSort] (dirty-checked), signals the queue change via
  /// `bumpPlaybackVersion`, ensures the active scenario is the workspace, plays
  /// the item, then exits via [onExitAfterPlay] or pops the navigator.
  static Future<void> _applyScenarioAndPlay(
    NavigatorState navigator, {
    required PlaybackScenarioStore store,
    required String scenarioId,
    required EffectivePlaybackItem item,
    ScenarioSortSpec? previewSort,
    String? vmStartMediaKey,
    int? vmStartOccurrenceIndex,
    required bool direct,
    VoidCallback? onExitAfterPlay,
  }) async {
    final ws = await ensurePlaybackWorkspace();

    var changed = false;
    if (!direct) {
      final source = await store.getScenario(scenarioId);
      if (source != null) {
        await store.overrideWorkspace(workspace: ws, source: source);
        changed = true;
      }
    }

    if (previewSort != null) {
      changed =
          (await store.applyPreviewSortConfig(ws.id, previewSort)) || changed;
    }

    // Signal a queue change (override/dirty-apply) to playbackVersion
    // subscribers regardless of whether the active scenario actually switches.
    if (changed) {
      await store.bumpPlaybackVersion();
    }

    if (store.state.activeScenarioId != ws.id) {
      await store.setActiveScenario(ws.id);
    }

    // Virtual-media blocking preflight (user waits on a progress bar): when
    // the tapped item belongs to a feasible merged group, re-verify every
    // segment against the database before the provider starts the session.
    // Findings merge into the service fail map so the tile yellow-marks and
    // playback falls back to normal. A preflight/scan cancel aborts the
    // whole playback (no fallthrough).
    final proceed =
        await _runVmPreflightIfNeeded(navigator, store: store, item: item);
    if (!proceed) return;

    final provider = ScenarioPlaybackProvider(store: store);
    await provider.play(
      PlaybackEntry(
        file: provider.fileOf(item.media),
        storageId: item.media.storageId,
        path: item.pathValue,
        key: item.mediaKey,
        available: item.available,
        occurrenceIndex: item.occurrenceId.occurrenceIndex,
      ),
      targetFileKey: vmStartMediaKey,
      targetOccurrenceIndex: vmStartOccurrenceIndex,
    );

    // The tap ran through a short-lived provider, so the singleton registry
    // provider still holds whatever locate cache it had. Drop it: a later
    // next/previous must re-locate from the freshly persisted current item
    // instead of a stale index left by a pre-tap / pre-sort state.
    PlaybackProviderRegistry.scenario.invalidateActiveSession();

    if (onExitAfterPlay != null) {
      onExitAfterPlay();
    } else if (navigator.mounted && navigator.canPop()) {
      // Dock queue lives inside Home Row, not a PopupRoute — canPop is false
      // so we must NOT pop the root route (white screen). Floating queue is a
      // PopupRoute so canPop true and pop is correct.
      navigator.pop();
    }
  }

  /// Blocking VM preflight for the tapped item's merged group, if any.
  ///
  /// Returns false when the user cancelled (abort the whole playback).
  /// - Already degraded at resolve time with a duration failure: offer ONE
  ///   scan per scope per session (dismissed scopes fall straight through to
  ///   ordinary playback, yellow mark kept).
  /// - Feasible group: re-verify against the database first; fresh duration
  ///   failures get the same single scan offer.
  /// - Other failures (missing node / timeout) stay silent-degraded.
  /// Preflight never blocks playback on unexpected errors: the provider's
  /// own guards decide (feasible → VM, else normal single).
  static Future<bool> _runVmPreflightIfNeeded(
    NavigatorState navigator, {
    required PlaybackScenarioStore store,
    required EffectivePlaybackItem item,
  }) async {
    try {
      final service = VirtualMediaService.instance;
      final key =
          canonicalKey(item.occurrenceId.storageId, item.occurrenceId.path);
      final existing = service.failInfoFor(key);
      if (existing != null) {
        if (_isDurationReason(existing.reason) &&
            !service.isScanDismissed(existing.scopeKey)) {
          final fg = service.failedGroupForScope(existing.scopeKey);
          if (fg != null && navigator.mounted) {
            return await _offerDurationScan(navigator, service, fg);
          }
        }
        return true;
      }
      if (await service.coveringRuleFor(
              item.occurrenceId.storageId, item.occurrenceId.path) ==
          null) {
        return true;
      }
      final wsId = store.state.activeScenarioId;
      if (wsId == null) return true;
      // Scenario-order groups: the preflight must verify the SAME group the
      // displayed row represents (base-order grouping could verify a different
      // set and wrongly mark/pass the tapped merged item).
      final groups = await store.resolver.resolveVmGroupsFor(
        wsId,
        playbackVersion: store.state.playbackVersion,
      );
      final group = groups.byKey[key];
      if (group == null) return true;
      // The scenario screen may have been left during VM pre-flight.
      if (!navigator.mounted) return true;
      final verifyT = getLocalizations(navigator.context);
      final outcome = await verifyWithProgressDialog(
        navigator,
        group,
        (onProgress, isCancelled) => verifyVmGroupForPlayback(
          group,
          onProgress: onProgress,
          shouldCancel: isCancelled,
          l10n: verifyT,
        ),
      );
      // Cancelling the preflight aborts the whole playback.
      if (outcome.cancelled) return false;
      if (outcome.extraFail.isNotEmpty) {
        service.appendFail(outcome.extraFail);
      }
      if (outcome.timedOut && outcome.report != null && navigator.mounted) {
        await showVmVerifyReportDialog(navigator, outcome.report!);
        return true;
      }
      final durationFails = outcome.extraFail.values.where(
        (f) => _isDurationReason(f.reason),
      );
      if (durationFails.isNotEmpty &&
          !service.isScanDismissed(group.scopeKey) &&
          navigator.mounted) {
        return await _offerDurationScan(navigator, service, group);
      }
      return true;
    } catch (_) {
      // Preflight must never block playback: on any unexpected error the
      // provider's own guards decide (feasible → VM, else normal single).
      return true;
    }
  }

  static bool _isDurationReason(VmFailReason reason) =>
      reason == VmFailReason.zeroDuration || reason == VmFailReason.probeFailed;

  /// Single scan-or-cancel offer for one infeasible group.
  ///
  /// Returns false when the user cancelled (abort the whole playback).
  /// Shell-first cascade (slow harvest is opt-in, never automatic): Shell
  /// scan first (skipped wholesale when every segment is network — FTP/WebDAV
  /// have no scan-time probing by design), then a second confirm before the
  /// background media_kit harvest for leftovers. Healed keys are confirmed by
  /// re-reading the database (single source of truth — scan claims alone
  /// never un-mark); a completion report appears whenever failures remain.
  /// "cancel merge" (or dialog dismiss) records a session dismissal so the
  /// prompt does not nag, and playback continues normally.
  static Future<bool> _offerDurationScan(
    NavigatorState navigator,
    VirtualMediaService service,
    VirtualMediaItem group,
  ) async {
    final unknownNames = [
      for (final s in group.segments)
        if (s.durationMs == null || s.durationMs! <= 0) s.name,
    ];
    final wantScan = await showVmDurationScanDialog(
      navigator,
      groupName: group.displayName,
      unknownNames: unknownNames,
      totalSegments: group.segments.length,
    );
    if (wantScan != true || !navigator.mounted) {
      service.dismissScanScope(group.scopeKey);
      return true;
    }
    final healed = <String>{};
    // Durations changed: refresh lists (re-resolve republishes fail marks,
    // subtitles pick up the new durations). Uses the LIGHT propagation so the
    // per-session Shell-empty cache is not wiped (a full rule-change reset
    // would re-probe files already known to be Shell-empty).
    Future<void> applyHealed(Set<String> claimed) async {
      final confirmed = await filterScanHealedByDb(group.segments, claimed);
      if (confirmed.isEmpty) return;
      healed.addAll(confirmed);
      service.removeFailFor(confirmed);
      await service.notifyDurationsChanged();
    }

    final allNetwork =
        group.segments.isNotEmpty && group.segments.every(_isNetworkSegment);
    final perFileTimeout = allNetwork
        ? const Duration(seconds: 30)
        : const Duration(seconds: 20);
    if (!allNetwork) {
      final scanT = getLocalizations(navigator.context);
      final scanOutcome = await scanWithProgressDialog(
        navigator,
        title: scanT.vm_dscan_title,
        cancelLabel: scanT.vm_dscan_stop_scan,
        total: group.segments.length,
        task: (onProgress, isCancelled) => scanVmGroupDurations(
          group.segments,
          onProgress: onProgress,
          shouldCancel: isCancelled,
          skipKeys: service.shellUnsupportedKeys,
          l10n: scanT,
        ),
      );
      // Partial results are already persisted (incremental write-back), so
      // they land even when the user stops the scan. Only genuinely Shell-empty
      // files (VT_EMPTY duration — only a demux can read them) skip the fast
      // path for the rest of the session; a write-back no-op can succeed once
      // its media_nodes row exists, so it must be retried.
      service.markShellUnsupported(scanOutcome.shellEmptyKeys);
      await applyHealed(scanOutcome.succeededKeys.toSet());
      if (scanOutcome.timedOut &&
          scanOutcome.report != null &&
          navigator.mounted) {
        await showVmVerifyReportDialog(navigator, scanOutcome.report!);
      }
      // User stopped the fast scan: keep what landed and continue normal
      // playback (skip the slow-harvest prompt) instead of aborting the whole
      // session — "取消扫描 = 保留已扫结果在 DB 并普通播放".
      if (scanOutcome.cancelled) {
        service.dismissScanScope(group.scopeKey);
        return true;
      }
    }
    if (!navigator.mounted) return true;
    final leftover = [
      for (final s in group.segments)
        if ((s.durationMs == null || s.durationMs! <= 0) &&
            !healed.contains(s.mediaKey))
          s,
    ];
    if (leftover.isEmpty) return true;
    if (!shouldOfferSlowScan([for (final s in leftover) s.mediaKey])) {
      return true;
    }
    final choice = await showVmSlowScanConfirmDialog(
      navigator,
      groupName: group.displayName,
      leftoverNames: [for (final s in leftover) s.name],
    );
    if (choice == VmSlowScanChoice.abort || !navigator.mounted) {
      return false;
    }
    if (choice != VmSlowScanChoice.slowScan) {
      service.dismissScanScope(group.scopeKey);
      return true;
    }
    final harvester = MediaKitHarvestOpener(perFileTimeout: perFileTimeout);
    try {
      final harvestT = getLocalizations(navigator.context);
      final harvestOutcome = await scanWithProgressDialog(
        navigator,
        title: harvestT.vm_resolve_harvest_title,
        cancelLabel: harvestT.vm_harvest_stop,
        total: leftover.length,
        task: (onProgress, isCancelled) => harvestVmDurations(
          leftover,
          opener: harvester.call,
          onProgress: onProgress,
          shouldCancel: isCancelled,
          // Propagate the per-file budget so the network branch (30s) is
          // actually honored, and scale the global budget with the group size
          // so a multi-file network group is not cut off after ~1 minute.
          perFileTimeout: perFileTimeout,
          totalBudget: Duration(
            seconds:
                (leftover.length * perFileTimeout.inSeconds).clamp(60, 600),
          ),
          l10n: harvestT,
        ),
      );
      // Stopping the harvest keeps its partial results and continues normal
      // playback; only the explicit "Cancel playback" gate above aborts.
      await applyHealed(harvestOutcome.succeededKeys.toSet());
      if (harvestOutcome.cancelled) {
        service.dismissScanScope(group.scopeKey);
        return true;
      }
      if (harvestOutcome.failedKeys.isNotEmpty && navigator.mounted) {
        final sample =
            harvestOutcome.failedKeys.take(3).map(_shortName).join(', ');
        final missing = harvestOutcome.failedKeys.length > 3
            ? '$sample, ${harvestT.vm_sheet_more_items(harvestOutcome.failedKeys.length)}'
            : sample;
        await showVmVerifyReportDialog(
          navigator,
          harvestT.vm_harvest_report(harvestOutcome.summary(harvestT), missing),
        );
      }
      return true;
    } finally {
      await harvester.dispose();
    }
  }

  static bool _isNetworkSegment(VirtualSegment seg) {
    try {
      final t = useStorageStore().findById(seg.storageId)?.type;
      return t == StorageType.ftp ||
          t == StorageType.webdav ||
          t == StorageType.network;
    } catch (_) {
      return false;
    }
  }

  static String _shortName(String mediaKey) {
    final idx = mediaKey.lastIndexOf('/');
    return idx < 0 ? mediaKey : mediaKey.substring(idx + 1);
  }
}
