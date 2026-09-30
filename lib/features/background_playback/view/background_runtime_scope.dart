import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/actions/background_playback_actions.dart';
import 'package:iris/features/background_playback/background_playback_gate.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/engine/background_scope_logic.dart';
import 'package:iris/features/background_playback/hooks/use_foreground_scope_key.dart';
import 'package:iris/features/background_playback/model/enum/bg_apply_scope.dart';
import 'package:iris/features/background_playback/model/enum/bg_cross_action.dart';
import 'package:iris/features/background_playback/model/enum/bg_exhausted_action.dart';
import 'package:iris/features/background_playback/model/enum/bg_quick_panel.dart';
import 'package:iris/features/background_playback/services/background_alignment.dart';
import 'package:iris/features/background_playback/services/background_lock_mapping.dart';
import 'package:iris/features/background_playback/services/current_foreground_media_key.dart';
import 'package:iris/features/background_playback/view/bg_align_dialog.dart';
import 'package:iris/features/background_playback/view/bg_continuation_dialog.dart';
import 'package:iris/features/virtual_media/interaction/controller/foreground_window_resolver.dart';
import 'package:iris/features/background_playback/services/background_sync_logic.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/bg_queue_sync_observer.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';
import 'package:provider/provider.dart';

/// Mirror diagnostics (which branch, master, jumps, latches, offset). Bound to
/// the debug-on `log.player` channel so a bad sync run is diagnosable from the
/// log without another code change.
final AreaKeyLog _mirrorLog = AreaKeyLog(LogKeys.player);

/// Runtime observer of the 副音 subsystem.
///
/// Mounted inside the foreground `Provider<MediaPlayer>` (and inside the engine
/// provider from `BackgroundPlaybackScope`), it owns the cross-layer behavior
/// that needs BOTH runtimes:
///
/// 1. **作用范围** — current-only pauses away from its anchored media; smart
///    auto-starts on a media with a saved 副音 pairing; all keeps playing.
/// 2. **进度锁定** — transport/position mirroring between the two runtimes.
/// 3. **对齐** — the first 副音 file of a run is aligned to the foreground
///    timeline; a shorter one asks ONCE, then later files chain from 00:00.
/// 4. **Resume memory** — the 副音 position is remembered per file when the
///    engine moves on, so a later run can resume it.
class BackgroundRuntimeScope extends HookWidget {
  const BackgroundRuntimeScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Localization is captured in build, never inside an effect body:
    // flutter_hooks runs effect initializers during initHook, where inherited
    // lookups (`Localizations.of`) are illegal.
    final t = getLocalizations(context);
    final bg = useBackgroundPlaybackStore();
    final enabled = bg.select(context, (s) => s.enabled);
    final applyScope = bg.select(context, (s) => s.applyScope);
    final anchorKey = bg.select(context, (s) => s.scopeAnchorKey);
    final offMediaKeys = bg.select(context, (s) => s.bgOffMediaKeys);
    final gateOpen = bg.select(context, (s) => s.gateOpen);
    // stopRestoreFg terminal state: 副音 is stopped for good and the foreground
    // plays un-ducked. Both mirrors must stand down — otherwise the transport
    // mirror reads the terminal pause as a transport disagreement and resumes
    // (and replays) the dead run.
    final bgExhausted = bg.select(context, (s) => s.bgExhausted);
    final bgExhaustedAction = bg.select(context, (s) => s.bgExhaustedAction);
    final seekLink = bg.select(context, (s) => s.seekLink);
    final lockLevel = bg.select(context, (s) => s.lockLevel);
    final stepMode = bg.select(context, (s) => s.stepMode);
    final bgStepSeq = bg.select(context, (s) => s.bgStepSeq);
    final bgSystemSeekSeq = bg.select(context, (s) => s.bgSystemSeekSeq);
    final fgSystemSeekSeq = bg.select(context, (s) => s.fgSystemSeekSeq);
    final bgRunSeq = bg.select(context, (s) => s.bgRunSeq);
    final bgUserAlignSeq = bg.select(context, (s) => s.bgUserAlignSeq);
    // The AUTHORITATIVE user-alignment offset (non-null after any alignment):
    // while set, the mirror keeps the pair on IT instead of re-deriving one from
    // samples, so a user alignment outranks the linkage level.
    final alignOffsetMs = bg.select(context, (s) => s.alignOffsetMs);
    // One-shot cross-file continuation (natural completion / empty alignment)
    // under BgExhaustedAction.nextBg.
    final bgContinuationSeq = bg.select(context, (s) => s.bgContinuationSeq);
    final bgContinuationFromAlign =
        bg.select(context, (s) => s.bgContinuationFromAlign);
    // Suppressed-warning memory (the continuation explainer can be silenced
    // forever); selected in build because a hook must not run inside an effect.
    final suppressedWarnings =
        useAppStore().select(context, (s) => s.suppressedWarnings);
    // The quick-bar 对齐 card already shows the alignment editor: never stack
    // the modal threshold prompt on top of it.
    final alignPanelOpen =
        bg.select(context, (s) => s.openQuickPanel == BgQuickPanel.align);
    // Align-edit mode owns the pair: seeks are always linked and bg follows the
    // draft offset (driven by the editor panel), so the normal lock stands down.
    final editing = bg.select(context, (s) => s.segmentEditMode);

    final engine = context.read<BackgroundPlaybackEngine>();
    // Rebuild on engine snapshots so the alignment below sees the real
    // duration once the file has loaded (throttled to ~10/s by the engine).
    useListenable(engine);

    // The 作用范围 identity: the physical foreground file, or the whole virtual
    // video while a VM session publishes an override (wholeVirtual).
    final fgKey = useForegroundScopeKey(context);
    // Captured in build (inherited lookups are forbidden inside useEffect bodies
    // by flutter_hooks); the effects only USE these values.
    final fgPlayer = context.read<MediaPlayer>();
    final fgPlaying = context.select<MediaPlayer, bool>((p) => p.isPlaying);
    // Scrub-drag ownership (single source: ScrubDragStore). While the user
    // holds a slider the foreground's pause/live seeks are GESTURE artifacts:
    // the mirror must not interpret them as user transport changes, nor let
    // the drag's ticks drag the 副音 timeline along.
    final bool isScrubbing =
        useScrubDragStore().select(context, (s) => s.isScrubbing);
    // Transport-mirror retry plumbing. A VM/scenario foreground can DROP the
    // first play() issued while it is still transitioning, and since the mirror
    // effect only re-runs on an fgPlaying change, a dropped command froze the
    // pair (bg advancing, fg counter stuck). A bounded timer re-reads the LIVE
    // state through refs (a captured snapshot would be stale) and re-issues the
    // command until the follower catches up.
    final fgPlayerRef = useRef<MediaPlayer>(fgPlayer);
    fgPlayerRef.value = fgPlayer;
    final fgPlayingRef = useRef<bool>(fgPlaying);
    fgPlayingRef.value = fgPlaying;
    final transportRetry = useRef<Timer?>(null);
    useEffect(() {
      return () => transportRetry.value?.cancel();
    }, const <Object?>[]);
    // The playback rate is app state, not a MediaPlayer snapshot field.
    final fgRate = useAppStore().select(context, (s) => s.rate);
    final fg = context.select<MediaPlayer, ({int posMs, int durMs})>(
      (p) =>
          (posMs: p.position.inMilliseconds, durMs: p.duration.inMilliseconds),
    );
    // The SINGLE physical foreground window (the VM segment, or the whole file
    // when not virtualized). The mirror clamps a 仅当前 bg-master target into
    // it so it can never land on another Virtual Media segment.
    final fgWindow = useForegroundWindow(context);

