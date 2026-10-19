import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/enum/playback_order.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/model/db/repositories/tag_play_repository.dart';
import 'package:iris/features/tag_play/model/domain/tag_media_counts.dart';
import 'package:iris/features/tag_play/resolver/tag_view_resolver.dart';
import 'package:iris/features/tag_play/store/use_tag_play_store.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/playback/vm_session_launcher.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart' show StorageType;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/utils/path_conv.dart';

final _log = AreaKeyLog(LogKeys.tagPlay);

/// Reactive status of the active tag view: 1-based display position, view
/// length and the tag's name. Drives the bar title `[cur/total]` prefix and
/// the trailing tag label ("· Tag <name>").
class TagViewStatus {
  final int index;
  final int count;
  final String tagName;

  const TagViewStatus({
    required this.index,
    required this.count,
    required this.tagName,
  });
}

/// Feature availability: tag_play is fully bound to the metadata-driven era.
/// Legacy persistence (no-database era) and metadata-gate-OFF users get NO
/// tag functionality at all — entries are hidden and actions are no-ops.
abstract final class TagPlayGate {
  static bool get enabled {
    final app = useAppStore().state;
    return !app.useLegacyStoragePersistence && app.useMetadataSettings;
  }

  /// View switching additionally requires the scenario-driven playback path.
  static bool get viewSwitchingEnabled =>
      enabled &&
      !useAppStore().state.useLegacyStoragePersistence &&
      useAppStore().state.useScenarioDrivenPlayback;

  /// Whether the "previous view" return stack is offered at all.
  ///
  /// A user preference (`tagplay.viewStackEnabled`), **OFF by default**: the
  /// sheet's radio already shows which tag is playing, so jumping back to the
  /// previously played tag is optional. When OFF the outgoing tag is never
  /// stashed and the sheet does not render the jump-back row; per-tag
  /// bookmarks are unaffected either way.
  static bool get viewStackEnabled => useTagPlayStore().state.viewStackEnabled;
}

/// Delegates the "no-tag" (0 号) side of view switching to the scenario
/// pipeline WITHOUT importing the provider registry (no cycles). Production
/// wiring passes [ScenarioPlaybackProvider]; tests pass fakes.
abstract class NoTagDelegate {
  Future<PlaybackEntry?> current();

  Future<void> advanceEntry(PlaybackEntry entry,
      {bool autoplay = true, String? targetFileKey});

  /// Persists the LIVE virtual-session segment as the no-tag context's own
  /// bookmark before the tag view takes over. Without it the no-tag row keeps
  /// the representative occurrence and a later return restarts at the group's
  /// first segment instead of the file actually playing. No-op when no
  /// virtual session is active.
  Future<void> captureCurrentSegment();
}

class ScenarioNoTagDelegate implements NoTagDelegate {
  final ScenarioPlaybackProvider provider;

  const ScenarioNoTagDelegate(this.provider);

  @override
  Future<PlaybackEntry?> current() => provider.current();

  @override
  Future<void> advanceEntry(PlaybackEntry entry,
          {bool autoplay = true, String? targetFileKey}) =>
      provider.advanceEntry(entry,
          autoplay: autoplay, targetFileKey: targetFileKey);

  @override
  Future<void> captureCurrentSegment() =>
      provider.captureCurrentVirtualSegment();
}

/// Decides where enter a tag view starts and which REAL file the optional VM
/// session must open on.
///
/// [bookmarkLost] is the user-facing "your file is gone" case: the tag HAS a
/// fresh bookmark but its physical file no longer resolves in the view. The
/// caller must NOT auto-play anything (a different video would betray the
/// bookmark); it reports the loss and offers "play from the top".
class TagResumeDecision {
  final int index;
  final String? fileKey;
  final bool bookmarkLost;

  const TagResumeDecision({
    required this.index,
    this.fileKey,
    this.bookmarkLost = false,
  });
}

