import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/app_shutdown.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/engine/background_scope_logic.dart';
import 'package:iris/features/background_playback/hooks/use_background_volume_context.dart';
import 'package:iris/features/background_playback/model/enum/bg_exhausted_action.dart';
import 'package:iris/features/background_playback/model/enum/bg_gate_stop_behavior.dart';
import 'package:iris/features/background_playback/services/background_volume_policy.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:provider/provider.dart';

final _log = AreaKeyLog(LogKeys.player);

/// Host of the 副音 engine, mounted once at the Home root (above the whole
/// player subtree). While [BackgroundPlaybackState.enabled] the scope owns
/// exactly one [BackgroundPlaybackEngine] (following the global
/// `playerBackend`) and exposes it to the player Stack below through
/// `Provider<BackgroundPlaybackEngine>`. Disabling (or switching the player
/// backend) disposes the engine and starts fresh.
///
/// The engine is driven declaratively by store state — this widget never
/// calls player APIs of the foreground runtime; the only links to the
/// foreground are the same-file skip guard ([excludedForegroundKey]) and the
/// mapping session fields written by the MappingScope (E 节): when
/// [BackgroundPlaybackState.mappedFile] is set, THAT file replaces the
/// natural queue entry until the resolver exits the segment.
class BackgroundPlaybackScope extends HookWidget {
  const BackgroundPlaybackScope({
    super.key,
    required this.child,
    this.debugEngine,
  });

  final Widget child;

  /// Test seam: the scope normally builds (and owns) its own runtime, which
  /// allocates a native player — impossible under `flutter test`. An injected
  /// engine is NOT disposed by this widget.
  @visibleForTesting
  final BackgroundPlaybackEngine? debugEngine;

