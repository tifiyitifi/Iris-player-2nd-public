// DESIGN DECISION — NO EDL / VIRTUAL TIMELINE (2026-08-25, approved).
// Virtual Media plays its segments via sequential single-file opens.
// Heterogeneous playback stability is the ONLY hard requirement: segments
// may differ in codec/resolution/fps, have missing audio tracks, differing
// track counts, or be corrupt/unreadable.
// mpv EDL was evaluated and rejected because:
//   1. virtual track layout across heterogeneous segments is decided
//      by an undocumented heuristic; missing tracks produce "holes"
//      (officially a non-guaranteed fringe case);
//   2. any source failing to open fails the ENTIRE timeline;
//   3. all segment demuxers are opened eagerly — handles/cache grow
//      linearly with segment count (critical on Android fd limits).
// Sequential playback trades a brief switch gap for graceful degradation
// and constant resource usage. Do NOT replace this with EDL, edl:// URIs,
// or any virtual-timeline mechanism without explicit user approval.
// See .ai_knowledge/tmp/virtual_media/virtual_media_spec_v2.md §0.1.

import 'dart:async';
import 'package:flutter/foundation.dart';

import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/virtual_media/interaction/state/vm_drag_gate.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/progress_write_guard.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/playback/vm_duration_backfill.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/features/virtual_media/vm_l10n.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart'
    show ContentType, FileItem, PlayQueueItem;
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/playback/active_repeat.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/models/storages/storage.dart' show StorageType;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/store/use_tag_play_store.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/utils/seek_tail_guard.dart';

final _log = AreaKeyLog(LogKeys.mediaProbe);

/// Sequential playback driver for Virtual Media sessions (spec §9).
///
/// Owns the four playback touch points WITHOUT the player core ever knowing
/// Virtual Media exists — the player just sees ordinary single-file feeds:
///
/// 1. FEED     — [startSession]/advances push the current segment's physical
///                file through the synthetic single-item play queue (the same
///                proven mechanism scenario/tag-play use).
/// 2. TIMELINE — hooks translate position/duration through
///                [translatePosition]/[totalDurationMs] when [isActive].
/// 3. COMPLETE — hooks ask [maybeHandleCompleted] first; segment end never
///                reaches PlaybackContext.next().
/// 4. ERROR    — hooks route open errors to [handleSegmentError]; a broken
///                segment is skipped, the session survives.

/// Pure boundary decision for stepping within/across items (spec §9.4).
///
/// Returns the new position; `ended: true` when no destination exists
/// (wrap not requested). Entering a PREVIOUS item sets [atItemEnd] so the
/// caller lands on that item's LAST segment. [wrapWithinItem] loops at the
/// item boundary instead of crossing into a sibling — the Repeat.one model
/// (replay the WHOLE merged item, never just the current physical segment).
@visibleForTesting
VmAdvancePlan? vmPlanAdvance({
  required int queueIndex,
  required int segmentIndex,
  required int queueLength,
  required int segmentsLength,
  required bool forward,
  bool wrapRepeatAll = false,
  bool wrapWithinItem = false,
}) {
  final nextSeg = segmentIndex + (forward ? 1 : -1);
  if (nextSeg >= 0 && nextSeg < segmentsLength) {
    return VmAdvancePlan(queueIndex, nextSeg, false, false);
  }
  if (wrapWithinItem && segmentsLength > 0) {
    return VmAdvancePlan(
        queueIndex, forward ? 0 : segmentsLength - 1, false, false);
  }
  final nextQ = queueIndex + (forward ? 1 : -1);
  if (nextQ >= 0 && nextQ < queueLength) {
    return VmAdvancePlan(nextQ, 0, !forward, false);
  }
  if (wrapRepeatAll && queueLength > 0) {
    return VmAdvancePlan(forward ? 0 : queueLength - 1, 0, !forward, false);
  }
  return const VmAdvancePlan(0, 0, false, true);
}

/// Whether a completed segment under Repeat.one must be handled by the virtual
/// controller (replay the whole merged item) rather than handed to the
/// backend's native single-file loop.
///
/// A multi-segment item's "single repeat" is the WHOLE item; letting the
/// backend loop only the current physical segment freezes the virtual
/// progress (it never reaches the item end). A single-segment item is
/// identical to its physical file, so the native loop is correct there.
@visibleForTesting
bool vmRepeatOneHandlesWithinItem({
  required int segmentsLength,
  required int segmentIndex,
}) =>
    segmentsLength > 1 && segmentIndex >= 0 && segmentIndex < segmentsLength;

/// Nearest queue index strictly after/before [fromIndex] (in [forward]
/// direction) whose item passes [isFeasible]. Null when none remains before
/// the queue edge. Never wraps — wrap stays with [vmPlanAdvance].
@visibleForTesting
int? vmNearestFeasibleQueueIndex({
  required int fromIndex,
  required int queueLength,
  required bool forward,
  required bool Function(int index) isFeasible,
}) {
  if (forward) {
    for (var i = fromIndex + 1; i < queueLength; i++) {
      if (isFeasible(i)) return i;
    }
  } else {
    for (var i = fromIndex - 1; i >= 0; i--) {
      if (isFeasible(i)) return i;
    }
  }
  return null;
}

/// [vmPlanAdvance] hardened against unplayable siblings: when the planned
/// neighbour is infeasible (empty / zero-duration item) the plan is re-routed
/// to the nearest feasible item in the SAME direction. An exhausted scan
/// degrades to the terminal plan (`ended`) so the caller ends the session
/// instead of freezing on a segment the queue cannot leave (H1).
@visibleForTesting
VmAdvancePlan? vmPlanFeasibleAdvance({
  required int queueIndex,
  required int segmentIndex,
  required int queueLength,
  required int segmentsLength,
  required bool forward,
  required bool Function(int queueIndex) isFeasible,
  bool wrapRepeatAll = false,
  bool wrapWithinItem = false,
}) {
  final plan = vmPlanAdvance(
    queueIndex: queueIndex,
    segmentIndex: segmentIndex,
    queueLength: queueLength,
    segmentsLength: segmentsLength,
    forward: forward,
    wrapRepeatAll: wrapRepeatAll,
    wrapWithinItem: wrapWithinItem,
  );
  if (plan == null || plan.ended) return plan;
  if (plan.queueIndex < 0 || plan.queueIndex >= queueLength) return plan;
  if (isFeasible(plan.queueIndex)) return plan;
  final alt = vmNearestFeasibleQueueIndex(
    fromIndex: plan.queueIndex,
    queueLength: queueLength,
    forward: forward,
    isFeasible: isFeasible,
  );
  if (alt == null) return const VmAdvancePlan(0, 0, false, true);
  return VmAdvancePlan(alt, 0, !forward, false);
}

class VmAdvancePlan {
  final int queueIndex;
  final int segmentIndex;

  /// True when entering from the BACK into a sibling item — the caller
  /// lands on that item's LAST segment instead of [segmentIndex].
  final bool atItemEnd;
  final bool ended;

  const VmAdvancePlan(
      this.queueIndex, this.segmentIndex, this.atItemEnd, this.ended);
}

