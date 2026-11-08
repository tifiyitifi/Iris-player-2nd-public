import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/engine/background_scope_logic.dart';
import 'package:iris/features/background_playback/model/domain/background_mapping.dart';
import 'package:iris/features/background_playback/resolver/active_mapping_resolver.dart';
import 'package:iris/features/background_playback/resolver/mapping_timeline_math.dart';
import 'package:iris/features/background_playback/services/background_file_builder.dart';
import 'package:iris/features/background_playback/store/use_background_mapping_staging_store.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/fake_cut/core/fake_cut_background_scope.dart';
import 'package:iris/features/fake_cut/store/use_fake_cut_store.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';
import 'package:provider/provider.dart';

/// Foreground-position → 副音-mapping driver (E 节, the ONLY cross layer).
///
/// Mounted between the foreground `Provider<MediaPlayer>` and [Player]. It
/// watches the foreground file/position/duration/playing and the active
/// mapping timeline, and issues 副音 commands purely through the background
/// store (the scope effects above own the engine). Natural playback is never
/// touched here unless a mapped/silence segment is active.
class MappingScope extends HookWidget {
  const MappingScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bg = useBackgroundPlaybackStore();
    final bgEnabled = bg.select(context, (s) => s.enabled);
    // The user gate is the single "may play" permission: the E 节 saved-timeline
    // driver must not enter a mapped segment (or resume one) while it is shut —
    // that is what made a cold launch auto-play the resumed media's mapping.
    final gateOpen = bg.select(context, (s) => s.gateOpen);
    final mappingEnabled = bg.select(context, (s) => s.mappingEnabled);
    final exhausted = bg.select(context, (s) => s.bgExhausted);
    final applyScope = bg.select(context, (s) => s.applyScope);
    final anchorKey = bg.select(context, (s) => s.scopeAnchorKey);
    final offMediaKeys = bg.select(context, (s) => s.bgOffMediaKeys);
    final ignoreNoBg = bg.select(context, (s) => s.ignoreNoBg);
    final followFgSwitch = bg.select(context, (s) => s.bgFollowsFgSwitch);
    final mappedActive = bg.select(context, (s) => s.mappedFile != null);
    final silenceActive = bg.select(context, (s) => s.mappedSilenceOn);
    final exitLatch = bg.select(context, (s) => s.mappedExitAdvanced);
    // The align editor owns bg while open (it drives the position from the
    // draft offset) — the saved-timeline driver must not fight it.
    final editing = bg.select(context, (s) => s.segmentEditMode);
    final appRate = useAppStore().select(context, (s) => s.rate);
    // A version stamp of the A-B editor's in-memory overlay so the timeline
    // effect reloads when one is staged/cleared (the store holds plain maps and
    // is not otherwise observed here). Only the map identity matters: any
    // stage/discard produces a new map.
    final apbOverlayVersion = useBackgroundMappingStagingStore()
        .select(context, (s) => identityHashCode(s.apbOverlay));

    final playQueue = usePlayQueueStore().select(context, (s) => s.playQueue);
    final playIndex = usePlayQueueStore().select(context, (s) => s.currentIndex);
    final FileItem? fgFile = useMemoized(
      () {
        if (playQueue.isEmpty || playIndex < 0) return null;
        final i = playQueue.indexWhere((e) => e.index == playIndex);
        if (i < 0 || i >= playQueue.length) return null;
        return playQueue[i].file;
      },
      [playQueue, playIndex],
    );
    final String? fgKey = useMemoized(
      () {
        final f = fgFile;
        if (f == null) return null;
        return canonicalProgressKey(f.storageId, f.path, uri: f.uri);
      },
      [fgFile],
    );
    final String fgStorageId = fgFile?.storageId ?? '';
    final String fgCanonicalPath =
        fgFile == null ? '' : canonicalDbPath(fgFile.path.join('/'));