  @override
  Widget build(BuildContext context) {
    final bg = useBackgroundPlaybackStore();
    final enabled = bg.select(context, (s) => s.enabled);
    final keepWarm = bg.select(context, (s) => s.keepWarmPlayer);
    final backend = useAppStore().select(context, (s) => s.playerBackend);

    // One engine instance for the whole session while enabled OR preloaded
    // (sub_media §1): constructing it at launch is what removes the black
    // flash when the user later starts 副音. Recreated on a backend switch.
    final wantEngine = enabled || keepWarm;
    final engine = useMemoized<BackgroundPlaybackEngine?>(
      () => debugEngine ??
          (wantEngine
              ? BackgroundPlaybackEngine(backend: backend, warmOnly: !enabled)
              : null),
      [wantEngine, backend, debugEngine],
    );
    useEffect(() {
      final e = engine;
      if (e == null) return null;
      // Desktop shutdown: a window close tears the engine down without
      // unmounting the tree, so this cleanup never runs — register the engine
      // so its player is disposed before the isolate dies (see [AppShutdown]).
      final unregister = AppShutdown.registerDisposer(() async => e.dispose());
      final unregisterQuiesce = AppShutdown.registerQuiesce(() => e.pause());
      return () {
        unregisterQuiesce();
        unregister();
        // An injected engine belongs to its caller.
        if (debugEngine == null) e.dispose();
      };
    }, [engine, debugEngine]);

    final queue = bg.select(context, (s) => s.queue);
    final currentIndex = bg.select(context, (s) => s.currentIndex);
    final bgAutoPlay = bg.select(context, (s) => s.bgAutoPlay);
    // 开机状态 gate: the run is armed but the gate is CLOSED until the user
    // opens it from the quick bar — nothing may load/play before then.
    final gateOpen = bg.select(context, (s) => s.gateOpen);
    final gateStopBehavior = bg.select(context, (s) => s.gateStopBehavior);
    final bgRate = bg.select(context, (s) => s.rate);
    final bgMuted = bg.select(context, (s) => s.bgMuted);
    // The duck gate is ONE predicate shared with `useBackgroundVolumeContext`:
    // the engine-side policy must read the same session flags or the background
    // engine keeps a non-zero volume after the pair was handed back (the same
    // 「换集后视频只剩 30% 音量、副音却静音」 family of reports).
    final bgExhausted = bg.select(context, (s) => s.bgExhausted);
    final bgQueueEnded = bg.select(context, (s) => s.bgQueueEnded);
    final bgOutOfScope = bg.select(context, (s) => s.bgOutOfScope);
    final bgSuspendedByFakeCut =
        bg.select(context, (s) => s.bgSuspendedByFakeCut);
  // Mapping session (E 节).
  final mappedFile = bg.select(context, (s) => s.mappedFile);
  final mappedSeekSeq = bg.select(context, (s) => s.mappedSeekSeq);
    // 进度锁定 rollover (fg → bg mapping): one-shot queue jump + seek.
    final lockSeekSeq = bg.select(context, (s) => s.lockSeekSeq);
    final lockSeekTargetMs = bg.select(context, (s) => s.lockSeekTargetMs);
    final lockTargetIndex = bg.select(context, (s) => s.lockTargetIndex);
    // WholeVirtual tiled entrance: one-shot queue jump + offset seek, owned
    // by the VM link's precomputed plan (a separate sequence so it never
    // shares identity with the lock rollover above).
    final tiledSeekSeq = bg.select(context, (s) => s.tiledSeekSeq);
    final tiledSeekTargetMs = bg.select(context, (s) => s.tiledSeekTargetMs);
    final tiledTargetIndex = bg.select(context, (s) => s.tiledTargetIndex);

    final masterVolume = useAppStore().select(context, (s) => s.volume);
    final masterMuted = useAppStore().select(context, (s) => s.isMuted);
    final appRate = useAppStore().select(context, (s) => s.rate);
    final bgRateLock = bg.select(context, (s) => s.bgRateLock);
    // Effective fg/bg ratio for the foreground media being paired (sub_media
    // §5.5) — the 副音 engine gets master × its bg share.
    final bgVolume = useBackgroundVolumeContext(context);
    final bgVolumePercent = bgVolume.ratio.bgPercent;

    // Open target: mapped segment file wins over the natural queue entry.
    final FileItem? naturalFile = useMemoized(
      () {
        if (engine == null || !enabled) return null;
        if (currentIndex < 0 || currentIndex >= queue.length) return null;
        return queue[currentIndex];
      },
      [engine, enabled, queue, currentIndex],
    );
    // Open target: the mapped segment file wins over the natural queue entry.
    // While the A-B editor is open the queue itself is the edit target (the
    // editor pre-aligns the live queue), so there is no separate preview file.
    final FileItem? openTarget = mappedFile ?? naturalFile;
    final openTargetKey = useMemoized<String?>(
      () => openTarget == null ? null : backgroundMediaKey(openTarget),
      [openTarget],
    );

    // Wire natural completion to the queue advance. Completion while a mapped
    // segment is active = the mapped file ended early (clamp still not
    // enough): advance the natural queue once and let the resolver latch the
    // aborted segment.
    useEffect(() {
      final e = engine;
      if (e == null) return null;
      e.onCompleted = () {
        final s = useBackgroundPlaybackStore().state;
        if (!s.enabled) return;
        // A-中心-B editor open: transport frozen — reaching the end pauses
        // instead of advancing the 副音 queue.
        if (s.segmentEditMode) {
          unawaited(e.pause());
          return;
        }
        final store = useBackgroundPlaybackStore();
        if (s.mappedFile != null) {
          unawaited(store.mappedCompletionEarly());
          return;
        }
        // 副音 exhausted: the current file ended while the video keeps playing.
        // Under stopRestoreFg the run terminates — 副音 stops and the foreground
        // returns to its own (un-ducked) volume.
        if (s.bgExhaustedAction == BgExhaustedAction.stopRestoreFg) {
          store.markBgExhausted();
          unawaited(e.pause());
          return;
        }
        if (s.bgRepeat == Repeat.one) {
          // Repeat.one outranks nextBg: an explicit single-track loop replays
          // the same file rather than walking the list.
          store.noteSystemSeek();
          e.replay();
          return;
        }
        // nextBg: 副音 always keeps a track. The runtime observer owns the
        // cross-file continuation — it has the physical fg window AND the pair's
        // authoritative offset, so the queue can be walked as ONE looping
        // timeline and playback continues at the entry carrying the SAME virtual
        // position, never restarting the next index at its own 00:00 (which
        // would re-anchor a non-zero alignment).
        store.requestBgContinuation(fromAlign: false);
      };
      return () {
        e.onCompleted = null;
      };
    }, [engine]);

    // Open on file change (engine may be null while disabled/transitional).
    // A closed gate blocks loading entirely: a cold launch must reach a
    // definite "armed but stopped, nothing loaded" state, and a gate stop must
    // not be undone by a queued open.
    useEffect(() {
      final e = engine;
      if (e == null || openTarget == null || !enabled || !gateOpen) return null;
      _log.i('bg open $openTargetKey autoplay=$bgAutoPlay');
      e.open(openTarget, autoplay: bgAutoPlay);
      return null;
      // Open is keyed on the file identity; bgAutoPlay only decides the
      // initial play flag of the open below.
    }, [engine, openTargetKey, openTarget, enabled, gateOpen]);

    // Autoplay sync (separate from open so play/pause never re-opens).
    // Silence segments hold bg paused via bgAutoPlay=false; when bgAutoPlay
    // flips back the same file resumes in place.
    //
    // Split out of the effect so the settle listener below can re-issue it.
    void applyAutoplaySync(BackgroundPlaybackEngine e) {
      if (!enabled || openTarget == null) return;
      if (e.isInitializing) return;
      // Shutdown fence: the quiesce pause flips isPlaying, which would re-enter
      // this sync and call play()/pause() on an engine being disposed.
      if (AppShutdown.isActive) return;
      // A closed gate is the single "may play" permission: never play while it
      // is shut, even if a stale flag says otherwise.
      if (bgAutoPlay && gateOpen) {
        if (!e.isPlaying) unawaited(e.play());
      } else {
        if (e.isPlaying) unawaited(e.pause());
      }
    }

    useEffect(() {
      final e = engine;
      if (e == null) return null;
      applyAutoplaySync(e);
      return null;
    }, [engine, bgAutoPlay, openTargetKey, enabled, gateOpen]);

    // A transport command issued WHILE the file is opening must survive the
    // open. The sync above bails on `isInitializing` (the flag is not
    // meaningful yet) and nothing re-runs it when the open settles: this scope
    // does not listen to the engine, and `open()` captured `autoplay` when it
    // dialled. So a 停止 during a slow (WebDAV/FTP) open still started the
    // track, and a 播放 left 副音 silent. Re-apply on the initializing →
    // settled EDGE only — a per-tick apply would fight the completion
    // continuation's own seek/play.
    final wasInitializing = useRef<bool>(false);
    useEffect(() {
      final e = engine;
      if (e == null) return null;
      void onEngineChanged() {
        final bool initializing = e.isInitializing;
        final bool settled = wasInitializing.value && !initializing;
        wasInitializing.value = initializing;
        if (settled) applyAutoplaySync(e);
      }

      wasInitializing.value = e.isInitializing;
      e.addListener(onEngineChanged);
      return () => e.removeListener(onEngineChanged);
    }, [engine, bgAutoPlay, openTargetKey, enabled, gateOpen]);

    // Gate stop reach: how much media state the close releases. `pause` is
    // already handled by the autoplay sync above (bgAutoPlay is false); `unload`
    // is a true stop — release the decoder/file handle while the warm native
    // instance and the run survive (a later gate open reloads and re-aligns).
    useEffect(() {
      final e = engine;
      if (e == null) return null;
      if (enabled &&
          !gateOpen &&
          gateStopBehavior == BgGateStopBehavior.unload) {
        unawaited(e.stop());
      }
      return null;
    }, [engine, enabled, gateOpen, gateStopBehavior]);

    // 副音 switched off: reach a definite STOPPED state. Without this the
    // engine (kept warm by `keepWarmPlayer`) would keep playing silently —
    // the "关闭" toggle must actually stop, not just flip a flag.
    useEffect(() {
      final e = engine;
      if (e == null) return null;
      if (!enabled) {
        unawaited(e.stop());
      }
      return null;
    }, [engine, enabled]);

    // Enabled but nothing to play (empty/out-of-range queue): stop the stale
    // audio instead of letting the previous file keep playing. The open
    // target already folds mappedFile over the natural entry.
    useEffect(() {
      final e = engine;
      if (e == null) return null;
      if (!shouldStopStaleEngine(
          enabled: enabled, hasOpenTarget: openTarget != null)) {
        return null;
      }
      unawaited(e.stop());
      return null;
    }, [engine, enabled, openTargetKey, openTarget]);

    // One-shot lock-mapping rollover: the store selected a new queue entry and
    // the intra-file target; land the seek once that file is the open target.
    final lockAppliedSeq = useRef<int>(-1);
    useEffect(() {
      final e = engine;
      if (e == null || !enabled) return null;
      if (lockSeekSeq <= 0 || lockTargetIndex < 0) return null;
      if (lockAppliedSeq.value == lockSeekSeq) return null;
      if (lockTargetIndex >= queue.length) return null;
      if (openTargetKey != backgroundMediaKey(queue[lockTargetIndex])) {
        return null;
      }
      lockAppliedSeq.value = lockSeekSeq;
      unawaited(
        e.seek(Duration(milliseconds: lockSeekTargetMs < 0
            ? 0
            : lockSeekTargetMs)),
      );
      return null;
    }, [
      engine,
      enabled,
      lockSeekSeq,
      lockSeekTargetMs,
      lockTargetIndex,
      openTargetKey,
      queue,
    ]);

    // One-shot tiled entrance: the VM link selected a queue entry and the
    // intra-file offset from its precomputed plan; land the seek once that
    // file is the open target, then consume the one-shot so later opens of
    // the same file resume the normal alignment chain.
    final tiledAppliedSeq = useRef<int>(-1);
    useEffect(() {
      final e = engine;
      if (e == null || !enabled) return null;
      if (tiledSeekSeq <= 0 || tiledTargetIndex < 0) return null;
      if (tiledAppliedSeq.value == tiledSeekSeq) return null;
      if (tiledTargetIndex >= queue.length) return null;
      if (openTargetKey != backgroundMediaKey(queue[tiledTargetIndex])) {
        return null;
      }
      tiledAppliedSeq.value = tiledSeekSeq;
      unawaited(
        e.seek(Duration(
            milliseconds:
                tiledSeekTargetMs < 0 ? 0 : tiledSeekTargetMs)),
      );
      unawaited(Future.microtask(
        () => useBackgroundPlaybackStore().consumeTiledSeek(),
      ));
      return null;
    }, [
      engine,
      enabled,
      tiledSeekSeq,
      tiledSeekTargetMs,
      tiledTargetIndex,
      openTargetKey,
      queue,
    ]);

    // One-shot proportional seek while a mapped segment drives 副音 (the
    // MappingScope bumps mappedSeekSeq). engine.file is assigned synchronously
    // in open(), so an entry seek right after the open lands correctly.
    useEffect(() {
      final e = engine;
      if (e == null || !enabled || mappedSeekSeq <= 0) return null;
      if (mappedFile == null) return null;
      final s = useBackgroundPlaybackStore().state;
      final target = Duration(milliseconds: s.mappedSeekTargetMs);
      e.seek(target);
      return null;
    }, [engine, enabled, mappedSeekSeq, mappedFile, openTargetKey]);

    // Volume policy (master × bg ratio) and rate. Inside a mapped playMedia
    // segment the alignment rate (mappedRate) overrides the natural policy;
    // otherwise rate-lock mirrors the foreground app rate.
    useEffect(() {
      final e = engine;
      if (e == null) return null;
      final s = useBackgroundPlaybackStore().state;
      final volume = BackgroundVolumePolicy.backgroundEngineVolume(
        master: masterVolume,
        muted: masterMuted,
        bgActive: BackgroundVolumePolicy.active(
          enabled: enabled,
          gateOpen: gateOpen,
          // A stopRestoreFg terminal run is silent like a closed gate; a run
          // that ran off its queue, moved out of 作用范围, or stands down for a
          // 虚拟剪播 cut is equally inactive. Keep this identical to the foreground
          // volume context, or the two engines disagree about who is ducking.
          exhausted: bgExhausted,
          queueEnded: bgQueueEnded,
          outOfScope: bgOutOfScope || bgSuspendedByFakeCut,
        ),
        bgPercent: bgVolumePercent,
        bgMuted: bgMuted,
      );
      e.setVolume(volume);
      final mappedRate = s.mappedRate;
      if (mappedRate != null) {
        e.setRate(mappedRate);
      } else if (bgRateLock) {
        final store = useBackgroundPlaybackStore();
        if ((store.state.rate - appRate).abs() > 1e-9) {
          unawaited(store.setRate(appRate));
        }
        e.setRate(appRate);
      } else {
        e.setRate(bgRate);
      }
      return null;
    }, [
      engine,
      enabled,
      gateOpen,
      masterVolume,
      masterMuted,
      bgVolumePercent,
      bgMuted,
      bgRate,
      bgRateLock,
      appRate,
      mappedFile,
      bgExhausted,
      bgQueueEnded,
      bgOutOfScope,
      bgSuspendedByFakeCut,
    ]);

    if (engine == null) return child;
    // ChangeNotifierProvider (not Provider.value): engine is a Listenable and
    // children that select it must rebuild on every snapshot notification.
    return ChangeNotifierProvider<BackgroundPlaybackEngine>.value(
      value: engine,
      child: child,
    );
  }
}
