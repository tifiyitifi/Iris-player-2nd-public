import 'dart:collection';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/logging/scenario_log_keys.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_sort_spec.dart';
import 'package:iris/features/scenario_playback/playback/playback_position_signal.dart';
import 'package:iris/features/scenario_playback/playback/playback_progress.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/playback/vm_session_launcher.dart';
import 'package:iris/features/virtual_media/resolver/vm_stream_merge.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart' show StorageType;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/utils/path_conv.dart';

final areaKeyLog = AreaKeyLog(ScenarioLogKeys.playback);

/// [PlaybackProvider] backed by the scenario resolver.
///
/// Playback continuity is provided without relying on queue indices: the
/// current item is identified by [PlaybackOccurrenceId] (storageId+path+
/// occurrenceIndex), and next/previous are resolved from the scenario's
/// effective stream.
class ScenarioPlaybackProvider implements PlaybackProvider {
  /// Upper bound for indexed lookups / locate scans over the effective stream.
  static const _maxLocateItems = 10000;

  /// Hidden FIFO cap on per-scenario locate caches kept in memory. Each
  /// scenario (default SystemPlaying / each independent entry workspace) owns
  /// its own queue and current item; caching the locate hint keeps next/prev
  /// O(1) and switching between recent contexts instant. Eviction is LOSSLESS:
  /// the DB (scenario state = which video, media_nodes = global per-file
  /// progress) remains the source of truth.
  static const int maxCachedSessions = 8;

  final PlaybackScenarioStore _store;

  /// Per-scenario locate caches keyed by scenarioId, in access order (the most
  /// recently touched scenario is last; the oldest is evicted past
  /// [maxCachedSessions]).
  final LinkedHashMap<String, _LocateCache> _sessions =
      LinkedHashMap<String, _LocateCache>();

  /// Per-tap merge groups, cached by effective-stream signature: play /
  /// next / prev / completion each used to re-collect the whole stream and
  /// re-run O(stream × rules) matching. The signature (definition config +
  /// shuffle + playback version + rule revision) misses only content scanned
  /// after caching — handled by a covered-but-missing refresh (see
  /// [vmGroupsCacheAction]). Single entry: the active scenario's taps are
  /// serial, and a scenario switch changes the signature anyway.
  _VmGroupsCache? _vmGroupsCache;

  /// Merge groups for [scenarioId], reused across taps while the effective
  /// stream is unchanged. The tapped entry is already rule-covered (the
  /// caller checked); a covered-but-missing entry refreshes once instead of
  /// serving stale groups.
  Future<VmStreamGroups> _vmGroupsFor(
      String scenarioId, PlaybackEntry entry) =>
      _vmGroupsForKey(
          scenarioId, entry.storageId, entry.path);

  /// Key-based core of [_vmGroupsFor] for call sites holding storage+path
  /// instead of a full [PlaybackEntry] (e.g. the locate fallback below).
  ///
  /// Groups come from the resolver's SCENARIO-ORDER materialization
  /// ([ScenarioResolver.resolveVmGroupsFor]) — the same derivation the queue /
  /// preview overlay renders. Sourcing from `collectEffectiveItems` (which is
  /// deliberately base order: name asc + forced dedup) made playback group
  /// differently from the displayed list whenever the scenario sort / shuffle /
  /// duplicate policy was non-default: the displayed child list then disagreed
  /// with the fed session (wrong child highlight, "play from this child"
  /// falling back to segment 0) or the group was deemed infeasible and the
  /// merged row degraded to ordinary single-file play.
  Future<VmStreamGroups> _vmGroupsForKey(
      String scenarioId, String storageId, String path) async {
    final entryKey = canonicalKey(storageId, path);
    final signature = await _currentSignature();
    var forceRefresh = false;
    final cached = _vmGroupsCache;
    if (cached != null && cached.scenarioId == scenarioId) {
      final action = vmGroupsCacheAction(
        cachedSignature: cached.signature,
        currentSignature: signature,
        entryCoveredInCache:
            cached.groups.byKey.containsKey(entryKey) ||
                cached.groups.failByKey.containsKey(entryKey),
      );
      if (action == VmGroupsCacheAction.useCached) return cached.groups;
      // The provider cache missed but the resolver's signature-keyed cache
      // would still serve the same stale groups (its signature agrees with
      // ours), so the refresh must be forced explicitly.
      forceRefresh = true;
    }
    final groups = await _store.resolver.resolveVmGroupsFor(
      scenarioId,
      playbackVersion: _store.state.playbackVersion,
      forceRefresh: forceRefresh,
    );
    _vmGroupsCache =
        _VmGroupsCache(scenarioId: scenarioId, signature: signature, groups: groups);
    return groups;
  }

