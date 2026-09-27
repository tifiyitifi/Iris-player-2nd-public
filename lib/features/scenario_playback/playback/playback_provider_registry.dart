import 'package:iris/features/background_playback/controller/background_playback_router.dart';
import 'package:iris/features/background_playback/services/background_lock_mapping.dart';
import 'package:iris/features/background_playback/services/segment_edit_guard.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/playback/playback_position_signal.dart';
import 'package:iris/features/scenario_playback/playback/playback_progress.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/playback/legacy_queue_provider.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/playback/tag_play_controller.dart';
import 'package:iris/features/tag_play/store/use_tag_play_store.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/ab_loop_engine.dart';
import 'package:iris/features/windows/desktop_keyboard/store/key_sequence_buffer_store.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/path_conv.dart';

/// Routes playback to the correct [PlaybackProvider].
///
/// There are three mechanisms of playback (priority order):
/// 1. the oldest legacy queue (`useLegacyStoragePersistence == true`,
///    UnifiedPlayQueueStore in-memory backend)
/// 2. the scenario-driven ("drift base") system
///    (`useScenarioDrivenPlayback == true`, the current development target)
/// 3. the paged play queue (`useScenarioDrivenPlayback == false`,
///    UnifiedPlayQueueStore query backend)
///
/// All coexist; the scenario-driven mode is the default development path and
/// can be switched back to the paged queue at any time by toggling
/// `AppState.useScenarioDrivenPlayback` in code until the final version is
/// settled.
class PlaybackProviderRegistry {
  static late final ScenarioPlaybackProvider _scenario;
  static late final LegacyQueueProvider _legacy;
  static late final TagPlayController _tagPlay;
  static BackgroundPlaybackRouter? _bgRouter;

  static void init() {
    _scenario = ScenarioPlaybackProvider();
    _legacy = LegacyQueueProvider();
    _tagPlay = TagPlayController(
      noTagDelegate: ScenarioNoTagDelegate(_scenario),
    );
  }

  /// Registers the 副音 router (BackgroundPlaybackBootstrap). While its
  /// [BackgroundPlaybackRouter.targetIsBackground] is true, the user actions
  /// below (next/prev/shuffle/repeat/stop) drive the background runtime
  /// instead of the foreground queue. Natural completion deliberately keeps
  /// flowing through the foreground path only.
  static void registerBackgroundRouter(BackgroundPlaybackRouter? router) {
    _bgRouter = router;
  }

  static ScenarioPlaybackProvider get scenario => _scenario;

  static LegacyQueueProvider get legacy => _legacy;

  static TagPlayController get tagPlay => _tagPlay;

  /// Scenario-driven mode is active only in drift mode (non-legacy storage)
  /// with the scenario-driven flag enabled.
  static bool get _useScenarioMode {
    final app = useAppStore().state;
    return !app.useLegacyStoragePersistence && app.useScenarioDrivenPlayback;
  }

  /// True while a tag play view drives playback (meta-driven + scenario mode
  /// + an active tag view).
  static bool get _useTagViewMode =>
      _useScenarioMode && TagPlayGate.viewSwitchingEnabled &&
      useTagPlayStore().state.activeViewTagId != null;

  /// Whether the scenario-driven mode owns playback right now (drift mode).
  static bool get scenarioModeActive => _useScenarioMode;

  /// Whether a tag play view owns the playback context. Its controller feeds
  /// and books the session itself, so scenario-side bookkeeping (current item /
  /// position) must stand back while it is true.
  static bool get tagViewDriving => _useTagViewMode;

  /// The provider the player should use right now.
  static PlaybackProvider active() =>
      _useTagViewMode ? _TagViewPlaybackAdapter() : (_useScenarioMode ? scenario : legacy);

  static void _resetEphemerals() {
    AbLoopEngine.instance.reset();
    useKeySequenceBufferStore().close();
  }

  /// Declares that playback is now fed from OUTSIDE the scenario provider (the
  /// history popup, the storage / media-library browsers, open file, open link,
  /// a share intent, SAF) and drops the scenario's published position.
  ///
  /// The bar title's `[cur/total]` prefix reads a process-wide signal that only
  /// `ScenarioPlaybackProvider.play` resets, so a feed that bypasses the
  /// provider left the previous stream's numbers behind and the title kept
  /// claiming them over unrelated content. Every "I am taking the player now"
  /// declaration must go through here.
  ///
  /// The hand-off also drops context OWNERSHIP ([clear] resets both), which is
  /// what hands the prefix to the incoming feed's own queue index — an
  /// external list feed carries a meaningful one that must not stay suppressed.
  static void beginExternalFeed() {
    PlaybackPositionSignal.instance.clear();
  }