/// Orchestrates tag play views: entering/exiting a filtered "tag list
/// playback" on top of the CURRENT scenario, per-tag resume bookmarks, and
/// the jump-back rules.
///
/// Orthogonality contract: nothing here mutates scenario definitions, states
/// or resolvers. The no-tag path keeps using the untouched scenario pipeline;
/// a tag view is a derived snapshot resolved on demand and remembered per tag.
///
/// Return path ("暂存"): every context owns its position in its OWN row —
/// each tag has a view_state bookmark row, and the scenario state row is
/// never written while a tag view plays. When the user opts into the return
/// stack ([TagPlayGate.viewStackEnabled], OFF by default) switching tag→tag
/// pushes the outgoing tag onto a persisted stack
/// ([TagPlayStore.pushViewStack]); [popView] restores it through the normal
/// jump-back rules, and a full exit hands playback back to the scenario's own
/// last position. With the stack OFF, switching simply re-enters the new tag's
/// own bookmark and no return path is offered.
class TagPlayController {
  final TagPlayRepository repo;
  final TagViewResolver Function()? resolverFactory;
  final NoTagDelegate noTagDelegate;

  TagPlayController({
    TagPlayRepository? repo,
    this.resolverFactory,
    required this.noTagDelegate,
  }) : repo = repo ?? DbModule.tagPlayRepo;

  /// Default resolver: derived from the live scenario store's resolver.
  TagViewResolver _makeResolver() {
    final custom = resolverFactory;
    if (custom != null) return custom();
    return TagViewResolver(
      source: ResolverEffectiveItemsSource(usePlaybackScenarioStore().resolver),
      indexedSource:
          ResolverIndexedTagItemsSource(usePlaybackScenarioStore().resolver),
      repo: repo,
    );
  }

  // ── Availability / state ──

  bool get isActive => useTagPlayStore().state.activeViewTagId != null;

  int? get activeTagId => useTagPlayStore().state.activeViewTagId;

  /// Resolved snapshot of the active tag view; null when inactive.
  TagViewSnapshot? snapshot;

  bool _recovering = false;

  /// True after the last enter/recovery when the tag's stored bookmark could
  /// not be located (file gone). Surfaces read this to show the "file lost"
  /// dialog and to let Play start from the top of the list.
  bool get isBookmarkLost => _bookmarkLost;
  bool _bookmarkLost = false;

  /// Reactive position/name of the active view; null when not in a tag view.
  final ValueNotifier<TagViewStatus?> tagViewStatus = ValueNotifier(null);

  String? _tagNameCache;

  Future<void> _ensureTagName(int tagId) async {
    if (_tagNameCache != null) return;
    try {
      final tag = await repo.tagById(tagId);
      if (tag != null) _tagNameCache = tag.name;
    } catch (_) {}
  }

  void _emitViewStatus(TagViewSnapshot snap, int virtualPos) {
    final name = _tagNameCache;
    if (name == null) {
      tagViewStatus.value = null;
      return;
    }
    tagViewStatus.value = TagViewStatus(
      index: virtualPos + 1,
      count: snap.length,
      tagName: name,
    );
  }

  /// Scenario the active view was entered against. Bound by [enterView] and
  /// kept across steps so mid-view operations never depend on the global
  /// store's async refresh cycle; [bindScenario] seeds it for restart
  /// recovery where no enter happened yet in this process.
  String? _boundScenarioId;

  void bindScenario(String scenarioId) => _boundScenarioId = scenarioId;

  String? get _scenarioId =>
      _boundScenarioId ?? usePlaybackScenarioStore().state.activeScenarioId;