  /// Reactive position of the current item in the effective stream
  /// (0-based index, total count); null while nothing plays. Backs the bar
  /// title's `[cur/total]` prefix in scenario mode.
  ///
  /// Forwards to the process-wide [PlaybackPositionSignal]: the title must see
  /// the position no matter WHICH instance established it, and list taps run
  /// through a short-lived provider by design (see [invalidateActiveSession]).
  ValueNotifier<({int index, int count})?> get position =>
      PlaybackPositionSignal.instance.position;

  /// Returns (and touches) the locate cache for [scenarioId], evicting the
  /// oldest scenario past [maxCachedSessions].
  _LocateCache _cacheFor(String scenarioId) {
    final existing = _sessions.remove(scenarioId);
    final cache = existing ?? _LocateCache();
    _sessions[scenarioId] = cache;
    while (_sessions.length > maxCachedSessions) {
      _sessions.remove(_sessions.keys.first);
    }
    return cache;
  }

  /// Drops one scenario's locate cache (its effective stream changed, or a new
  /// playback context was established).
  void _invalidateSession(String? scenarioId) {
    if (scenarioId != null) _sessions.remove(scenarioId);
  }

  /// Drops the ACTIVE scenario's locate cache from THIS provider instance.
  ///
  /// Surface-level play actions (list taps) build a short-lived
  /// [ScenarioPlaybackProvider] to persist + feed the player, so the singleton
  /// registry provider's cache is never touched by them. Calling this on the
  /// singleton keeps it from serving a pre-tap / pre-sort index afterwards.
  void invalidateActiveSession() =>
      _invalidateSession(_store.state.activeScenarioId);

  ScenarioPlaybackProvider({PlaybackScenarioStore? store})
      : _store = store ?? usePlaybackScenarioStore();

  /// The hand-off generation a publish-capable operation runs under.
  ///
  /// Taken at the ENTRY of such an operation — never at the publish itself.
  /// Locating is asynchronous (signature probe, ordering-hint item seek, and on
  /// a queue the index cannot serve a `resolvePage` of up to 10k rows), so an
  /// external feed / stop / new `play` can always land in that window; a token
  /// captured at the publish would already be the NEW generation and the stale
  /// write would go through. Threaded into every publish the operation makes, so
  /// one hand-off retires all of them.
  int _contextToken() => PlaybackPositionSignal.instance.generation;

  /// Publishes [index] as the scenario's position in the effective stream, or
  /// blanks it when [index] is null. Dropped when [token] is no longer the
  /// current generation: the context that started this locate handed the player
  /// over while it was in flight, so its numbers describe nothing on screen.
  Future<void> _emitPosition(int? index,
      {int? count, required int token}) async {
    final signal = PlaybackPositionSignal.instance;
    if (index == null) {
      signal.blank(token);
      return;
    }
    signal.publish(token, (index: index, count: count ?? await totalCount()));
  }

  @override
  Future<int> totalCount() async {
    final indexed = await _store.indexedTotalCount();
    if (indexed != null) return indexed;
    final result = await _store.resolvePage(page: 0, pageSize: 1);
    return result.totalItems;
  }

  @override
  Future<PlaybackEntry?> current() async {
    final item = await _store.getCurrentItem();
    return item == null ? null : _toEntry(item);
  }

  @override
  Future<PlaybackEntry?> next() async {
    final token = _contextToken();
    final index = await _locateCurrentIndex(token);
    if (index == null) return null;
    final total = await totalCount();
    final target = index + 1;
    if (target >= total) return null;
    final entry = await _itemAt(target);
    // CLOSE_DEBUG_LOG
    areaKeyLog.d(
        'provider.next index=$index total=$total target=$target entry=${entry?.key}#${entry?.occurrenceIndex}');
    if (entry != null) {
      await _persistCurrent(entry, virtualPos: target);
      await _storeLocated(entry, target, count: total, token: token);
    }
    return entry;
  }