    // ── Saved 副音 pairing of the foreground file (smart scope) ──
    final playQueue = usePlayQueueStore().select(context, (s) => s.playQueue);
    final playIndex =
        usePlayQueueStore().select(context, (s) => s.currentIndex);
    final FileItem? fgFile = useMemoized(
      () {
        if (playQueue.isEmpty || playIndex < 0) return null;
        final i = playQueue.indexWhere((e) => e.index == playIndex);
        if (i < 0 || i >= playQueue.length) return null;
        return playQueue[i].file;
      },
      [playQueue, playIndex],
    );
    final String fgStorageId = fgFile?.storageId ?? '';
    final String fgPath =
        fgFile == null ? '' : canonicalDbPath(fgFile.path.join('/'));
    final savedMapping = useFuture(
      useMemoized(
        () async {
          if (applyScope != BgApplyScope.smart || fgStorageId.isEmpty) {
            return false;
          }
          try {
            return await DbModule.bgMappingRepo.hasTimelineFor(
              storageId: fgStorageId,
              path: fgPath,
            );
          } catch (_) {
            return false;
          }
        },
        [applyScope, fgStorageId, fgPath],
      ),
    );
    final bool hasSavedMapping = savedMapping.data ?? false;

    // ── 1. 作用范围: pause/resume/auto-start on a foreground media switch ──
    final startedForFg = useRef<String?>(null);
    useEffect(() {
      switch (resolveBgScopeOnFgChange(
        enabled: enabled,
        applyScope: applyScope,
        anchorKey: anchorKey,
        newFgKey: fgKey,
        offMediaKeys: offMediaKeys,
        newFgHasSavedMapping: hasSavedMapping,
        gateOpen: gateOpen,
      )) {
        case BgScopeAction.pauseBg:
          startedForFg.value = null;
          bg.pauseForScope();
        case BgScopeAction.resumeBg:
          // Returning to the anchor media must respect the video's transport:
          // a paused foreground is not force-resumed by the scope.
          bg.resumeForScope(play: fgPlaying);
        case BgScopeAction.startBg:
          if (startedForFg.value == fgKey) break;
          startedForFg.value = fgKey;
          unawaited(BackgroundPlaybackActions.startForSavedMapping(
            autoplay: fgPlaying,
          ));
        case BgScopeAction.none:
          break;
      }
      return null;
    }, [
      enabled,
      applyScope,
      anchorKey,
      fgKey,
      offMediaKeys,
      hasSavedMapping,
      gateOpen,
    ]);

    // ── 1b. 跨视频: a real LIST-ITEM switch may start a new 副音 track ──
    //
    // `bgItemSwitch` (default newBg). Only the NON-VM case is handled here: an
    // active Virtual Media session owns its own block/video transitions in the
    // VM link (which can tell a segment switch from a new virtual item).
    //
    // 作用范围 wins: a scope transition (pause/resume/start, including leaving
    // the 仅当前 anchor or a smart media without a saved pairing) must never
    // also switch tracks — only a plain `none` (e.g. 全部) advances 副音.
    final bgItemSwitch = bg.select(context, (s) => s.bgItemSwitch);
    final vmSessionActive = bg.select(context, (s) => s.vmSessionActive);
    final prevItemFgKey = useRef<String?>(null);
    useEffect(() {
      final prev = prevItemFgKey.value;
      prevItemFgKey.value = fgKey;
      if (!enabled || vmSessionActive) return null;
      // Gate closed: an explicit stop must never be undone by a track switch.
      if (!gateOpen) return null;
      if (bgItemSwitch != BgCrossAction.newBg) return null;
      if (prev == null || fgKey == null || prev == fgKey) return null;
      final scopeAction = resolveBgScopeOnFgChange(
        enabled: enabled,
        applyScope: applyScope,
        anchorKey: anchorKey,
        newFgKey: fgKey,
        offMediaKeys: offMediaKeys,
        newFgHasSavedMapping: hasSavedMapping,
        gateOpen: gateOpen,
      );
      if (scopeAction != BgScopeAction.none) return null;
      unawaited(
        useBackgroundPlaybackStore().step(
          forward: true,
          excludedKey: excludedForegroundKey(),
        ),
      );
      return null;
    }, [
      enabled,
      fgKey,
      vmSessionActive,
      bgItemSwitch,
      applyScope,
      anchorKey,
      offMediaKeys,
      hasSavedMapping,
      gateOpen,
    ]);