  /// Resolves a fresh snapshot for [tagId] against [scenarioId].
  ///
  /// Honors the global "ignore scenario" switch: when ON, the tag's whole
  /// active membership is the stream instead of the scenario ∩ members.
  Future<TagViewSnapshot> resolveSnapshot(int tagId, String scenarioId) async {
    // Mode 1 joins the persisted scenario index; make sure it exists so a tag
    // switch does not fall back to a full O(N) stream walk. A no-op once the
    // generation is current, and skipped when a test injects its own resolver.
    if (resolverFactory == null) {
      try {
        await usePlaybackScenarioStore().ensureQueueIndex(scenarioId);
      } catch (_) {
        // Index unavailable: the resolver keeps its legacy walk fallback.
      }
    }
    return _makeResolver().resolve(
      tagId: tagId,
      scenarioId: scenarioId,
      ignoreScenario: useTagPlayStore().state.ignoreScenario,
    );
  }

  /// Per-tag availability for the sheet: `scenarioCount / totalCount` for
  /// every tag in one pass. Without an active scenario only membership totals
  /// are known (scenarioCount = 0).
  Future<Map<int, TagMediaCounts>> mediaCounts() async {
    final sid = _scenarioId;
    if (sid == null || sid.isEmpty) {
      final members = await repo.activeMembersByTag();
      return {
        for (final entry in members.entries)
          entry.key: TagMediaCounts(
            scenarioCount: 0,
            totalCount: entry.value.length,
          ),
      };
    }
    final resolver = usePlaybackScenarioStore().resolver;
    return TagMediaCountResolver(
      source: ResolverEffectiveItemsSource(resolver),
      repo: repo,
      resolver: resolver,
    ).resolveAll(scenarioId: sid);
  }

  // ── Jump-back rules ──

  /// Decides where entering a tag's view starts playing and which REAL file
  /// the optional VM session must open on (see [TagResumeDecision]):
  /// - never played → newest added member present in the view;
  /// - bookmarked within the TAG's own resume window (null window = permanent)
  ///   and still present → resume that file;
  /// - bookmark in-window but its file vanished from the view → [bookmarkLost]
  ///   (no feed; the caller reports it and Play starts from the top);
  /// - bookmark stale (outside the window) → newest added member.
  Future<TagResumeDecision> resolveStart({
    required TagViewSnapshot snap,
    required DateTime now,
  }) async {
    if (snap.isEmpty) return const TagResumeDecision(index: 0);
    final state = snap.state;
    final lastKey = state.lastMediaKey;
    final lastPlayedAt = state.lastPlayedAt;

    if (lastKey != null && lastPlayedAt != null) {
      final window = snap.resumeWindow;
      final withinWindow =
          window == null || now.difference(lastPlayedAt) <= window;
      if (withinWindow) {
        final idx = snap.indexOfFileKey(lastKey);
        if (idx != null) {
          return TagResumeDecision(index: idx, fileKey: lastKey);
        }
        _log.w('tag resume: bookmark file gone '
            'tag=${snap.tagId} key=$lastKey → report lost');
        return const TagResumeDecision(index: 0, bookmarkLost: true);
      }
    }

    final latest = await repo.latestActiveMember(snap.tagId);
    if (latest != null) {
      // Canonical key — the SAME shape the snapshot index is built with (and
      // every other comparison in this file uses). A raw interpolation misses
      // a pre-normalization member row and silently falls back to index 0.
      final key = canonicalKey(latest.storageId, latest.path);
      final idx = snap.indexOfFileKey(key);
      if (idx != null) return TagResumeDecision(index: idx, fileKey: key);
    }
    return const TagResumeDecision(index: 0);
  }

  /// Index-only view of [resolveStart] for callers/tests that only need where
  /// to start a list. [_persistBookmark] owns the VM file target separately.
  Future<int> resolveStartIndex({
    required TagViewSnapshot snap,
    required DateTime now,
  }) async =>
      (await resolveStart(snap: snap, now: now)).index;

  // ── Snapshot recovery (restart-safe) ──