  @override
  Future<PlaybackEntry?> previous() async {
    final token = _contextToken();
    final index = await _locateCurrentIndex(token);
    if (index == null) return null;
    final target = index - 1;
    if (target < 0) return null;
    final entry = await _itemAt(target);
    // CLOSE_DEBUG_LOG
    areaKeyLog.d(
        'provider.previous index=$index target=$target entry=${entry?.key}#${entry?.occurrenceIndex}');
    if (entry != null) {
      await _persistCurrent(entry, virtualPos: target);
      await _storeLocated(entry, target, token: token);
    }
    return entry;
  }

  /// Loops back to the first effective item when [next] hits the end of the
  /// queue (Repeat.all). Persists the new current occurrence and fills the
  /// position cache exactly like [next]/[previous], so the next completion
  /// advances from index 0 instead of re-wrapping to the same first item.
  Future<PlaybackEntry?> wrapToFirst() async {
    final token = _contextToken();
    final entry = await _itemAt(0);
    // CLOSE_DEBUG_LOG
    areaKeyLog.d(
        'provider.wrapToFirst entry=${entry?.key}#${entry?.occurrenceIndex}');
    if (entry != null) {
      await _persistCurrent(entry, virtualPos: 0);
      await _storeLocated(entry, 0, token: token);
    }
    return entry;
  }

  /// Loops back to the last effective item when [previous] hits the head of
  /// the queue (Repeat.all). Symmetric to [wrapToFirst].
  Future<PlaybackEntry?> wrapToLast() async {
    final token = _contextToken();
    final total = await totalCount();
    final entry = await _itemAt(total - 1);
    // CLOSE_DEBUG_LOG
    areaKeyLog.d(
        'provider.wrapToLast total=$total entry=${entry?.key}#${entry?.occurrenceIndex}');
    if (entry != null) {
      await _persistCurrent(entry, virtualPos: total - 1);
      await _storeLocated(entry, total - 1, count: total, token: token);
    }
    return entry;
  }

  @override
  Future<PlaybackEntry?> itemAt(int index) async {
    if (index < 0) return null;
    return _itemAt(index);
  }

  @override
  Future<List<PlaybackEntry>> page({
    required int offset,
    required int count,
  }) async {
    final pageIndex = offset ~/ count;
    final result = await _store.resolvePage(page: pageIndex, pageSize: count);
    return result.items.skip(offset - pageIndex * count).map(_toEntry).toList();
  }

  /// Starts playback of [entry] in the active scenario.
  ///
  /// The tapped item is usually NOT the queue's first item, so its ACTUAL
  /// effective index is resolved and persisted before playback starts. This
  /// makes the very first next/previous work through the cache/ordering hint
  /// instead of depending on a full rescan.
  Future<void> play(
    PlaybackEntry entry, {
    bool autoplay = true,
    String? targetFileKey,
    int? targetOccurrenceIndex,
  }) async {
    // CLOSE_DEBUG_LOG
    areaKeyLog.d(
        'provider.play entry storageId=${entry.storageId} path=${entry.path} occ=${entry.occurrenceIndex} key=${entry.key} autoplay=$autoplay');
    // Playback context is (re)established for BOTH paths — an ordinary feed
    // and a virtual session — before the merge layer decides.
    await _store.setCurrentItem(
      occurrence: PlaybackOccurrenceId(
        storageId: entry.storageId,
        path: entry.path,
        occurrenceIndex: entry.occurrenceIndex,
      ),
    );
    // New playback context for this scenario: drop its stale locate cache so
    // establishCurrentPosition re-locates from the explicit target.
    _invalidateSession(_store.state.activeScenarioId);
    // Claim the context BEFORE dropping the position below: the title must not
    // spend one frame without an owner while the new item is being located.
    // Also retires any locate still in flight from the previous context.
    PlaybackPositionSignal.instance.claimNewContext();
    await _emitPosition(null,
        token: PlaybackPositionSignal.instance.generation);
    // Virtual Media merge layer (scenario-first): a tapped entry covered by
    // an enabled rule starts a VM session (multiple media as ONE video)
    // instead of the single-file feed. The session queue derives from the
    // scenario's OWN effective stream — the same derivation the list display
    // used — so siblings are exactly what the scenario shows.
    if (await _startVmSession(entry,
        autoplay: autoplay,
        targetFileKey: targetFileKey,
        targetOccurrenceIndex: targetOccurrenceIndex)) {
      // A merged row is still ONE position in the scenario stream, so it needs
      // the same publish the ordinary path gets below. Returning early left the
      // bar title on the previous item's number for the whole session (and on
      // nothing at all when the context had never been located).
      await establishCurrentPosition();
      return;
    }
    await establishCurrentPosition();
    await advanceEntry(entry, autoplay: autoplay);
  }

