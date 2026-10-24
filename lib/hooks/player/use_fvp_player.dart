import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:fvp/fvp.dart';
import 'package:iris/features/background_playback/hooks/use_background_volume_context.dart';
import 'package:iris/features/background_playback/services/background_volume_policy.dart';
import 'package:iris/features/background_playback/services/segment_edit_guard.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/ab_loop_engine.dart';
import 'package:iris/globals.dart' as globals;
import 'package:iris/features/virtual_media/interaction/controller/virtual_seek_handler.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/interaction/state/vm_drag_gate.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/meta_settings/engine/step_tail_finish_mode.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/hooks/player/advance_play_queue_on_completed.dart';
import 'package:iris/hooks/player/live_progress_attribution.dart';
import 'package:iris/hooks/player/media_info_writeback.dart';
import 'package:iris/hooks/player/seek_clamp.dart';
import 'package:iris/hooks/player/seek_tuning.dart';
import 'package:iris/hooks/player/use_playback_progress_claim.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/progress.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/features/scenario_playback/playback/playback_progress.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/actions/media_revision_actions.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/media_library/store/use_playback_progress_store.dart';
import 'package:iris/app_shutdown.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_history_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/utils/check_data_source_type.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/features/webdav_discovery/services/webdav_playback_uri.dart';
import 'package:iris/features/webdav_discovery/view/webdav_playback_error_dialog.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/utils/seek_tail_guard.dart';
import 'package:iris/widgets/dialogs/show_copyable_error_dialog.dart';
import 'package:media_stream/media_stream.dart';
import 'package:saf_util/saf_util.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyPlayer);
// CLOSE_DEBUG_LOG: playback diagnostics for the "jumps to end" investigation.
final diagLog = AreaKeyLog(LogKeys.player);

/// Whether a seek with attribution [src] is a STEP seek (← / → / double-tap)
/// and must use the fvp backend's per-seek KEYFRAME ("fast") seek.
///
/// `video_player`'s `seekTo` is an EXACT seek: fvp (mdk) decodes from the
/// previous keyframe up to the target, so one tap froze the picture for the
/// whole seek. mpv's own ←/→ is a RELATIVE KEYFRAME seek and is what the
/// media_kit backend now issues natively; fvp has no relative seek, so the
/// closest parity is the fvp controller extension's `fastSeekTo`
/// (mdk `SeekFlag.keyFrame`). It is applied to step seeks ONLY — scrub / dial /
/// resume / lock-retry need the exact landing. (The global `fastSeek`
/// registration option would degrade those too, hence per-seek here.)
///
/// Pure so the src → mode decision is unit-testable.
bool fvpStepUsesKeyframeSeek(String src) => src == 'step';

/// Whether a seek from [src] must arm the position-intent lock.
///
/// A step is the one seek whose landing is DELIBERATELY not the requested
/// target: the keyframe seek lands on the previous keyframe, which on a long GOP
/// is seconds away, while the lock requires the player to be observed within
/// ±2s of the target. Arming it there made the 1s tick re-issue an EXACT seek
/// after 5s (a visible jump to where the user already was) and blocked the
/// progress write for up to 10s. media_kit's step already skips the lock; this
/// keeps fvp at parity. Every other caller (scrub / dial / resume / lock-retry)
/// needs the lock so the sanitizer cannot reject its landing.
///
/// Pure so the src → lock decision is unit-testable.
bool fvpShouldArmPositionLock(String src) => !fvpStepUsesKeyframeSeek(src);

/// The position a user-seek burst persists for a seek attributed to [src].
///
/// The PERSISTED position must never run ahead of what has actually played.
/// A step lands on the PREVIOUS KEYFRAME (deliberately behind the requested
/// target), so writing the target — as this hook used to — made a kill inside
/// the burst resume to a frame that was never on screen. media_kit already
/// persists the engine's OBSERVED position for a step; fvp must match it.
/// Every other caller persists the requested target (the authoritative intent
/// of an exact seek).
///
/// Pure so the src → persisted-position decision is unit-testable.
int fvpPersistedSeekMs({
  required String src,
  required int targetMs,
  required int observedMs,
}) =>
    fvpStepUsesKeyframeSeek(src) ? observedMs : targetMs;

/// Floor for the fvp step tail window (see [fvpStepNeedsExactSeek]).
///
/// 2 s: long enough to cover an ordinary short step and the final GOP of a
/// typical encode, short enough that the exact (slower) seek only applies where
/// a key-frame landing could actually be wrong.
const int kFvpStepTailExactWindowMs = 2000;

/// Whether a STEP seek must take the EXACT (`seekTo`) path because its target
/// sits in the media tail.
///
/// mdk keeps mpv's forward-only contract for an IN-RANGE target — the first
/// frame is "a key frame whose timestamp >= startPosition" (`generated_bindings`
/// `prepare` doc) — but a target PAST the media end is served with "the last key
/// frame of media" (`seek` doc). The last key frame of a file can sit a whole GOP
/// before its end, so that substitution is the tail rollback: the picture jumps
/// back to the final GOP and every further press lands there again, because the
/// next press re-anchors on the rolled-back position.
///
/// A step whose target falls inside the tail window therefore goes through the
/// exact seek: it decodes to the requested point and reports the frame it really
/// shows. The window is `max(one step, kFvpStepTailExactWindowMs)` — one step
/// covers "this press would reach the end", the floor covers short steps next to
/// a long final GOP.
///
/// Pure so the src → landing-mode decision stays unit-testable.
bool fvpStepNeedsExactSeek({
  required int targetMs,
  required int durationMs,
  required int deltaMs,
}) {
  if (durationMs <= 0) return false;
  final int step = deltaMs < 0 ? -deltaMs : deltaMs;
  final int window =
      step > kFvpStepTailExactWindowMs ? step : kFvpStepTailExactWindowMs;
  return targetMs >= durationMs - window;
}