/// Whether a deferred segment jump (one that waited for an in-flight feed)
/// is still meaningful against the POST-feed state.
///
/// The caller captured [targetScopeKey] and [index] against the item BEFORE
/// the feed ran. A cross-body feed swaps the scope — the old index then
/// refers to the previous item's segments and must be dropped. Returns false
/// (drop) when the session moved to another scope, the target went
/// out-of-range, or the feed already landed on the target segment (jump
/// collapses to a no-op).
@visibleForTesting
bool vmRevalidateDeferredJump({
  required String targetScopeKey,
  required int index,
  required VirtualMediaItem? currentItem,
  required int currentSegmentIndex,
}) {
  final cur = currentItem;
  if (cur == null) return false;
  if (cur.scopeKey != targetScopeKey) return false;
  if (index < 0 || index >= cur.segments.length) return false;
  if (index == currentSegmentIndex) return false;
  return true;
}

/// Resolves the per-scenario progress scope for session-stop clears.
///
/// Returns null when no scenario owns the session — the caller must SKIP the
/// `vm_progress` clear (never fall back to a scope-wide delete, which would
/// wipe every scenario's/tag's row for the scope). `tagId` follows the table
/// convention: the active tag view id as string, `''` for no-tag.
@visibleForTesting
({String scenarioId, String tagId})? resolveVmProgressScope({
  required String? activeScenarioId,
  required Object? activeViewTagId,
}) {
  if (activeScenarioId == null || activeScenarioId.isEmpty) return null;
  final tag = activeViewTagId;
  return (scenarioId: activeScenarioId, tagId: tag == null ? '' : '$tag');
}

/// Drops a second terminal event (error/completed) for the SAME segment while
/// the first one is still driving a transition/feed. Without it an
/// error→advance followed by the same file's completed→advance skips a
/// healthy segment. Pure: fully unit-testable.
@visibleForTesting
bool shouldDropVmTerminalEvent({
  required String? handledKey,
  required String incomingKey,
  required bool transitioning,
  required bool feedInFlight,
}) {
  if (handledKey == null || handledKey != incomingKey) return false;
  return transitioning || feedInFlight;
}

class VirtualMediaController {
  VirtualMediaController._();

  static final VirtualMediaController instance = VirtualMediaController._();

  VmPlaybackStore get store => useVmPlaybackStore();
  VmPlaybackState get state => store.state;

  /// Canonical key of the segment we last fed; [isActive] self-heals by
  /// comparing it against what the queue is actually playing, so playback
  /// started from ANY other entry point silently ends a stale session.
  String? _expectedSegmentKey;

  int _localMs = 0;
  Timer? _anchorTimer;
  int _consecutiveErrors = 0;
  MediaProbeService? _probeService;

  /// Test seam: overrides the media-node lookup in [_feedCurrent] so a feed
  /// failure (thrown lookup) can be exercised without a broken database.
  /// Null in production — the real [DbModule.mediaNodeRepo] lookup is used.
  @visibleForTesting
  Future<MediaNode?> Function(String storageId, List<String> path)?
      debugNodeLoaderOverride;

  /// Last flushed anchor position: the 5s timer skips the DB write when
  /// neither the segment nor the local position moved (paused/idle sessions
  /// must not churn the database).
  int _lastFlushedMs = -1;
  String? _lastFlushedSegKey;

  /// Backfill generation: each [startSession] bumps it so an older
  /// [_backfillUnknownDurations] loop exits instead of racing the new
  /// session's patches.
  int _backfillGen = 0;

  /// Stashed cross-segment drag target (virtual ms) for the preview
  /// strategy — and for throttled-away direct ticks. Committed exactly once
  /// by the hooks' drag-release effect, so every slider shares one commit
  /// path without touching slider code.
  int? _dragStashVirtualMs;

  /// Last live-drag cross-segment open (throttle anchor, spec §6).
  DateTime? _lastCrossJumpAt;

  /// Monotonic feed generation: every [_feedCurrent] captures the current
  /// value and drops its result when a newer jump/advance/session replaced
  /// it mid-flight (rapid repeated seeks). Without it a slow DB lookup from
  /// an older jump can overwrite [_expectedSegmentKey] after the newer feed,
  /// briefly deactivating the session and routing the next seek down the
  /// ordinary single-file path.
  int _feedSeq = 0;

  /// True while [_feedCurrent] is awaiting its async node lookup / queue push.
  ///
  /// A jump/advance arriving during this window must serialize behind the
  /// in-flight feed instead of issuing a second `player.open` on the same
  /// physical file (the double-open race that resets playback to 0%).
  bool _feedInFlight = false;

  /// The in-flight [_feedCurrent] future, awaited by jumps/advances that
  /// arrive while [_feedInFlight] is true so they never overlap a feed.
  Future<void>? _feedFuture;

  /// Terminal-event guard: key of the segment whose error/completed is
  /// currently driving a transition (`scopeKey:segmentIndex:mediaKey`).
  /// A second terminal event for the same key arriving while transitioning
  /// or feeding is a duplicate emission and must be dropped (see
  /// [shouldDropVmTerminalEvent]). Set synchronously before the first await
  /// so a concurrent duplicate always observes it.
  String? _terminalGuardKey;

  /// The progress value the CURRENT feed pre-writes to the segment's
  /// media_nodes row BEFORE the queue update triggers the player open
  /// (write-before-play).
  ///
  /// The player hook treats every VM feed as an ordinary single file and
  /// lands it through the ONE shared resume path (duration arrival → read
  /// DB progress → seek). The pre-write is what steers that path:
  /// a targeted jump writes the intra-segment target, a sequential advance
  /// writes 0 (explicit from-beginning — a present 0 row never falls back
  /// to stale HistoryStore data), and a plain open writes nothing (the
  /// file's own last progress applies, exactly like a real single video).
  /// Null = no pre-write for the current feed.
  int? _feedPreWriteMs;

  /// True when the NEXT feed must land ON its segment end (finish the merged
  /// item). Set by [_jumpToSegment] with `finishAtEnd` and consumed by
  /// [_feedCurrent] — one-shot carrier, never inherited by an ordinary feed.
  bool _pendingFeedFinishAtEnd = false;

  /// Feed generation whose open must land ON the segment end. The player hooks
  /// read [feedFinishesItem] after the duration arrives, then seek to the
  /// duration so the engine raises `completed` and the provider advances past
  /// the merged item (a cross-segment finish would otherwise open the last
  /// segment mid-file and depend on playing the tail out).
  int _finishOnFeedSeq = 0;

  /// Whether the feed that produced [generation] was opened to finish the item
  /// (see [_pendingFeedFinishAtEnd]). False for any superseded generation.
  bool feedFinishesItem(int generation) =>
      generation > 0 &&
      generation == _feedSeq &&
      _finishOnFeedSeq == generation;

  // ── Reactivity helpers used by UI/hooks ──

  /// Memoized [isActive] inputs: hooks read liveness N times per build/tick
  /// alongside `state.item`/`currentOffsetMs`/`translatePosition`, and the
  /// canonical-key derivation is pure string work. The fingerprint is
  /// identity-based (the item, queue entry and expected key are all immutable
  /// snapshots — identical inputs imply an identical verdict), so a hit can
  /// never go stale; any replacement misses and recomputes once.
  Object? _activeMemoItem;
  Object? _activeMemoEntry;
  int _activeMemoIndex = -1;
  String? _activeMemoExpected;
  bool? _activeMemo;