  /// Starts a Virtual Media session when [entry] is covered by an enabled
  /// rule and belongs to a feasible merged group.
  ///
  /// Shared by [play] (list tap / first open) and [advanceEntry] (next/prev,
  /// Repeat.all wrap, natural completion, resume) so ANY feed outlet that
  /// lands on a virtual body re-enters the merged session instead of
  /// degrading to the single representative file ("把虚拟媒体当单一媒体播放").
  ///
  /// Returns true when a session was started — the caller must NOT feed the
  /// single file afterwards. False keeps ordinary single-file playback.
  /// Preflight-degraded members and infeasible groups fall through here.
  ///
  /// NOTE: does NOT touch scenario current-item / position caches. [play]
  /// owns those for its "new playback context" semantics (and now also
  /// establishes the position on this merge branch); callers that already
  /// persisted the target (e.g. [next]/[previous] via [_persistCurrent]) keep
  /// their locate caches intact so the NEXT step stays list-independent without
  /// a full rescan.
  Future<bool> _startVmSession(
    PlaybackEntry entry, {
    bool autoplay = true,
    String? targetFileKey,
    int? targetOccurrenceIndex,
  }) async {
    final scenarioId = _store.state.activeScenarioId;
    if (scenarioId == null) return false;
    // Fast path: no enabled rule covers the file → ordinary play.
    if (await VirtualMediaService.instance
            .coveringRuleFor(entry.storageId, entry.path) ==
        null) {
      return false;
    }
    final entryKey = canonicalKey(entry.storageId, entry.path);
    final groups = await _vmGroupsFor(scenarioId, entry);
    final fail = groups.failByKey[entryKey];
    if (fail != null) {
      // Preflight-degraded: this member cannot merge (unknown duration
      // etc.) — fall through to ordinary single-file playback. The list
      // tile already carries the yellow mark + log line from resolve.
      areaKeyLog.w('provider vm-degraded entry=$entryKey '
          'reason=${fail.reason.name} scope=${fail.scopeKey}: normal play');
      return false;
    }
    // The blocking play-time preflight publishes RUNTIME failures (missing
    // node / probe) into the service map; the fresh scenario-order resolve
    // cannot see those. Honor them so a just-failed merged item degrades to
    // ordinary single-file playback instead of starting a session that errors
    // out segment by segment (the documented "falls back to normal" contract).
    final runtimeFail = VirtualMediaService.instance.failInfoFor(entryKey);
    if (runtimeFail != null) {
      areaKeyLog.w('provider vm-runtime-degraded entry=$entryKey '
          'reason=${runtimeFail.reason.name}: normal play');
      return false;
    }
    final group = groups.byKey[entryKey];
    if (group == null ||
        group.segments.isEmpty ||
        group.totalDurationMs <= 0) {
      if (group != null) {
        areaKeyLog.w('provider vm-infeasible entry=$entryKey '
            'segments=${group.segments.length} '
            'total=${group.totalDurationMs}: normal play');
      }
      return false;
    }
    // Resume contract (shared with tag_play): by default the group re-opens
    // on the segment watched most recently (newest per-file lastPlayedAt) and
    // at that file's own saved position. Identity-keyed, so it survives the
    // re-resolution that changes the group's positional scopeKey.
    //
    // [targetFileKey]/[targetOccurrenceIndex] are the per-context bookmark
    // (e.g. a resumed no-tag occurrence, or an expandable child tap): when
    // they name one of this group's segments, that exact segment wins over
    // recency so the stored file re-opens. The occurrence index keeps a
    // duplicated file (`allowDuplicate`) on the tapped occurrence.
    final targetIdx = targetFileKey == null
        ? null
        : group.indexOfSegment(targetFileKey, targetOccurrenceIndex);
    final target = targetIdx == null ? null : targetFileKey;
    final progressByKey =
        target == null ? await loadSegmentProgress(group) : noSegmentProgress;
    final plan = planVmSessionStartFromGroups(
      storageId: entry.storageId,
      path: entry.path,
      groups: groups,
      progressByKey: progressByKey,
      targetMediaKey: target,
      targetOccurrenceIndex: targetIdx == null ? null : targetOccurrenceIndex,
    );
    if (plan == null) return false;
    await VirtualMediaController.instance.startSession(
      queue: plan.queue,
      queueIndex: plan.queueIndex,
      segmentIndex: plan.segmentIndex,
      initialLocalMs: plan.initialLocalMs,
      autoplay: autoplay,
    );
    // The scenario's current occurrence stays the entry's own identity here
    // (highlight/next-prev depend on it). The REAL segment is captured to the
    // no-tag bookmark only when a tag view takes over the context — see
    // [captureCurrentVirtualSegment] via the tag controller's outgoing capture.
    return true;
  }