  /// Steps to the previous/next entry, feeding the player when running in
  /// scenario-driven mode.
  ///
  /// Virtual media contract (spec §4): user Next/Prev always cross virtual
  /// bodies (perceptually “one file”). Inner stepping is reserved for
  /// natural completion / chapter clicks via [VirtualMediaController.step]
  /// and [maybeHandleCompleted]; this method therefore clears the virtual
  /// session before delegating to the outer queue — the target entry then
  /// re-enters a merged session through the VM-aware `advanceEntry` when it
  /// is itself a virtual body.
  static Future<void> step({required bool forward}) async {
    // A-中心-B editor open: the fg/bg pair is frozen — prev/next must not swap
    // it out (covers the fg queue, scenario/tag stepping and the bg route).
    if (SegmentEditGuard.transportFrozen) return;
    final bg = _bgRouter;
    if (bg != null && bg.targetIsBackground) {
      await bg.step(forward: forward);
      return;
    }
    _resetEphemerals();
    if (VirtualMediaController.instance.isActive) {
      // Cross virtual body — do not step inside. Natural completion uses
      // maybeHandleCompleted directly via the player hooks. The next entry
      // (virtual or real) is fed by advanceEntry below, which restarts a
      // merged session for a virtual target.
      // Lightweight deactivation: the next feed overwrites the queue +
      // autoplay, so the heavy `stop` (empty-queue flash, autoplay off/on)
      // must not run here. preserveProgress semantics are kept — the body's
      // anchor survives so prev back onto it resumes the last position.
      await VirtualMediaController.instance.deactivateForNavigation();
    }

    if (_useTagViewMode) {
      // tagPlay.next()/previous() already feed the player through their own
      // advanceEntry (bookmark + VM session); feeding the returned entry a
      // second time here started the virtual session twice.
      final entry = forward ? await tagPlay.next() : await tagPlay.previous();
      if (entry == null) {
        final repeat = usePlaybackScenarioStore().state.activeScenarioRepeat;
        if (repeat == Repeat.all) {
          if (forward) {
            await tagPlay.wrapToFirst();
          } else {
            await tagPlay.wrapToLast();
          }
        }
      }
      return;
    }

    if (!_useScenarioMode) {
      final store = usePlayQueueStore();
      if (forward) {
        await store.next();
      } else {
        await store.previous();
      }
      return;
    }

    var entry = forward ? await scenario.next() : await scenario.previous();
    final repeat = usePlaybackScenarioStore().state.activeScenarioRepeat;
    if (entry == null && repeat == Repeat.all) {
      entry =
          forward ? await scenario.wrapToFirst() : await scenario.wrapToLast();
    }
    if (entry != null) {
      await scenario.advanceEntry(entry);
    }
  }

  /// Toggles shuffle using the mechanism of the active mode.
  static Future<void> toggleShuffle() async {
    final bg = _bgRouter;
    if (bg != null && bg.targetIsBackground) {
      await bg.toggleShuffle();
      return;
    }
    if (_useTagViewMode) {
      await tagPlay.toggleShuffle();
      return;
    }
    if (_useScenarioMode) {
      await usePlaybackScenarioStore().toggleShuffle();
      return;
    }
    final store = usePlayQueueStore();
    final app = useAppStore();
    if (app.state.shuffle) {
      await store.sort();
    } else {
      await store.shuffle();
    }
    await app.updateShuffle(!app.state.shuffle);
  }

  /// Toggles repeat using the mechanism of the active mode.
  ///
  /// Scenario mode cycles the scenario's `repeatMode` (Definition, D1);
  /// legacy mode cycles `AppState.repeat`.
  static Future<void> toggleRepeat() async {
    final bg = _bgRouter;
    if (bg != null && bg.targetIsBackground) {
      await bg.toggleRepeat();
      return;
    }
    if (_useScenarioMode) {
      final store = usePlaybackScenarioStore();
      final current = store.state.activeScenarioRepeat;
      final next = switch (current) {
        Repeat.none => Repeat.all,
        Repeat.all => Repeat.one,
        Repeat.one => Repeat.none,
      };
      await store.setRepeat(next);
      return;
    }
    await useAppStore().toggleRepeat();
  }