  bool get isActive {
    final item = state.item;
    if (item == null) {
      _activeMemo = null;
      return false;
    }
    final q = usePlayQueueStore().state;
    final queue = q.playQueue;
    if (queue.isEmpty) {
      _activeMemo = null;
      return false;
    }
    final idx = q.currentIndex.clamp(0, queue.length - 1);
    final entry = queue[idx];
    final memo = _activeMemo;
    if (memo != null &&
        identical(item, _activeMemoItem) &&
        identical(entry, _activeMemoEntry) &&
        idx == _activeMemoIndex &&
        _expectedSegmentKey == _activeMemoExpected) {
      return memo;
    }
    final file = entry.file;
    final key = canonicalProgressKey(file.storageId, file.path, uri: file.uri);
    final active = key == _expectedSegmentKey;
    _activeMemoItem = item;
    _activeMemoEntry = entry;
    _activeMemoIndex = idx;
    _activeMemoExpected = _expectedSegmentKey;
    _activeMemo = active;
    return active;
  }

  /// True while [_feedCurrent] is awaiting its async node lookup / queue push.
  bool get feedInFlight => _feedInFlight;

  /// Clears a STALE session: the store still holds an item but the play queue
  /// is no longer on [_expectedSegmentKey] (e.g. the user opened a normal file
  /// from storage/history without going through the VM stop/step paths).
  ///
  /// The player hooks call this once per build. A switch in flight
  /// ([_feedInFlight]) or a transition is left alone — those windows are
  /// legitimate and short-lived.
  ///
  /// Contract: `transitioning` may NOT be ignored here (a legitimate switch
  /// keeps [isActive] false until its own feed lands), so it must be released
  /// elsewhere first — [clearTransition] while the queue still belongs to the
  /// session, [releaseOrphanedTransition] once it does not. Without those two
  /// release points this method and `transitioning` would guard on each other
  /// forever and the stale item could never drop. Unlike [stop] this NEVER
  /// touches the play queue or autoPlay: the file that replaced the session
  /// keeps playing; only the VM decorations (dual time, segment marks,
  /// timeline translation) drop.
  void reconcileStaleSession() {
    if (state.item == null) return;
    if (_feedInFlight || state.transitioning) return;
    if (isActive) return;
    ++_feedSeq; // invalidate any lingering feed result
    _feedInFlight = false;
    _feedFuture = null;
    _stopAnchorTimer();
    store.replace(const VmPlaybackState());
    _clearSessionKeys();
    _dragStashVirtualMs = null;
    _lastCrossJumpAt = null;
    _log.i('vm stale session cleared (queue left the expected segment)');
  }

  /// Acknowledges (clears) the last fatal session error. Called by the player's
  /// error-dialog host after the user dismisses the dialog, so a later session
  /// starts with a clean state and the dialog is not re-shown.
  void acknowledgeError() {
    if (state.lastError == null) return;
    store.replace(state.copyWith(lastError: null));
  }

  int get totalDurationMs => state.item?.totalDurationMs ?? 0;

  int get currentOffsetMs => state.item?.offsetOf(state.segmentIndex) ?? 0;

  /// Hook-side O(1) tick translation: local engine position → virtual.
  Duration translatePosition(Duration localPosition) =>
      Duration(milliseconds: currentOffsetMs + localPosition.inMilliseconds);

  VirtualSegment get currentSegment {
    final item = state.item!;
    if (item.segments.isEmpty) {
      throw StateError('vm currentSegment on empty item ${item.scopeKey}');
    }
    return item.segments[state.segmentIndex.clamp(0, item.segments.length - 1)];
  }

  /// Null-safe accessor for paths where an empty item must degrade instead
  /// of throwing (flush/advance/error handlers).
  VirtualSegment? get currentSegmentOrNull {
    final item = state.item;
    if (item == null || item.segments.isEmpty) return null;
    return item.segments[state.segmentIndex.clamp(0, item.segments.length - 1)];
  }

  /// Clears per-session keys when a session ends or is replaced: the expected
  /// segment (liveness) plus the anchor-flush watermark (dedup).
  void _clearSessionKeys() {
    _expectedSegmentKey = null;
    _terminalGuardKey = null;
    _lastFlushedMs = -1;
    _lastFlushedSegKey = null;
  }

  /// Key identifying the segment a terminal event is attributed to.
  /// Hooks attribute error/completed to the CURRENT segment, so the guard
  /// key is derived from the current state at event time.
  String _terminalKeyForCurrent() {
    final item = state.item;
    if (item == null || item.segments.isEmpty) return '';
    final idx = state.segmentIndex.clamp(0, item.segments.length - 1);
    return '${item.scopeKey}:$idx:${item.segments[idx].mediaKey}';
  }

  /// Clears THIS session's per-scenario `vm_progress` row. Unknown owner
  /// (no active scenario) skips the delete and logs — a scope-wide fallback
  /// would wipe other scenarios'/tags' resume rows for the same scope.
  Future<void> _clearScopedVmProgress(String scopeKey) async {
    final scope = resolveVmProgressScope(
      activeScenarioId: usePlaybackScenarioStore().state.activeScenarioId,
      activeViewTagId: useTagPlayStore().state.activeViewTagId,
    );
    if (scope == null) {
      _log.w('vm stop skipped vm_progress clear: no active scenario');
      return;
    }
    try {
      await DbModule.virtualMediaRepo.clearVmProgressForScope(
        scope.scenarioId,
        scope.tagId,
        scopeKey,
      );
    } catch (_) {}
  }

  /// Monotonic feed generation, incremented on every [_feedCurrent].
  ///
  /// Hooks capture this right before `player.open` and compare it when a
  /// duration arrives: a mismatch means the duration belongs to a feed that
  /// has since been superseded (double-open race), and seeking/resuming on it
  /// would fight the newer open.
  int get feedGeneration => _feedSeq;

  // ── Session lifecycle ──