  /// Records the LIVE virtual-session segment as the active scenario's current
  /// occurrence. No-op when no session is active. Invoked when a tag view is
  /// about to take over the no-tag context, so returning later resumes the same
  /// physical file instead of the merged group's representative.
  Future<void> captureCurrentVirtualSegment() async {
    final vm = VirtualMediaController.instance;
    final seg = vm.isActive ? vm.currentSegmentOrNull : null;
    if (seg == null) return;
    try {
      await _store.setCurrentItem(
        occurrence: PlaybackOccurrenceId(
          storageId: seg.storageId,
          path: seg.path.join('/'),
          occurrenceIndex: seg.occurrenceIndex,
        ),
      );
    } catch (e) {
      areaKeyLog.w('capture virtual segment failed: $e');
    }
  }

  /// Resolves the current occurrence's ACTUAL effective index in the current
  /// resolve order and persists it as the ordering hint ([ScenarioState]
  /// `currentVirtualPos`), also filling the position cache.
  ///
  /// Returns the index, or null when the current occurrence is absent from
  /// the effective queue. Called on the first override so a user-tapped item
  /// (which is not the first item) gets its own real position.
  Future<int?> establishCurrentPosition() async {
    final index = await _locateCurrentIndex(_contextToken());
    // CLOSE_DEBUG_LOG
    areaKeyLog.d('establishCurrentPosition located=$index');
    if (index == null) return null;
    // The locate already proved this persisted occurrence exists in the
    // effective stream; re-resolving the item here was a second unbounded walk.
    final occurrence = (await _store.activeState())?.currentPlaybackOccurrence;
    if (occurrence == null) return null;
    await _store.setCurrentItem(occurrence: occurrence, virtualPos: index);
    return index;
  }

  /// PotPlayer-style stop: resets the current item's resume state (position 0
  /// + completed) so the next play starts from the beginning, while keeping the
  /// current item selected. The registry's [PlaybackProviderRegistry.stop]
  /// additionally clears the player feed so the player hook unloads the media.
  ///
  /// A stop that follows a FAILED open must not flag the file completed: a
  /// media row without a parsed duration has never been played, and marking it
  /// completed would corrupt resume/watched semantics. The selection semantics
  /// are preserved either way.
  Future<void> stop() async {
    final entry = await current();
    if (entry == null) return;
    // CLOSE_DEBUG_LOG
    areaKeyLog.d('provider.stop entry=${entry.key}#${entry.occurrenceIndex}');
    if (!await hasParsedDuration(entry.file)) {
      areaKeyLog.d(
          'provider.stop skip progress reset: media never opened (${entry.key})');
      return;
    }
    await persistPlaybackProgress(
      file: entry.file,
      position: Duration.zero,
      completed: true,
    );
  }