    // 简播 suspends the pair for THIS media; the E 節 driver must stand down
    // exactly like the scope observer does (it used to re-enter mapped segments
    // and play over the cut).
    final bool fakeCutActive = fakeCutBlocksBackground(
      fgKey,
      useFakeCutStore().select(context, (FakeCutStoreState s) => s.playingKey),
    );
    // The queue-end hand-back: the run walked off the end of its list, so the
    // driver must not re-enter a mapped segment (which would set `bgAutoPlay`
    // true and make 副音 sound behind an "inactive" pair).
    final bool queueEnded = bg.select(context, (s) => s.bgQueueEnded);
    // The scope verdict for the media playing now: 副音 is applied to it only
    // inside the run's 作用范围 and never for a user opt-out / a cut.
    final bool scopeApplied = resolveApplyToCurrent(
      enabled: bgEnabled,
      applyScope: applyScope,
      anchorKey: anchorKey,
      offMediaKeys: offMediaKeys,
      fgKey: fgKey,
      fakeCutActive: fakeCutActive,
    );
    // The single gate every branch below reads. The mapping layer is a SECOND
    // owner of the 副音 runtime: an out-of-scope / exhausted pair must never let
    // it open files, hold silence or mirror transport.
    final bool mayDrive = mappingMayDrive(
      enabled: bgEnabled,
      gateOpen: gateOpen,
      mappingEnabled: mappingEnabled,
      scopeApplied: scopeApplied,
      exhausted: exhausted,
      queueEnded: queueEnded,
    );

    final fg = context.select<MediaPlayer, ({int posMs, int durMs, bool playing})>(
      (p) => (
        posMs: p.position.inMilliseconds,
        durMs: p.duration.inMilliseconds,
        playing: p.isPlaying,
      ),
    );

    // Loaded timeline per foreground file (auto-reload on toggle).
    final timeline = useState<BackgroundMappingTimeline?>(null);
    final timelineKey = useState<String?>(null);

    // Region machine state (persisted across builds).
    final prevRegion = useRef<({String kind, String? key})?>(
      const (kind: 'gap', key: null),
    );
    final lastFgKey = useRef<String?>(null);
    final lastPosMs = useRef<int>(-1);
    final lastWall = useRef<DateTime>(DateTime.fromMillisecondsSinceEpoch(0));
    final notifiedMissingKey = useRef<String?>(null);
    // In-flight latch: `act()` has real awaits, and the effect re-runs on every
    // fg tick. Without this, two overlapping runs both observed the OLD
    // prevRegion and both took the new-segment transition (a double
    // enterMappedSegment / double switch on a segment boundary).
    final acting = useRef<bool>(false);