  /// Starts (or replaces) a session at [queueIndex]/[segmentIndex].
  ///
  /// Hard guard: only feasible items (non-empty, positive total duration)
  /// may start a session. Callers check preflight first; this is the last
  /// line of defense so an infeasible group can never hijack playback — it
  /// no-ops and the caller falls back to ordinary single-file play.
  ///
  /// [initialLocalMs] opens WITH an intra-segment position (cold-start
  /// anchor restore): it becomes the one-shot [pendingSeekMs] handoff the
  /// hooks consume after open. Null keeps the legacy DB-resume behavior.
  /// [autoplay] false restores the session paused (startup policy off).
  Future<void> startSession({
    required List<VirtualMediaItem> queue,
    required int queueIndex,
    int segmentIndex = 0,
    int? initialLocalMs,
    bool autoplay = true,
  }) async {
    assert(queue.isNotEmpty, 'empty virtual queue');
    if (queue.isEmpty) return;
    if (queueIndex < 0 || queueIndex >= queue.length) return;
    // A feed may still be mid-flight (e.g. a direct list tap lands while the
    // previous segment feed is between its node lookup and its pre-write).
    // Serialize after it: the pre-write slot is a single field, and a stale
    // feed consuming it would leave THIS open with no pre-write — the resume
    // then falls back to a stale/0 row (intermittent from-head).
    if (_feedInFlight) {
      final inflight = _feedFuture;
      if (inflight != null) await inflight;
    }
    final candidate = queue[queueIndex];
    if (candidate.segments.isEmpty || candidate.totalDurationMs <= 0) {
      _log.w('vm startSession rejected infeasible item '
          '(${candidate.scopeKey}): segments=${candidate.segments.length} '
          'total=${candidate.totalDurationMs}');
      return;
    }
    final segIdx = segmentIndex.clamp(0, candidate.segments.length - 1);
    final segDur = candidate.segments[segIdx].durationMs ?? 0;
    // The same segment-tail contract as every other VM seek (clampVmLocalMs):
    // an anchor lands on `segDur - kSeekTailGuardMs` at most, never on the old
    // `segDur - 1` rounding error that sits inside the final GOP.
    //
    // A null [initialLocalMs] keeps the legacy DB-resume behavior (the
    // segment's own saved position decides), so it must NOT become a 0: a 0
    // anchor is an explicit from-the-beginning pre-write and would kill that
    // resume.
    final pending =
        initialLocalMs == null ? null : clampVmLocalMs(segDur, initialLocalMs);
    store.replace(state.copyWith(
      item: queue[queueIndex],
      segmentIndex: segIdx,
      queue: queue,
      queueIndex: queueIndex,
      lastError: null,
      // Targeted open carries the handoff; plain open keeps legacy
      // DB-resume. Either way mark the switch in flight so the UI does
      // not flash the 0% pre-open state.
      pendingSeekMs: pending,
      transitioning: true,
    ));
    _consecutiveErrors = 0;
    _localMs = pending ?? 0;
    _lastFlushedMs = -1;
    _lastFlushedSegKey = null;
    _backfillGen++;
    // Cold-start anchor restore pre-writes the intra-segment position so
    // the shared resume path lands there; a plain open pre-writes nothing
    // and resumes the file's own last progress (real-single-video semantics).
    _feedPreWriteMs = pending;
    _dragStashVirtualMs = null;
    _lastCrossJumpAt = null;
    _startAnchorTimer();
    await _feedCurrent(autoplay: autoplay);
    // Lazy duration backfill: probe segments with unknown duration in the
    // background; failures get the nominal red-bar unit (spec: duration
    // 缺失 → 先尝试获取 → 失败给红条单位).
    unawaited(_backfillUnknownDurations());
  }

  /// Convenience for single-item playback.
  Future<void> startItem(VirtualMediaItem item, {int segmentIndex = 0}) =>
      startSession(queue: [item], queueIndex: 0, segmentIndex: segmentIndex);

  /// PotPlayer-style stop: unload feed + flush anchor + deactivate.
  ///
  /// [preserveProgress] is for NAVIGATION (cross-body next/prev): the session
  /// is torn down but this body's anchor + vm_progress rows are KEPT so
  /// returning to it (prev) resumes the last position. A user stop keeps the
  /// clearing semantics (spec §2).
  Future<void> stop({bool preserveProgress = false, String? keepError}) async {
    final item = state.item;
    if (item == null) return;
    ++_feedSeq; // invalidate any feed still in flight
    // A superseded feed's finally-block checks seq equality before clearing;
    // bumping the generation alone would leak the in-flight flag, so clear
    // it here when no replacement feed takes over.
    _feedInFlight = false;
    _feedFuture = null;
    await _flushAnchor();
    _stopAnchorTimer();
    if (!preserveProgress) {
      // Clear THIS session's per-scenario vm_progress only (spec §2: stop
      // clears). Never a scope-wide delete: the PK is
      // (scenarioId, tagId, scopeKey) and other scenarios/tags share the
      // scope. Anchors stay scope-global by table design.
      await _clearScopedVmProgress(item.scopeKey);
      try {
        await DbModule.virtualMediaRepo.statesDao.deleteByScope(item.scopeKey);
      } catch (_) {}
    }
    store.replace(keepError == null
        ? const VmPlaybackState()
        : VmPlaybackState(lastError: keepError));
    _clearSessionKeys();
    _dragStashVirtualMs = null;
    _lastCrossJumpAt = null;
    await useAppStore().updateAutoPlay(false);
    await usePlayQueueStore().clear();
    _log.i('vm session stopped (${item.displayName}) '
        'preserveProgress=$preserveProgress');
  }

  /// Lightweight deactivate for cross-item NAVIGATION (next/prev): clears
  /// session state + timers but leaves the play queue and autoplay alone.
  ///
  /// Unlike [stop] (which unloads the feed for a user stop), navigation
  /// immediately re-feeds via the scenario provider — tearing down the queue
  /// first would flash an empty queue through every queue listener and
  /// pointlessly toggle autoplay off and back on. The in-flight feed is still
  /// invalidated so a stale lookup cannot push the old file after the step.
  /// Anchors flush first so returning (prev) resumes the last position.
  Future<void> deactivateForNavigation() async {
    final item = state.item;
    if (item == null) return;
    ++_feedSeq; // invalidate any feed still in flight
    _feedInFlight = false;
    _feedFuture = null;
    await _flushAnchor();
    _stopAnchorTimer();
    store.replace(const VmPlaybackState());
    _clearSessionKeys();
    _dragStashVirtualMs = null;
    _lastCrossJumpAt = null;
    _log.i('vm session deactivated for navigation (${item.displayName})');
  }

  /// Stop-to-first: clear virtual progress + first segment progress 0,
  /// then land on segment 0 without auto-play (spec §2).
  Future<void> stopToFirst({bool clearFirstSegmentProgress = true}) async {
    if (state.item == null || state.item!.segments.isEmpty) return;
    // Serialize behind any in-flight feed: the pre-write slot is single-field.
    if (_feedInFlight) {
      final inflight = _feedFuture;
      if (inflight != null) await inflight;
    }
    // Resolve the target from the LIVE state AFTER the await: a cross-body feed
    // that settled during it may have swapped the session body (H3). Acting on
    // the pre-await item would clear/park the WRONG body's progress.
    final item = state.item;
    if (item == null || item.segments.isEmpty) return;
    // Clear virtual progress to 0 (new v21 progress table mirror + anchor).
    // Per user decision: stop clears vm_progress table outright — scoped to
    // THIS session's (scenario, tag, scope), never scope-wide.
    await _clearScopedVmProgress(item.scopeKey);
    try {
      await DbModule.virtualMediaRepo.saveAnchor(
        scopeKey: item.scopeKey,
        segmentKey: item.segments.first.mediaKey,
        localPositionMs: 0,
      );
    } catch (_) {}
    // First-segment media_nodes progress is cleared via the feed pre-write
    // (write-before-play), the same channel a sequential advance uses.
    _feedPreWriteMs = clearFirstSegmentProgress ? 0 : null;
    await _flushAnchor();
    _stopAnchorTimer();
    // Keep session on first segment, don't auto-play.
    store.replace(state.copyWith(
      segmentIndex: 0,
      pendingSeekMs: null,
      transitioning: false,
    ));
    _localMs = 0;
    _startAnchorTimer();
    // Feed PAUSED: stop lands the merged item on segment 0 without auto-play
    // (spec §2). Feeding with the default autoPlay=true opened the file
    // playing and the trailing updateAutoPlay(false) could not re-pause it.
    await _feedCurrent(autoplay: false);
    _log.i('vm stopToFirst (${item.displayName}) -> seg 0');
  }