  /// Feeds the resolved entry to the player through the unified queue store.
  ///
  /// VM-aware: when [entry] is a virtual body (covered by an enabled rule),
  /// starts/re-enters the merged session instead of playing the single
  /// representative file. This is the single choke point behind next/prev,
  /// Repeat.all wrap, natural completion and resume — all of which land here
  /// with an entry from the overlay-merged effective stream.
  Future<void> advanceEntry(
    PlaybackEntry entry, {
    bool autoplay = true,
    String? targetFileKey,
  }) async {
    if (await _startVmSession(entry,
        autoplay: autoplay, targetFileKey: targetFileKey)) {
      return;
    }
    if (autoplay) {
      await useAppStore().updateAutoPlay(true);
    }
    final store = usePlayQueueStore();
    await store.update(
      playQueue: [PlayQueueItem(file: entry.file, index: 0)],
      index: 0,
    );
  }

  /// Feeds [entry] like [advanceEntry] AND books it as the scenario's current
  /// item at effective [index], publishing the position the bar title reads.
  ///
  /// [advanceEntry] deliberately ONLY feeds: every one of its callers
  /// (next/previous, Repeat.all wrap, natural completion) has already persisted
  /// the target through its own bookkeeping, and booking it again here would
  /// cost a second unbounded locate on the following step. A jump that arrives
  /// WITHOUT that bookkeeping — the 副音 cross-file roll, the resume head
  /// fallback — must book itself here, or the scenario's current item and the
  /// bar title keep describing the file it left.
  Future<void> advanceTo(
    PlaybackEntry entry, {
    required int index,
    bool autoplay = true,
  }) async {
    final token = _contextToken();
    await _persistCurrent(entry, virtualPos: index);
    await _storeLocated(entry, index, token: token);
    await advanceEntry(entry, autoplay: autoplay);
  }

  /// Re-validates the current item after the effective queue changed
  /// (remove / temporary exclude / batch remove / override). If the current
  /// item is gone, immediately advances to the next effective item so playback
  /// never hangs on a deleted entry (B3).
  Future<void> revalidateCurrent() async {
    final token = _contextToken();
    final current = await _store.getCurrentItem();
    if (current != null) return; // still in the effective set

    final state = await _store.activeState();
    final hint = state?.currentVirtualPos;
    if (hint != null) {
      final atHint = await _itemAt(hint);
      if (atHint != null) {
        await _persistCurrent(atHint, virtualPos: hint);
        await _storeLocated(atHint, hint, token: token);
        await advanceEntry(atHint);
        return;
      }
    }
    final first = await itemAt(0);
    if (first != null) {
      await _storeLocated(first, 0, token: token);
      await advanceEntry(first);
    }
  }

  // ── Helpers ──

  /// Records [entry]'s effective [index] in the ACTIVE scenario's locate cache
  /// (FIFO-bounded) and emits the reactive position.
  Future<void> _storeLocated(PlaybackEntry entry, int index,
      {int? count, required int token}) async {
    final scenarioId = _store.state.activeScenarioId;
    if (scenarioId != null) {
      final cache = _cacheFor(scenarioId);
      cache.index = index;
      cache.key = entry.key;
      cache.occurrence = entry.occurrenceIndex;
    }
    await _emitPosition(index, count: count, token: token);
  }

  Future<void> _persistCurrent(PlaybackEntry entry, {int? virtualPos}) async {
    await _store.setCurrentItem(
      occurrence: PlaybackOccurrenceId(
        storageId: entry.storageId,
        path: entry.path,
        occurrenceIndex: entry.occurrenceIndex,
      ),
      virtualPos: virtualPos,
    );
  }

