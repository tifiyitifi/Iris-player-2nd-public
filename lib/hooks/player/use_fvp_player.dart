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
import 'package:iris/hooks/player/advance_play_queue_on_completed.dart';
import 'package:iris/hooks/player/media_info_writeback.dart';
import 'package:iris/hooks/player/seek_clamp.dart';
import 'package:iris/hooks/player/seek_tuning.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/progress.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/features/scenario_playback/playback/playback_progress.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
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

  useEffect(() {
    () async {
      if (file != null &&
          controller.value.value.isCompleted &&
          controller.value.value.position != Duration.zero &&
          controller.value.value.duration != Duration.zero) {
        if (useScrubDragStore().state.any) {
          diagLog.d('completed suppressed hold/seek');
          usePlayerUiStore().updatePendingCompleted(true);
          return;
        }
        // A-B editor open: locked to the CURRENT media — no segment switch and
        // no queue advance. Pause and wait for the user.
        if (SegmentEditGuard.transportFrozen) {
          controller.value.pause();
          return;
        }
        if (await VirtualMediaController.instance.maybeHandleCompleted()) {
          return;
        }
        // CLOSE_DEBUG_LOG
        diagLog.d(
            'completed fired pos=${controller.value.value.position.inMilliseconds}ms dur=${controller.value.value.duration.inMilliseconds}ms file=${file.name} repeat=$repeat curIdx=$currentPlayIndex total=${playQueue.length}');
        areaKeyLog.i('Completed: ${file.name}');
        persistPlaybackProgress(
          file: file,
          position: controller.value.value.position,
          completed: true,
          writeTag: 'completed',
        );
        lastProgressWrite.value = DateTime.now();
        lastWrittenPosMs.value =
            controller.value.value.position.inMilliseconds;
        if (repeat == Repeat.one) return;
        final handled = await PlaybackProviderRegistry.advanceOnComplete(repeat);
        // CLOSE_DEBUG_LOG
        diagLog.d('completed advance handled=$handled');
        if (handled) return;
        await advancePlayQueueOnCompleted(repeat);
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
        final wasCompleted = await readPlaybackCompleted(file);
        // CLOSE_DEBUG_LOG
        diagLog.d(
            'resume eval wasCompleted=$wasCompleted alwaysFromBeginning=$alwaysPlayFromBeginning vmTargeted=$vmTargeted');
        if ((wasCompleted || alwaysPlayFromBeginning) && !vmTargeted) {
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
      } catch (e) {
        gate.unmark(key);
        areaKeyLog.e('Error saving media info to DB: $e');
      }
    }();
    return null;
  }, [controller.value.value.duration, controller.value.value.size, mediaInfoKey]);

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
      usePlaybackProgressStore().update(fileId, posMs, durMs);

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
          controller.value.value.duration != Duration.zero) {
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

  // Attribution-only [src]: see the media_kit hook — log only, the
  // tear-off still satisfies `Future<void> Function(Duration)`.
  Future<void> seek(Duration newPosition, [String src = 'player']) async {
    // An absolute jump re-anchors the NEXT relative step on the fresh
    // position; a cross-segment step re-anchors below (its local axis
    // changes). Only 'step' keeps the accumulation alive.
    if (src != 'step') {
      stepIntent.value.reset();
      stepOsdTargetMs.value = null;
    }
    // Step seeks land on a KEYFRAME (mpv-native parity, see
    // [fvpStepUsesKeyframeSeek]); everything else needs the exact landing.
    final bool keyframe = fvpStepUsesKeyframeSeek(src);
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
          final clamped =
              clampVmLocalMs(item.segments[segIdx].durationMs, localMs);
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
          await (keyframe
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
            await vm.jumpToSegment(segIdx, localMs: localMs);
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
    final target = clampSeekTarget(newPosition, totalMs);
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
        observedMs: controller.value.value.position.inMilliseconds,
      ),
    ));
    await (keyframe
        ? controller.value.fastSeekTo(target)
        : controller.value.seekTo(target));
  }

  /// Relative skip on the VIRTUAL timeline (ms precision, clamped).
  /// See the media_kit hook for the coordinate rationale.
  Future<void> seekRelative(int deltaMs) async {
    final vm = VirtualMediaController.instance;
    final item = vm.state.item;
    final rawPosMs = controller.value.value.position.inMilliseconds;
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
        diagLog.d('[bg-scrub] drag-release commit stashed=$stashed');
        seek(Duration(milliseconds: stashed), 'release-commit');
      }
    }
    return;
  }, [dragActiveF]);

  // Media identity changed: a pending burst write must still reach the file it
  // was recorded for (mirror of the media_kit hook).
  final mediaUriF = file?.uri;
  useEffect(() {
    flushUserSeekBurst();
    stepBurstTimer.value?.cancel();
    stepBurstTimer.value = null;
    stepIntent.value.reset();
    stepOsdTargetMs.value = null;
    lastUserSeekWrite.value = null;
    return;
  }, [mediaUriF]);

  // Unmount: cancel the debounce/step-burst timers and land the last pending
  // write. (Mirror of the media_kit hook's unmount dispose, which the
  // body-form effect there was silently skipping.)
  useEffect(() {
    return () {
      stepBurstTimer.value?.cancel();
      stepBurstTimer.value = null;
      stepIntent.value.reset();
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
              : vmPosF,
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