  // ── Hook touch points ──

  /// Returns true when the completed event belonged to an active virtual
  /// session and was fully handled (next segment/item fed).
  ///
  /// Repeat-one is handled HERE for multi-segment items: the merged item
  /// replays as a whole (wrap within it), otherwise the backend would loop
  /// only the current physical segment and the virtual progress would never
  /// advance (H4). Single-segment items still return false so the backend's
  /// native loop keeps running (the native loop IS the whole item there).
  ///
  /// When the LAST segment completes (no wrap), the session deactivates and
  /// this returns FALSE so the underlying playback provider (scenario queue)
  /// advances past the merged entry naturally.
  Future<bool> maybeHandleCompleted() async {
    if (!isActive) return false;
    final key = _terminalKeyForCurrent();
    if (shouldDropVmTerminalEvent(
      handledKey: _terminalGuardKey,
      incomingKey: key,
      transitioning: state.transitioning,
      feedInFlight: _feedInFlight,
    )) {
      return true;
    }
    _terminalGuardKey = key;
    try {
      if (activePlaybackRepeat() == Repeat.one) {
        final item = state.item;
        if (item == null ||
            !vmRepeatOneHandlesWithinItem(
              segmentsLength: item.segments.length,
              segmentIndex: state.segmentIndex,
            )) {
          return false;
        }
        return await advance(forward: true, wrapWithinItem: true);
      }
      return await advance(forward: true);
    } finally {
      _terminalGuardKey = null;
    }
  }

  /// Returns true when the error belongs to an active session and the broken
  /// segment was skipped. Three consecutive failures abort the session with
  /// a visible error instead of spinning through a dead library (spec §9.5).
  Future<bool> handleSegmentError() async {
    if (!isActive) return false;
    final key = _terminalKeyForCurrent();
    if (shouldDropVmTerminalEvent(
      handledKey: _terminalGuardKey,
      incomingKey: key,
      transitioning: state.transitioning,
      feedInFlight: _feedInFlight,
    )) {
      return true;
    }
    _terminalGuardKey = key;
    try {
      _consecutiveErrors++;
      final seg = currentSegmentOrNull;
      _log.w('vm segment failed '
          '(${seg?.name ?? 'unknown'}), consecutive=$_consecutiveErrors');
      if (_consecutiveErrors >= 3) {
        // Fatal: stop and keep the localized reason in state so the player's
        // error host can surface it (never a silent stop).
        await stop(keepError: vmLocalizations().vm_error_session_stopped);
        return true;
      }
      final advanced = await advance(forward: true, markAnchor: false);
      if (!advanced) {
        // The broken segment was the last feasible destination: [advance]
        // already ended the session. Keep a localized reason in state so the
        // failure is visible instead of silently frozen; the outer provider
        // still owns advancing past the dead entry (user-driven).
        store.replace(state.copyWith(
            lastError: vmLocalizations().vm_error_segment_unplayable));
      }
      return true;
    } finally {
      _terminalGuardKey = null;
    }
  }

  /// Next / previous across segments and items (registry.step seam).
  ///
  /// Boundary semantics follow the album model: prev at a segment start goes
  /// to the previous segment; next at the last segment crosses into the next
  /// item. Wrap only under Repeat.all; otherwise clamp (no-op).
  Future<void> step({required bool forward}) async {
    if (!isActive) return;
    final wrap = activePlaybackRepeat() == Repeat.all;
    await advance(forward: forward, wrapRepeatAll: wrap);
  }

  /// UI seek on the VIRTUAL timeline (scrubber passes translated values).
  ///
  /// Same-segment targets delegate to the raw seek closure; cross-segment
  /// targets pre-write the intra-segment offset to media_nodes and feed the
  /// segment, so the shared native resume path lands mid-segment. Chapter
  /// clicks pass no offset and land on the segment start (spec §29
  /// chapter-click model).
  Future<void> seekFromUi(Duration virtualPos,
      {required void Function(Duration local) rawSeek}) async {
    final item = state.item;
    if (item == null || item.segments.isEmpty || !isActive) {
      rawSeek(virtualPos);
      return;
    }
    final (idx, localMs) = item.locate(virtualPos.inMilliseconds);
    if (idx == state.segmentIndex) {
      final clamped = clampVmLocalMs(item.segments[idx].durationMs, localMs);
      _localMs = clamped;
      rawSeek(Duration(milliseconds: clamped));
      await _flushAnchor();
    } else {
      await _jumpToSegment(idx, localMs: localMs);
    }
  }

  /// Chapter click inside the active item (never Context.next(), spec §29).
  ///
  /// [localMs] carries a slider-computed intra-segment offset so a
  /// cross-segment scrub lands mid-segment; null/omitted lands on start.
  /// [finishAtEnd] marks an explicit "finish this item" (tail step / release at
  /// 100%): the feed then lands ON the segment end and the hooks finish it,
  /// instead of the usual `segDur - kSeekTailGuardMs` clamp that can never
  /// raise `completed`.
  Future<void> jumpToSegment(
    int index, {
    int? localMs,
    bool finishAtEnd = false,
  }) =>
      _jumpToSegment(index, localMs: localMs, finishAtEnd: finishAtEnd);

  /// Stash a cross-segment drag target (preview strategy, or a
  /// throttled-away direct tick) for the release commit.
  void stashDragTarget(int virtualMs) {
    _dragStashVirtualMs = virtualMs;
  }

  /// Take the stashed drag target once. Null = nothing pending.
  int? takeDragTarget() {
    final v = _dragStashVirtualMs;
    _dragStashVirtualMs = null;
    return v;
  }

  /// Throttle guard: a live drag may open at most one cross segment per
  /// window; the release commit covers the dropped tail.
  bool shouldThrottleCrossJump() {
    final last = _lastCrossJumpAt;
    if (last == null) return false;
    return !vmCrossJumpAllowed(last, DateTime.now());
  }

  /// Record a live-drag cross-segment open (throttle anchor).
  void markCrossJump() {
    _lastCrossJumpAt = DateTime.now();
  }

  /// Ends the switch-in-flight freeze once the fed file is ready (the hook's
  /// duration arrival calls this; the resume seek itself is the shared
  /// native path — VM carries no seek logic in the hooks).
  ///
  /// Callers gate on [isActive], so an orphaned transition (the play queue
  /// already left the session) can never reach this — that case goes through
  /// [releaseOrphanedTransition] instead.
  void clearTransition() {
    if (state.transitioning || state.pendingSeekMs != null) {
      store.replace(state.copyWith(transitioning: false, pendingSeekMs: null));
    }
  }