FvpPlayer useFvpPlayer(BuildContext context) {
  final appStore = useAppStore();
  final autoPlay = appStore.select(context, (state) => state.autoPlay);
  final rate = appStore.select(context, (state) => state.rate);
  final volume = appStore.select(context, (state) => state.volume);
  final isMuted = appStore.select(context, (state) => state.isMuted);
  // 副音 volume policy (see background_volume_policy.dart): off = master.
  // The fg ratio resolves per foreground media (sub_media §5.5).
  final bgVolume = useBackgroundVolumeContext(context);
  final bgActive = bgVolume.active;
  final fgVolumePercent = bgVolume.ratio.fgPercent;
  final fgMuted = bgVolume.fgMuted;
  final useScenario = appStore.select(context,
      (s) => !s.useLegacyStoragePersistence && s.useScenarioDrivenPlayback);
  final scenarioRepeat =
      usePlaybackScenarioStore().select(context, (s) => s.activeScenarioRepeat);
  final repeat = useScenario
      ? scenarioRepeat
      : appStore.select(context, (state) => state.repeat);
  final playQueue =
      usePlayQueueStore().select(context, (state) => state.playQueue);
  final currentIndex =
      usePlayQueueStore().select(context, (state) => state.currentIndex);
  final bool alwaysPlayFromBeginning =
      appStore.select(context, (state) => state.alwaysPlayFromBeginning);
  // Tail-step policy (metadata AUX `playback.stepTailFinish`): what a FORWARD
  // step press does once its target reaches the media end — finish the item
  // (advance) while playing, hold the press while paused. Resolved through the
  // SAME gate-aware resolver the settings UI uses, so a gate-OFF run degrades
  // to `strict` instead of executing a `window` value left over from the meta
  // era. Selecting the resolved value (not the raw field) also rebuilds this
  // hook when the gate flips.
  final stepTailFinishMode = appStore.select(
    context,
    (state) => resolveStepTailFinishMode(
      state,
      metadataEnabled: state.useMetadataSettings && MetaSettingsModule.ready,
    ),
  );

  final history = useHistoryStore().select(context, (state) => state.history);

  final looping =
      useMemoized(() => repeat == Repeat.one ? true : false, [repeat]);

  final int currentPlayIndex = useMemoized(
      () => playQueue.indexWhere((element) => element.index == currentIndex),
      [playQueue, currentIndex]);

  final FileItem? file = useMemoized(
      () => playQueue.isEmpty || currentPlayIndex < 0
          ? null
          : playQueue[currentPlayIndex].file,
      [playQueue, currentPlayIndex]);
  // Latest media bound to the hook, readable from timers created for an
  // EARLIER media (mirror of the media_kit hook; see
  // shouldAttributeLiveProgress).
  final latestMediaUri = useRef<String?>(null);
  latestMediaUri.value = file?.uri;

  // Multi-instance progress ownership: claim this file before the open effect
  // reads its resume position (see MediaProgressClaim).
  usePlaybackProgressClaim(file);

  final externalSubtitle = useState<int?>(null);

  final List<Subtitle> externalSubtitles =
      useMemoized(() => file?.subtitles ?? [], [file?.subtitles]);

  final isInitializing = useState(false);

  /// Live-progress DB throttle: last DB write time and position (events reset
  /// the 10s window; the per-second timer writes the media column at most every
  /// 10s so crash-resume is at most ~10s stale).
  final lastProgressWrite = useRef<DateTime?>(null);
  final lastWrittenPosMs = useRef<int?>(null);

  /// Position sanitizer: last accepted (monotonic, in-range) position for the
  /// current file, and a flag raised by a user seek that resets the guard.
  final lastSanePosMs = useRef<int?>(null);
  final userSeekPending = useRef<bool>(false);

  /// Feed generation captured by [init] at open time. A duration arrival that
  /// happens after the controller has moved on to a NEWER feed belongs to a
  /// superseded open (double-open race) and must not clear the switch freeze.
  final openVmFeedGen = useRef<int?>(null);

  /// Per-open resume gate: after an open the player reports pre-seek head
  /// samples (~533ms) until the duration-arrival resume decision settles.
  /// Persist + History writes are skipped while unsettled so a next/prev
  /// tap inside the window cannot clobber the real stored progress.
  final positionLock = useRef(PlaybackPositionLock());

  /// Media whose `initialize()` has COMPLETED — the only media whose controller
  /// samples are trustworthy (see shouldAttributeLiveProgress).
  final openedMediaUri = useRef<String?>(null);

  /// mpv-parity tail state for the current media (see [MpvSeekTailState]) and
  /// the EOF window it arms.
  final stepTail = useRef(MpvSeekTailState());
  final tailCollapseTimer = useRef<Timer?>(null);

  /// One item-finished dispatch at a time: the engine's completion flag and the
  /// tail collapse are two doors to the SAME advance (`playloop.c:1240-1243`)
  /// and must never advance the queue twice.
  final finishedDispatchInFlight = useRef<bool>(false);

  /// Lock-independent step accumulation (mirror of the media_kit hook; see
  /// [StepIntent]): the position lock unlocks on its ±2s landing tolerance,
  /// so chaining a relative step onto it (or onto the raw position) makes
  /// repeated presses recompute the same target.
  final stepIntent = useRef(StepIntent());

  /// The step target the OSD should report (ms on the EXPOSED axis: the virtual
  /// total under a VM session, the file's own timeline otherwise), or null when
  /// no burst is live. Mirror of the media_kit hook's `stepOsdTargetMs`: without
  /// it `player.stepIntentTargetMs` was null on the fvp backend, so the keyboard
  /// OSD fell back to a per-press snapshot and appeared frozen while ←/→ was held.
  final stepOsdTargetMs = useRef<int?>(null);

  /// Step-burst idle window (mirror of the media_kit burst timer): a press
  /// inside [kStepBurstWindow] keeps the burst — and the accumulation — alive;
  /// once it lapses the recorded target is stale (playback ran past it) and is
  /// dropped so the next press anchors on the live position instead of jumping
  /// backwards. fvp has no seek chain, so this timer IS the burst detector.
  final stepBurstTimer = useRef<Timer?>(null);

  /// The media the external-subtitle index was last armed for. The duration
  /// effect that selects track 0 runs on every duration change (including a
  /// mid-play revision), so without this a revised duration reset a
  /// user-chosen external track back to the first one.
  final externalSubtitleFileKey = useRef<String?>(null);

  /// Records a step target and arms the idle window that drops it (see
  /// [stepBurstTimer]).
  void noteStepIntent(int targetMs) {
    stepIntent.value.note(targetMs);
    stepBurstTimer.value?.cancel();
    stepBurstTimer.value = Timer(kStepBurstWindow, () {
      stepBurstTimer.value = null;
      stepIntent.value.reset();
    });
  }

  MediaStream mediaStream = useMemoized(() => MediaStream());
  final streamUrl = useMemoized(() => mediaStream.url);

  final controller = useState(VideoPlayerController.networkUrl(Uri.parse('')));

  final isPlaying = useListenableSelector(
      controller.value, () => controller.value.value.isPlaying);
  final position = useListenableSelector(
      controller.value, () => controller.value.value.position);
  final duration = useListenableSelector(
      controller.value, () => controller.value.value.duration);
  final buffered = useListenableSelector(
      controller.value, () => controller.value.value.buffered);
  final width = useListenableSelector(
      controller.value, () => controller.value.value.size.width);
  final height = useListenableSelector(
      controller.value, () => controller.value.value.size.height);

  useEffect(() {
    if (file?.type != ContentType.video) {
      usePlayerUiStore().updateAspectRatio(0);
      usePlayerUiStore().updateVideoSize(0, 0);
      return;
    }

    if (width != 0 && height != 0) {
      usePlayerUiStore().updateAspectRatio(width / height);
      usePlayerUiStore().updateVideoSize(width, height);
    } else {
      usePlayerUiStore().updateAspectRatio(0);
      usePlayerUiStore().updateVideoSize(0, 0);
    }
    return;
  }, [file?.type, width, height]);

  Future<void> init(FileItem? file) async {
    isInitializing.value = true;
    // Until this open completes, the controller still describes the previous
    // media: no sample may be attributed to this file yet. A RE-open of the
    // SAME media keeps the flag (see the media_kit hook).
    if (file == null || openedMediaUri.value != file.uri) {
      openedMediaUri.value = null;
    }
    // CLOSE_DEBUG_LOG: vm double-open / back-to-0% investigation. Capture the
    // controller's feed generation at open time so a duration arrival from a
    // superseded open (double-open race) can be recognized and dropped.
    openVmFeedGen.value = VirtualMediaController.instance.feedGeneration;

    try {
      if (controller.value.value.isInitialized) {
        areaKeyLog.i('Dispose player');
        controller.value.dispose();
      }

      if (file == null || file.uri.isEmpty) {
        controller.value = VideoPlayerController.networkUrl(Uri.parse(''));
      } else {
        final storage = useStorageStore().findById(file.storageId);
        final auth = storage?.getAuth();

        // CLOSE_DEBUG_LOG
        diagLog.d('open uri=${file.uri} type=${file.storageType} source=${checkDataSourceType(file).name}');
        areaKeyLog.i('Open file: $file');

        // A wildcard WebDAV entry whose host was never resolved would dial
        // `192.168.*.*`. Resolve once and rebuild the address from the storage
        // record; explain a failure instead of initializing an unplayable source.
        var playUri = file.uri;
        if (storage is WebDAVStorage) {
          final target = await webdavPlaybackTarget(storage, file.path);
          if (target.uri == null) {
            if (context.mounted) {
              await showWebdavPlaybackFailure(context, file, target.failure!);
            }
            return;
          }
          playUri = target.uri!;
        }

        switch (checkDataSourceType(file)) {
          case DataSourceType.file:
            // Hook-level fallback: repair the known-broken '/X:/...' shape
            // before it reaches dart:io; other forms pass through untouched.
            controller.value = VideoPlayerController.file(
              File(sanitizePlayableUri(playUri)),
              httpHeaders: auth != null ? {'authorization': auth} : {},
            );
          case DataSourceType.contentUri:
            bool isExists = false;
            try {
              isExists = await SafUtil().exists(playUri, false);
            } catch (e) {
              areaKeyLog.w('SafUtil.exists failed for $playUri: $e');
            }
            controller.value = VideoPlayerController.contentUri(
              isExists ? Uri.parse(playUri) : Uri.parse(''),
            );
          default:
            controller.value = VideoPlayerController.networkUrl(
              Uri.parse(file.storageType == StorageType.ftp
                  ? '$streamUrl/$playUri'
                  : playUri),
              httpHeaders: auth != null ? {'authorization': auth} : {},
            );
        }
      }
      await controller.value.initialize();
      // CLOSE_DEBUG_LOG
      diagLog.d(
          'opened dur=${controller.value.value.duration.inMilliseconds}ms pos=${controller.value.value.position.inMilliseconds}ms playing=${controller.value.value.isPlaying}');
      // Only now does the controller belong to THIS media. A superseded open
      // (double-open race) must not claim the newer media either.
      final String? openedUri = file?.uri;
      if (openedUri != null && latestMediaUri.value == openedUri) {
        openedMediaUri.value = openedUri;
      }
      await controller.value.setLooping(repeat == Repeat.one ? true : false);
      await controller.value.setPlaybackSpeed(rate);
      await controller.value
          .setVolume(BackgroundVolumePolicy.toFvpScale(
              BackgroundVolumePolicy.foregroundEngineVolume(
            master: volume,
            muted: isMuted,
            bgActive: bgActive,
            fgPercent: fgVolumePercent,
            fgMuted: fgMuted,
          )));
    } catch (e) {
      // CLOSE_DEBUG_LOG
      diagLog.w('open error: $e');
      areaKeyLog.e('Error initializing player: $e');
      // Fail-open (mirror of the media_kit hook): a failed open never lands
      // its locked target, so release the position-intent lock instead of
      // blocking legitimate saves until the lock timeout fires.
      positionLock.value.unlock();
    } finally {
      isInitializing.value = false;
    }
  }

  // Save-on-switch MUST be declared BEFORE the init effect below:
  // flutter_hooks runs same-build cleanups in declaration order, and init()
  // synchronously replaces controller.value — a cleanup declared after it
  // would read the NEW (uninitialized) controller, fail its isInitialized
  // check and silently skip the old file's final save (a deterministic ≤10s
  // progress loss on every switch).
  useEffect(() {
    return () {
      if (isAndroid &&
          globals.initUri == file?.uri &&
          globals.initUri != null &&
          globals.initUri!.startsWith('content://')) {
        return;
      }

      if (file != null &&
          controller.value.value.isInitialized &&
          controller.value.value.duration != Duration.zero) {
        // Skip saving when the change is a scenario stop: the registry's
        // stop() clears the queue facade (playQueue becomes empty) and resets
        // progress itself. On a normal track change the facade still holds the
        // next entry, so the pre-stop position never overwrites the reset.
        // While a VM session owns the queue its segments' media_nodes progress
        // belongs to the controller (feed pre-write + anchor flush): saving
        // the leaving segment's live position here would clobber the just
        // pre-written landing target of a same-physical-file jump.
        if (!(useScenario && usePlayQueueStore().state.playQueue.isEmpty) &&
            !VirtualMediaController.instance.isActive) {
          // Position-intent lock: the player reports pre-land samples until
          // the resume seek has been OBSERVED at its target — skip the write
          // entirely (not a 0 write).
          if (positionLock.value.blocksWrites) {
            diagLog.d(
                'persist skipped (locked phase=${positionLock.value.phase.name} target=${positionLock.value.targetMs}) file=${file.name} pos=${controller.value.value.position.inMilliseconds}ms');
            return;
          }
          final rawPosMs = controller.value.value.position.inMilliseconds;
          final durMs = controller.value.value.duration.inMilliseconds;
      final posMs = sanePlaybackPos(
        lastSanePosMs.value,
        rawPosMs,
        durMs,
        userSeeked: false,
        inFlightTargetMs: positionLock.value.blocksWrites
            ? positionLock.value.targetMs
            : null,
      );
          final sanePosition = Duration(milliseconds: posMs);
          areaKeyLog.i('Save progress: ${file.name}, position: $sanePosition, duration: ${controller.value.value.duration}');
          persistPlaybackProgress(
            file: file,
            position: sanePosition,
            durationMs: durMs,
            writeTag: 'cleanup',
          );
          lastProgressWrite.value = DateTime.now();
          lastWrittenPosMs.value = posMs;
          lastSanePosMs.value = posMs;
          useHistoryStore().add(Progress(
            dateTime: DateTime.now().toUtc(),
            position: sanePosition,
            duration: controller.value.value.duration,
            file: file,
          ));
        }
      }
    };
  }, [file]);

  useEffect(() {
    // Position-intent lock: writes stay blocked from the open until the
    // resume/VM/user target has been observed ONCE (not merely issued).
    positionLock.value.armPending();
    init(file);
    return;
  }, [file?.uri]);

  useEffect(() {
    return () {
      if (controller.value.value.isInitialized) {
        controller.value.dispose();
      }
    };
  }, []);

  // Scenario resume: when a same-scenario re-play re-feeds the SAME file
  // (value-equal FileItem), the init effect above does not re-run, so a paused
  // video stays paused. autoPlay flipping false→true is the only signal that
  // survives; resume playback here. Declared after the init effect so a NEW
  // file's init sets isInitializing synchronously first and this skips.
  useEffect(() {
    // Shutdown fence: mirrors the media_kit hook — the quiesce pause wakes this
    // effect, and resuming here would drive play() into a disposing controller.
    if (AppShutdown.isActive) return;
    if (useScenario &&
        autoPlay &&
        controller.value.value.isInitialized &&
        !controller.value.value.isCompleted &&
        !controller.value.value.isPlaying) {
      controller.value.play();
    }
    return;
  }, [
    useScenario,
    autoPlay,
    controller.value.value.isInitialized,
    controller.value.value.isPlaying,
    controller.value.value.isCompleted,
  ]);

  // CLOSE_DEBUG_LOG: capture video_player backend errors (a failing file may
  // end without ever completing normally).
  final hasError = useListenableSelector(
      controller.value, () => controller.value.value.hasError);
  useEffect(() {
    if (hasError) {
      diagLog.w('player.error: ${controller.value.value.errorDescription}');
      if (VirtualMediaController.instance.isActive) {
        VirtualMediaController.instance.handleSegmentError();
      }
      // Fail-open: a broken open can never land its locked target.
      positionLock.value.unlock();
    }
    return;
  }, [hasError]);

  // Position-intent lock landing check (mirror of the media_kit position
  // stream listener): the controller notifies on every frame; the player
  // must be OBSERVED once at/near the locked target before writes resume.
  useEffect(() {
    final c = controller.value;
    void listener() {
      if (positionLock.value.checkLanding(
          c.value.position.inMilliseconds, c.value.duration.inMilliseconds)) {
        // CLOSE_DEBUG_LOG (no file here: the listener's closure can lag the
        // current file — pos/target identify the landing).
        diagLog.d(
            'lock landed pos=${c.value.position.inMilliseconds}ms target-reached phase=unlocked');
      }
    }

    c.addListener(listener);
    return () => c.removeListener(listener);
  }, [controller.value]);

  useEffect(() {
    () async {
      final currentExternalSubtitle = externalSubtitle.value;
      if (currentExternalSubtitle == null || externalSubtitles.isEmpty) {
        controller.value.setExternalSubtitle('');
      } else if (externalSubtitle.value! < externalSubtitles.length) {
        bool isExists = true;

        final subtitle = externalSubtitles[currentExternalSubtitle];
        final storage = file == null
            ? null
            : useStorageStore().resolveStorageForNodeId(file.storageId);
        // Shared resolver: rebuilds the WebDAV authority from the current
        // storage record and centralises the FTP proxy prefix, so this path
        // matches the track panel and the media_kit auto-select exactly.
        final uri = subtitlePlayableUri(
          storage,
          subtitle,
          mediaStreamUrl: streamUrl ?? '',
        );

        areaKeyLog.i('External subtitle uri: $uri');

        if (Platform.isAndroid && subtitle.uri.startsWith('content://')) {
          try {
            isExists = await SafUtil().exists(uri, false);
          } catch (e) {
            areaKeyLog.w('SafUtil.exists subtitle failed for $uri: $e');
            isExists = false;
          }
        }

        if (isExists) {
          // NOTE: fvp exposes no error surface for `setExternalSubtitle`, so a
          // REMOTE subtitle that fails to fetch still has no feedback here — the
          // existence pre-check above only covers the LOCAL (SAF) case. The
          // media_kit path watches the engine error stream instead.
          controller.value.setExternalSubtitle(uri);
        } else {
          externalSubtitle.value = null;
          // The fvp backend used to drop the request in silence: the track
          // simply never appeared, with nothing to tell a dead subtitle link
          // (a renamed file) from a bug. Same surface the media_kit auto-select
          // uses.
          if (context.mounted) {
            await showCopyableErrorDialog(
              context,
              message: getLocalizations(context)
                  .track_subtitle_load_failed(subtitle.name),
            );
          }
        }
      }
    }();

    return;
  }, [externalSubtitles, externalSubtitle.value]);

  /// Finishes the CURRENT item: the single advance path shared by the backend's
  /// completion flag and the mpv-parity tail collapse (mirror of the media_kit
  /// hook — see `dispatchItemFinished` there for the playloop rationale).
  ///
  /// [expectedUri] binds a caller to the media it decided about; a finish that
  /// arrives after the queue moved on must die here.
  Future<void> dispatchItemFinished({
    required bool fromEngine,
    String? expectedUri,
  }) async {
    final String src = fromEngine ? 'engine' : 'step-eof';
    final FileItem? f = file;
    if (f == null) return;
    final VideoPlayerValue v = controller.value.value;
    if (expectedUri != null && f.uri != expectedUri) {
      diagLog.d('completed dropped (stale finish) src=$src file=${f.name}');
      return;
    }
    if (fromEngine && useScrubDragStore().state.any) {
      diagLog.d('completed suppressed hold/seek');
      usePlayerUiStore().updatePendingCompleted(true);
      return;
    }
    if (finishedDispatchInFlight.value) return;
    if (SegmentEditGuard.transportFrozen) {
      diagLog.d('completed paused by segment-edit freeze src=$src');
      controller.value.pause();
      return;
    }
    finishedDispatchInFlight.value = true;
    try {
      // The item is finished from here on: drop the tail arm so a repeat-one
      // loop of the SAME media can arm again.
      stepTail.value.reset();
      tailCollapseTimer.value?.cancel();
      tailCollapseTimer.value = null;
      if (await VirtualMediaController.instance.maybeHandleCompleted()) return;
      // CLOSE_DEBUG_LOG
      diagLog.d(
          'completed fired src=$src pos=${v.position.inMilliseconds}ms dur=${v.duration.inMilliseconds}ms file=${f.name} repeat=$repeat curIdx=$currentPlayIndex total=${playQueue.length}');
      areaKeyLog.i('Completed: ${f.name}');
      if (v.position != Duration.zero) {
        persistPlaybackProgress(
          file: f,
          position: v.position,
          completed: true,
          writeTag: 'completed',
        );
        lastProgressWrite.value = DateTime.now();
        lastWrittenPosMs.value = v.position.inMilliseconds;
      }
      if (repeat == Repeat.one) return;
      final handled = await PlaybackProviderRegistry.advanceOnComplete(repeat);
      // CLOSE_DEBUG_LOG
      diagLog.d('completed advance handled=$handled src=$src');
      if (handled) return;
      await advancePlayQueueOnCompleted(repeat);
    } finally {
      finishedDispatchInFlight.value = false;
    }
  }

  useEffect(() {
    () async {
      if (file != null &&
          controller.value.value.isCompleted &&
          controller.value.value.position != Duration.zero &&
          controller.value.value.duration != Duration.zero) {
        await dispatchItemFinished(fromEngine: true);
      } else if (usePlayerUiStore().state.pendingCompleted) {
        // A seek reset the backend completion flag (a drag returned from 100%
        // to a mid position): drop the stale suppressed latch so the release
        // cannot advance (see shouldFlushSuppressedCompletion).
        usePlayerUiStore().updatePendingCompleted(false);
      }
    }();
    return;
  }, [controller.value.value.isCompleted]);

  // Flush suppressed completed when hold released.
  final pendingCompletedFvp = usePlayerUiStore().select(context, (s) => s.pendingCompleted);
  final isHoldingDownFvp = useScrubDragStore().select(context, (s) => s.isHolding);
  useEffect(() {
    if (!pendingCompletedFvp || isHoldingDownFvp) return;
    if (!shouldFlushSuppressedCompletion(
      pendingCompleted: pendingCompletedFvp,
      holding: isHoldingDownFvp,
      completed: controller.value.value.isCompleted,
    )) {
      // Stale latch: a seek during the drag carried playback off the end, so
      // the release position decides playback — never advance (the
      // "touch 100%, come back to 50%, still jumps" defect).
      usePlayerUiStore().updatePendingCompleted(false);
      return;
    }
    usePlayerUiStore().updatePendingCompleted(false);
    () async {
      if (repeat == Repeat.one) return;
      if (SegmentEditGuard.transportFrozen) {
        controller.value.pause();
        return;
      }
      if (await VirtualMediaController.instance.maybeHandleCompleted()) {
        return;
      }
      final handled = await PlaybackProviderRegistry.advanceOnComplete(repeat);
      if (handled) return;
      await advancePlayQueueOnCompleted(repeat);
    }();
    return;
  }, [
    pendingCompletedFvp,
    isHoldingDownFvp,
    controller.value.value.isCompleted,
    repeat,
    currentPlayIndex,
    playQueue.length,
  ]);

  useEffect(() {
    if (controller.value.value.isInitialized) {
      controller.value.setPlaybackSpeed(rate);
    }
    return;
  }, [rate]);

  useEffect(() {
    if (controller.value.value.isInitialized) {
      controller.value.setVolume(BackgroundVolumePolicy.toFvpScale(
          BackgroundVolumePolicy.foregroundEngineVolume(
        master: volume,
        muted: isMuted,
        bgActive: bgActive,
        fgPercent: fgVolumePercent,
        fgMuted: fgMuted,
      )));
    }
    return;
  }, [volume, isMuted, bgActive, fgVolumePercent, fgMuted]);

  useEffect(() {
    if (controller.value.value.isInitialized) {
      areaKeyLog.i('Set looping: $looping');
      controller.value.setLooping(repeat == Repeat.one ? true : false);
    }
    return;
  }, [looping]);

  useEffect(() {
    () async {
      if (controller.value.value.duration != Duration.zero &&
          file != null &&
          file.type == ContentType.video) {
        // CLOSE_DEBUG_LOG
        diagLog.d('durationArrived dur=${controller.value.value.duration.inMilliseconds}ms file=${file.name}');
        // VM feeds open like any ordinary single file: the controller
        // pre-wrote the landing position (jump target, or 0 for sequential
        // advance) into media_nodes BEFORE this open, and the shared
        // DB-authoritative resume below lands it. The only VM touch point
        // left here is the switch-freeze bookkeeping.
        final vmCtrlDur = VirtualMediaController.instance;
        if (vmCtrlDur.isActive) {
          // A duration from an open that started under an OLDER feed belongs
          // to a superseded file: dropping it keeps the newer feed's switch
          // freeze intact until its own duration arrives. A null generation
          // (open raced before capture) must NOT clear: its file is unknown.
          final openGen = openVmFeedGen.value;
          if (openGen != null && openGen == vmCtrlDur.feedGeneration) {
            vmCtrlDur.clearTransition();
          }
        } else {
          // The play queue left the session: clearTransition() can never fire
          // for it (it is gated on isActive), so the orphaned freeze is
          // released here — otherwise `transitioning` latches and blocks the
          // stale-session cleanup forever, leaving every progress surface
          // partitioning this normal file into virtual segments.
          vmCtrlDur.releaseOrphanedTransition();
        }
        // Completed files start from the beginning — resuming at the end would
        // instantly complete again and spin the auto-advance loop. A VM feed
        // under the CURRENT generation is an explicit targeted open (the
        // controller pre-wrote the landing position): the user's jump intent
        // outranks the global always-play-from-beginning setting.
        final vmOpenGen = openVmFeedGen.value;
        final vmTargeted = vmCtrlDur.isActive &&
            vmOpenGen != null &&
            vmOpenGen == vmCtrlDur.feedGeneration;
        // A cross-segment "finish this item" feed: the controller opened the
        // last segment with its END as the target. Land ON the duration so the
        // engine raises `completed` and the provider advances past the merged
        // item — the DB-resume path below would clamp to its 5 s/guard margins
        // and leave the item one tail short of finishing.
        final vmFinishOnFeed =
            vmTargeted && vmCtrlDur.feedFinishesItem(vmOpenGen);
        final wasCompleted = await readPlaybackCompleted(file);
        // CLOSE_DEBUG_LOG
        diagLog.d(
            'resume eval wasCompleted=$wasCompleted alwaysFromBeginning=$alwaysPlayFromBeginning vmTargeted=$vmTargeted finishOnFeed=$vmFinishOnFeed');
        if (vmFinishOnFeed) {
          areaKeyLog.i('VM finish-on-feed: ${file.name}');
          final Duration end = controller.value.value.duration;
          positionLock.value.armTarget(end.inMilliseconds);
          await controller.value.seekTo(end);
        } else if ((wasCompleted || alwaysPlayFromBeginning) && !vmTargeted) {
          areaKeyLog.i('Skip resume for ${file.name}');
          positionLock.value.unlock();
        } else {
          final dbPos = await readPlaybackProgress(file);
          final budget = await readHistoryRestoreBudget(file);
          final (decision, resumeAt) = resolveOpenResume(
              dbPos, controller.value.value.duration.inMilliseconds, budget);
          // CLOSE_DEBUG_LOG: logged unconditionally — the previously silent
          // branches (fromBeginningExplicit / empty history) must be
          // attributable from the same repro log.
          diagLog.d('resume decision=$decision dbPos=$dbPos budget=$budget '
              'target=$resumeAt dur=${controller.value.value.duration.inMilliseconds}ms file=${file.name}');
          switch (decision) {
            case OpenResumeDecision.seekDb:
              areaKeyLog.i('Resume DB progress: ${file.name} position: $resumeAt');
              // Lock BEFORE issuing the seek: landing checks run on the
              // controller listener, which can fire before the await
              // completes.
              positionLock.value.armTarget(resumeAt);
              await controller.value.seekTo(Duration(milliseconds: resumeAt));
            case OpenResumeDecision.fromBeginningExplicit:
              // The row at ≤0 carries no budget: an explicit "from the
              // beginning" (e.g. a VM sequential-advance pre-write). Never
              // resurrect a stale HistoryStore position on top of it. Locked
              // at 0 — the first head tick lands and unlocks.
              areaKeyLog.i('Explicit from-beginning row for ${file.name}');
              positionLock.value.armTarget(0);
            case OpenResumeDecision.fallbackHistory:
              Progress? progress =
                  // history[file.getID()];  // legacy: surface-dependent uri key
                  history[canonicalProgressKey(file.storageId, file.path,
                      uri: file.uri)]; // unified
              if (progress != null &&
                  (progress.duration.inMilliseconds -
                          progress.position.inMilliseconds) >
                      5000) {
                // CLOSE_DEBUG_LOG
                diagLog.d('resume seek history pos=${progress.position.inMilliseconds}ms dur=${progress.duration.inMilliseconds}ms');
                areaKeyLog.i('Resume progress: ${file.name} position: ${progress.position} duration: ${progress.duration}');
                positionLock.value.armTarget(progress.position.inMilliseconds);
                await controller.value.seekTo(progress.position);
                // One history fallback was consumed: burn budget so a
                // repeated failed open cannot keep re-falling back forever.
                // The seek landing (or this file's own live saves) will
                // re-write a real positive position next.
                if (dbPos == null || dbPos <= 0) {
                  await spendHistoryRestoreBudget(file);
                }
              } else {
                // Previously a SILENT fall-through to the head — now
                // attributable (history empty or remaining <5s).
                diagLog.d('resume fallbackHistory empty -> head '
                    'hasEntry=${progress != null} file=${file.name}');
                positionLock.value.unlock();
              }
          }
        }
      } else if (file == null || file.type != ContentType.video) {
        // Non-video opens have no resume decision: unblock persistence so
        // audio saves keep working exactly as before. A video file whose
        // duration has not arrived yet stays locked until its resume lands.
        positionLock.value.unlock();
      }

      if (autoPlay) {
        controller.value.play();
      }

      if (externalSubtitles.isNotEmpty) {
        // Only re-arm on a different FILE: the parsed duration can be revised
        // mid-play, and the old unconditional reset silently dropped the user's
        // chosen external track back to the first one.
        final key = file == null
            ? null
            : canonicalProgressKey(file.storageId, file.path, uri: file.uri);
        if (externalSubtitleFileKey.value != key) {
          externalSubtitleFileKey.value = key;
          externalSubtitle.value = 0;
        }
      }
    }();
    return;
  }, [controller.value.value.duration]);

  // Write duration + probed dimensions to media_nodes DB when they first
  // become available (lazy probe backfill: playing a file fills any gaps
  // left by an unprobed scan).
  // The write-once mark is keyed by the FILE ([MediaInfoWritebackGate]): a
  // per-hook boolean stayed set for the whole session, so everything after the
  // first file was silently skipped.
  final mediaInfoGate = useRef(MediaInfoWritebackGate());
  final mediaInfoKey = file == null
      ? null
      : canonicalProgressKey(file.storageId, file.path, uri: file.uri);
  useEffect(() {
    final d = controller.value.value.duration;
    final size = controller.value.value.size;
    final w = size.width.round();
    final h = size.height.round();
    final key = mediaInfoKey;
    if (file == null || key == null) return null;
    // ATTRIBUTION GUARD (see MediaInfoWritebackGate.belongsToOpenFile): on a
    // track switch this effect runs for the NEW key while `controller.value`
    // still describes the PREVIOUS media (initialize() is awaited in the effect
    // above). Writing those values keyed by the new file poisoned `media_nodes`
    // — every row inherited its predecessor's duration and dimensions — and the
    // write-once mark then dropped the real values.
    if (!mediaInfoGate.value
        .belongsToOpenFile(mediaUri: file.uri, openedUri: openedMediaUri.value)) {
      return null;
    }
    final gate = mediaInfoGate.value;
    final needDuration = gate.needsDuration(key, d.inMilliseconds);
    final needDims = gate.needsDims(key, w, h);
    if (!needDuration && !needDims) return null;
    if (needDuration) gate.markDurationWritten(key);
    if (needDims) gate.markDimsWritten(key);
    // Immediate live-progress seed: give the progress UIs the just-parsed
    // duration right away instead of waiting for the next 1s timer tick.
    if (needDuration) {
      usePlaybackProgressStore().update(
        // file.getID(),  // legacy: surface/platform-dependent uri key
        canonicalProgressKey(file.storageId, file.path,
            uri: file.uri), // unified
        controller.value.value.position.inMilliseconds,
        d.inMilliseconds,
      );
    }
    () async {
      try {
        final dbPath = file.path.join('/');
        if (dbPath.isEmpty) {
          // No segment path to key the write on (SAF single pick): nothing was
          // written, so release the mark instead of swallowing the backfill.
          gate.unmark(key);
          return;
        }
        final rows = await DbModule.mediaNodeRepo.updateFileMediaInfo(
          storageId: file.storageId,
          path: dbPath,
          durationMs: needDuration ? d.inMilliseconds : null,
          width: needDims ? w : null,
          height: needDims ? h : null,
          pixelCount: needDims ? w * h : null,
        );
        if (rows <= 0) {
          // No `media_nodes` row matched (unscanned file, or a stored path-shape
          // mismatch such as the collapsed SAF scheme). The database was NOT
          // updated, so release the mark: keeping it would drop this file's
          // duration/dimensions for the rest of the session.
          gate.unmark(key);
          areaKeyLog.w('Media info write-back matched no row: ${file.name}');
          return;
        }
        areaKeyLog.i('Saved media info to DB: ${file.name} '
            'dur=${needDuration ? d.inMilliseconds : "-"}ms');
        // Only a write that CHANGED the row moves this file in a duration sort
        // (or out of its NULLS-LAST bucket), so only then is an open list
        // re-resolved. An already-correct value must stay free: this runs once
        // per played file.
        if (mediaInfoCorrects(
          storedDurationMs: file.durationMs,
          durationMs: d.inMilliseconds,
        )) {
          await MediaRevisionActions.mediaNodesChanged([file.storageId]);
        }
      } catch (e) {
        gate.unmark(key);
        areaKeyLog.e('Error saving media info to DB: $e');
      }
    }();
    return null;
    // `isInitializing` is a dependency so the write is RETRIED once this file's
    // open completed: a duration that arrived during `initialize()` is skipped
    // by the attribution guard above, and no further emission would come.
  }, [
    controller.value.value.duration,
    controller.value.value.size,
    mediaInfoKey,
    isInitializing.value,
  ]);

  // Live progress: update the in-memory store every second so progress UIs can
  // tick in real time; throttle media-column DB writes to at most once per 10s
  // (each save event — including track change — resets the 10s window) so
  // crash-resume is at most ~10s stale while IO stays bounded.
  useEffect(() {
    final current = file;
    if (current == null) return null;

    lastProgressWrite.value = DateTime.now();
    lastSanePosMs.value = null;
    userSeekPending.value = false;

    final timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      // Position-intent lock fail-open: runs BEFORE the duration early-return
      // so a pending lock (duration never arrives) still releases.
      final timeout = positionLock.value.tickTimeout();
      if (timeout == PositionLockTimeoutAction.retrySeek) {
        final target = positionLock.value.targetMs;
        // CLOSE_DEBUG_LOG
        diagLog.d('lock timeout retry seek target=$target file=${current.name} '
            'src=lock-retry(native)');
        if (target != null) {
          await controller.value.seekTo(Duration(milliseconds: target));
        }
      } else if (timeout == PositionLockTimeoutAction.released) {
        // CLOSE_DEBUG_LOG
        diagLog.d('lock timeout released file=${current.name}');
      }
      if (!controller.value.value.isInitialized ||
          controller.value.value.duration == Duration.zero) {
        return;
      }
      // Attribution gate (mirror of the media_kit hook): the tick can land
      // between "hook rebuilt for the next entry" and "initialize() done",
      // while the controller still holds THIS file's tail.
      if (!shouldAttributeLiveProgress(
        sampleUri: current.uri,
        openUri: openedMediaUri.value,
        latestUri: latestMediaUri.value,
      )) {
        return;
      }
      final rawPosMs = controller.value.value.position.inMilliseconds;
      final durMs = controller.value.value.duration.inMilliseconds;
      final userSeeked = userSeekPending.value;
      userSeekPending.value = false;
      final posMs = sanePlaybackPos(
        lastSanePosMs.value,
        rawPosMs,
        durMs,
        userSeeked: userSeeked,
        inFlightTargetMs: positionLock.value.blocksWrites
            ? positionLock.value.targetMs
            : null,
      );
      if (rawPosMs != posMs) {
        areaKeyLog.d(
            'progress glitch raw=$rawPosMs kept=$posMs userSeek=$userSeeked');
      }
      lastSanePosMs.value = posMs;
      // final fileId = current.getID();  // legacy: surface/platform-dependent uri key
      final fileId = canonicalProgressKey(current.storageId, current.path,
          uri: current.uri); // unified
      // Pre-landing samples stay out of the live mirror while an intent is in
      // flight (see the media_kit hook's identical gate).
      if (!positionLock.value.blocksWrites) {
        usePlaybackProgressStore().update(fileId, posMs, durMs);
      }

      final lastWrite = lastProgressWrite.value;
      final now = DateTime.now();
      if (posMs != lastWrittenPosMs.value &&
          (lastWrite == null ||
              now.difference(lastWrite) >= const Duration(seconds: 10))) {
        // Position-intent lock: skip the throttled DB write until the
        // locked target has been observed; the in-memory store update above
        // still ticks the UI.
        if (positionLock.value.blocksWrites) {
          diagLog.d(
              'persist skipped (locked phase=${positionLock.value.phase.name} target=${positionLock.value.targetMs}) file=${current.name} pos=${posMs}ms');
        } else {
          persistPlaybackProgress(
              file: current,
              position: Duration(milliseconds: posMs),
              durationMs: durMs,
              writeTag: 'timer');
        }
        lastProgressWrite.value = now;
        lastWrittenPosMs.value = posMs;
      }
    });

    return () {
      timer.cancel();
      if (controller.value.value.isInitialized &&
          controller.value.value.duration != Duration.zero &&
          shouldAttributeLiveProgress(
            sampleUri: current.uri,
            openUri: openedMediaUri.value,
            latestUri: latestMediaUri.value,
          ) &&
          !positionLock.value.blocksWrites) {
        final raw = controller.value.value.position.inMilliseconds;
        final dur = controller.value.value.duration.inMilliseconds;
        usePlaybackProgressStore().update(
          // current.getID(),  // legacy: surface/platform-dependent uri key
          canonicalProgressKey(current.storageId, current.path,
              uri: current.uri), // unified
          sanePlaybackPos(
            lastSanePosMs.value,
            raw,
            dur,
            userSeeked: false,
            inFlightTargetMs: positionLock.value.blocksWrites
                ? positionLock.value.targetMs
                : null,
          ),
          dur,
        );
      }
    };
  }, [file]);

  useEffect(() {
    if (controller.value.value.isPlaying) {
      areaKeyLog.i('Enable wakelock');
      WakelockPlus.enable();
    } else {
      areaKeyLog.i('Disable wakelock');
      WakelockPlus.disable();
    }
    return;
  }, [controller.value.value.isPlaying]);

  Future<void> play() async {
    if (useScenario && file == null) {
      // The player was fully stopped (feed cleared). Re-feed the ACTIVE
      // context — a tag view resumes inside its own list (never the scenario
      // item behind it), and a lost tag bookmark starts from the top.
      await PlaybackProviderRegistry.resumeActive();
    }
    if (!controller.value.value.isInitialized &&
        !isInitializing.value &&
        file != null) {
      init(file);
    }
    controller.value.play();
  }

  Future<void> pause() async {
    controller.value.pause();
  }

  // ── Seek-burst control (mirror of the media_kit hook) ──
  //
  // Only the PROGRESS WRITES are collapsed (one Drift read+write per repeat
  // would hammer the UI isolate); the seeks themselves are issued one per press
  // so a held key advances frame by frame instead of jumping once.
  //
  // NOTE: the media_kit hook issues mpv's NATIVE relative keyframe seek
  // (`seek <delta> relative+keyframes`), which mpv coalesces itself, and keeps
  // no Dart accumulator. fvp has no relative / natively-coalesced seek, so the
  // Dart [stepIntent] accumulation above IS the burst tracker here, and each
  // step press is turned into an absolute seek that uses the keyframe
  // (`fastSeekTo`) path — see [fvpStepUsesKeyframeSeek].
  final userSeekWrite = useRef(
      TrailingCoalescer<({FileItem file, Duration position, int durationMs})>());
  final userSeekWriteTimer = useRef<Timer?>(null);
  // Last payload actually written, so a single seek does not pay a redundant
  // trailing write 350ms later.
  final lastUserSeekWrite =
      useRef<({FileItem file, Duration position, int durationMs})?>(null);

  void persistUserSeekWrite(
      ({FileItem file, Duration position, int durationMs}) w) {
    if (lastUserSeekWrite.value == w) return;
    lastUserSeekWrite.value = w;
    unawaited(persistPlaybackProgress(
      file: w.file,
      position: w.position,
      durationMs: w.durationMs,
      userSeekToHead: w.position == Duration.zero,
      userSeek: true,
      writeTag: 'user-seek',
    ));
  }

  void persistUserSeekBurst(Duration target) {
    final FileItem? f = file;
    if (f == null) return;
    final w = (
      file: f,
      position: target,
      durationMs: controller.value.value.duration.inMilliseconds,
    );
    final bool leading = !userSeekWrite.value.hasPending;
    userSeekWrite.value.record(w);
    if (leading) persistUserSeekWrite(w);
    userSeekWriteTimer.value?.cancel();
    userSeekWriteTimer.value = Timer(kUserSeekWriteDebounce, () {
      final pending = userSeekWrite.value.flush();
      if (pending != null) persistUserSeekWrite(pending);
    });
  }

  void flushUserSeekBurst() {
    userSeekWriteTimer.value?.cancel();
    userSeekWriteTimer.value = null;
    final pending = userSeekWrite.value.flush();
    if (pending != null) persistUserSeekWrite(pending);
  }

  /// Drops the step bookkeeping (media change / unmount / absolute seek /
  /// rewind): the burst accumulator, the OSD target and any pending tail arm.
  ///
  /// An ABSOLUTE seek must call this, not just clear the OSD (media_kit's
  /// [seek] calls its own `resetStepBurst` for exactly this reason): the tail
  /// arm stays media-bound for [kMpvSeekEofWindow], so a press that armed a
  /// finish and a seek away from the end inside that window would otherwise
  /// collapse the arm and advance away from the position the user just chose.
  void resetStepBurst() {
    stepBurstTimer.value?.cancel();
    stepBurstTimer.value = null;
    stepIntent.value.reset();
    stepOsdTargetMs.value = null;
    stepTail.value.reset();
    tailCollapseTimer.value?.cancel();
    tailCollapseTimer.value = null;
  }

  // Attribution-only [src]: see the media_kit hook — log only, the
  // tear-off still satisfies `Future<void> Function(Duration)`.
  //
  // [intent] states what the caller wants at the media end (see [SeekIntent]):
  // a scrub drag residency stops short of the tail, only a release at 100% may
  // land ON it and advance.
  Future<void> seek(
    Duration newPosition, [
    String src = 'player',
    SeekIntent intent = SeekIntent.stopAtTail,
  ]) async {
    // An absolute jump re-anchors the NEXT relative step on the fresh
    // position; a cross-segment step re-anchors below (its local axis
    // changes). Only 'step' keeps the accumulation alive. Everything else
    // ALSO drops a pending tail arm: the arm outlives the seek by its 300ms
    // EOF window, so a press at the tail followed by a seek back to the middle
    // would otherwise collapse the arm and advance the queue from a position
    // the user never finished (media_kit parity — its seek calls the same
    // `resetStepBurst`).
    if (src != 'step') resetStepBurst();
    // Step seeks land on a KEYFRAME (mpv-native parity, see
    // [fvpStepUsesKeyframeSeek]) unless the target is in the media tail, where a
    // key-frame landing can only be wrong (see [fvpStepNeedsExactSeek]);
    // everything else needs the exact landing.
    final bool stepSeek = fvpStepUsesKeyframeSeek(src);
    // Virtual Media: cross-segment targets open WITH the intra-segment
    // offset (pendingSeekMs handoff) instead of flashing 0% first — unless
    // the drag strategy says to hold the picture until release (spec §6).
    if (VirtualMediaController.instance.isActive) {
      final vm = VirtualMediaController.instance;
      final item = vm.state.item;
      if (item != null) {
        final (segIdx, localMs) = item.locate(newPosition.inMilliseconds);
        final curSeg = vm.state.segmentIndex;
        // CLOSE_DEBUG_LOG: vm seek-coordinate attribution (mirror of the
        // media_kit hook).
        diagLog.d('[vm-seek] target=${newPosition.inMilliseconds}V '
            'resolved seg=$segIdx local=$localMs cur=$curSeg src=$src');
        if (segIdx != curSeg &&
            newPosition.inMilliseconds < item.offsetOf(curSeg)) {
          diagLog.w('[vm-seek] backward cross-segment '
              'target=${newPosition.inMilliseconds}V seg=$segIdx cur=$curSeg '
              '(legal for chapter/rewind; investigate otherwise)');
        }
        if (segIdx == vm.state.segmentIndex) {
          // An unknown segment duration makes the intra-segment target a
          // fabricated 0 (`clampVmLocalMs`), which the lock + persist below
          // would write over the file's saved progress. Hold instead — and drop
          // any previous press's OSD target so a held key does not keep showing
          // a landing this press never asked for.
          const handler = VirtualSeekHandler();
          if (!handler.segmentDurationKnown(item, segIdx)) {
            stepOsdTargetMs.value = null;
            return;
          }
          final clamped = clampVmLocalMs(item.segments[segIdx].durationMs,
              localMs, intent: intent);
          // Step accumulation on the SEGMENT-LOCAL axis (the axis
          // seekRelative reads — see StepIntent).
          if (src == 'step') noteStepIntent(clamped);
          // The OSD reads the virtual axis (the one `player.duration` exposes),
          // while the step accumulator is segment-LOCAL.
          if (src == 'step') {
            stepOsdTargetMs.value = item.offsetOf(segIdx) + clamped;
          }
          userSeekPending.value = true;
          lastSanePosMs.value = null;
          // Position-intent lock + save-once (mirror of the media_kit hook) — but
          // NOT for a step: its keyframe landing is deliberately off-target and
          // would trip the lock's miss path (see [fvpShouldArmPositionLock]).
          if (fvpShouldArmPositionLock(src)) {
            positionLock.value.armTarget(clamped);
          }
          if (file != null) {
            // Leading + trailing burst writes, exactly like the non-VM path
            // below: a held arrow key used to write Drift on EVERY repeat (a
            // read+write per press on the UI isolate), while the media_kit hook
            // coalesces the same burst. A STEP persists the OBSERVED position,
            // not the requested one: its keyframe landing is behind the target
            // (see [fvpPersistedSeekMs]).
            final int observedMs =
                controller.value.value.position.inMilliseconds;
            persistUserSeekBurst(Duration(
              milliseconds: fvpPersistedSeekMs(
                src: src,
                targetMs: clamped,
                observedMs: observedMs,
              ),
            ));
          }
          final Duration seekTarget = Duration(milliseconds: clamped);
          // A step landing in the segment tail must be EXACT: mdk's key-frame
          // seek answers a target it cannot reach with the media's LAST key
          // frame (see [fvpStepNeedsExactSeek]).
          final bool useKeyframe = stepSeek &&
              !fvpStepNeedsExactSeek(
                targetMs: clamped,
                durationMs: item.segments[segIdx].durationMs ?? 0,
                deltaMs: clamped -
                    controller.value.value.position.inMilliseconds,
              );
          await (useKeyframe
              ? controller.value.fastSeekTo(seekTarget)
              : controller.value.seekTo(seekTarget));
        } else {
          final dragging = useScrubDragStore().state.any;
          // A cross-segment step lands on ANOTHER segment: the local axis the
          // accumulator was recorded in no longer applies.
          stepIntent.value.reset();
          stepOsdTargetMs.value = null;
          final decision = decideVmDragSeek(
            strategy: useAppStore().state.vmCrossSegmentDragStrategy,
            isDragging: dragging,
            crossSegment: true,
          );
          if (decision == VmDragSeekDecision.stashPreview) {
            vm.stashDragTarget(newPosition.inMilliseconds);
          } else if (!vmCrossJumpStashes(
            dragging: dragging,
            withinThrottleWindow: vm.shouldThrottleCrossJump(),
          )) {
            vm.markCrossJump();
            await vm.jumpToSegment(segIdx,
                localMs: localMs,
                finishAtEnd: intent == SeekIntent.finishAtEnd);
          } else {
            // Throttled tick: keep the newest target for the release commit.
            vm.stashDragTarget(newPosition.inMilliseconds);
          }
        }
        return;
      }
    }
    areaKeyLog.i('Seek to: $newPosition src=$src');
    if (controller.value.value.duration == Duration.zero) return;
    // A user-initiated jump resets the position-sanitizer guard so the new
    // position (possibly backward) is accepted on the next sample.
    userSeekPending.value = true;
    lastSanePosMs.value = null;
    final totalMs = controller.value.value.duration;
    final target = clampSeekTarget(newPosition, totalMs, intent: intent);
    final int observedMs = controller.value.value.position.inMilliseconds;
    if (src == 'step') {
      noteStepIntent(target.inMilliseconds);
      stepOsdTargetMs.value = target.inMilliseconds;
    }
    // Position-intent lock + save-once (mirror of the media_kit hook): the
    // user's explicit target is the authoritative progress from this moment.
    // A burst collapses to leading+trailing writes. A STEP is exempt: its
    // keyframe landing is deliberately off-target (see
    // [fvpShouldArmPositionLock]) — so it persists the OBSERVED position, never
    // the target ([fvpPersistedSeekMs]).
    if (fvpShouldArmPositionLock(src)) {
      positionLock.value.armTarget(target.inMilliseconds);
    }
    persistUserSeekBurst(Duration(
      milliseconds: fvpPersistedSeekMs(
        src: src,
        targetMs: target.inMilliseconds,
        observedMs: observedMs,
      ),
    ));
    // A step landing in the media tail must be EXACT: mdk answers a key-frame
    // target it cannot reach with the media's LAST key frame, which is the tail
    // rollback (see [fvpStepNeedsExactSeek]).
    final bool useKeyframe = stepSeek &&
        !fvpStepNeedsExactSeek(
          targetMs: target.inMilliseconds,
          durationMs: totalMs.inMilliseconds,
          deltaMs: target.inMilliseconds - observedMs,
        );
    await (useKeyframe
        ? controller.value.fastSeekTo(target)
        : controller.value.seekTo(target));
  }

  /// Applies mpv's EOF collapse to the tail press currently armed for [uri].
  ///
  /// Two independent guards keep a finish from touching the entry that replaced
  /// it: the arm itself carries [uri] ([MpvSeekTailState]), and this media's
  /// open must still be the completed one (see [shouldAcceptStepPress]).
  Future<void> collapseTailStepToEof(String uri) async {
    tailCollapseTimer.value?.cancel();
    tailCollapseTimer.value = null;
    if (latestMediaUri.value != uri) return;
    if (openedMediaUri.value != uri) return;
    if (!stepTail.value.consumeCollapse(mediaUri: uri)) return;
    await dispatchItemFinished(fromEngine: false, expectedUri: uri);
  }

  /// Arms mpv's EOF window for the tail press just issued (mirror of the
  /// media_kit hook: the playloop's own "continuous seeks past EOF are EOF").
  void armTailEofWindow() {
    tailCollapseTimer.value?.cancel();
    final String? uri = file?.uri;
    if (uri == null) return;
    tailCollapseTimer.value = Timer(kMpvSeekEofWindow, () {
      if (latestMediaUri.value != uri) return;
      if (controller.value.value.isCompleted) return;
      unawaited(collapseTailStepToEof(uri));
    });
  }

  /// Applies the tail-step policy ([decideStepTail]) for a press whose target
  /// reaches the caller axis end. [end] is the CALLER axis end (the file
  /// duration, or the merged Virtual-Media total), [stepTargetMs] the landing
  /// the ordinary step would use, ON THAT SAME CALLER AXIS — the non-VM path
  /// passes accumulated file ms, the VM path [vmTailStepTargetMs] (local ms +
  /// segment offset), because the argument ends up in `seek()`, which resolves
  /// VM targets against the merged timeline.
  ///
  /// mpv parity (see the media_kit hook's identical block): the press stays a
  /// normal forward step and must NOT become a per-repeat absolute
  /// `seek <duration>` — that is what starves EOF, because `handle_eof()`
  /// returns while a seek is queued (`player/playloop.c:1247-1250`).
  /// [MpvSeekTailState] swallows the repeats (mpv drops the queued seek,
  /// `playloop.c:1240-1243`) and [armTailEofWindow] collapses the press to EOF
  /// when the engine does not report the end within [kMpvSeekEofWindow].
  ///
  /// `hold` (paused) swallows the press: nothing is sought and nothing is
  /// written, so the progress cannot roll backwards (「暂停时保留」). The step
  /// accumulator is dropped too — a swallowed press must not anchor the next
  /// one.
  Future<void> applyTailStep(
      StepTailAction action, Duration end, int stepTargetMs) async {
    diagLog.d('[step-tail] action=${action.name} end=${end.inMilliseconds}ms '
        'pos=${controller.value.value.position.inMilliseconds}ms '
        'playing=$isPlaying mode=${stepTailFinishMode.name} '
        'target=$stepTargetMs armed=${stepTail.value.armed}');
    switch (action) {
      case StepTailAction.step:
        return;
      case StepTailAction.hold:
        // A paused press must not arm a finish (it returns before
        // `armFirstPress`), and it must NOT drop an arm the playing press
        // already raised: that pending collapse is the item's real finish.
        stepOsdTargetMs.value = null;
        stepBurstTimer.value?.cancel();
        stepBurstTimer.value = null;
        stepIntent.value.reset();
        return;
      case StepTailAction.finishItem:
        // Already armed for this media: swallow the press (see media_kit) and
        // keep the OSD parked on the caller-axis end.
        final String? tailUri = file?.uri;
        if (tailUri == null) return;
        if (!stepTail.value.armFirstPress(tailUri, end.inMilliseconds)) {
          stepOsdTargetMs.value = end.inMilliseconds;
          return;
        }
        // The ordinary forward step. It cannot reach EOF on its own (mdk
        // serves an unreachable key-frame target with the media's last key
        // frame), which is precisely why the EOF window below is the finish
        // path on this backend.
        userSeekPending.value = true;
        lastSanePosMs.value = null;
        await seek(Duration(milliseconds: stepTargetMs), 'step');
        // `seek` republishes its own (clamped) step target for the OSD; the
        // tail finish is the CALLER-axis end the user asked for.
        stepOsdTargetMs.value = end.inMilliseconds;
        armTailEofWindow();
        return;
    }
  }

  /// Relative skip on the VIRTUAL timeline (ms precision, clamped).
  /// See the media_kit hook for the coordinate rationale.
  Future<void> seekRelative(int deltaMs) async {
    // mpv parity: see the media_kit hook's identical gate — a seek only applies
    // to the entry whose demuxer is loaded (`player/playloop.c:311`), and the
    // switch clears whatever was queued (`loadfile.c:1825-1826`). Presses that
    // land while a media is switching are dropped instead of being resolved
    // against the previous file's duration/position.
    if (gateStepPress(
          mediaUri: file?.uri,
          openedUri: openedMediaUri.value,
          dispatchInFlight: finishedDispatchInFlight.value,
        ) ==
        StepPressGate.dropMediaSwitching) {
      diagLog.d('[step] dropped (media switching) file=${file?.name} '
          'opened=${openedMediaUri.value != null} advancing=${finishedDispatchInFlight.value}');
      return;
    }
    final vm = VirtualMediaController.instance;
    final item = vm.state.item;
    final rawPosMs = controller.value.value.position.inMilliseconds;
    // A rewind leaves the tail: the next forward tail press must be able to
    // arm its own finish (mpv re-evaluates EOF on every seek).
    if (deltaMs < 0) resetStepBurst();
    // Same accumulation contract as the media_kit hook: step intent → lock
    // intent → reported. The lock unlocks early (landing tolerance) and the
    // reported position can sit still, so neither is a sound base alone.
    final int? pendingIntent =
        positionLock.value.blocksWrites ? positionLock.value.targetMs : null;
    // Burst-gated: an expired burst leaves a stale target that must not anchor
    // the press (see [stepBurstTimer]); the lock intent still covers an
    // in-flight seek.
    final int baseMs = stepIntent.value.baseFor(
        reportedMs: rawPosMs,
        lockIntentMs: pendingIntent,
        active: stepBurstTimer.value != null);
    if (vm.isActive && item != null) {
      const handler = VirtualSeekHandler();
      // Tail policy on the VIRTUAL axis, BEFORE `resolveRelativeSeek` clamps the
      // target into the last segment: a press that reaches the merged item's end
      // finishes the item instead of being parked inside the last segment's
      // final GOP (the clamp reports `segDur - kSeekTailGuardMs`, which can
      // never raise `completed`).
      final int vmSegIdx = vm.state.segmentIndex;
      if (handler.segmentDurationKnown(item, vmSegIdx)) {
        final int vmSegDur = item.segments[vmSegIdx].durationMs ?? 0;
        final StepTailAction vmTail = decideStepTail(
          reportedMs: item.offsetOf(vmSegIdx) + baseMs.clamp(0, vmSegDur),
          deltaMs: deltaMs,
          durationMs: item.totalDurationMs,
          mode: stepTailFinishMode,
          playing: isPlaying,
        );
        if (vmTail != StepTailAction.step) {
          await applyTailStep(
            vmTail,
            Duration(milliseconds: item.totalDurationMs),
            // `applyTailStep` forwards the target to `seek()`, which resolves
            // on the VIRTUAL axis: put the segment's offset back (see
            // [vmTailStepTargetMs]) instead of handing over the local ms.
            vmTailStepTargetMs(
              segmentOffsetMs: item.offsetOf(vmSegIdx),
              baseMs: baseMs,
              deltaMs: deltaMs,
              segmentDurationMs: vmSegDur,
            ),
          );
          return;
        }
      }
      final target = handler.resolveRelativeSeek(
        item,
        segmentIndex: vm.state.segmentIndex,
        localMs: baseMs,
        deltaMs: deltaMs,
      );
      // An unresolvable move (no probed duration on the target segment) must NOT
      // be turned into a step: the degenerate 0 used to be persisted over the
      // file's saved progress (「进度归 0」). Drop a previous press's OSD target
      // too (see [stepOsdTargetMs]).
      if (target == null) {
        stepOsdTargetMs.value = null;
        // Drop the accumulation too: a press that resolved nothing must not
        // leave a stale base (and a live burst window) for the next press.
        stepBurstTimer.value?.cancel();
        stepBurstTimer.value = null;
        stepIntent.value.reset();
        return;
      }
      await seek(Duration(milliseconds: target.virtualMs), 'step');
      return;
    }
    final totalMs = controller.value.value.duration.inMilliseconds;
    if (totalMs <= 0) {
      stepOsdTargetMs.value = null;
      return;
    }
    // Tail policy: a press whose target reaches the end finishes the item while
    // playing and is held while paused. It must run BEFORE the clamp below — a
    // step can never finish the item on its own, because mdk serves a key-frame
    // target it cannot reach with "the last key frame of media" (the visible
    // rollback), and `lastSeekableMs` stops 100 ms short of the end anyway.
    final StepTailAction tail = decideStepTail(
      reportedMs: baseMs,
      deltaMs: deltaMs,
      durationMs: totalMs,
      mode: stepTailFinishMode,
      playing: isPlaying,
    );
    if (tail != StepTailAction.step) {
      final int lastMs = lastSeekableMs(totalMs);
      await applyTailStep(
        tail,
        Duration(milliseconds: totalMs),
        (baseMs + deltaMs).clamp(0, lastMs),
      );
      return;
    }
    // Unlike the media_kit backend the target IS clamped into the media: mdk has
    // no relative seek, and a key-frame seek whose target runs past the media end
    // is served with "the last key frame of media" (`generated_bindings` `seek`
    // doc) — a straight jump back to the final GOP, i.e. the very rollback the mpv
    // backend avoids by forwarding an unclamped delta. Bounding the target here
    // and letting `seek()` take the EXACT path inside the tail window (see
    // [fvpStepNeedsExactSeek]) keeps the landing forward and honest.
    final int lastMs = lastSeekableMs(totalMs);
    final target = (baseMs + deltaMs).clamp(0, lastMs);
    await seek(Duration(milliseconds: target), 'step');
  }

  Future<void> backward(int seconds) async => seekRelative(-seconds * 1000);

  Future<void> forward(int seconds) async => seekRelative(seconds * 1000);

  Future<void> stepBackward() async {
    if (file?.type == ContentType.video) {
      // PotPlayer parity: entering frame mode pauses first, then steps.
      // Must also clear autoPlay so the scenario-resume effect does not
      // immediately re-play (全平台：按帧后保持暂停，长按多帧松手仍暂停).
      await useAppStore().updateAutoPlay(false);
      await controller.value.pause();
      await controller.value.step(frames: -1);
      areaKeyLog.i('Step backward');
    }
  }

  Future<void> stepForward() async {
    if (file?.type == ContentType.video) {
      // PotPlayer parity: entering frame mode pauses first, then steps.
      await useAppStore().updateAutoPlay(false);
      await controller.value.pause();
      await controller.value.step(frames: 1);
      areaKeyLog.i('Step forward');
    }
  }

  Future<void> saveProgress() async {
    if (isAndroid &&
        globals.initUri == file?.uri &&
        globals.initUri != null &&
        globals.initUri!.startsWith('content://')) {
      return;
    }

    if (file != null && controller.value.value.duration != Duration.zero) {
      // Position-intent lock (see the file-change cleanup): pausing / leaving
      // before the locked target lands would persist a pre-land sample.
      if (positionLock.value.blocksWrites) {
        diagLog.d(
            'persist skipped (locked phase=${positionLock.value.phase.name} target=${positionLock.value.targetMs}) file=${file.name} pos=${controller.value.value.position.inMilliseconds}ms');
        return;
      }
      final rawPosMs = controller.value.value.position.inMilliseconds;
      final durMs = controller.value.value.duration.inMilliseconds;
      final posMs = sanePlaybackPos(
        lastSanePosMs.value,
        rawPosMs,
        durMs,
        userSeeked: userSeekPending.value,
        inFlightTargetMs: positionLock.value.blocksWrites
            ? positionLock.value.targetMs
            : null,
      );
      final sanePosition = Duration(milliseconds: posMs);
      areaKeyLog.i('Save progress: ${file.name}, position: $sanePosition, duration: ${controller.value.value.duration}');
      await persistPlaybackProgress(
        file: file,
        position: sanePosition,
        durationMs: durMs,
        userSeekToHead: userSeekPending.value && posMs == 0,
        writeTag: 'saveProgress',
      );
      lastProgressWrite.value = DateTime.now();
      lastWrittenPosMs.value = posMs;
      lastSanePosMs.value = posMs;
      useHistoryStore().add(Progress(
        dateTime: DateTime.now().toUtc(),
        position: sanePosition,
        duration: controller.value.value.duration,
        file: file,
      ));
    }
  }

  // Dispose-time save: capture the LATEST saveProgress closure each build —
  // the mount-time closure would persist the CURRENT position onto the FIRST
  // file's row (cross-file clobber).
  final latestSaveProgress = useRef(saveProgress);
  latestSaveProgress.value = saveProgress;
  useEffect(() => () => latestSaveProgress.value(), []);

  // Desktop shutdown: the window close tears the engine down without
  // unmounting the tree, so the cleanups above never run. Register so the
  // close can save + dispose the controller before the isolate dies (see
  // [AppShutdown]).
  useEffect(() {
    final unregisterQuiesce = AppShutdown.registerQuiesce(() async {
      if (controller.value.value.isInitialized) {
        await controller.value.pause();
      }
    });
    final unregisterSave = AppShutdown.registerSave(
      () => latestSaveProgress.value(),
    );
    final unregisterDispose = AppShutdown.registerDisposer(() async {
      if (controller.value.value.isInitialized) {
        controller.value.dispose();
      }
    });
    return () {
      unregisterDispose();
      unregisterSave();
      unregisterQuiesce();
    };
  }, []);

  // Virtual Media timeline translation (spec §4.2).
  final vmCtrlF = VirtualMediaController.instance;
  final isVmF = vmCtrlF.isActive;
  // Stale-session self-heal (mirrors the media_kit hook): clear a store item
  // that is no longer the active session so progress surfaces drop the
  // phantom dual time / segment marks after a direct normal-file open.
  final vmStaleF = vmCtrlF.state.item != null && !isVmF;
  useEffect(() {
    if (vmStaleF) vmCtrlF.reconcileStaleSession();
    return null;
  }, [vmStaleF]);
  final vmDurF = isVmF
      ? Duration(milliseconds: vmCtrlF.totalDurationMs)
      : duration;
  // While a switch is in flight the new file reports 0% pre-seek: freeze
  // the exposed position on the jump target instead of flashing backward.
  final vmFrozenF = isVmF &&
      vmCtrlF.state.transitioning &&
      vmCtrlF.state.pendingSeekMs != null;
  final vmPosF = isVmF
      ? (vmFrozenF
          ? Duration(
              milliseconds: vmCtrlF.currentOffsetMs +
                  (vmCtrlF.state.pendingSeekMs ?? 0))
          : vmCtrlF.translatePosition(position))
      : position;
  // Gated on the position lock: while a target is pending/locked the raw
  // position is a pre-land sample — feeding it to the controller would
  // pollute the anchor flush with the leaving file's offset.
  if (isVmF && !positionLock.value.blocksWrites) {
    vmCtrlF.noteTick(position.inMilliseconds);
  }
  // Raw buffered end is local to the current segment; map it onto the
  // virtual total so the bar and the duration share one axis.
  final rawBufferedEndF = buffered.isEmpty
      ? Duration.zero
      : buffered.reduce((max, curr) => curr.end > max.end ? curr : max).end;
  final vmBufferF = isVmF && vmCtrlF.state.item != null
      ? Duration(
          milliseconds: const VirtualSeekHandler().virtualBufferMs(
            vmCtrlF.state.item!,
            segmentIndex: vmCtrlF.state.segmentIndex,
            rawBufferMs: rawBufferedEndF.inMilliseconds,
          ))
      : rawBufferedEndF;

  // Central drag-release commit (spec §6): a stashed cross-segment target
  // (preview strategy, or a throttled direct tick) lands exactly once when
  // the drag ends. Covers every slider — none needs its own commit path.
  // The re-invoked seek re-gates with dragging=false, so it always acts.
  final dragActiveF = useScrubDragStore().select(context, (s) => s.any);
  useEffect(() {
    if (!dragActiveF) {
      // Drag ended: land the collapsed trailing progress write immediately.
      flushUserSeekBurst();
      final stashed = VirtualMediaController.instance.takeDragTarget();
      if (stashed != null &&
          VirtualMediaController.instance.isActive) {
        // The release carries the finish intent: a VM drag to 100% must land
        // ON the merged item's end through the same 99% rule as the single-file
        // path — the plain `seek` clamp would stop at `segDur - guard` and the
        // linear bar could never advance.
        final int vmTotal =
            VirtualMediaController.instance.state.item?.totalDurationMs ?? 0;
        diagLog.d('[bg-scrub] drag-release commit stashed=$stashed');
        seek(Duration(milliseconds: stashed), 'release-commit',
            vmReleaseSeekIntent(stashed, vmTotal));
      }
    }
    return;
  }, [dragActiveF]);

  // Media identity changed: a pending burst write must still reach the file it
  // was recorded for (mirror of the media_kit hook).
  final mediaUriF = file?.uri;
  useEffect(() {
    flushUserSeekBurst();
    resetStepBurst();
    lastUserSeekWrite.value = null;
    return;
  }, [mediaUriF]);

  // Unmount: cancel the debounce/step-burst timers and land the last pending
  // write. (Mirror of the media_kit hook's unmount dispose, which the
  // body-form effect there was silently skipping.)
  useEffect(() {
    return () {
      resetStepBurst();
      flushUserSeekBurst();
    };
  }, []);

  final fvpPlayer = useMemoized(
    () => FvpPlayer(
      controller: controller.value,
      isInitializing: isInitializing.value,
      isPlaying: isPlaying,
      externalSubtitle: externalSubtitle,
      externalSubtitles: externalSubtitles,
      position:
          !controller.value.value.isInitialized || vmDurF == Duration.zero
              ? Duration.zero
              : clampPositionToMedia(vmPosF, vmDurF),
      duration: controller.value.value.isInitialized ? vmDurF : Duration.zero,
      buffer: !controller.value.value.isInitialized || vmDurF == Duration.zero
          ? Duration.zero
          : vmBufferF,
      width: width,
      height: height,
      play: play,
      pause: pause,
      backward: backward,
      forward: forward,
      stepBackward: stepBackward,
      stepForward: stepForward,
      seek: seek,
      finishSeek: (target) =>
          seek(target, 'release-commit', SeekIntent.finishAtEnd),
      saveProgress: saveProgress,
      stepIntentTargetMs: () => stepOsdTargetMs.value,
    ),
    [
      controller.value,
      controller.value.value.isInitialized,
      isInitializing.value,
      isPlaying,
      externalSubtitle.value,
      externalSubtitles,
      position,
      duration,
      vmPosF,
      vmDurF,
      vmBufferF,
      buffered,
      width,
      height,
      play,
      pause,
      seek,
      backward,
      forward,
      stepBackward,
      stepForward,
      saveProgress,
    ],
  );

  // AB-loop engine binding: lifecycle-driven so backend swaps rebind and a
  // disposed player never leaves a zombie loop (see AbLoopEngine). The fvp
  // wrapper exposes no position stream, so the engine polls the LIVE
  // controller through this closure every 250 ms. Declared last so its
  // cleanup runs FIRST on unmount, before controller.dispose().
  useEffect(() {
    AbLoopEngine.instance.attach(
      player: fvpPlayer,
      pollSource: () => controller.value.value.position,
    );
    return AbLoopEngine.instance.detach;
  }, []);

  return fvpPlayer;
}