  /// PotPlayer-style stop: resets the current item's progress and clears the player
  /// feed so the player hook unloads the media; the current item stays selected
  /// so a later play resumes it from the beginning. Legacy mode keeps the
  /// existing `updateCurrentIndex(-1)` stop behavior.
  ///
  /// During an active tag view the stop only unloads the feed: the scenario's
  /// current item is NOT the file being played, so resetting "scenario
  /// progress" would corrupt the wrong row. The tag view keeps its bookmark.
  static Future<void> stop() async {
    final bg = _bgRouter;
    if (bg != null && bg.targetIsBackground) {
      await bg.stop();
      return;
    }
    _resetEphemerals();
    // The foreground feed is going away, so the scenario's published position
    // no longer describes anything on screen. Deliberately AFTER the 副音
    // early-return above: stopping the background runtime leaves the foreground
    // scenario position valid.
    beginExternalFeed();
    await useAppStore().updateAutoPlay(false);
    // Virtual Media session: unload feed + flush anchor + deactivate.
    if (VirtualMediaController.instance.isActive) {
      await VirtualMediaController.instance.stop();
      return;
    }
    if (_useTagViewMode) {
      await usePlayQueueStore().clear();
      return;
    }
    if (_useScenarioMode) {
      if (usePlaybackScenarioStore().state.activeScenarioId != null) {
        await scenario.stop();
      }
      await usePlayQueueStore().clear();
      return;
    }
    await usePlayQueueStore().updateCurrentIndex(-1);
  }

  /// Re-feeds the ACTIVE playback context after a full stop (the player was
  /// unloaded): the current item when one is selected, else the FIRST item of
  /// the active view. Context-aware so a stopped tag view resumes inside the
  /// tag — never the no-tag scenario item sitting behind it (which is also what
  /// makes "file lost → Play starts from the top" work: the tag has no current
  /// entry, so the first item is fed).
  static Future<void> resumeActive({bool autoplay = true}) async {
    if (!_useScenarioMode) return;
    if (autoplay) await useAppStore().updateAutoPlay(true);
    if (_useTagViewMode) {
      final current = await tagPlay.currentEntry();
      if (current != null) {
        await tagPlay.advanceEntry(current, autoplay: autoplay);
      } else {
        await tagPlay.advanceFirst(autoplay: autoplay);
      }
      return;
    }
    final entry = await scenario.current();
    if (entry != null) {
      // Same shape as ScenarioPlaybackProvider.play: a stop cleared the
      // position, and advanceEntry alone does not re-publish it — without this
      // "stop → play" would show no prefix at all instead of a stale one.
      await scenario.establishCurrentPosition();
      await scenario.advanceEntry(entry, autoplay: autoplay);
      return;
    }
    // No persisted current item ("file lost → play from the top"): there is
    // nothing to locate, and `establishCurrentPosition` would resolve that
    // absent occurrence and publish nothing — the bar title would sit prefix-
    // less while item 0 plays. The fallback's own index is known outright, so
    // book it directly instead of looking it up.
    final head = await scenario.itemAt(0);
    if (head != null) {
      await scenario.advanceTo(head, index: 0, autoplay: autoplay);
    }
  }

  /// Advances playback when the current media completes.
  ///
  /// In scenario-driven mode, repeat handling is done here; the legacy path
  /// returns false so callers keep the existing queue-based behavior.
  static Future<bool> advanceOnComplete(Repeat repeat) async {
    // A-中心-B editor open: playback reaching its end must PAUSE, not advance
    // to the next entry. `true` = handled, so the calling hook stops here.
    if (SegmentEditGuard.transportFrozen) return true;
    _resetEphemerals();
    if (repeat == Repeat.one) return false;
    if (_useTagViewMode) {
      // See step(): the tag controller feeds internally; do not feed twice.
      final entry = await tagPlay.next();
      if (entry == null && repeat == Repeat.all) {
        await tagPlay.wrapToFirst();
      }
      return true;
    }
    if (!_useScenarioMode) return false;

    var entry = await scenario.next();
    if (entry == null && repeat == Repeat.all) {
      entry = await scenario.wrapToFirst();
    }
    if (entry != null) {
      await scenario.advanceEntry(entry);
    }
    return true;
  }

  /// Guard against a pathological queue blowing up the roll page request.
  static const int _kMaxRollEntries = 500;