  /// Releases a transition the normal path can never acknowledge, then lets
  /// [reconcileStaleSession] clean up. Duration arrival of the file that
  /// replaced the session is the caller (both player hooks' `else` branch).
  ///
  /// Why this must exist: [clearTransition] is gated on [isActive], so once
  /// the play queue has left the session nothing is left to release
  /// `transitioning` — yet [reconcileStaleSession] refuses to run while it is
  /// set. The two would guard on each other (deadlock), pinning the store's
  /// item so every progress surface keeps partitioning a normal file into
  /// virtual segments (the player hooks' reconcile also keys its effect on a
  /// stale flag that never toggles again, so it cannot recover either).
  ///
  /// An in-flight feed still owns the switch and is left alone; its
  /// finally-block is not the retry point either — the freeze outlives the
  /// feed — so this is the one place an orphan can be released.
  void releaseOrphanedTransition() {
    if (state.item == null) return;
    if (_feedInFlight) return;
    clearTransition();
    reconcileStaleSession();
  }

  /// Periodic tick from hooks (translated position) → in-memory cache only;
  /// DB writes are throttled to the timer below.
  ///
  /// Frozen while a switch is in flight: the hook still reports the LEAVING
  /// file's local position during the feed window, and writing it into
  /// [_localMs] would make the post-feed anchor flush store the old
  /// position under the NEW segment (anchor pollution → wrong resume).
  void noteTick(int localMs) {
    if (state.transitioning) return;
    _localMs = localMs;
  }

  // ── Internals ──

  /// Resolves unknown segment durations for the ACTIVE item in batches,
  /// patching the store once per batch so scrubber marks fill in live.
  ///
  /// - Network segments (FTP/WebDAV/network) are NEVER probed mid-playback:
  ///   remote probes stall the session and each spawn costs an isolate. Their
  ///   durations resolve via the playing segment's lazy backfill or harvest.
  /// - Real duration → also written back to media_nodes (next resolve uses
  ///   it, matching the hooks' lazy backfill for the playing segment).
  /// - Probe failure/non-positive duration → nominal red-bar unit flagged
  ///   `durationEstimated` (never re-probed within the session).
  /// - The item is rebuilt in place with the segment index untouched, so no
  ///   spurious segment switch is triggered (ticks use the cached offset;
  ///   only seeks re-run the binary search). A patch AT/AFTER the current
  ///   segment keeps the virtual position pixel-stable (prefix-sum
  ///   property); a patch BEFORE it legitimately shifts the virtual position
  ///   forward — the earlier timeline was a zero placeholder, and the local
  ///   playback position does not move. Anchors stay keyed by segment key +
  ///   local position, so resume is unaffected by the shift.
  Future<void> _backfillUnknownDurations() async {
    final gen = _backfillGen;
    try {
      _probeService ??= createMediaProbeService();
      // Storage-type cache: one lookup per storage, not per segment.
      final typeCache = <String, StorageType>{};
      bool isNetwork(VirtualSegment s) {
        final t = typeCache.putIfAbsent(s.storageId, () {
          try {
            return useStorageStore().findById(s.storageId)?.type ??
                StorageType.none;
          } catch (_) {
            return StorageType.none;
          }
        });
        return t == StorageType.ftp ||
            t == StorageType.webdav ||
            t == StorageType.network;
      }
      // Monotonic cursor: segments keep their order across patches, so each
      // scan resumes after the last resolved index instead of from 0
      // (O(n) total, not O(k·n)).
      var cursor = 0;
      var scopeHops = 0;
      while (gen == _backfillGen) {
        final item = state.item;
        if (item == null) return;
        final plan = planVmBackfillBatch(item.segments,
            cursor: cursor, isNetwork: isNetwork);
        if (plan.done) return;
        final batchIdx = plan.indices;
        List<ProbeResult> results;
        try {
          results = await _probeService!.probeFiles([
            for (final i in batchIdx)
              nodePlayableUri(item.segments[i].path,
                  uri: item.segments[i].uri),
          ]);
        } catch (_) {
          results = [for (final _ in batchIdx) ProbeResult.empty];
        }
        if (gen != _backfillGen) return; // superseded while probing

        final cur = state.item;
        if (cur == null) return; // session ended while probing
        if (cur.scopeKey != item.scopeKey) {
          if (++scopeHops >= 8) return; // flapping session: stop spinning
          cursor = 0;
          continue; // item switched
        }

        var patched = cur.segments;
        for (var k = 0; k < batchIdx.length; k++) {
          final idx = batchIdx[k];
          if (idx >= patched.length) continue;
          final seg = patched[idx];
          final raw = k < results.length ? results[k] : ProbeResult.empty;
          final sane = sanitizeProbeResult(raw);
          final real = (sane.durationMs != null && sane.durationMs! > 0)
              ? sane.durationMs
              : null;
          if (real != null) {
            try {
              await DbModule.mediaNodeRepo.updateFileMediaInfo(
                storageId: seg.storageId,
                path: canonicalDbPath(seg.path.join('/')),
                durationMs: real,
                width: sane.width,
                height: sane.height,
                pixelCount: sane.pixelCount,
              );
            } catch (e) {
              _log.w('vm probe write-back failed: $e');
            }
          } else {
            _log.e('vm probe failed for ${seg.name} '
                '(${seg.storageId}:${seg.path.join('/')}) — '
                'red bar will show; please report');
          }
          patched = applyVmProbeOutcome(patched, idx, real);
        }
        // One coalesced patch per batch: a single prefix-sum rebuild and a
        // single listener fan-out instead of one per segment.
        store.replace(
            state.copyWith(item: rebuildVmItem(cur, patched)));
        cursor = batchIdx.last + 1;
      }
    } catch (e) {
      _log.w('vm duration backfill aborted: $e');
    }
  }