  Future<int?> _locateCurrentIndex(int token) async {
    // The locate cache/hint only needs the persisted occurrence ID (storage +
    // path + occurrenceIndex) — resolving the full item here used to force an
    // unbounded occurrence-stream walk before the bounded hint scan could run.
    final state = await _store.activeState();
    final occurrence = state?.currentPlaybackOccurrence;
    if (occurrence == null) return null;
    final currentCanonicalKey =
        canonicalKey(occurrence.storageId, occurrence.path);

    // Per-scenario locate cache (FIFO-bounded). It is dropped whenever the
    // effective stream may have changed (sort / shuffle refresh / dedup toggle
    // / source or exclude edits); the bounded scan below then finds the
    // current occurrence in the CURRENT order (list-independence).
    final scenarioId = _store.state.activeScenarioId;
    final cache = scenarioId == null ? _LocateCache() : _cacheFor(scenarioId);
    final signature = await _currentSignature();
    if (signature != cache.signature) {
      cache.index = null;
      cache.key = null;
      cache.occurrence = null;
      cache.signature = signature;
      // CLOSE_DEBUG_LOG
      areaKeyLog.d(
          'locate cache-invalidate current=${occurrence.occurrenceKey}');
    }

    if (cache.key == currentCanonicalKey &&
        cache.occurrence == occurrence.occurrenceIndex &&
        cache.index != null) {
      // CLOSE_DEBUG_LOG
      areaKeyLog.d('locate cache-hit index=${cache.index}');
      // Every other success path below publishes; the cache hit must too. It
      // used to skip that, which was invisible while nothing ever cleared the
      // process-wide signal — but once a stop / external feed drops it, a
      // re-locate that lands on this fast path resolved the index and left the
      // bar title with no prefix at all.
      await _emitPosition(cache.index, token: token);
      return cache.index;
    }

    // Fast path: the persisted ordering hint. Re-validate by occurrence key so
    // a duplicate at the hint position is never mistaken for the current one.
    final hint = state?.currentVirtualPos;
    if (hint != null) {
      final item = await _itemAt(hint);
      // CLOSE_DEBUG_LOG
      areaKeyLog.d(
          'locate hint=$hint item=${item?.key}#${item?.occurrenceIndex} wanted=$currentCanonicalKey#${occurrence.occurrenceIndex}');
      if (item != null &&
          canonicalKey(item.storageId, item.path) == currentCanonicalKey &&
          item.occurrenceIndex == occurrence.occurrenceIndex) {
        cache.index = hint;
        cache.key = currentCanonicalKey;
        cache.occurrence = occurrence.occurrenceIndex;
        await _emitPosition(hint, token: token);
        // CLOSE_DEBUG_LOG
        areaKeyLog.d('locate hint-ok index=$hint');
        return hint;
      }
    }

    // Bounded scan of the effective stream: ONE coherent prefix fetch.
    //
    // The index-backed seek handles any ordinal, so this only runs for a queue
    // the index cannot serve. A single
    // resolvePage(page: 0, pageSize: _maxLocateItems) returns the prefix in
    // display order with every row carrying its own position, so `i` below IS
    // the position the queue pages on — nothing to reconstruct.
    final scan = await _store.resolvePage(
      page: 0,
      pageSize: _maxLocateItems,
    );
    for (var i = 0; i < scan.items.length; i++) {
      final item = scan.items[i];
      if (canonicalKey(item.occurrenceId.storageId, item.occurrenceId.path) ==
              currentCanonicalKey &&
          item.occurrenceId.occurrenceIndex ==
              occurrence.occurrenceIndex) {
        cache.index = i;
        cache.key = currentCanonicalKey;
        cache.occurrence = occurrence.occurrenceIndex;
        await _emitPosition(i, token: token);
        // CLOSE_DEBUG_LOG
        areaKeyLog
            .d('locate scan-found index=$i totalScanned=${scan.items.length}');
        return i;
      }
    }
    // CLOSE_DEBUG_LOG
    areaKeyLog.d('locate scan-null totalScanned=${scan.items.length}');
    // VM merge fallback (scenario-first): the persisted occurrence may be a
    // segment INSIDE a virtual group (e.g. resumed from a pre-merge current
    // item). Locate the group's representative (first-segment) entry instead
    // so next/prev step past the whole merged video.
    if ((await VirtualMediaService.instance.coveringRuleFor(
            occurrence.storageId, occurrence.path)) !=
        null) {
      if (scenarioId != null) {
        final groups = await _vmGroupsForKey(scenarioId,
            occurrence.storageId, occurrence.path);
        final g = groups.byKey[currentCanonicalKey];
        if (g != null) {
          final repKey = g.segments.first.mediaKey;
          for (var i = 0; i < scan.items.length; i++) {
            final item = scan.items[i];
            if (canonicalKey(
                    item.occurrenceId.storageId, item.occurrenceId.path) ==
                repKey) {
              cache.index = i;
              cache.key = currentCanonicalKey;
              cache.occurrence = occurrence.occurrenceIndex;
              await _emitPosition(i, token: token);
              areaKeyLog.d('locate vm-representative index=$i');
              return i;
            }
          }
        }
      }
    }
    return null;
  }