  /// Returns the active snapshot, lazily rebuilding it after a restart
  /// (`activeViewTagId` persists but the in-memory snapshot does not).
  ///
  /// Recovery relocates by the STORED bookmark key directly (no time-window
  /// check, no bookmark re-stamp) so stepping keeps working without feeding
  /// the player or mutating persisted times. Returns null when there is no
  /// recoverable view (empty view auto-exits).
  Future<TagViewSnapshot?> ensureSnapshot() async {
    if (!isActive) return null;
    final existing = snapshot;
    if (existing != null) return existing;
    if (_recovering) return null;
    _recovering = true;
    try {
      final tagId = activeTagId!;
      final sid = _scenarioId;
      if (sid == null) return null;

      final snap = await resolveSnapshot(tagId, sid);
      if (snap.isEmpty) {
        await exitToNoTag();
        return null;
      }

      final decision = await resolveStart(snap: snap, now: DateTime.now());

      snapshot = snap;
      if (decision.bookmarkLost) {
        // Do NOT silently pick another video on recovery: expose the list but
        // drop the current entry so a later Play starts from the top.
        _bookmarkLost = true;
        _currentEntry = null;
        tagViewStatus.value = null;
        await _ensureTagName(tagId);
        _log.i('ensureSnapshot recovered tag=$tagId bookmark LOST');
        return snapshot;
      }
      _bookmarkLost = false;
      _currentEntry = _toEntry(snap.items[decision.index]);
      await _ensureTagName(tagId);
      _emitViewStatus(snap, decision.index);
      _log.i(
          'ensureSnapshot recovered tag=$tagId idx=${decision.index}/${snap.length}');
      return snapshot;
    } catch (e) {
      _log.e('ensureSnapshot failed: $e');
      return null;
    } finally {
      _recovering = false;
    }
  }

  // ── View switching ──

  /// Enters the tag's play view, persisting the CURRENT active tag (if any)
  /// onto the return stack first. [scenarioId] overrides the coordinator's
  /// active id (tests / explicit switching). Returns the start entry; null
  /// when there is nothing to play.
  Future<PlaybackEntry?> enterView(
    int tagId, {
    String? scenarioId,
    bool autoplay = true,
  }) =>
      _enterView(tagId,
          stashCurrent: true, scenarioId: scenarioId, autoplay: autoplay);

  Future<PlaybackEntry?> _enterView(
    int tagId, {
    required bool stashCurrent,
    String? scenarioId,
    bool autoplay = true,
  }) async {
    if (!TagPlayGate.viewSwitchingEnabled) {
      _log.w('enterView ignored: feature unavailable');
      return null;
    }
    final sid = scenarioId ?? _scenarioId;
    if (sid == null) return null;

    final snap = await resolveSnapshot(tagId, sid);
    if (snap.isEmpty) {
      _log.i('enterView($tagId): empty view');
      return null;
    }

    final decision = await resolveStart(snap: snap, now: DateTime.now());

    final store = useTagPlayStore();
    final previous = store.state.activeViewTagId;

    // Capture the OUTGOING context's real file BEFORE the active-view flag
    // flips: afterwards `activeTagId` already names the incoming tag and the
    // write would land on the wrong row.
    await _captureOutgoing();

    if (TagPlayGate.viewStackEnabled &&
        stashCurrent &&
        previous != null &&
        previous != tagId &&
        !store.state.viewStackTagIds.contains(tagId)) {
      await store.pushViewStack(previous);
    }

    await store.setActiveView(tagId);
    snapshot = snap;
    _boundScenarioId = sid;
    await _ensureTagName(tagId);

    if (decision.bookmarkLost) {
      // Keep the list but auto-play NOTHING: the stored file vanished, so
      // picking another video would betray the bookmark (user choice C). Stop
      // the outgoing feed too — the caller reports the loss as a dialog and a
      // later Play starts from the top via [advanceFirst].
      _bookmarkLost = true;
      _currentEntry = null;
      tagViewStatus.value = null;
      await useAppStore().updateAutoPlay(false);
      await usePlayQueueStore().clear();
      _log.i('enterView($tagId): bookmark file lost → list shown, feed stopped');
      return null;
    }

    _bookmarkLost = false;
    final entry = _toEntry(snap.items[decision.index]);
    await advanceEntry(entry,
        autoplay: autoplay, targetFileKey: decision.fileKey);
    // Persist AFTER the feed so the bookmark records the REAL segment that
    // actually opened (a merged group may land deeper than the item entry).
    await _persistBookmark(snap, entry, virtualPos: decision.index);
    _log.i('enterView($tagId): start=${decision.index}/${snap.length} '
        'key=${entry.key} target=${decision.fileKey ?? '-'}');
    return entry;
  }