  Future<void> _jumpToSegment(
    int index, {
    int? localMs,
    bool finishAtEnd = false,
  }) async {
    final item = state.item;
    if (item == null ||
        item.segments.isEmpty ||
        index < 0 ||
        index >= item.segments.length) {
      return;
    }
    if (index == state.segmentIndex) {
      // Same-segment corrective jump (a cross-feed race resolved back onto
      // the current segment with a different intra-segment target): without
      // a raw-seek channel the only precise path is a targeted re-feed.
      // Identical targets are no-ops.
      final segDur = item.segments[index].durationMs ?? 0;
      // The same segment-tail contract as every other VM seek: an ordinary
      // corrective jump stops `kSeekTailGuardMs` short of the segment end
      // (never the old `segDur - 1`, which sits inside the final GOP); only an
      // explicit finish that really targets the end may land ON it.
      //
      // The check below compares against the target this jump would ACTUALLY
      // seek to, so it uses the SAME rule as the cross-segment path further
      // down: `finishAtEnd` relaxes the guard only for a target at/after
      // `segDur`. Comparing an intent-clamped value here would make a 99% /
      // in-guard target look different from the position we are already on and
      // trigger a pointless re-feed of the same spot.
      final int raw = localMs ?? _localMs;
      final bool finishes = finishAtEnd && segDur > 0 && raw >= segDur;
      final target = finishes
          ? clampVmLocalMs(segDur, raw, intent: SeekIntent.finishAtEnd)
          : clampVmLocalMs(segDur, raw);
      if (target == _localMs && state.pendingSeekMs == null) return;
    }
    // A feed is mid-flight (async node lookup / queue push). Jumping now
    // would overlap it with a second `player.open` on the same physical file
    // (the back-to-0% race). Wait for the feed to land, then re-evaluate from
    // the POST-feed state. If the feed moved the session onto a DIFFERENT
    // item (cross-body feed), the caller's index refers to the old item's
    // segments and is meaningless now — drop the jump.
    if (_feedInFlight) {
      final inflight = _feedFuture;
      if (inflight != null) await inflight;
      // The feed may already have moved the session (cross-body swap), made
      // the target out-of-range, or landed exactly on the target segment —
      // any of which makes the deferred jump a no-op.
      if (!vmRevalidateDeferredJump(
        targetScopeKey: item.scopeKey,
        index: index,
        currentItem: state.item,
        currentSegmentIndex: state.segmentIndex,
      )) {
        return;
      }
    }
    final cur = state.item;
    if (cur == null || cur.segments.isEmpty) return;
    final segDur = cur.segments[index].durationMs ?? 0;
    // finishAtEnd is the one caller allowed ON the segment end (the shared
    // clamp contract); every ordinary jump keeps the SAME shared tail guard as
    // the rest of the app (`segDur - kSeekTailGuardMs`, via clampVmLocalMs) —
    // neither it nor the old `segDur - 1` rounding error can raise an instant
    // `completed`, but the 1 ms landing sits inside the final GOP, which is
    // exactly the rollback the guard exists for. Only a target that really IS
    // the end converts into a feed-finish: a 99%-release still lands
    // mid-segment and plays the tail out, exactly like the single-file path.
    final int raw = localMs ?? 0;
    final bool finishes = finishAtEnd && segDur > 0 && raw >= segDur;
    final target = finishes
        ? clampVmLocalMs(segDur, raw, intent: SeekIntent.finishAtEnd)
        : clampVmLocalMs(segDur, raw);
    // CLOSE_DEBUG_LOG: vm double-open / back-to-0% investigation.
    _log.d('[vm-jump] to seg=$index target=$target '
        'from=${state.segmentIndex} feedInFlight=$_feedInFlight');
    store.replace(state.copyWith(
      segmentIndex: index,
      // UI-freeze anchor only: the hooks expose this position while the
      // switch is in flight and never seek from it.
      pendingSeekMs: target,
      transitioning: true,
      lastSwitchWasSeek: true,
    ));
    _localMs = target;
    // Write-before-play: the resume target lands in media_nodes BEFORE the
    // open, so the shared native resume path (duration arrival → DB read →
    // seek) brings the new segment up at the requested position — the same
    // mechanism a real single video uses for its last progress. The write
    // also clears a stale completed flag, which would otherwise suppress
    // the resume entirely.
    _feedPreWriteMs = target;
    _pendingFeedFinishAtEnd = finishes;
    // A live jump supersedes any stashed drag tail from earlier ticks.
    _dragStashVirtualMs = null;
    await _feedCurrent();
  }

  /// Returns true when the session is still active after the advance
  /// (another segment/item was fed); false when it ended.
  ///
  /// [wrapWithinItem] loops at the item boundary (Repeat.one: replay the whole
  /// merged item) instead of crossing into a sibling. Infeasible siblings are
  /// skipped in the same direction; an exhausted queue ends the session.
  Future<bool> advance({
    required bool forward,
    bool markAnchor = true,
    bool wrapRepeatAll = false,
    bool wrapWithinItem = false,
  }) async {
    // A feed is mid-flight: advancing now would overlap it with a second
    // `player.open` (the back-to-0% race). Wait for the feed to land, then
    // plan from the POST-feed state so the advance never double-opens the
    // same physical file.
    if (_feedInFlight) {
      final inflight = _feedFuture;
      if (inflight != null) await inflight;
    }
    final item = state.item;
    if (item == null) return false;
    // CLOSE_DEBUG_LOG: vm double-open / back-to-0% investigation.
    _log.d('[vm-advance] forward=$forward markAnchor=$markAnchor '
        'wrap=$wrapRepeatAll wrapItem=$wrapWithinItem seg=${state.segmentIndex} '
        'feedInFlight=$_feedInFlight');

    bool isFeasibleQueueIndex(int i) {
      final it = state.queue[i];
      return it.segments.isNotEmpty && it.totalDurationMs > 0;
    }

    final plan = vmPlanFeasibleAdvance(
      queueIndex: state.queueIndex,
      segmentIndex: state.segmentIndex,
      queueLength: state.queue.length,
      segmentsLength: item.segments.length,
      forward: forward,
      wrapRepeatAll: wrapRepeatAll,
      wrapWithinItem: wrapWithinItem,
      isFeasible: isFeasibleQueueIndex,
    );
    if (plan == null || plan.ended) {
      // End of session: flush and deactivate gracefully.
      _log.d('[vm-advance] ended (no feasible destination)');
      await _endSession();
      return false;
    }

    if (plan.queueIndex < 0 || plan.queueIndex >= state.queue.length) {
      return false;
    }
    final nextItem = state.queue[plan.queueIndex];
    if (nextItem.segments.isEmpty || nextItem.totalDurationMs <= 0) {
      // Defensive: the feasibility scan should have excluded this; never
      // leave the session frozen on an unplayable item (H1).
      _log.w('vm advance rejected infeasible item (${nextItem.scopeKey})');
      await _endSession();
      return false;
    }
    final segIdx =
        plan.atItemEnd ? nextItem.segments.length - 1 : plan.segmentIndex;
    if (markAnchor) {
      _consecutiveErrors = 0;
      unawaited(_saveAnchor(nextItem.scopeKey,
          nextItem.segments[segIdx.clamp(0, nextItem.segments.length - 1)], 0));
    }
    store.replace(state.copyWith(
      item: nextItem,
      segmentIndex: segIdx,
      queueIndex: plan.queueIndex,
      // Unified switch mechanism: sequential advance is a jump to local 0.
      // UI-freeze anchor only — the hooks never seek from it.
      pendingSeekMs: 0,
      transitioning: true,
      lastSwitchWasSeek: false,
    ));
    _localMs = 0;
    // Write-before-play: sequential advance pre-writes 0 so the shared
    // resume path reads an explicit "from the beginning" (a present 0 row
    // never resurrects a stale HistoryStore position), and clears a stale
    // completed flag that would otherwise suppress the resume.
    _feedPreWriteMs = 0;
    _dragStashVirtualMs = null;
    await _feedCurrent();
    return true;
  }

  /// Ends the session cleanly: invalidate any in-flight feed, flush the
  /// anchor, stop the flush timer and drop the session state.
  ///
  /// Shared by the natural end-of-queue path and the infeasible-neighbour path
  /// (H1): freezing on a segment the queue cannot leave is worse than ending
  /// the merged entry so the outer provider can move on.
  Future<void> _endSession() async {
    ++_feedSeq; // invalidate any feed still in flight
    _feedInFlight = false;
    _feedFuture = null;
    await _flushAnchor();
    _stopAnchorTimer();
    store.replace(const VmPlaybackState());
    _clearSessionKeys();
    _dragStashVirtualMs = null;
    _lastCrossJumpAt = null;
  }