  /// A lightweight fingerprint of everything that changes the effective
  /// resolution order (definition config + shuffle state + playback version).
  ///
  /// Built from [ScenarioSortSpec] — the SAME value object the resolver/preview
  /// understand — instead of a hand-maintained field list. A manual list once
  /// omitted `sourceInternalFirst`, so toggling 同目录连续 left the locate cache
  /// valid and `next()` served a stale index (PageDown from the 4th visible item
  /// jumped to the 12th). Deriving the fingerprint from the spec makes any
  /// future order knob automatically invalidate the cache.
  Future<String> _currentSignature() async {
    final id = _store.state.activeScenarioId;
    if (id == null) return '';
    final scenario = await _store.getScenario(id);
    if (scenario == null) return '$id|missing';
    final state = await _store.getState(id);
    final spec = ScenarioSortSpec.fromScenario(scenario, state?.shuffleSeed);
    return [
      id,
      spec.sortField.name,
      spec.sortDirection.name,
      spec.order.name,
      spec.duplicatePolicy.name,
      spec.sourceInternalFirst,
      spec.shuffleSeed,
      state?.shuffleVersion,
      _store.state.playbackVersion,
      // VM rule edits change the merged list shape without touching the
      // scenario definition — include the overlay revision.
      VirtualMediaService.instance.revision,
    ].join('|');
  }

  /// Resolves the effective item at [index] (0-based position in the
  /// EFFECTIVE stream — what the user sees).
  ///
  /// The index seek is valid at ANY ordinal; the `_maxLocateItems` bound below
  /// only guards the legacy prefix materialization used when the derived index
  /// is unavailable. Applying it before the seek used to cap `next`/`previous`
  /// and `itemAt` at 10000 on a 500k queue.
  Future<PlaybackEntry?> _itemAt(int index) async {
    if (index < 0) return null;
    // Index-backed seek: O(log n) rank lookup + one row rebuild, instead of an
    // O(index) prefix materialization.
    final indexed = await _store.resolveItemAtIndex(index);
    if (indexed != null) return _toEntry(indexed);
    if (index >= _maxLocateItems) return null;
    final result = await _store.resolvePage(page: 0, pageSize: index + 1);
    final items = result.items;
    if (items.length <= index) return null;
    return _toEntry(items[index]);
  }

  PlaybackEntry _toEntry(EffectivePlaybackItem item) {
    final file = _mediaFileToFileItem(item.media);
    return PlaybackEntry(
      file: file,
      storageId: item.media.storageId,
      path: item.occurrenceId.path,
      key: item.mediaKey,
      occurrenceIndex: item.occurrenceId.occurrenceIndex,
      available: item.available,
    );
  }

  /// Converts a [MediaNode] to a [FileItem] (shared with queue views).
  FileItem fileOf(MediaNode node) => _mediaFileToFileItem(node);

  FileItem _mediaFileToFileItem(MediaNode node) {
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
      type: _convertMediaType(file.mediaType),
      lastModified: file.modifiedAt,
      // Subtitle associations persisted at scan time (schema v50) so a
      // scenario-resolved entry offers the same external tracks as a browse.
      subtitles: file.subtitles ?? const [],
    );
  }

  ContentType _convertMediaType(MediaType mt) {
    switch (mt) {
      case MediaType.video:
        return ContentType.video;
      case MediaType.audio:
        return ContentType.audio;
      case MediaType.unknown:
        return ContentType.other;
    }
  }
}

/// Cached per-tap merge groups for one scenario (see [_VmGroupsCache] use in
/// `ScenarioPlaybackProvider._vmGroupsFor`).
class _VmGroupsCache {
  final String scenarioId;
  final String signature;
  final VmStreamGroups groups;

  const _VmGroupsCache({
    required this.scenarioId,
    required this.signature,
    required this.groups,
  });
}

/// Per-scenario locate cache: the last-resolved effective index of the
/// scenario's current item plus the effective-stream signature it belongs to.
/// Kept in a FIFO-bounded map so switching among recent contexts stays O(1);
/// dropping one is lossless (the DB is the source of truth).
class _LocateCache {
  int? index;
  String? key;
  int? occurrence;
  String? signature;
}