  /// Persists the currently playing REAL file onto the OUTGOING context's own
  /// bookmark before a view switch.
  ///
  /// Must run while the outgoing context is still active. The active tag (if
  /// any) stores the live virtual segment in its view-state row; the no-tag
  /// context stores it in the scenario's `currentPlaybackOccurrence` through
  /// the delegate — both keyed by file identity, so a recomposed group still
  /// resumes the same physical file. Single-file playback needs no capture:
  /// its feed already persisted the file key.
  Future<void> _captureOutgoing() async {
    if (!VirtualMediaController.instance.isActive) return;
    final outgoingTag = activeTagId;
    if (outgoingTag != null) {
      final snap = snapshot;
      final seg = VirtualMediaController.instance.currentSegmentOrNull;
      if (snap != null && seg != null) {
        final prev = snap.state;
        await repo.saveState(prev.copyWith(
          lastMediaKey: seg.mediaKey,
          lastVirtualPos: snap.indexOfFileKey(seg.mediaKey),
          lastPlayedAt: DateTime.now(),
          lastActiveAt: DateTime.now(),
        ));
      }
    } else {
      await noTagDelegate.captureCurrentSegment();
    }
    await VirtualMediaController.instance.deactivateForNavigation();
  }

  /// Plays the current bookmark, or — when it was lost (or nothing is current)
  /// — the FIRST item of the active view. Backs the player hook's Play button
  /// after a stopped feed, and the post-loss "start from the top" action.
  Future<PlaybackEntry?> advanceFirst({bool autoplay = true}) async {
    final snap = await ensureSnapshot();
    if (snap == null || snap.isEmpty) return null;
    final entry = _toEntry(snap.items.first);
    await advanceEntry(entry, autoplay: autoplay);
    await _persistBookmark(snap, entry, virtualPos: 0);
    return entry;
  }

  /// Re-resolves the ACTIVE tag view and re-feeds playback at the current
  /// item's relocated position, without touching the return stack.
  ///
  /// Used when a composition-changing setting flips (e.g. the global
  /// "ignore scenario" switch) so both the rendered list and the virtual-media
  /// session (slider) reflect the new stream immediately.
  Future<PlaybackEntry?> refreshActiveView({String? scenarioId}) async {
    final tagId = activeTagId;
    if (tagId == null) return null;
    return _enterView(tagId, stashCurrent: false, scenarioId: scenarioId);
  }

  /// Pops one level of the return stack: restores the previously entered tag
  /// view (via its own bookmark), or falls back to the original no-tag list
  /// when the stack is empty.
  Future<PlaybackEntry?> popView({String? scenarioId}) async {
    if (!isActive) return null;
    final store = useTagPlayStore();
    final restore = await store.popViewStack();
    if (restore == null || restore == activeTagId) {
      return exitToNoTag();
    }
    return _enterView(restore, stashCurrent: false, scenarioId: scenarioId);
  }