  Future<void> _feedCurrent({bool autoplay = true}) async {
    final seq = ++_feedSeq;
    // One-shot finish handoff: this feed (and only this one) opens at its end.
    _finishOnFeedSeq = _pendingFeedFinishAtEnd ? seq : 0;
    _pendingFeedFinishAtEnd = false;
    final item = state.item;
    if (item == null) return;
    final seg = currentSegment;
    final pending = state.pendingSeekMs;
    // CLOSE_DEBUG_LOG: vm double-open / back-to-0% investigation.
    _log.d('[vm-feed] seq=$seq autoplay=$autoplay '
        'scope=${item.scopeKey} segIdx=${state.segmentIndex} '
        'seg=${seg.mediaKey} local=${pending ?? _localMs} '
        'transitioning=${state.transitioning}');
    _feedInFlight = true;
    final self = _doFeedCurrent(seq, autoplay);
    _feedFuture = self;
    try {
      await self;
    } finally {
      // Only the CURRENT feed clears the flag; a superseded one must leave
      // the newer feed's in-flight state untouched.
      if (seq == _feedSeq) {
        _feedInFlight = false;
        _feedFuture = null;
      }
    }
  }

  Future<void> _doFeedCurrent(int seq, bool autoplay) async {
    final item = state.item;
    if (item == null || item.segments.isEmpty) return;
    final seg = currentSegmentOrNull;
    if (seg == null) return;
    final MediaNode? node;
    try {
      final loader = debugNodeLoaderOverride;
      node = await (loader != null
          ? loader(seg.storageId, seg.path)
          : DbModule.mediaNodeRepo
              .getNodeByPath(storageId: seg.storageId, path: seg.path));
    } catch (e) {
      // A failed lookup is exactly an open failure: keep the session keys so
      // handleSegmentError's `isActive` gate still sees the session and can
      // skip the broken segment (clearing them here disabled the recovery).
      _log.w('vm feed lookup failed (${seg.mediaKey}): $e');
      unawaited(handleSegmentError());
      return;
    }
    // Superseded by a newer jump/advance/session while the lookup was in
    // flight: drop the stale result so it can neither hijack the expected
    // key nor push an outdated feed into the play queue.
    if (seq != _feedSeq) return;
    if (node == null) {
      // Library row vanished between resolve and play — treat as broken
      // segment (same policy as an open failure).
      unawaited(handleSegmentError());
      return;
    }

    final FileItem file;
    try {
      file = _fileOf(node);
    } catch (e) {
      _log.w('vm feed file resolve failed (${seg.mediaKey}): $e');
      unawaited(handleSegmentError());
      return;
    }
    // Write-before-play: land the pre-write BEFORE the queue update so the
    // player hook's resume read (duration arrival) always sees the decided
    // value — jump target, explicit 0, or nothing (plain open). The hooks
    // hold no VM seek logic: this write IS the whole steering mechanism.
    final preWrite = _feedPreWriteMs;
    _feedPreWriteMs = null;
    if (preWrite != null) {
      try {
        // The pre-write fully owns this segment's media_nodes progress for
        // the session: a mid-segment jump writes the authoritative target,
        // and a sequential advance writes 0 — in both cases the history-
        // restore budget is 0 so the open-resume path can never resurrect a
        // stale HistoryStore position over the decided landing (a 0 row stays
        // an explicit from-the-beginning). The fresh lastPlayedAt stamp also
        // marks THIS segment as the most-recently-watched one, so any
        // re-resolution (rule edit / tag switch / cold-start) reopens the
        // session here instead of an older — or the first — segment
        // ("回退到第一个视频").
        await DbModule.mediaNodeRepo.updatePlaybackProgress(
          storageId: seg.storageId,
          path: canonicalDbPath(seg.path.join('/')),
          positionMs: preWrite,
          completed: false,
          lastPlayedAt: DateTime.now(),
          historyRestoreBudgetMs: 0,
          intent: ProgressWriteIntent.targeted,
          writeTag: 'vm-prewrite',
        );
      } catch (e) {
        _log.w('vm progress pre-write failed: $e');
      }
    }
    if (seq != _feedSeq) return;
    await useAppStore().updateAutoPlay(autoplay);
    if (seq != _feedSeq) return;
    try {
      await usePlayQueueStore().update(
        playQueue: [PlayQueueItem(file: file, index: 0)],
        index: 0,
      );
    } catch (e) {
      _log.w('vm feed queue update failed (${seg.mediaKey}): $e');
      unawaited(handleSegmentError());
      return;
    }
    if (seq != _feedSeq) return;
    // The session is only active once the queue actually carries this feed.
    _expectedSegmentKey =
        canonicalProgressKey(file.storageId, file.path, uri: file.uri);
    await _flushAnchor();
  }

  FileItem _fileOf(MediaNode node) {
    final file = node.maybeMap(file: (f) => f, orElse: () => null);
    if (file == null) {
      return FileItem(name: node.name, uri: playableUri(node.path));
    }
    final storage = useStorageStore().findById(file.storageId);
    return FileItem(
      storageId: file.storageId,
      storageType: storage?.type ?? StorageType.none,
      name: file.name,
      uri: mediaNodePlayableUri(storage, file.path, uri: file.uri),
      path: file.path,
      size: file.sizeInBytes ?? 0,
      type: switch (file.mediaType) {
        MediaType.video => ContentType.video,
        MediaType.audio => ContentType.audio,
        MediaType.unknown => ContentType.other,
      },
      lastModified: file.modifiedAt,
      // Subtitle associations persisted at scan time (schema v50): a VM segment
      // feed opens like an ordinary file and must offer the same external
      // tracks as a browse.
      subtitles: file.subtitles ?? const [],
    );
  }

  void _startAnchorTimer() {
    _stopAnchorTimer();
    _anchorTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => unawaited(_flushAnchor()));
  }

  void _stopAnchorTimer() {
    _anchorTimer?.cancel();
    _anchorTimer = null;
  }

  Future<void> _flushAnchor() async {
    final item = state.item;
    if (item == null || item.segments.isEmpty) return;
    final idx = state.segmentIndex.clamp(0, item.segments.length - 1);
    final seg = item.segments[idx];
    if (_lastFlushedMs == _localMs && _lastFlushedSegKey == seg.mediaKey) {
      return;
    }
    await _saveAnchor(item.scopeKey, seg, _localMs);
  }

  /// Persists the legacy positional anchor row (`scopeKey` → segment + local
  /// position).
  ///
  /// COMPATIBILITY/DIAGNOSTICS ONLY — do not make this authoritative for
  /// resume. `scopeKey` is a positional identity that shifts on every stream
  /// recomposition (rule edit, shuffle, add/remove, tag switch), so restoring
  /// by it would land on the wrong physical file. Resume is derived from each
  /// FILE's own progress by recency instead (see `resolveVmResumeByProgress`
  /// in `vm_resume_target.dart`).
  Future<void> _saveAnchor(
      String scopeKey, VirtualSegment seg, int localMs) async {
    try {
      await DbModule.virtualMediaRepo.saveAnchor(
        scopeKey: scopeKey,
        segmentKey: seg.mediaKey,
        localPositionMs: localMs,
      );
      _lastFlushedMs = localMs;
      _lastFlushedSegKey = seg.mediaKey;
    } catch (e) {
      _log.w('anchor save failed: $e');
    }
  }
}