    // Timeline (re)load — keyed on the fg file and the mapping switches.
    useEffect(() {
      final want = mayDrive && fgKey != null;
      if (!want) {
        if (timeline.value != null) {
          timeline.value = null;
          timelineKey.value = null;
        }
        return null;
      }
      var stale = false;
      unawaited(() async {
        try {
          final t = await DbModule.bgMappingRepo.getTimelineForFg(
            storageId: fgStorageId,
            path: fgCanonicalPath,
          );
          if (stale) return;
          // An A-B editor SESSION overlay wins over the committed DB row: a
          // commit-less exit must still make the alignment live in memory for
          // this playback (the overlay dies with the session / a file switch).
          final overlay = useBackgroundMappingStagingStore()
              .apbOverlayFor(BackgroundMappingStagingStore.stagingKey(
            fgStorageId,
            fgCanonicalPath,
          ));
          timeline.value = overlay?.timeline ?? t;
          timelineKey.value = fgKey;
        } catch (_) {
          // A DB failure must not surface as an unhandled async error from the
          // build phase; degrade to "no timeline" and keep natural playback.
          if (stale) return;
          timeline.value = null;
          timelineKey.value = null;
        }
      }());
      return () {
        stale = true;
      };
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [
      mayDrive,
      fgKey,
      fgStorageId,
      fgCanonicalPath,
      apbOverlayVersion,
    ]);

    // Foreground file identity changed while mapping was driving.
    useEffect(() {
      if (editing) return null;
      if (!bgEnabled || fgKey == null) return null;
      if (lastFgKey.value != null && lastFgKey.value != fgKey) {
        // The A-B editor overlay is scoped to ONE playback of ONE foreground:
        // a file switch ends it (see also the stop effect below). Only one fg
        // is ever edited at a time, so dropping them all is precise.
        useBackgroundMappingStagingStore().discardAllApbOverlays();
        // Follow OFF: 副音 never follows a foreground switch — bail out of any
        // active mapped/silence state. When the new media is OUT of 作用范围 the
        // scope already owns the transition: drop the override IN PLACE (never
        // step — advancing the queue here contradicted `bgCrossStepAllowed`).
        if (!followFgSwitch) {
          unawaited(_leaveAllMapped(bg, advance: mayDrive));
        }
      }
      lastFgKey.value = fgKey;
      return null;
    }, [
      bgEnabled,
      fgKey,
      followFgSwitch,
      mappedActive,
      silenceActive,
      editing,
      mayDrive,
    ]);

    // Playback stop / foreground unload: the editor overlay is "this playback
    // only", so the moment the foreground is gone (queue cleared, current item
    // dropped) every APB overlay is released. A gate/feature teardown clears it
    // too — the runtime it described no longer exists.
    useEffect(() {
      if (fgKey == null || !bgEnabled) {
        useBackgroundMappingStagingStore().discardAllApbOverlays();
      }
      return null;
    }, [fgKey, bgEnabled]);

    // Core per-tick mapping state machine.
    useEffect(() {
      final store = useBackgroundPlaybackStore();
      if (editing) return null;
      // Gate closed / out of 作用范围 / exhausted: 副音 is stopped and must stay
      // silent — never enter a mapped segment or resume a silence hold. Forget
      // the region so a return to scope re-evaluates from scratch.
      //
      // The override is dropped IN PLACE: `exitMappedNatural` would `step` the
      // natural queue and `resumeNatural` would set `bgAutoPlay` true, both
      // undoing the pause the scope just issued.
      if (!mayDrive || fgKey == null) {
        if (mappedActive || silenceActive) {
          unawaited(store.dropMappedOverride());
        }
        prevRegion.value = (kind: 'gap', key: null);
        lastPosMs.value = -1;
        return null;
      }
      final t = timeline.value;
      if (t == null || t.storageId.isEmpty || fgKey != timelineKey.value) {
        return null;
      }
      if (fg.durMs <= 0) return null;
      final segs = t.sortedSegments;
      final seg = ActiveMappingResolver.effectiveAt(segs, fg.posMs);
      final effective = (seg == null || (ignoreNoBg && !seg.isPlayMedia))
          ? null
          : seg;
      final kind = effective == null
          ? 'gap'
          : effective.isPlayMedia
              ? 'play'
              : 'silence';
      final key = effective == null
          ? null
          : ActiveMappingResolver.segmentKey(effective);

      final prev = prevRegion.value!;
      final regionChanged = prev.kind != kind || prev.key != key;

      // Seek/continuous-drift detection for proportional repositioning inside
      // a playMedia segment.
      final now = DateTime.now();
      final elapsedMs = now.difference(lastWall.value).inMilliseconds;
      final expected = elapsedMs * appRate;
      final drift = (fg.posMs - lastPosMs.value - expected).abs();
      final isSeek = lastPosMs.value >= 0 &&
          (fg.posMs < lastPosMs.value || drift > 2500);
      lastPosMs.value = fg.posMs;
      lastWall.value = now;

      Future<void> act() async {
        if (!regionChanged && !(kind == 'play' && isSeek)) {
          // Mirror fg play/pause while a playMedia segment is active.
          if (kind == 'play' && mappedActive) {
            final s = store.state;
            if (s.bgAutoPlay != fg.playing) store.setPlaying(fg.playing);
          }
          return;
        }

        if (kind == 'gap') {
          if (prev.kind == 'play' && !exitLatch) {
            await store.exitMappedNatural();
          } else if (prev.kind == 'silence') {
            await store.resumeNatural();
          } else if (exitLatch) {
            await store.clearMappedExitLatch();
          }
          prevRegion.value = (kind: 'gap', key: null);
          return;
        }

        if (kind == 'silence') {
          if (prev.kind == 'play' && !exitLatch) {
            // Silence pauses in place — never advance the natural queue here
            // (the step belongs to the play → gap path only).
            await store.exitMappedInPlace();
          }
          if (!silenceActive) await store.silenceHold();
          prevRegion.value = (kind: 'silence', key: key);
          return;
        }

        // playMedia region.
        final seg2 = effective!;
        if (exitLatch) {
          // Previous mapped file ended early — stay natural until the fg
          // leaves this segment.
          if (prev.kind != 'play') await store.clearMappedExitLatch();
          prevRegion.value = (kind: 'gap', key: null);
          return;
        }
        final isNewSegment = prev.kind != 'play' || prev.key != key;
        if (isNewSegment) {
          final file = await _resolveMappedFile(seg2);
          if (file == null) {
            final keyNow = '${seg2.bgStorageId}:${seg2.bgPath}';
            if (notifiedMissingKey.value != keyNow && context.mounted) {
              notifiedMissingKey.value = keyNow;
              final t2 = getLocalizations(context);
              final navigator = Navigator.of(context, rootNavigator: true);
              unawaited(showMessageDialog(
                navigator,
                title: t2.bg_mapping_missing_title,
                message: t2.bg_mapping_missing_body(keyNow),
                type: MessageDialogType.info,
              ));
            }
            // Missing mapped file = treat this segment as a gap (never crash,
            // never loop).
            prevRegion.value = (kind: 'gap', key: null);
            return;
          }
          final target = MappingTimelineMath.bgTargetMsFor(seg2, fg.posMs);
          final rate = MappingTimelineMath.segmentRate(seg2, appRate);
          await store.enterMappedSegment(
            file,
            targetMs: target,
            rate: rate,
            fgPercent: seg2.fgPercent,
            bgPercent: seg2.bgPercent,
          );
        } else if (isSeek && mappedActive) {
          final target = MappingTimelineMath.bgTargetMsFor(seg2, fg.posMs);
          await store.requestMappedSeek(target);
        }
        // Mirror fg play/pause while active.
        final s = store.state;
        if (s.mappedFile != null && s.bgAutoPlay != fg.playing) {
          store.setPlaying(fg.playing);
        }
        prevRegion.value = (kind: 'play', key: key);
      }

      // A transition is already in flight — let it settle; the next tick
      // resumes from the updated prevRegion.
      if (acting.value) return null;
      acting.value = true;
      unawaited(act().whenComplete(() => acting.value = false));
      // The effect intentionally runs on every fg tick; only transitions take
      // effect (refs guard re-entry).
      // ignore: prefer_const_constructors
      return null;
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [
      mayDrive,
      ignoreNoBg,
      fgKey,
      fg.posMs,
      fg.durMs,
      fg.playing,
      appRate,
      timeline.value,
      mappedActive,
      silenceActive,
      exitLatch,
      editing,
    ]);

    return child;
  }

  /// Leaves the E 節 override when the foreground moves on.
  ///
  /// [advance] false means the pair is not (or no longer) applied to the new
  /// media — the scope owns that transition and the queue must NOT move, so the
  /// override is dropped in place. A real follow-off switch inside scope keeps
  /// the §13 "natural next" semantics ([BackgroundPlaybackStore
  /// .exitMappedNatural]).
  static Future<void> _leaveAllMapped(
    BackgroundPlaybackStore store, {
    bool advance = true,
  }) async {
    if (!advance) {
      await store.dropMappedOverride();
      return;
    }
    final s = store.state;
    if (s.mappedFile != null) {
      await store.exitMappedNatural();
    } else if (s.mappedSilenceOn) {
      await store.resumeNatural();
    }
  }

  /// Resolves a stored (storageId, canonical path) reference to a playable
  /// FileItem via the scanned media library; null when the file vanished.
  static Future<FileItem?> _resolveMappedFile(MappingSegment seg) async {
    final storageId = seg.bgStorageId;
    final path = seg.bgPath;
    if (storageId == null || path == null || path.isEmpty) return null;
    final nodes = await DbModule.mediaNodeRepo.nodesByMediaKeys({
      canonicalKey(storageId, path),
    });
    for (final node in nodes) {
      final f = node.maybeMap(file: (v) => v, orElse: () => null);
      if (f == null) continue;
      return backgroundFileItemFromMediaFile(f);
    }
    return null;
  }
}