  /// Clears the active tag view WITHOUT re-feeding playback — used when the
  /// playback context is about to switch (e.g. a desktop entry activation) so
  /// the tag adapter cannot keep driving the previous scenario. The tag keeps
  /// its own bookmark.
  Future<void> clearActiveView() async {
    if (!isActive) return;
    // Capture the tag's live segment before the flag clears (parity with
    // enterView/exitToNoTag), then flush the virtual session.
    await _captureOutgoing();
    await useTagPlayStore().setActiveView(null);
    await useTagPlayStore().clearViewStack();
    snapshot = null;
    tagViewStatus.value = null;
    _boundScenarioId = null;
    _bookmarkLost = false;
  }

  /// Returns to the original (no-tag) scenario queue, clearing the whole
  /// return stack. The exiting tag keeps its own bookmark; the scenario
  /// resumes ITS last position independently.
  Future<PlaybackEntry?> exitToNoTag() async {
    if (!isActive) return null;
    // Capture the tag's live segment onto ITS row before the flag clears.
    await _captureOutgoing();
    await useTagPlayStore().setActiveView(null);
    await useTagPlayStore().clearViewStack();
    snapshot = null;
    tagViewStatus.value = null;
    _bookmarkLost = false;

    // The no-tag context resumes its OWN last real file (captured when we last
    // left it, or persisted by its own feed). Passing it as the VM target keeps
    // a merged group opening on that file instead of the group's first segment.
    final entry = await noTagDelegate.current();
    if (entry != null) {
      await noTagDelegate.advanceEntry(entry, targetFileKey: entry.key);
    }
    return entry;
  }

  /// Re-resolves the active view after memberships/spec changed. Relocates
  /// the current item by key; falls back per jump-back rules when it vanished.
  /// [scenarioId] overrides the coordinator's active id (tests / explicit
  /// switching); when omitted the live active scenario is used.
  Future<bool> revalidate({String? scenarioId}) async {
    final tagId = activeTagId;
    if (tagId == null) return false;
    final sid = scenarioId ?? _scenarioId;
    if (sid == null) return false;

    final previous = _currentEntry;
    final snap = await resolveSnapshot(tagId, sid);

    if (snap.isEmpty) {
      // Everything expired/vanished → drop back to the original list.
      await exitToNoTag();
      return true;
    }

    int targetIndex = 0;
    if (previous != null) {
      final byKey = snap.indexOfKey(previous.key);
      targetIndex =
          byKey ?? await resolveStartIndex(snap: snap, now: DateTime.now());
    } else {
      targetIndex = await resolveStartIndex(snap: snap, now: DateTime.now());
    }

    snapshot = snap;
    final entry = _toEntry(snap.items[targetIndex]);
    await _persistBookmark(snap, entry, virtualPos: targetIndex);
    _currentEntry = entry;
    return true;
  }

  // ── Bookmark persistence ──

  Future<void> _persistBookmark(
    TagViewSnapshot snap,
    PlaybackEntry entry, {
    required int virtualPos,
  }) async {
    final prev = snap.state;
    final now = DateTime.now();
    final next = prev.copyWith(
      lastMediaKey: _realFileKeyFor(entry),
      lastVirtualPos: virtualPos,
      lastPlayedAt: now,
      lastActiveAt: now,
    );
    await repo.saveState(next);
    _emitViewStatus(snap, virtualPos);
  }

  /// The REAL file that will play for [entry]: the live virtual segment when a
  /// session is active (a merged group may open deeper than the item entry),
  /// else the entry's own file key. Relocation matches THIS identity, so a
  /// recomposed group never loses the position.
  String _realFileKeyFor(PlaybackEntry entry) {
    if (VirtualMediaController.instance.isActive) {
      final seg = VirtualMediaController.instance.currentSegmentOrNull;
      if (seg != null) return seg.mediaKey;
    }
    return entry.key;
  }

  // ── Stepping / shuffle inside the active view ──

  /// Next entry of the active view (null at the tail; caller wraps).
  Future<PlaybackEntry?> next() => _step(forward: true);

  /// Previous entry of the active view (null at the head; caller wraps).
  Future<PlaybackEntry?> previous() => _step(forward: false);