    // ── 1c. A refused/failed 副音 open is reported once ──
    //
    // The engine halts the previous audio and records which file failed (see
    // [BackgroundPlaybackEngine.open]): without a surface the queue stalls with
    // silence and no reason. Playback errors are ALWAYS-ON dialogs, never
    // suppressed (capability_matrix §6). Reported once per (file, error) so a
    // rebuild storm does not stack dialogs.
    final engineError = engine.errorText;
    final engineErrorFile = engine.file;
    final notifiedOpenError = useRef<String?>(null);
    useEffect(() {
      if (!enabled || engineError == null || engineErrorFile == null) {
        return null;
      }
      final key = '${backgroundMediaKey(engineErrorFile)}|$engineError';
      if (notifiedOpenError.value == key) return null;
      notifiedOpenError.value = key;
      unawaited(showMessageDialog(
        Navigator.of(context, rootNavigator: true),
        title: t.bg_open_failed_title,
        message: t.bg_open_failed_body(engineErrorFile.name),
        type: MessageDialogType.error,
      ));
      return null;
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [enabled, engineError, engineErrorFile]);

    // ── 2. 进度锁定 (第 3 轮问题 3) ──
    //
    // Transport mirror: while the link shares transport, play/pause is copied
    // from the CONTROLLED player (the panel's target) onto the other side, so
    // the pair behaves like ONE media with a natural second track.
    //
    // The align editor OWNS both 副音 position and transport: its audition
    // driver starts/stops 副音 from the playhead's [A,B] state, so the generic
    // mirror stands down entirely (see the `editing` early return) — otherwise
    // it would immediately resume the 副音 the driver just stopped outside A/B.
    //
    // The player the shared controls drive is the MASTER; the other side is
    // pulled to its state — never the reverse — so the pair follows whichever
    // player the panel is on and the mirror cannot oscillate.
    //
    // TWO guards below are what keep the mirror from overreaching, and both
    // existed only implicitly before:
    // - [scopeApplied]: 副音 is not applied to the media playing now, so the
    //   two runtimes are NOT a pair. The scope observer (effect 1) has already
    //   paused 副音; mirroring "fg plays / bg paused" back into a play is what
    //   kept a 仅当前 run 激活 after the foreground moved on.
    // - [bgAuthoritative]: a secondary runtime with nothing loaded cannot be a
    //   master. It has no transport to copy, so its silence must not become a
    //   pause command for the video.
    final scopeApplied = resolveApplyToCurrent(
      enabled: enabled,
      applyScope: applyScope,
      anchorKey: anchorKey,
      offMediaKeys: offMediaKeys,
      fgKey: fgKey,
    );
    final controlTarget = bg.select(context, (s) => s.controlTarget);
    // An E-节 mapping timeline owns 副音 transport with its own mirror (see
    // MappingScope), so the generic transport mirror must stand down while it
    // is active — otherwise it would fight the silence hold / segment play.
    final mappedOwnsBg = bg.select(
      context,
      (s) => s.mappedFile != null || s.mappedSilenceOn,
    );
    useEffect(() {
      // A closed gate stops the pair: the fg must never mirror its play state
      // onto a stopped 副音 (that would silently undo an explicit gate stop).
      if (!enabled || !gateOpen || !shouldSyncTransport(seekLink)) return null;
      // Out of 作用范围: the run is not for this media. Effect 1 has paused
      // 副音 and the user gate is still open, so without this the mirror read
      // that pause as a transport disagreement and resumed it (仅当前 + fg A→B
      // left the run 激活), or — with 副音 as master — paused the video.
      if (!scopeApplied) {
        transportRetry.value?.cancel();
        transportRetry.value = null;
        return null;
      }
      // The align editor owns the pair's transport (its audition driver joins
      // 副音 only inside [A,B]): never mirror over it.
      if (editing) return null;
      // Terminal stopRestoreFg: the run is dead. Never mirror a play onto it —
      // the fg keeps playing, 副音 stays silent until a new alignment clears
      // the exhaustion (see the alignment effect's clearBgExhausted).
      if (bgExhausted) {
        transportRetry.value?.cancel();
        transportRetry.value = null;
        return null;
      }
      // While a scrub drag owns the foreground, only the DRAG's pause travels:
      // the reverse direction never runs, so a bg-master session cannot drive
      // the foreground back to playing under the user's finger (which used to
      // fight every drag and made the thumb snap back). See [BgScrubPolicy].
      final BgScrubPolicy scrubPolicy = resolveBgScrubPolicy(
        enabled: enabled,
        link: seekLink,
        level: lockLevel,
      );
      if (isScrubbing && scrubPolicy != BgScrubPolicy.none) {
        if (!fgPlaying && engine.isPlaying) {
          _mirrorLog.d('[bg-scrub] transport scrub-pause master='
              '${mirrorSourceIsBackground(bgEnabled: enabled, target: controlTarget) ? 'bg' : 'fg'} '
              'policy=${scrubPolicy.name}');
          bg.setPlaying(false);
          unawaited(engine.pause());
        }
        transportRetry.value?.cancel();
        transportRetry.value = null;
        return null;
      }
      // While a 副音 file is opening, its playing flag is not yet meaningful —
      // mirroring it would blip the other side.
      if (engine.isInitializing || mappedOwnsBg) return null;
      final bgPlaying = engine.isPlaying;
      if (!shouldMirrorTransport(fgPlaying: fgPlaying, bgPlaying: bgPlaying)) {
        // The pair agrees: any in-flight catch-up retry is spent.
        transportRetry.value?.cancel();
        transportRetry.value = null;
        return null;
      }
      final bgIsMaster = mirrorSourceIsBackground(
        bgEnabled: enabled,
        target: controlTarget,
      );
      // Bounded catch-up for a mirror-issued PLAY the follower ignored (a VM
      // foreground drops it while transitioning). Without this the effect never
      // re-runs — the snapshot only changes when the command lands — and the
      // follower stays frozen for the rest of the session.
      void armFgPlayRetry() {
        if (transportRetry.value != null) return;
        int attempts = 0;
        transportRetry.value =
            Timer.periodic(const Duration(milliseconds: 200), (timer) {
          attempts++;
          final s = useBackgroundPlaybackStore().state;
          final bool stillMaster = mirrorSourceIsBackground(
            bgEnabled: s.enabled,
            target: s.controlTarget,
          );
          if (!stillMaster ||
              !engine.isPlaying ||
              fgPlayingRef.value ||
              attempts >= 10) {
            timer.cancel();
            transportRetry.value = null;
            return;
          }
          unawaited(useAppStore().updateAutoPlay(true));
          unawaited(fgPlayerRef.value.play());
        });
      }

      _mirrorLog.d(
        'transport master=${bgIsMaster ? 'bg' : 'fg'} '
        'fgPlaying=$fgPlaying bgPlaying=$bgPlaying',
      );
      if (bgIsMaster) {
        // Nothing loaded (empty/unreachable queue, an unloaded gate stop) or a
        // refused/failed open: the secondary runtime is DEAD, not authoritative.
        // It has no transport of its own, so its silence must not become a
        // pause command for the video — the "点开副音后播放被暂停" report, which
        // only ever fired when the candidate could not be opened.
        final bool bgAuthoritative =
            engine.file != null && engine.errorText == null;
        if (!bgAuthoritative) {
          _mirrorLog.d('bg dead runtime is not a master (fg keeps playing)');
          transportRetry.value?.cancel();
          transportRetry.value = null;
          return null;
        }
        // 副音 controls the panel → the foreground follows it.
        //
        // The slave's autoplay flag must follow too: both hooks re-play
        // whenever their own flag is on and the player is not playing
        // (use_media_kit_player "scenario resume"), which would immediately
        // undo a mirrored PAUSE. Set the flag BEFORE the transport command.
        unawaited(useAppStore().updateAutoPlay(bgPlaying));
        if (bgPlaying) {
          unawaited(fgPlayer.play());
          armFgPlayRetry();
        } else {
          transportRetry.value?.cancel();
          transportRetry.value = null;
          unawaited(fgPlayer.pause());
        }
      } else {
        // Foreground is the master → 副音 follows, with the same flag rule
        // (bgAutoPlay drives BackgroundPlaybackScope's autoplay effect).
        bg.setPlaying(fgPlaying);
        if (fgPlaying) {
          unawaited(engine.play());
        } else {
          unawaited(engine.pause());
        }
      }
      return null;
    }, [
      enabled,
      gateOpen,
      bgExhausted,
      seekLink,
      lockLevel,
      editing,
      controlTarget,
      mappedOwnsBg,
      scopeApplied,
      fgPlaying,
      engine.isPlaying,
      engine.isInitializing,
      isScrubbing,
    ]);

    // ── 2b. Position mapping: master → other ──
    //
    // The 副音 queue is one continuous timeline (files concatenated by
    // duration). A seek maps through a FIXED offset, so a target overflowing
    // the queue rolls into the neighbouring file at the corresponding local
    // position (a virtual continuous track).
    //
    // Direction follows the control target: while the panel drives the
    // FOREGROUND, fg → bg (feeding a 副音 position back into a Virtual Media
    // foreground is what once made it jump to an earlier segment, "闪回第一个
    // 块"). While the panel drives 副音, bg → fg instead, so operating the
    // Sub Audio seek visibly moves the video too.
    final queue = bg.select(context, (s) => s.queue);
    final currentIndex = bg.select(context, (s) => s.currentIndex);

    final durationsFuture = useFuture(
      useMemoized(
        () async {
          if (queue.isEmpty || !BackgroundPlaybackGate.enabled) {
            return const <int>[];
          }
          final keys = <String>{
            for (final f in queue) canonicalKey(f.storageId, f.path.join('/')),
          };
          try {
            final nodes = await DbModule.mediaNodeRepo.nodesByMediaKeys(keys);
            final byKey = <String, int>{};
            for (final n in nodes) {
              final f = n.maybeMap(file: (v) => v, orElse: () => null);
              final d = f?.durationMs;
              if (f == null || d == null || d <= 0) continue;
              byKey[canonicalKey(f.storageId, f.path.join('/'))] = d;
            }
            return <int>[
              for (final f in queue)
                byKey[canonicalKey(f.storageId, f.path.join('/'))] ?? 0,
            ];
          } catch (_) {
            return <int>[for (var i = 0; i < queue.length; i++) 0];
          }
        },
        [queue],
      ),
    );

    // The current file's live duration (engine snapshot) may be fresher than
    // the DB row, so it always overrides the resolved one.
    final timeline = useMemoized(
      () {
        final base = durationsFuture.data ?? const <int>[];
        final d = <int>[
          for (var i = 0; i < queue.length; i++) i < base.length ? base[i] : 0,
        ];
        final live = engine.duration.inMilliseconds;
        if (currentIndex >= 0 && currentIndex < d.length && live > 0) {
          d[currentIndex] = live;
        }
        return BgQueueTimeline(d);
      },
      [durationsFuture.data, queue, currentIndex, engine.duration],
    );

    final lastFgMs = useRef<int?>(null);
    final lastFgAt = useRef(DateTime.now());
    final lastBgMs = useRef<int?>(null);
    final lastBgAt = useRef(DateTime.now());
    final suppressUntil = useRef(DateTime.fromMillisecondsSinceEpoch(0));
    final lockOffsetMs = useRef(0);
    final lockOffsetReady = useRef(false);
    // Step tracking: a discrete step bumps [bgStepSeq]; the latch stays set
    // until the resulting bg jump is actually handled, so an intermediate
    // guard run (file still opening) cannot lose the "this was a step" fact.
    final stepSeqRef = useRef(bgStepSeq);
    final pendingStepRef = useRef(false);
    // One cross-file fg roll at a time (the roll + its transport re-assert is
    // async; a second roll mid-flight would fight the first).
    final fgRollingRef = useRef(false);
    // System-seek latch: tiled entrances, alignment landings and replays bump
    // [bgSystemSeekSeq]. A fresh bump ARMS the latch; it is consumed only once
    // the native seek has actually LANDED (a bg jump is observed) or a short
    // deadline expires. Consuming it on an intermediate sample — before the
    // native seek reports the new position — misread the landing as a user
    // jump and mirrored it back onto the foreground: the "enabling 副音 skips
    // the episode" report. While armed the mirror touches neither side.
    final systemSeekRef = useRef(bgSystemSeekSeq);
    final systemSeekArmed = useRef(false);
    final systemSeekDeadline = useRef<DateTime?>(null);
    // The fg-side twin: a foreground seek THIS mirror issues (bg-master seek or
    // roll) is not a user fg gesture. Its landing must be swallowed, otherwise
    // it is mapped back onto the bg queue and the two timelines ping-pong.
    // The deadline is longer than the bg one: a cross-file roll goes through
    // `seekVirtualTo` (async paging) plus the 350ms settle delay.
    final fgSystemSeekRef = useRef(fgSystemSeekSeq);
    final fgSystemSeekArmed = useRef(false);
    final fgSystemSeekDeadline = useRef<DateTime?>(null);
    // Fresh bg files are never mirrored: the first sample of a new open
    // re-anchors instead (covers alignment chains on later files, tiled
    // opens and mapping entries that carry no step latch of their own).
    final prevBgOpenKey = useRef<String?>(null);
    // Explicit restart-for-current resets the whole alignment.
    final prevRunSeq = useRef(bgRunSeq);

    useEffect(() {
      // Gate closed: the pair is not running, so drop the lock baseline. A gate
      // open re-runs this effect and re-anchors from the fresh 副音 position
      // (the alignment plan is re-applied, never the remembered one). The same
      // stand-down applies to a terminal stopRestoreFg run: it is stopped, so
      // no mirror may move either side (and no window may clamp fg seeks).
      //
      // Out of 作用范围 counts as a stand-down too: the two timelines belong to
      // different media, so a background offset derived for the previous file
      // must never be pushed onto this one.
      if (bgMirrorStandsDown(
        enabled: enabled && scopeApplied,
        gateOpen: gateOpen,
        exhausted: bgExhausted,
      )) {
        lastFgMs.value = null;
        lastBgMs.value = null;
        lockOffsetReady.value = false;
        pendingStepRef.value = false;
        return null;
      }
      if (bgStepSeq != stepSeqRef.value) {
        stepSeqRef.value = bgStepSeq;
        pendingStepRef.value = true;
      }
      // No position mirroring at all (independent / play-pause-only): a pending
      // step can never be consumed here, so drop it — otherwise it would
      // suppress the first genuine bg seek after the link is turned back on.
      if (!shouldSyncPosition(link: seekLink, level: lockLevel)) {
        pendingStepRef.value = false;
        lastFgMs.value = fg.posMs;
        lastBgMs.value = engine.position.inMilliseconds;
        lastFgAt.value = DateTime.now();
        lastBgAt.value = DateTime.now();
        lockOffsetReady.value = false;
        return null;
      }
      if (editing || engine.isInitializing || mappedOwnsBg) {
        // The lock does not own bg position right now (edit mode drives it from
        // the draft, or an E-节 timeline does). Keep the sample fresh, never
        // mirror — EXCEPT while a step is pending: refreshing the baseline and
        // the offset here would absorb the new file's position reset, losing
        // both the swapOnly suppression and the followLink roll target.
        if (!pendingStepRef.value) {
          lastFgMs.value = fg.posMs;
          lastBgMs.value = engine.position.inMilliseconds;
          lastFgAt.value = DateTime.now();
          lastBgAt.value = DateTime.now();
          lockOffsetReady.value = false;
        }
        return null;
      }
      final now = DateTime.now();
      final fgMs = fg.posMs;
      final bgMs = engine.position.inMilliseconds;
      final suppressed = now.isBefore(suppressUntil.value);

      final fgJump = isPositionJump(
        prevMs: lastFgMs.value,
        posMs: fgMs,
        elapsedMs: now.difference(lastFgAt.value).inMilliseconds,
        rate: fgRate,
      );
      // A bg-side jump (our own mapping seek, or the alignment seek that lands
      // a fresh file) must not re-anchor the offset on an intermediate
      // position. It is detected but NEVER mirrored back to the foreground.
      final bgJump = isPositionJump(
        prevMs: lastBgMs.value,
        posMs: bgMs,
        elapsedMs: now.difference(lastBgAt.value).inMilliseconds,
        rate: engine.rate,
      );

      final prevFg = lastFgMs.value;
      lastFgMs.value = fgMs;
      lastFgAt.value = now;
      lastBgMs.value = bgMs;
      lastBgAt.value = now;

      // Explicit restart-for-current ("use bg for THIS fg"): drop the old
      // alignment entirely — old queue progress is gone, re-align from here.
      if (bgRunSeq != prevRunSeq.value) {
        prevRunSeq.value = bgRunSeq;
        lastFgMs.value = null;
        lastBgMs.value = null;
        lockOffsetReady.value = false;
        pendingStepRef.value = false;
        useBackgroundPlaybackStore().publishSeekWindow();
        return null;
      }
      // A fresh bg file is never mirrored on its transition sample: the next
      // settled samples re-anchor from it.
      final bgOpenKey =
          engine.file == null ? null : backgroundMediaKey(engine.file!);
      if (bgOpenKey != prevBgOpenKey.value) {
        prevBgOpenKey.value = bgOpenKey;
        lockOffsetReady.value = false;
        pendingStepRef.value = false;
        return null;
      }

      // A suppressed window is our OWN seek settling: do not re-anchor on the
      // intermediate bg position. The baseline above already absorbed any jump
      // this sample carried, so a pending step is consumed here too.
      if (suppressed) {
        pendingStepRef.value = false;
        return null;
      }
      if (timeline.isEmpty) return null;

      final int bgVirtual = timeline.virtualPositionOf(currentIndex, bgMs);
      // User alignment is AUTHORITATIVE: while [alignOffsetMs] is set the pair's
      // offset IS it, and the mirror must never re-derive one from a sample
      // (which would silently undo the user's alignment on the next drift). The
      // derived [lockOffsetMs] only owns the offset until the first alignment.
      final int effectiveOffset = alignOffsetMs ?? lockOffsetMs.value;
      final bool offsetReady = alignOffsetMs != null || lockOffsetReady.value;
      void anchor() {
        if (alignOffsetMs != null) return;
        lockOffsetMs.value = fgMs - bgVirtual;
        lockOffsetReady.value = true;
      }

      // ── System-seek latches (a seek WE issued to the other side) ──
      //
      // ARM on issue, consume only once the landing is observed (or the
      // deadline expires). Consuming early let the later landing be mirrored on
      // the foreground; NOT consuming the fg side at all let the bg-master
      // mirror's own fg seek be read back as a user fg seek, rolling the bg
      // queue and ping-ponging the two timelines (see the ref docs above).
      if (bgSystemSeekSeq != systemSeekRef.value) {
        systemSeekRef.value = bgSystemSeekSeq;
        systemSeekArmed.value = true;
        systemSeekDeadline.value = now.add(const Duration(milliseconds: 900));
        pendingStepRef.value = false;
      }
      if (fgSystemSeekSeq != fgSystemSeekRef.value) {
        fgSystemSeekRef.value = fgSystemSeekSeq;
        fgSystemSeekArmed.value = true;
        fgSystemSeekDeadline.value =
            now.add(const Duration(milliseconds: 1200));
      }
      final DateTime? bgDeadline = systemSeekDeadline.value;
      final DateTime? fgDeadline = fgSystemSeekDeadline.value;
      final bool bgExpired = bgDeadline != null && now.isAfter(bgDeadline);
      final bool fgExpired = fgDeadline != null && now.isAfter(fgDeadline);
      final bool bgLanding = systemSeekArmed.value &&
          shouldConsumeSystemSeekLatch(
            armed: true,
            bgJump: bgJump,
            deadlineExpired: bgExpired,
          );
      final bool fgLanding = fgSystemSeekArmed.value &&
          shouldConsumeSystemSeekLatch(
            armed: true,
            bgJump: fgJump,
            deadlineExpired: fgExpired,
          );
      // While a system seek is still in flight, nothing mirrors and nothing
      // re-anchors: anchoring on an intermediate position would poison the
      // offset the landing is judged against.
      if (systemSeekArmed.value && !bgLanding) return null;
      if (fgSystemSeekArmed.value && !fgLanding) return null;
      if (bgLanding) {
        systemSeekArmed.value = false;
        systemSeekDeadline.value = null;
        pendingStepRef.value = false;
      }
      if (fgLanding) {
        fgSystemSeekArmed.value = false;
        fgSystemSeekDeadline.value = null;
      }

      final bgIsMaster = mirrorSourceIsBackground(
        bgEnabled: enabled,
        target: controlTarget,
      );
      final mirrorAction = resolveBgMirrorAction(
        enabled: enabled,
        positionSync: true,
        // A scrub drag owns the foreground sample: its live seek ticks are not
        // user position jumps and must never pull the 副音 timeline. The
        // baseline refs above stay fresh, so the release edge re-runs this
        // effect and the 高同步 drift correction aligns the pair exactly once.
        standDown: isScrubbing,
        bgIsMaster: bgIsMaster,
        fgJump: fgJump,
        bgJump: bgJump,
        fgSystemSeekLanding: fgLanding,
        bgSystemSeekLanding: bgLanding,
        pendingStep: pendingStepRef.value,
        mirrorStep: shouldMirrorStep(
          stepMode: stepMode,
          link: seekLink,
          level: lockLevel,
        ),
        lockOffsetReady: offsetReady,
        // 高同步 continuous lockstep: the mapped fg position for the current
        // bg sample is `bgVirtual + offset`, so the gap to drive is exactly how
        // far the follower is from it. Sign-agnostic; the master decides who
        // moves.
        driftMs: (fgMs - bgVirtual - effectiveOffset).abs(),
      );
      // The step latch is spent the moment its bg landing is observed, however
      // this sample resolves it.
      if (bgJump) pendingStepRef.value = false;
      _mirrorLog.d(
        'mirror $mirrorAction master=${bgIsMaster ? 'bg' : 'fg'} '
        'fgJump=$fgJump bgJump=$bgJump fgLand=$fgLanding bgLand=$bgLanding '
        'ready=${lockOffsetReady.value} offset=$effectiveOffset '
        'drift=${(fgMs - bgVirtual - effectiveOffset).abs()} '
        'scrub=$isScrubbing fg=$fgMs bg=$bgMs',
      );

      switch (mirrorAction) {
        case BgMirrorAction.none:
          return null;
        case BgMirrorAction.anchor:
        case BgMirrorAction.stayBg:
        case BgMirrorAction.stayFg:
          anchor();
          return null;
        case BgMirrorAction.bgDrivesFg:
        case BgMirrorAction.fgDrivesBg:
          break;
      }

      // ── 副音 is the master: a bg seek drives the foreground ──
      if (mirrorAction == BgMirrorAction.bgDrivesFg) {
        // A target at/past the foreground window must ROLL (全部) or clamp
        // (仅当前), never park the player exactly at its end: that raises a
        // genuine completion and auto-advances the queue.
        final int fgTarget = bgVirtual + effectiveOffset;
        suppressUntil.value = now.add(const Duration(milliseconds: 400));
        // 仅当前: 副音 exists only inside the current PHYSICAL foreground
        // window, so the target is clamped into IT — clamping against the
        // merged virtual total still allowed a cross-segment VM jump. Our own
        // seek is noted so its landing is swallowed, not mapped back to bg.
        if (applyScope == BgApplyScope.currentOnly) {
          final bool virtual = fgWindow.virtualActive;
          final int windowStart = virtual ? fgWindow.virtualOffsetMs : 0;
          final int windowDur =
              virtual ? fgWindow.durationMs : fgPlayer.duration.inMilliseconds;
          // An unknown window length cannot be clamped INTO: a raw seek would
          // park the player past its end and raise a genuine completion, i.e.
          // skip the episode. Leave the foreground alone until it reports one.
          if (windowDur <= 0) {
            _mirrorLog.d('bg-master scoped hold target=$fgTarget (no window)');
            return null;
          }
          bg.noteFgSystemSeek();
          unawaited(fgPlayer.seek(Duration(
            milliseconds: clampFgTargetToWindow(
              fgTarget: fgTarget,
              windowStartMs: windowStart,
              windowDurMs: windowDur,
            ),
          )));
          return null;
        }
        switch (resolveBgMasterFgAction(
          fgTarget: fgTarget,
          fgDurMs: fgPlayer.duration.inMilliseconds,
          // A cross-file roll is a real queue advance, so it must be EARNED by
          // a real 副音 move (a user seek/step landing). The 高同步 continuous
          // drift correction also lands here, and a drifted pair mapping
          // outside the current file must not move the video — that was the
          // "开启副音就跳到下一集" report.
          allowRoll: bgJump,
        )) {
          case BgMasterFgAction.hold:
            _mirrorLog.d('bg-master hold target=$fgTarget drift=in-window');
          case BgMasterFgAction.seek:
            bg.noteFgSystemSeek();
            unawaited(fgPlayer.seek(Duration(milliseconds: fgTarget)));
          case BgMasterFgAction.roll:
            if (!fgRollingRef.value) {
              // Cross-file roll: the foreground switches FILE, and neither its open
              // path (which opens with the autoplay flag) nor the 作用范围 observer
              // (which may pause 副音 on a media change) may touch the pair's
              // transport — a seek must leave play/pause exactly as it was. Capture
              // the MASTER's state and re-assert it once the roll has settled.
              final bool wasPlaying = engine.isPlaying;
              fgRollingRef.value = true;
              bg.noteFgSystemSeek();
              unawaited(() async {
                try {
                  // Flags FIRST: the new file's open path reads them, so it opens in
                  // the right transport state (setting them afterwards would let the
                  // file open playing and then get paused — an audible blip).
                  unawaited(useAppStore().updateAutoPlay(wasPlaying));
                  bg.setPlaying(wasPlaying);
                  await PlaybackProviderRegistry.seekVirtualTo(
                    fgTarget,
                    keepPlaying: wasPlaying,
                  );
                  // Let the new file open and the scope observer settle first.
                  await Future<void>.delayed(const Duration(milliseconds: 350));
                  if (!context.mounted) return;
                  // Re-assert the PLAYERS only: the scope observer may have paused a
                  // side when the foreground item changed.
                  if (wasPlaying) {
                    await fgPlayer.play();
                    await engine.play();
                  } else {
                    await fgPlayer.pause();
                    await engine.pause();
                  }
                } finally {
                  fgRollingRef.value = false;
                }
              }());
            }
        }
        return null;
      }

      // ── Foreground is the master: a user fg seek drives 副音 ──
      if (prevFg == null || !offsetReady) {
        // First sample is already a jump — anchor from it and follow next time.
        anchor();
        return null;
      }

      final target = resolveLockTarget(
        fgMs: fgMs,
        offsetMs: effectiveOffset,
        timeline: timeline,
        // The 副音 queue is a virtual continuous track: a target past its end
        // loops back to an earlier file at the corresponding position ("如果
        // bg seek 不到 → 循环回更前面的媒体衔接后对应位置").
        wrap: true,
      );
      suppressUntil.value = now.add(const Duration(milliseconds: 400));
      if (bgLockTargetRolls(target, currentIndex)) {
        unawaited(
          bg.requestLockTarget(
            index: target.fileIndex,
            targetMs: target.localMs,
          ),
        );
      } else if ((target.localMs - bgMs).abs() >
          BackgroundSyncLogic.kPositionToleranceMs) {
        // Compare the MAPPED local target against the 副音's own local position
        // — the previous `shouldMirrorPosition(fgMs, bgMs)` mixed the fg
        // absolute axis with the bg local one, so a non-zero offset or a
        // multi-file queue looked "drifted" on every sample and a genuine 高同步
        // drift could be skipped.
        //
        // Our own bg seek: its landing must not be read back as a bg gesture.
        bg.noteSystemSeek();
        unawaited(engine.seek(Duration(milliseconds: target.localMs)));
      }
      return null;
      // ignore: prefer_const_constructors
    }, [
      enabled,
      gateOpen,
      bgExhausted,
      editing,
      seekLink,
      lockLevel,
      stepMode,
      bgStepSeq,
      bgSystemSeekSeq,
      fgSystemSeekSeq,
      bgRunSeq,
      applyScope,
      controlTarget,
      scopeApplied,
      engine.isInitializing,
      mappedOwnsBg,
      fg.posMs,
      fgRate,
      fgWindow.durationMs,
      fgWindow.virtualOffsetMs,
      alignOffsetMs,
      engine.position.inMilliseconds,
      timeline,
      currentIndex,
      isScrubbing,
    ]);

    // ── 2c. 仅当前 + 高同步: bg stays within the fg window [A,B] ──
    //
    // The window (file-local ms) is published for the shared-controls adapter,
    // which clamps every bg seek to it. A = the bg position mapped to fg 00:00
    // (before it 副音 does not exist); B = the one mapped to fg 100%. A bg side
    // already mapped past B (e.g. chained there while fg is paused) is paused.
    useEffect(() {
      final store = useBackgroundPlaybackStore();
      // A closed gate drops the lock window too: with no published window the
      // sliders/dial cannot clamp fg seeks into a dead bg axis, and the
      // boundary stopBelow can never pause the video (完全独立 at runtime).
      // Out of 作用范围 is the same situation: the [A,B] window belongs to the
      // anchored media, so publishing it for another one — and letting the
      // strict-lockstep boundary pause THAT video — would be wrong.
      if (bgMirrorStandsDown(
        enabled: enabled && scopeApplied,
        gateOpen: gateOpen,
        exhausted: bgExhausted,
      )) {
        store.publishSeekWindow();
        return null;
      }
      // FREEZE while a scrub drag is in flight: the drag's own seeks would move
      // the offset the window is derived from, and a mid-drag window change made
      // the slider's clamp snap the thumb back. The boundary stopBoth is
      // deferred too, so it can never clear `autoPlay` mid-gesture and leave the
      // release unable to resume. Both re-evaluate on the release edge below.
      if (isScrubbing) {
        return null;
      }
      final highSync = shouldSyncPosition(link: seekLink, level: lockLevel);
      final fgDur = fg.durMs;
      final int effectiveOffset = alignOffsetMs ?? lockOffsetMs.value;
      final bool offsetReady = alignOffsetMs != null || lockOffsetReady.value;
      if (applyScope != BgApplyScope.currentOnly ||
          !highSync ||
          editing ||
          mappedOwnsBg ||
          fgDur <= 0 ||
          !offsetReady ||
          timeline.isEmpty) {
        store.publishSeekWindow();
        return null;
      }
      store.publishSeekWindow(
        floorLocalMs: bgSeekFloorLocalMs(
          timeline: timeline,
          currentIndex: currentIndex,
          offsetMs: effectiveOffset,
        ),
        ceilingLocalMs: bgSeekCeilingLocalMs(
          timeline: timeline,
          currentIndex: currentIndex,
          offsetMs: effectiveOffset,
          fgDurMs: fgDur,
        ),
      );
      final bgVirtual = timeline.virtualPositionOf(
        currentIndex,
        engine.position.inMilliseconds,
      );
      if (engine.isPlaying &&
          shouldPauseBgPastWindow(
            bgVirtualMs: bgVirtual,
            fgDurMs: fgDur,
            offsetMs: effectiveOffset,
          )) {
        store.setPlaying(false);
        unawaited(engine.pause());
        // 仅当前 = strict lockstep: the MASTER stops too. On the bg-master side
        // the engine pause already cascades through the transport mirror; on the
        // fg-master side the foreground must be stopped explicitly (and its
        // autoplay flag cleared, or the scenario-resume effect re-plays it).
        final bool bgIsMaster = mirrorSourceIsBackground(
          bgEnabled: enabled,
          target: controlTarget,
        );
        if (!bgIsMaster) {
          unawaited(useAppStore().updateAutoPlay(false));
          unawaited(fgPlayer.pause());
        }
        _mirrorLog.d(
          'boundary currentOnly stopBoth master=${bgIsMaster ? 'bg' : 'fg'} '
          'bg=$bgVirtual fgDur=$fgDur offset=$effectiveOffset',
        );
      }
      return null;
    }, [
      enabled,
      gateOpen,
      bgExhausted,
      applyScope,
      scopeApplied,
      editing,
      seekLink,
      lockLevel,
      mappedOwnsBg,
      fg.posMs,
      fg.durMs,
      engine.position.inMilliseconds,
      engine.isPlaying,
      timeline,
      currentIndex,
      isScrubbing,
      alignOffsetMs,
    ]);

    // NOTE: while the align editor is open, the bg position is driven by the
    // editor itself (SegmentAlignEditPanel), which has the PHYSICAL foreground
    // window — the lock above stands down via its `editing` guard.

    // ── 3. Alignment of each newly loaded 副音 file ──
    //
    // Alignment ALWAYS targets the current REAL single file: the physical
    // foreground window (a VM merge undone) decides the anchor and the seek
    // position — never the merged virtual total.
    //
    // A run's FIRST file is aligned from the persisted default; every USER
    // switch (queue step/jump) re-applies the mode so the new file lands where
    // the setting says (`fromFgHead` → `bgPos = fgPos`). A natural completion is
    // owned by the scope ([BgExhaustedAction.nextBg]) and chains from the new
    // file's 00:00 without re-aligning.
    final firstAlignDoneForRun = useRef(false);
    // Re-entrancy gate, set SYNCHRONOUSLY before the prompt is shown and cleared
    // only when it closes: a re-run while the dialog is up must be a no-op.
    final askingForRun = useRef(false);
    // Own run-seq latch (the mirror effect owns prevRunSeq and runs first, so
    // sharing it would hide the restart from this effect).
    final prevAlignRunSeq = useRef(bgRunSeq);
    // Open/switch latches: an open is fresh when the engine's file key changes;
    // a user switch is a userInitiated step/jump (`bgUserAlignSeq`).
    final prevAlignOpenKey = useRef<String?>(null);
    final prevUserAlignSeq = useRef(bgUserAlignSeq);
    // Set by an explicit restart-for-current (`bgRunSeq`): re-apply even when
    // the engine's file key did not change (the same file is re-anchored).
    final forceReapply = useRef(false);
    final alignPercent = bg.select(context, (s) => s.alignPercent);
    final alignMode = bg.select(context, (s) => s.alignMode);
    final alignAutoPauseRemainSec =
        bg.select(context, (s) => s.alignAutoPauseRemainSec);
    final openKey =
        engine.file == null ? null : backgroundMediaKey(engine.file!);
    final bool alignReady =
        engine.duration > Duration.zero && fgWindow.durationMs > 0;
    // WholeVirtual tiled entrance owns its open (see the scope's tiled
    // one-shot): the precomputed offset — not the run chain — decides.
    final tiledSeekSeq = bg.select(context, (s) => s.tiledSeekSeq);
    final tiledTargetIndex = bg.select(context, (s) => s.tiledTargetIndex);

    useEffect(() {
      // Gate closed: forget the per-run alignment chain so the FIRST open after
      // the user re-opens the gate re-applies the plan (pause mode re-aligns
      // even though the file stayed loaded; unload mode aligns on the reload).
      if (!enabled || !gateOpen) {
        firstAlignDoneForRun.value = false;
        askingForRun.value = false;
        forceReapply.value = false;
        prevAlignOpenKey.value = null;
        return null;
      }
      // Explicit restart-for-current: rerun the whole alignment chain. The file
      // may be unchanged, so force the re-apply below.
      if (bgRunSeq != prevAlignRunSeq.value) {
        prevAlignRunSeq.value = bgRunSeq;
        firstAlignDoneForRun.value = false;
        forceReapply.value = true;
      }
      // The align editor owns the pair (and already pauses playback on open);
      // never interrupt it with an alignment prompt.
      if (editing || askingForRun.value) return null;
      if (tiledSeekSeq > 0 &&
          tiledTargetIndex >= 0 &&
          tiledTargetIndex < queue.length) {
        final tiledFile = queue[tiledTargetIndex];
        if (openKey != null && openKey == backgroundMediaKey(tiledFile)) {
          // This open is a tiled entrance: consume the run's first alignment
          // so no seek competes with the precomputed offset the scope lands.
          firstAlignDoneForRun.value = true;
          prevAlignOpenKey.value = openKey;
          return null;
        }
      }
      final file = engine.file;
      if (file == null || !alignReady) return null;
      final bool userSwitch = bgUserAlignSeq != prevUserAlignSeq.value;
      prevUserAlignSeq.value = bgUserAlignSeq;
      final bool freshOpen = openKey != prevAlignOpenKey.value;
      prevAlignOpenKey.value = openKey;
      // Re-align on: an explicit restart, any user switch, or the first open of
      // a run. A natural completion open leaves the mirror to chain it.
      final bool shouldApply = forceReapply.value ||
          userSwitch ||
          (freshOpen && !firstAlignDoneForRun.value);
      if (!shouldApply) return null;
      forceReapply.value = false;
      firstAlignDoneForRun.value = true;
      final store = useBackgroundPlaybackStore();
      final int fgPos = fgWindow.positionMs;
      final int bgDur = engine.duration.inMilliseconds;
      // Publish the AUTHORITATIVE offset of this alignment BEFORE any seek: the
      // mirror then keeps the pair on the user's anchor instead of re-deriving
      // one from the landing (which would drop a non-zero offset).
      final int offset = resolveAlignmentOffsetMs(
        mode: alignMode,
        currentFgMs: fgPos,
        bgDurMs: bgDur,
        percent: alignPercent,
      );
      store.setAlignOffset(offset);
      final int target = bgAlignTargetMs(
        mode: alignMode,
        fgPosMs: fgPos,
        bgDurMs: bgDur,
        percent: alignPercent,
      );
      // Under nextBg the alignment must never park the 副音 at the current
      // file's tail when the mapped position lies BEYOND it: the current fg
      // moment would then have no bg. Hand the cross-file continuation to the
      // runtime observer, which locates the looping timeline at this position
      // (the「对齐后当前 fg 位置没有 bg」case; aligns-into-file keeps the plain
      // seek below).
      final bool needsContinuation =
          bgExhaustedAction == BgExhaustedAction.nextBg &&
          bgDur > 0 &&
          fgPos - offset >= bgDur;
      if (needsContinuation) {
        store.noteSystemSeek();
        store.requestBgContinuation(fromAlign: true);
        return null;
      }
      if (target > 0) {
        // A system landing: latch it so the mirror swallows the jump instead of
        // driving the foreground with it.
        store.noteSystemSeek();
        unawaited(engine.seek(Duration(milliseconds: target)));
      }
      store.clearBgExhausted();
      return null;
    }, [
      enabled,
      gateOpen,
      editing,
      openKey,
      alignReady,
      alignPercent,
      alignMode,
      bgUserAlignSeq,
      tiledSeekSeq,
      tiledTargetIndex,
      bgRunSeq,
      bgExhaustedAction,
    ]);

    // ── 3b. Remaining-副音 threshold (stopRestoreFg only) ──
    //
    // When the aligned 副音 has less than `alignAutoPauseRemainSec` left, raise
    // the shared alignment popup — it pauses both runtimes and restores their
    // transport on close. Under [BgExhaustedAction.nextBg] the continuation is
    // automatic (the setting already decided), so the prompt is suppressed and
    // playback is never interrupted; it is kept for stopRestoreFg, where the
    // user must be able to learn that 副音 will stop. See
    // [shouldRaiseAlignThreshold].
    //
    // The remainder is window-aware: under 仅当前 + 高同步 the published
    // ceiling caps it (anything past the ceiling is unplayable), and a bg
    // already parked past the ceiling is skipped — the §2c window owns it.
    final autoPauseLatched = useRef(false);
    final autoPauseOpenKey = useRef<String?>(null);
    final bgCeilingLocalMs =
        bg.select(context, (s) => s.bgSeekCeilingLocalMs);
    useEffect(() {
      final store = useBackgroundPlaybackStore();
      if (!enabled || !gateOpen) {
        autoPauseLatched.value = false;
        return null;
      }
      if (autoPauseOpenKey.value != openKey) {
        autoPauseOpenKey.value = openKey;
        autoPauseLatched.value = false;
      }
      if (editing || askingForRun.value || alignPanelOpen) return null;
      final int dur = engine.duration.inMilliseconds;
      final int pos = engine.position.inMilliseconds;
      if (dur <= 0 || engine.isInitializing) return null;
      if (bgCeilingLocalMs != null && pos >= bgCeilingLocalMs) return null;
      if (!shouldRaiseAlignThreshold(
        enabled: enabled,
        gateOpen: gateOpen,
        exhaustedAction: bgExhaustedAction,
        bgDurMs: dur,
        bgPosMs: pos,
        thresholdSec: alignAutoPauseRemainSec,
        ceilingLocalMs: bgCeilingLocalMs,
      )) {
        autoPauseLatched.value = false;
        return null;
      }
      if (autoPauseLatched.value) return null;
      autoPauseLatched.value = true;
      askingForRun.value = true;
      unawaited(
        showBgAlignModal(context, engine: engine, fgPlayer: fgPlayer)
            .whenComplete(() {
          askingForRun.value = false;
        }),
      );
      store.setPlaying(false);
      return null;
      // ignore: prefer_const_constructors
    }, [
      enabled,
      gateOpen,
      alignAutoPauseRemainSec,
      editing,
      alignPanelOpen,
      bgCeilingLocalMs,
      bgExhaustedAction,
      openKey,
      engine.position.inMilliseconds,
      engine.duration,
      engine.isInitializing,
    ]);

    // ── 3c. Cross-file CONTINUATION (BgExhaustedAction.nextBg) ──
    //
    // A 副音 file ENDED, or an alignment left the current fg position with no bg
    // content, while the SINGLE foreground video keeps playing. The 副音 queue is
    // one LOOPING timeline, so playback continues at the entry carrying the SAME
    // virtual position (`resolveBgContinuation`), preserving the pair's offset —
    // never restart the next file at its own 00:00 (which silently re-anchors and
    // is what made a non-zero alignment "lose" its bg).
    //
    // A NATURAL completion applies the continuation SILENTLY: the setting
    // (nextBg) already decided, so the pair is never paused and no dialog
    // interrupts. The explainer is kept only for the alignment case (the user
    // just re-aligned onto a position with no bg) and is DEFERRED out of this
    // synchronous effect body — flutter_hooks runs effect bodies during
    // initHook, where opening a dialog (`Localizations.of`) asserts. The
    // continuation runs in a `finally` so a dismissed/failed dialog can never
    // strand the queue on the completed file.
    final prevContinuationSeq = useRef(bgContinuationSeq);
    useEffect(() {
      if (bgContinuationSeq == prevContinuationSeq.value) return null;
      prevContinuationSeq.value = bgContinuationSeq;
      if (!enabled || !gateOpen || bgExhausted) return null;
      if (bgExhaustedAction != BgExhaustedAction.nextBg) return null;
      if (editing || mappedOwnsBg) return null;
      final store = useBackgroundPlaybackStore();
      if (timeline.isEmpty || timeline.totalMs <= 0) {
        // No known duration to locate in: stop rather than guess.
        store.setPlaying(false);
        unawaited(engine.pause());
        return null;
      }
      final int fgMs = fgWindow.positionMs;
      final int offset = alignOffsetMs ?? lockOffsetMs.value;
      final target = resolveBgContinuation(
        fgMs: fgMs,
        offsetMs: offset,
        timeline: timeline,
      );
      if (target == null) return null;
      final bool fromAlign = bgContinuationFromAlign;

      void apply() {
        // A system landing: the open + local seek, with the landing swallowed so
        // the mirror never drives the foreground with it.
        store.setPlaying(true);
        unawaited(store.requestLockTarget(
          index: target.index,
          targetMs: target.localMs,
        ));
      }

      // Natural completion: continue seamlessly — no pause, no dialog.
      if (!fromAlign) {
        apply();
        return null;
      }
      if (bgContinuationSuppressed(suppressedWarnings)) {
        apply();
        return null;
      }
      final bool fgWasPlaying = fgPlayer.isPlaying;
      unawaited(engine.pause());
      unawaited(fgPlayer.pause());
      store.setPlaying(false);
      final entries = <BgContinuationEntry>[
        for (var i = 0; i < timeline.length; i++)
          BgContinuationEntry(
            name: i < queue.length ? queue[i].name : '',
            durationMs: timeline.durationsMs[i],
            localMs: i == target.index ? target.localMs : null,
          ),
      ];
      // Defer past the synchronous effect body (see the section note).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(() async {
          try {
            if (context.mounted) {
              await showBgContinuationDialog(
                context,
                entries: entries,
                fromAlign: fromAlign,
              );
            }
          } finally {
            apply();
            if (fgWasPlaying) await fgPlayer.play();
          }
        }());
      });
      return null;
      // ignore: prefer_const_constructors
    }, [bgContinuationSeq]);

    // A Virtual Media block carrying a SAVED mapping outranks the VM scope rule
    // ("任何实际视频保存的规则映射大于这个规则"): the VM link bumps this when
    // such a block is LEFT, so the following blocks restart the alignment chain
    // and re-align from 00:00 instead of chaining onto the mapped block.
    final vmAlignResetSeq = bg.select(context, (s) => s.vmAlignResetSeq);
    useEffect(() {
      if (vmAlignResetSeq <= 0) return null;
      // Restart the chain AND forget the open latch: the next block may carry
      // the same bg file, which must still re-align (from 00:00 per the VM
      // rule) instead of being mistaken for a chained continuation.
      firstAlignDoneForRun.value = false;
      prevAlignOpenKey.value = null;
      return null;
    }, [vmAlignResetSeq]);

    return Stack(
      // passthrough keeps [child]'s constraints byte-for-byte what it received
      // before, so hosting an observer can never resize the player.
      fit: StackFit.passthrough,
      children: [
        child,
        const Positioned(
          left: 0,
          top: 0,
          width: 0,
          height: 0,
          child: BgQueueSyncObserver(),
        ),
      ],
    );
  }
}