  /// Rolls the ACTIVE foreground queue onto the entry containing [targetMs] of
  /// the concatenated foreground timeline.
  ///
  /// Used by the 副音 position mirror while 副音 is the master: a seek that maps
  /// past the current foreground file must move the foreground by one or more
  /// whole files instead of clamping to the file end (which used to raise a
  /// spurious completion and advance the queue).
  ///
  /// [keepPlaying] is the transport state to preserve: a seek must never change
  /// play/pause. The landing offset is PRE-WRITTEN as the target file's resume
  /// position so the foreground hook's normal open-resume seeks there — a seek
  /// issued after the file opens would race the load. Returns true when a roll
  /// was performed.
  static Future<bool> seekVirtualTo(
    int targetMs, {
    bool keepPlaying = true,
  }) async {
    if (SegmentEditGuard.transportFrozen) return false;
    final provider = active();
    final total = await provider.totalCount();
    if (total <= 1 || total > _kMaxRollEntries) return false;
    final entries = await provider.page(offset: 0, count: total);
    if (entries.isEmpty) return false;
    final durations = await _entryDurationsMs(entries);
    final timeline = BgQueueTimeline(durations);
    if (timeline.isEmpty || timeline.totalMs <= 0) return false;
    final (targetIndex, localMs) = timeline.locate(targetMs);
    final current = await provider.current();
    if (current == null) return false;
    final currentIndex = entries.indexWhere(
      (e) =>
          e.key == current.key &&
          e.occurrenceIndex == current.occurrenceIndex,
    );
    if (currentIndex < 0 || targetIndex == currentIndex) return false;

    final int landing = localMs < 0 ? 0 : localMs;
    await persistPlaybackProgress(
      file: entries[targetIndex].file,
      position: Duration(milliseconds: landing),
      durationMs: durations[targetIndex],
      userSeek: true,
      userSeekToHead: landing <= 0,
      writeTag: 'bg-step-roll',
    );

    // Scenario/tag providers' next()/previous() only move their OWN bookkeeping
    // (the player is fed exclusively by advanceEntry), so the roll must feed the
    // target entry in ONE hop. Keeping it single-hop also means the foreground
    // sees exactly one item change for the whole roll.
    if (_useTagViewMode) {
      await tagPlay.advanceEntry(entries[targetIndex], autoplay: keepPlaying);
      return true;
    }
    if (_useScenarioMode) {
      // The roll is a real jump, so the target gets BOOKED (current item +
      // published position) the way the scenario's own next()/previous() book
      // theirs before handing the entry over. `advanceEntry` only feeds, which
      // left the bar title — and the next next/prev, which steps from the
      // current item — describing the file the roll left.
      await scenario.advanceTo(entries[targetIndex],
          index: targetIndex, autoplay: keepPlaying);
      return true;
    }

    // Legacy/paged queue: its next()/previous() mutate the queue store, which
    // feeds the player, so walking the queue IS the correct path there.
    var i = currentIndex;
    var guard = 0;
    while (i != targetIndex && guard++ <= total) {
      if (i < targetIndex) {
        await provider.next();
        i++;
      } else {
        await provider.previous();
        i--;
      }
    }
    return true;
  }

  /// Best-effort concatenated durations of [entries] (0 when unknown), reusing
  /// the same media-node lookup the 副音 timeline uses.
  static Future<List<int>> _entryDurationsMs(
    List<PlaybackEntry> entries,
  ) async {
    try {
      final keys = <String>{
        for (final e in entries)
          if (e.storageId.isNotEmpty) canonicalKey(e.storageId, e.path),
      };
      if (keys.isEmpty) return List<int>.filled(entries.length, 0);
      final nodes = await DbModule.mediaNodeRepo.nodesByMediaKeys(keys);
      final byKey = <String, int>{};
      for (final n in nodes) {
        final f = n.maybeMap(file: (v) => v, orElse: () => null);
        final d = f?.durationMs;
        if (f == null || d == null || d <= 0) continue;
        byKey[canonicalKey(f.storageId, f.path.join('/'))] = d;
      }
      return <int>[
        for (final e in entries)
          e.storageId.isEmpty
              ? 0
              : (byKey[canonicalKey(e.storageId, e.path)] ?? 0),
      ];
    } catch (_) {
      return List<int>.filled(entries.length, 0);
    }
  }
}

/// [PlaybackProvider] view over the active tag play view. Satisfies surfaces
/// that only need the current entry/count of what is playing; stepping and
/// shuffle keep flowing through [tagPlay] so bookmark persistence stays in
/// one place. Count/current lazily recover the snapshot after a restart.
class _TagViewPlaybackAdapter implements PlaybackProvider {
  const _TagViewPlaybackAdapter();

  @override
  Future<int> totalCount() async =>
      (await PlaybackProviderRegistry.tagPlay.ensureSnapshot())?.length ?? 0;

  @override
  Future<PlaybackEntry?> current() =>
      PlaybackProviderRegistry.tagPlay.currentEntry();

  @override
  Future<PlaybackEntry?> next() => PlaybackProviderRegistry.tagPlay.next();

  @override
  Future<PlaybackEntry?> previous() =>
      PlaybackProviderRegistry.tagPlay.previous();

  @override
  Future<PlaybackEntry?> itemAt(int index) async =>
      index == 0 ? current() : null;

  @override
  Future<List<PlaybackEntry>> page({
    required int offset,
    required int count,
  }) async {
    return offset == 0 && count > 0
        ? [if (await current() != null) (await current())!]
        : const [];
  }
}