  Future<PlaybackEntry?> _step({required bool forward}) async {
    final snap = await ensureSnapshot();
    if (snap == null || snap.isEmpty) return null;
    final cur = _currentEntry;
    var idx = cur != null ? (snap.indexOfKey(cur.key) ?? -1) : -1;
    idx += forward ? 1 : -1;
    if (idx < 0 || idx >= snap.length) return null;

    final entry = _toEntry(snap.items[idx]);
    await advanceEntry(entry);
    await _persistBookmark(snap, entry, virtualPos: idx);
    return entry;
  }

  Future<PlaybackEntry?> wrapToFirst() => _jumpTo(0);

  Future<PlaybackEntry?> wrapToLast() async {
    final snap = await ensureSnapshot();
    return _jumpTo((snap?.length ?? 1) - 1);
  }

  /// Jumps straight to an absolute position inside the ACTIVE view (queue
  /// surface taps). Silently no-ops when the view is inactive/empty.
  Future<PlaybackEntry?> jumpToIndex(int index) => _jumpTo(index);

  /// Like [jumpToIndex], but opens the merged group on [targetFileKey] (a real
  /// child file) when the entry is a virtual-merged member — used by the
  /// expandable row's "play from this child" tap.
  Future<PlaybackEntry?> jumpToIndexWithFile(
    int index,
    String? targetFileKey, [
    int? targetOccurrenceIndex,
  ]) =>
      _jumpTo(
        index,
        targetFileKey: targetFileKey,
        targetOccurrenceIndex: targetOccurrenceIndex,
      );

  Future<PlaybackEntry?> _jumpTo(
    int index, {
    String? targetFileKey,
    int? targetOccurrenceIndex,
  }) async {
    final snap = await ensureSnapshot();
    if (snap == null || snap.isEmpty) return null;
    if (index < 0 || index >= snap.length) return null;
    final entry = _toEntry(snap.items[index]);
    await advanceEntry(entry,
        targetFileKey: targetFileKey,
        targetOccurrenceIndex: targetOccurrenceIndex);
    await _persistBookmark(snap, entry, virtualPos: index);
    return entry;
  }

  /// Toggles the ACTIVE TAG VIEW's shuffle only — the scenario's own order
  /// stays untouched (orthogonality).
  Future<void> toggleShuffle({String? scenarioId}) async {
    final tagId = activeTagId;
    if (tagId == null) return;
    final prev =
        await repo.stateOf(tagId) ?? TagViewResolver.defaultStateFor(tagId);
    final nowShuffled = prev.order == PlaybackOrder.shuffled;

    final next = nowShuffled
        ? prev.copyWith(order: PlaybackOrder.sequential)
        : prev.copyWith(
            order: PlaybackOrder.shuffled,
            shuffleSeed: DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
            shuffleVersion: prev.shuffleVersion + 1,
            shuffleItemCount: snapshot?.length ?? prev.shuffleItemCount,
          );
    await repo.saveState(next);

    // Re-resolve under the new order and keep playing the SAME item.
    await revalidate(scenarioId: scenarioId);
  }

  // ── Player feed ──

  PlaybackEntry? _currentEntry;

  /// Cached current entry; lazily recovers the snapshot after a restart so
  /// surfaces reading "what is playing" keep working without a fresh enter.
  Future<PlaybackEntry?> currentEntry() async {
    if (_currentEntry != null) return _currentEntry;
    await ensureSnapshot();
    return _currentEntry;
  }

  PlaybackEntry? get currentCachedEntry => _currentEntry;

  /// Feeds [entry] to the player, entering a Virtual Media session when the
  /// ACTIVE tag view's own stream covers it (mirrors the scenario provider's
  /// merge branch, but derived from the snapshot's cached groups). Without a
  /// covering rule the entry falls through to the ordinary single-file feed.
  ///
  /// [targetFileKey] is the per-context bookmark's real file: when it belongs
  /// to [entry]'s merged group, the session opens on THAT segment instead of
  /// the group's most-recently-watched one.
  Future<void> advanceEntry(
    PlaybackEntry entry, {
    bool autoplay = true,
    String? targetFileKey,
    int? targetOccurrenceIndex,
  }) async {
    _currentEntry = entry;
    // Any successful feed clears the "file gone" state (Play-from-top included).
    _bookmarkLost = false;
    if (await _startVmSession(entry,
        autoplay: autoplay,
        targetFileKey: targetFileKey,
        targetOccurrenceIndex: targetOccurrenceIndex)) {
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

  /// Starts (or re-enters) the Virtual Media session for [entry] when it is a
  /// member of a feasible group in the active tag view. Returns true when a
  /// session was started — the caller must not feed the single file after.
  ///
  /// The merge groups come from the SNAPSHOT (resolved once per view resolve),
  /// not from a second `resolveGroupsForStream` per feed — the previous double
  /// regex pass was the dominant per-tap cost.
  Future<bool> _startVmSession(
    PlaybackEntry entry, {
    bool autoplay = true,
    String? targetFileKey,
    int? targetOccurrenceIndex,
  }) async {
    final snap = snapshot ?? await ensureSnapshot();
    if (snap == null) return false;
    final groups = snap.vmGroups;
    if (groups == null || groups.isEmpty) return false;

    final entryKey = canonicalKey(entry.storageId, entry.path);
    if (groups.failByKey.containsKey(entryKey)) return false;
    // Runtime failures published by the blocking play-time preflight (missing
    // node / probe) are not part of the snapshot groups; honor them too so a
    // just-failed merged item degrades to ordinary single-file playback.
    if (VirtualMediaService.instance.failInfoFor(entryKey) != null) {
      return false;
    }
    final group = groups.byKey[entryKey];
    if (group == null || group.segments.isEmpty || group.totalDurationMs <= 0) {
      return false;
    }

    // Target only when the bookmark actually belongs to THIS group — a stale
    // file from a previous composition then falls back to recency instead of
    // forcing a segment that no longer exists. The occurrence index keeps a
    // duplicated file on the tapped occurrence.
    final targetIdx = targetFileKey == null
        ? null
        : group.indexOfSegment(targetFileKey, targetOccurrenceIndex);
    final target = targetIdx == null ? null : targetFileKey;
    // A located target needs no recency lookup: the planner lets the file's own
    // saved progress steer the open, so the whole DB round-trip is skipped.
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
    _log.i('tag vm session start key=$entryKey scope=${group.scopeKey} '
        'target=${target ?? '-'}');
    return true;
  }

  /// Converts a resolved item into a player entry (same shape as the
  /// scenario provider's conversion).
  PlaybackEntry _toEntry(EffectivePlaybackItem item) {
    final node = item.media;
    final file = node.maybeMap(
      file: (f) {
        final storage = useStorageStore().findById(f.storageId);
        return FileItem(
          storageId: f.storageId,
          storageType: storage?.type ?? StorageType.none,
          name: f.name,
          uri: mediaNodePlayableUri(storage, f.path, uri: f.uri),
          path: f.path,
          size: f.sizeInBytes ?? 0,
          type: _mediaTypeOf(f.mediaType),
          lastModified: f.modifiedAt,
          // Subtitle associations persisted at scan time (schema v50).
          subtitles: f.subtitles ?? const [],
        );
      },
      orElse: () => FileItem(name: node.name, uri: playableUri(node.path)),
    );
    return PlaybackEntry(
      file: file,
      storageId: node.storageId,
      path: item.occurrenceId.path,
      key: canonicalKey(item.occurrenceId.storageId, item.occurrenceId.path),
      occurrenceIndex: item.occurrenceId.occurrenceIndex,
      available: item.available,
    );
  }

  ContentType _mediaTypeOf(MediaType mt) {
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
