import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
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
import 'package:iris/hooks/player/seek_clamp.dart';
import 'package:iris/hooks/player/seek_tuning.dart';
import 'package:iris/features/meta_settings/engine/video_cache_preset.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
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
import 'package:iris/utils/check_data_source_type.dart';
import 'package:iris/features/webdav_discovery/services/webdav_playback_uri.dart';
import 'package:iris/features/webdav_discovery/view/webdav_playback_error_dialog.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/utils/platform.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:media_stream/media_stream.dart';
import 'package:path_provider/path_provider.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyPlayer);
// CLOSE_DEBUG_LOG: playback diagnostics for the "jumps to end" investigation.
final diagLog = AreaKeyLog(LogKeys.player);

MediaKitPlayer useMediaKitPlayer(BuildContext context) {
  final player = useMemoized(
    () => Player(
      configuration: const PlayerConfiguration(
        libass: true,
      ),
    ),
  );

  final controller = useMemoized(() => VideoController(player));

  final rate = useAppStore().select(context, (state) => state.rate);
  final volume = useAppStore().select(context, (state) => state.volume);
  final isMuted = useAppStore().select(context, (state) => state.isMuted);
  // 副音 volume policy: while background playback is on the foreground
  // engine plays at master × the effective fg ratio (default 30%); off =
  // verbatim. The ratio resolves per foreground media (sub_media §5.5).
  final bgVolume = useBackgroundVolumeContext(context);
  final bgActive = bgVolume.active;
  final fgVolumePercent = bgVolume.ratio.fgPercent;
  final fgMuted = bgVolume.fgMuted;

  // Reactive dep for the mpv seek/cache tuning effect below (value itself is
  // read live inside the effect).
  final videoCachePreset =
      useAppStore().select(context, (state) => state.videoCachePreset);

  useEffect(() {
    () async {
      player.setSubtitleTrack(SubtitleTrack.no());
      player.setRate(rate);
      player.setVolume(BackgroundVolumePolicy
          .foregroundEngineVolume(
            master: volume,
            muted: isMuted,
            bgActive: bgActive,
            fgPercent: fgVolumePercent,
            fgMuted: fgMuted,
          )
          .toDouble());

      if (Platform.isAndroid) {
        NativePlayer nativePlayer = player.platform as NativePlayer;

        final appSupportDir = await getApplicationSupportDirectory();
        final String fontsDir = "${appSupportDir.path}/fonts";

        final Directory fontsDirectory = Directory(fontsDir);
        if (!await fontsDirectory.exists()) {
          await fontsDirectory.create(recursive: true);
          areaKeyLog.i('fonts directory created');
        }

        final File file = File("$fontsDir/NotoSansCJKsc-Medium.otf");
        if (!await file.exists()) {
          final ByteData data =
              await rootBundle.load("assets/fonts/NotoSansCJKsc-Medium.otf");
          final Uint8List buffer = data.buffer.asUint8List();
          await file.create(recursive: true);
          await file.writeAsBytes(buffer);
          areaKeyLog.i('NotoSansCJKsc-Medium.otf copied');
        }

        await nativePlayer.setProperty("sub-fonts-dir", fontsDir);
        await nativePlayer.setProperty("sub-font", "NotoSansCJKsc-Medium");
      }
    }();
    return () {
      player.dispose();
    };
  }, []);

  // mpv seek/cache tuning. media_kit pins `hr-seek-framedrop=no` (mpv decodes
  // AND displays every frame from the previous keyframe to the target, which
  // reads as laggy fast-forward/rewind) and clamps the demuxer caches to
  // 32MiB. Re-assert IRIS's values here; the dep makes a cache-preset change
  // take effect immediately, without reopening the video.
  useEffect(() {
    final platform = player.platform;
    if (platform is! NativePlayer) return null;
    final state = useAppStore().state;
    final preset = resolveVideoCachePreset(
      state,
      metadataEnabled: state.useMetadataSettings && MetaSettingsModule.ready,
    );
    unawaited(applyMpvSeekTuning(
      platform,
      cacheMaxBytes: preset.maxBytes,
      cacheBackBytes: preset.backBytes,
    ));
    return null;
  }, [videoCachePreset]);

  final List<PlayQueueItem> playQueue =
      usePlayQueueStore().select(context, (state) => state.playQueue);
  final int currentIndex =
      usePlayQueueStore().select(context, (state) => state.currentIndex);
  final appStore = useAppStore();
  final bool autoPlay = appStore.select(context, (state) => state.autoPlay);
  final bool useScenario = appStore.select(context,
      (s) => !s.useLegacyStoragePersistence && s.useScenarioDrivenPlayback);
  final scenarioRepeat =
      usePlaybackScenarioStore().select(context, (s) => s.activeScenarioRepeat);
  final Repeat repeat = useScenario
      ? scenarioRepeat
      : appStore.select(context, (state) => state.repeat);
  final bool alwaysPlayFromBeginning =
      appStore.select(context, (state) => state.alwaysPlayFromBeginning);

  final history = useHistoryStore().select(context, (state) => state.history);

  final int currentPlayIndex = useMemoized(
      () => playQueue.indexWhere((element) => element.index == currentIndex),
      [playQueue, currentIndex]);

  final FileItem? file = useMemoized(
      () => playQueue.isEmpty || currentPlayIndex < 0
          ? null
          : playQueue[currentPlayIndex].file,
      [playQueue, currentPlayIndex]);

  final playingStream = useMemoized(() => player.stream.playing, []);
  bool playing = useStream(playingStream).data ?? false;

  final videoParamsStream = useMemoized(() => player.stream.videoParams, []);
  VideoParams? videoParams = useStream(videoParamsStream).data;

  // AudioParams? audioParams = useStream(player.stream.audioParams).data;

  final positionStream = useMemoized(() => player.stream.position, []);
  final position = useStream(positionStream).data ?? Duration.zero;

  final durationStream = useMemoized(() => player.stream.duration, []);
  Duration duration = useStream(durationStream).data ?? Duration.zero;

  final bufferStream = useMemoized(() => player.stream.buffer, []);
  Duration buffer = useStream(bufferStream).data ?? Duration.zero;

  final completedStream = useMemoized(() => player.stream.completed, []);
  bool completed = useStream(completedStream).data ?? false;

  // double rate = useStream(player.stream.rate).data ?? 1.0;

  final trackStream = useMemoized(() => player.stream.track, []);
  Track? track = useStream(trackStream).data;
  AudioTrack audio =
      useMemoized(() => track?.audio ?? AudioTrack.no(), [track?.audio]);
  SubtitleTrack subtitle = useMemoized(
      () => track?.subtitle ?? SubtitleTrack.no(), [track?.subtitle]);

  final tracksStream = useMemoized(() => player.stream.tracks, []);
  Tracks? tracks = useStream(tracksStream).data;
  List<AudioTrack> audios =
      useMemoized(() => (tracks?.audio ?? []), [tracks?.audio]);
  List<SubtitleTrack> subtitles = useMemoized(
      () => [...(tracks?.subtitle ?? [])]
        ..removeWhere((subtitle) => subtitle == SubtitleTrack.auto()),
      [tracks?.subtitle]);

  final List<Subtitle>? externalSubtitles = useMemoized(
      () => [...file?.subtitles ?? []]..removeWhere(
          (subtitle) => subtitles.any((item) => item.title == subtitle.name)),
      [file?.subtitles, subtitles]);

  final isInitializing = useState(false);

  MediaStream mediaStream = useMemoized(() => MediaStream(), []);

  // CLOSE_DEBUG_LOG: samples position/duration shortly after each open to
  // distinguish "jumps to end immediately" from "jumps after a resume seek".
  final watchdog = useRef<Timer?>(null);

  /// Live-progress DB throttle: last DB write time and position (events reset
  /// the 10s window; the per-second timer writes the media column at most every
  /// 10s so crash-resume is at most ~10s stale).
  final lastProgressWrite = useRef<DateTime?>(null);
  final lastWrittenPosMs = useRef<int?>(null);

  /// Position sanitizer: last accepted (monotonic, in-range) position for the
  /// current file, and a flag raised by a user seek (seek/forward/backward/step)
  /// that resets the guard so genuine jumps are accepted.
  final lastSanePosMs = useRef<int?>(null);
  final userSeekPending = useRef<bool>(false);

  /// Feed generation captured by [init] at open time. A duration arrival that
  /// happens after the controller has moved on to a NEWER feed belongs to a
  /// superseded open (double-open race) and must not clear the switch freeze.
  final openVmFeedGen = useRef<int?>(null);

  /// Per-open resume gate: after an open the player reports pre-seek head
  /// samples (~533ms) until the position-intent lock observes a landing.
  /// Persist + History writes are skipped while locked so a next/prev
  /// tap inside the window cannot clobber the real stored progress.
  final positionLock = useRef(PlaybackPositionLock());

  /// Late-bound (the step-seek chain lives further down, next to the burst
  /// block): the position stream reports landings to whatever handler is
  /// installed, so the chain can release its next queued step.
  final stepChainOnPosition = useRef<void Function(int)?>(null);

  Future<void> init(FileItem file) async {
    if (file.uri == '') return;
    isInitializing.value = true;
    // CLOSE_DEBUG_LOG: vm double-open / back-to-0% investigation. Capture the
    // controller's feed generation at open time so a duration arrival from a
    // superseded open (double-open race) can be recognized and dropped.
    openVmFeedGen.value = VirtualMediaController.instance.feedGeneration;

    try {
      final storage = useStorageStore().findById(file.storageId);
      final auth = storage?.getAuth();
      // CLOSE_DEBUG_LOG
      diagLog.d(
          'open uri=${file.uri} type=${file.storageType} autoPlay=$autoPlay path=${file.path}');
      areaKeyLog.i('Open file: $file');
      // Hook-level fallback: repair the known-broken '/X:/...' shape before
      // it reaches mpv; remote forms pass through untouched. Remove once every
      // producer emits playableUri() natively.
      final needsLocalRepair =
          checkDataSourceType(file) == DataSourceType.file;

      // A wildcard WebDAV entry whose host was never resolved would dial
      // `192.168.*.*`. Resolve once and rebuild the address from the storage
      // record; if that fails, explain it instead of opening nothing.
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

      // VM feeds are ordinary single-file opens: the controller pre-writes
      // the landing position to media_nodes BEFORE this open, and the shared
      // duration-arrival resume below lands it — no VM-specific open mode.
      await player.open(
        Media(
          file.storageType == StorageType.ftp
              ? '${mediaStream.url}/$playUri'
              : needsLocalRepair
                  ? sanitizePlayableUri(playUri)
                  : playUri,
          httpHeaders: auth != null ? {'authorization': auth} : {},
        ),
        play: autoPlay,
      );
      // CLOSE_DEBUG_LOG
      diagLog.d(
          'opened pos=${player.state.position.inMilliseconds}ms dur=${player.state.duration.inMilliseconds}ms playing=${player.state.playing}');

      // CLOSE_DEBUG_LOG: sample pos/dur at 1s for the first ~5s after open.
      // The @+Ns wall-clock marker distinguishes "main thread blocked" (tick
      // fires late, position advanced a lot) from a real position jump.
      final watchStart = DateTime.now();
      watchdog.value?.cancel();
      watchdog.value = Timer.periodic(const Duration(seconds: 1), (t) {
        final posMs = player.state.position.inMilliseconds;
        final durMs = player.state.duration.inMilliseconds;
        diagLog.d(
            'watch t=${t.tick} @+${DateTime.now().difference(watchStart).inSeconds}s pos=${posMs}ms dur=${durMs}ms playing=${player.state.playing}');
        if (t.tick >= 5) t.cancel();
      });
    } catch (e) {
      // CLOSE_DEBUG_LOG
      diagLog.w('open error: $e');
      areaKeyLog.e('Error initializing player: $e');
      // Fail-open: a failed open never lands its locked target.
      positionLock.value.unlock();
    } finally {
      isInitializing.value = false;
    }
  }

  useEffect(() {
    if (file == null || playQueue.isEmpty) {
      player.stop();
    } else {
      // Position-intent lock: writes stay blocked from the open until the
      // resume/VM/user target has been observed ONCE (not merely issued).
      positionLock.value.armPending();
      init(file);
    }
    return () {
      if (isAndroid &&
          globals.initUri == file?.uri &&
          globals.initUri != null &&
          globals.initUri!.startsWith('content://')) {
        return;
      }

      if (file != null && player.state.duration != Duration.zero) {
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
          // the resume seek has been OBSERVED at its target. A next/prev tap
          // inside that window must not persist a head sample over the real
          // stored progress — skip the write entirely (not a 0 write).
          if (positionLock.value.blocksWrites) {
            diagLog.d(
                'persist skipped (locked phase=${positionLock.value.phase.name} target=${positionLock.value.targetMs}) file=${file.name} pos=${player.state.position.inMilliseconds}ms');
            return;
          }
          final rawPosMs = player.state.position.inMilliseconds;
          final durMs = player.state.duration.inMilliseconds;
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
          areaKeyLog.i('Save progress: ${file.name}, position: $sanePosition, duration: ${player.state.duration}');
          persistPlaybackProgress(
            file: file,
            position: sanePosition,
            durationMs: durMs,
            writeTag: 'cleanup',
          );
          lastProgressWrite.value = DateTime.now();
          lastWrittenPosMs.value = posMs;
          useHistoryStore().add(Progress(
            dateTime: DateTime.now().toUtc(),
            position: sanePosition,
            duration: player.state.duration,
            file: file,
          ));
        }
      }
    };
  }, [file]);

  // Scenario resume: when a same-scenario re-play re-feeds the SAME file
  // (value-equal FileItem), the [file] init effect above does not re-run, so
  // player.open(play: autoPlay) never fires and a paused video stays paused.
  // autoPlay flipping false→true is the only signal that survives; resume
  // playback here. Declared after the [file] effect so a NEW file's init sets
  // isInitializing synchronously first and this skips (no stale-media blip).
  useEffect(() {
    // Shutdown fence: the window close keeps this tree mounted, and the
    // quiesce pause flips [playing] false — which would wake this effect into
    // `play()` on a player mid-dispose (media_kit asserts "[Player] has been
    // disposed"). Teardown never restarts playback.
    if (AppShutdown.isActive) return;
    if (useScenario &&
        autoPlay &&
        file != null &&
        !isInitializing.value &&
        !playing &&
        !completed) {
      player.play();
    }
    return;
  }, [
    useScenario,
    autoPlay,
    file,
    isInitializing.value,
    playing,
    completed,
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
          await player.seek(Duration(milliseconds: target));
        }
      } else if (timeout == PositionLockTimeoutAction.released) {
        // CLOSE_DEBUG_LOG
        diagLog.d('lock timeout released file=${current.name}');
      }
      if (player.state.duration == Duration.zero) return;
      final rawPosMs = player.state.position.inMilliseconds;
      final durMs = player.state.duration.inMilliseconds;
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
        diagLog.d(
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
        // completed deliberately omitted: an ordinary live save must never
        // clobber a just-set finished marker (a repeat-one file parked at its
        // tail would otherwise flip back to unfinished and re-jump on reopen).
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
      if (player.state.duration != Duration.zero) {
        final raw = player.state.position.inMilliseconds;
        final dur = player.state.duration.inMilliseconds;
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

  // CLOSE_DEBUG_LOG: capture media_kit decode/backend errors (previously
  // unlistened) — a failing file may end without emitting `completed`.
  final errorStream = useMemoized(() => player.stream.error, []);
  useEffect(() {
    final sub = errorStream.listen((e) {
      diagLog.w('player.error: $e');
      // Virtual Media: a broken segment is skipped, session survives.
      if (VirtualMediaController.instance.isActive) {
        VirtualMediaController.instance.handleSegmentError();
      }
      // Fail-open: a broken open can never land its locked target — release
      // the write block so this file's own saves resume on the error path.
      positionLock.value.unlock();
    });
    return () => sub.cancel();
  }, [errorStream]);

  // Position-intent lock landing check: the player must be OBSERVED once at
  // /near the locked target before writes resume — issuing the seek is not
  // enough (a failed/late seek used to leave the write window open).
  useEffect(() {
    final sub = positionStream.listen((p) {
      final int posMs = p.inMilliseconds;
      if (positionLock.value.checkLanding(
          posMs, player.state.duration.inMilliseconds)) {
        // CLOSE_DEBUG_LOG (no file here: the stream listener's closure can
        // lag the current file — pos/target identify the landing).
        diagLog.d(
            'lock landed pos=${posMs}ms target-reached phase=unlocked');
      }
      // Step burst: the chain issues its next target only from a landing.
      stepChainOnPosition.value?.call(posMs);
    });
    return () => sub.cancel();
  }, [positionStream]);

  // CLOSE_DEBUG_LOG: cancel the position watchdog on dispose.
  useEffect(() {
    return () => watchdog.value?.cancel();
  }, []);

  useEffect(() {
    () async {
      if (duration == Duration.zero) {
        await player.setSubtitleTrack(SubtitleTrack.no());
        return;
      }
      // CLOSE_DEBUG_LOG
      diagLog.d('durationArrived dur=${duration.inMilliseconds}ms file=${file?.name}');
      if (file == null || file.type != ContentType.video) {
        // Non-video opens have no resume decision: unblock persistence so
        // audio saves keep working exactly as before.
        positionLock.value.unlock();
      }
      if (file != null && file.type == ContentType.video) {
        final vmCtrlDur = VirtualMediaController.instance;
        // VM feeds open like any ordinary single file: the controller
        // pre-wrote the landing position (jump target, or 0 for sequential
        // advance) into media_nodes BEFORE this open, and the shared
        // DB-authoritative resume below lands it — exactly the mechanism a
        // real single video uses for its last progress. The only VM touch
        // point left here is the switch-freeze bookkeeping.
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
          final (decision, resumeAt) =
              resolveOpenResume(dbPos, duration.inMilliseconds, budget);
          // CLOSE_DEBUG_LOG: logged unconditionally — the previously silent
          // branches (fromBeginningExplicit / empty history) must be
          // attributable from the same repro log.
          diagLog.d('resume decision=$decision dbPos=$dbPos budget=$budget '
              'target=$resumeAt dur=${duration.inMilliseconds}ms file=${file.name}');
          switch (decision) {
            case OpenResumeDecision.seekDb:
              areaKeyLog.i('Resume DB progress: ${file.name} position: $resumeAt');
              // Lock BEFORE issuing the seek: landing checks run on the
              // position stream, which can fire before the seek await
              // completes.
              positionLock.value.armTarget(resumeAt);
              await player.seek(Duration(milliseconds: resumeAt));
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
                await player.seek(progress.position);
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
      }
      // 设置字幕
      if (externalSubtitles!.isNotEmpty) {
        areaKeyLog.i('Set external subtitle: ${externalSubtitles[0]}');
        final uri = file?.storageType == StorageType.ftp
            ? '${mediaStream.url}/${externalSubtitles[0].uri}'
            : externalSubtitles[0].uri;
        areaKeyLog.i('External subtitle uri: $uri');
        await player.setSubtitleTrack(
          SubtitleTrack.uri(
            uri,
            title: externalSubtitles[0].name,
          ),
        );
      } else if (subtitles.length > 1) {
        areaKeyLog.i('Set subtitle: ${subtitles[1].title ?? subtitles[1].language ?? subtitles[1].id}');
        await player.setSubtitleTrack(subtitles[1]);
      } else {
        await player.setSubtitleTrack(SubtitleTrack.no());
      }
    }();
    return;
  }, [duration]);

  // Write duration + probed dimensions to media_nodes DB when they first
  // become available (lazy probe backfill: playing a file fills any gaps
  // left by an unprobed scan).
  final durationSaved = useState(false);
  final dimsSaved = useState(false);
  useEffect(() {
    if (file == null) return null;
    final vp = videoParams;
    final vpW = vp?.w ?? 0;
    final vpH = vp?.h ?? 0;
    final needDuration = duration != Duration.zero && !durationSaved.value;
    final needDims = vpW > 0 && vpH > 0 && !dimsSaved.value;
    if (!needDuration && !needDims) return null;
    if (needDuration) durationSaved.value = true;
    if (needDims) dimsSaved.value = true;
    // Immediate live-progress seed: the progress UIs read the in-memory store
    // keyed by fileId, so give them the just-parsed duration right away
    // instead of waiting for the next 1s timer tick.
    if (needDuration) {
      usePlaybackProgressStore().update(
        // file.getID(),  // legacy: surface/platform-dependent uri key
        canonicalProgressKey(file.storageId, file.path,
            uri: file.uri), // unified
        player.state.position.inMilliseconds,
        duration.inMilliseconds,
      );
    }
    () async {
      try {
        final dbPath = file.path.join('/');
        if (dbPath.isNotEmpty) {
          await DbModule.mediaNodeRepo.updateFileMediaInfo(
            storageId: file.storageId,
            path: dbPath,
            durationMs:
                needDuration ? duration.inMilliseconds : null,
            width: needDims ? vpW : null,
            height: needDims ? vpH : null,
            pixelCount: needDims ? vpW * vpH : null,
          );
          areaKeyLog.i('Saved media info to DB: ${file.name} '
              'dur=${needDuration ? duration.inMilliseconds : "-"}ms');
        }
      } catch (e) {
        areaKeyLog.e('Error saving media info to DB: $e');
      }
    }();
    return null;
  }, [duration, videoParams?.w, videoParams?.h]);

  useEffect(() {
    () async {
      if (completed) {
        if (useScrubDragStore().state.any) {
          diagLog.d('completed suppressed hold/seek '
              'holding=${useScrubDragStore().state.isHolding} '
              'scrubbing=${useScrubDragStore().state.isScrubbing}');
          usePlayerUiStore().updatePendingCompleted(true);
          return;
        }
        // A-B editor open: the pair is locked to the CURRENT media — neither a
        // virtual segment switch nor a queue advance may happen. Pause on the
        // spot and wait for the user.
        if (SegmentEditGuard.transportFrozen) {
          diagLog.d('completed paused by segment-edit freeze');
          player.pause();
          return;
        }
        // Virtual Media session: segment end never reaches Context.next()
        // (spec §9.1). Repeat-one stays on the backend loop by design.
        if (await VirtualMediaController.instance.maybeHandleCompleted()) {
          return;
        }
        // CLOSE_DEBUG_LOG
        diagLog.d(
            'completed fired pos=${position.inMilliseconds}ms dur=${duration.inMilliseconds}ms file=${file?.name} repeat=$repeat mode=${useScenario ? 'scenario' : 'legacy'} curIdx=$currentPlayIndex total=${playQueue.length}');
        if (file != null && player.state.position != Duration.zero) {
          // Position guard (parity with the fvp hook): a spurious completed
          // at position 0 must not flag the file completed — that would
          // suppress every future resume (skip-resume branch).
          persistPlaybackProgress(
            file: file,
            position: player.state.position,
            completed: true,
            writeTag: 'completed',
          );
          lastProgressWrite.value = DateTime.now();
          lastWrittenPosMs.value = player.state.position.inMilliseconds;
        }
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
    return null;
  }, [completed, repeat]);

  // Flush suppressed completed when hold released.
  final pendingCompleted = usePlayerUiStore().select(context, (s) => s.pendingCompleted);
  final isHoldingDown = useScrubDragStore().select(context, (s) => s.isHolding);
  useEffect(() {
    if (!pendingCompleted || isHoldingDown) return;
    if (!shouldFlushSuppressedCompletion(
      pendingCompleted: pendingCompleted,
      holding: isHoldingDown,
      completed: completed,
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
        player.pause();
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
  }, [pendingCompleted, isHoldingDown, completed, repeat, currentPlayIndex, playQueue.length]);

  useEffect(() {
    player.setRate(rate);
    return;
  }, [rate]);

  useEffect(() {
    player.setVolume(BackgroundVolumePolicy
        .foregroundEngineVolume(
          master: volume,
          muted: isMuted,
          bgActive: bgActive,
          fgPercent: fgVolumePercent,
          fgMuted: fgMuted,
        )
        .toDouble());
    return;
  }, [volume, isMuted, bgActive, fgVolumePercent, fgMuted]);

  useEffect(() {
    areaKeyLog.i('$repeat');
    if (repeat == Repeat.one) {
      player.setPlaylistMode(PlaylistMode.loop);
    } else {
      player.setPlaylistMode(PlaylistMode.none);
    }
    return;
  }, [repeat]);

  useEffect(() {
    if (file?.type != ContentType.video) {
      usePlayerUiStore().updateAspectRatio(0);
      usePlayerUiStore().updateVideoSize(0, 0);
      return;
    }

    final width = videoParams?.w ?? 0;
    final height = videoParams?.h ?? 0;
    if (width == 0 || height == 0) {
      usePlayerUiStore().updateAspectRatio(0);
      usePlayerUiStore().updateVideoSize(0, 0);
    } else {
      usePlayerUiStore().updateAspectRatio(width / height);
      usePlayerUiStore().updateVideoSize(width.toDouble(), height.toDouble());
    }
    return;
  }, [file?.type, videoParams?.w, videoParams?.h]);

  Future<void> saveProgress() async {
    if (isAndroid &&
        globals.initUri == file?.uri &&
        globals.initUri != null &&
        globals.initUri!.startsWith('content://')) {
      return;
    }

    if (file != null && player.state.duration != Duration.zero) {
      // Position-intent lock (see the file-change cleanup): pausing / leaving
      // before the locked target lands would persist a pre-land sample.
      if (positionLock.value.blocksWrites) {
        diagLog.d(
            'persist skipped (locked phase=${positionLock.value.phase.name} target=${positionLock.value.targetMs}) file=${file.name} pos=${player.state.position.inMilliseconds}ms');
        return;
      }
      final rawPosMs = player.state.position.inMilliseconds;
      final durMs = player.state.duration.inMilliseconds;
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
      areaKeyLog.i('Save progress: ${file.name}, position: $sanePosition, duration: ${player.state.duration}');
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
        duration: player.state.duration,
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

  // Desktop shutdown: a window close tears the engine/isolate down WITHOUT
  // unmounting the tree, so the cleanups above never run — the player's native
  // (mpv) callbacks would outlive the isolate and crash the process on exit
  // (see [AppShutdown]). Register so the close can save + dispose first.
  useEffect(() {
    final unregisterQuiesce = AppShutdown.registerQuiesce(
      () => player.pause(),
    );
    final unregisterSave = AppShutdown.registerSave(
      () => latestSaveProgress.value(),
    );
    final unregisterDispose = AppShutdown.registerDisposer(
      () => player.dispose(),
    );
    return () {
      unregisterDispose();
      unregisterSave();
      unregisterQuiesce();
    };
  }, []);

  Future<void> play() async {
    if (useScenario && file == null) {
      // The player was fully stopped (feed cleared). Re-feed the ACTIVE
      // context — a tag view resumes inside its own list (never the scenario
      // item behind it), and a lost tag bookmark starts from the top.
      await PlaybackProviderRegistry.resumeActive();
    }
    if (duration == Duration.zero && file != null && !isInitializing.value) {
      await init(file);
    }
    await player.play();
  }

  Future<void> pause() async {
    await player.pause();
  }

  // ── Seek-burst control (fast-forward / rewind responsiveness) ──
  //
  // Only the PROGRESS WRITES are collapsed: a held arrow key (auto-repeat) or
  // a scrub drag would otherwise issue one UI-isolate Drift read+write per
  // repeat. The seeks themselves are issued one per press — collapsing them
  // would make the picture stand still and then jump once, instead of advancing
  // one step (one frame) per press and moving continuously while held. Each
  // seek is cheap because `applyMpvSeekTuning` restores
  // `hr-seek-framedrop=yes`.
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

  /// Leading + trailing progress write for one user-seek target. The leading
  /// write keeps the pre-seek durability contract; the trailing one collapses
  /// the rest of the burst so a held key no longer issues one Drift
  /// read+write per repeat.
  void persistUserSeekBurst(Duration target) {
    final FileItem? f = file;
    if (f == null) return;
    final w = (file: f, position: target, durationMs: duration.inMilliseconds);
    final bool leading = !userSeekWrite.value.hasPending;
    userSeekWrite.value.record(w);
    if (leading) persistUserSeekWrite(w);
    userSeekWriteTimer.value?.cancel();
    userSeekWriteTimer.value = Timer(kUserSeekWriteDebounce, () {
      final pending = userSeekWrite.value.flush();
      if (pending != null) persistUserSeekWrite(pending);
    });
  }

  /// Flushes the trailing burst write immediately (drag release / media
  /// change / unmount).
  void flushUserSeekBurst() {
    userSeekWriteTimer.value?.cancel();
    userSeekWriteTimer.value = null;
    final pending = userSeekWrite.value.flush();
    if (pending != null) persistUserSeekWrite(pending);
  }

  // ── Rapid step burst (keyboard / double-tap ← →) ──
  //
  // WHY A CHAIN, NOT A CADENCE (measured 2026-09-29 on a 4K local file): mpv
  // keeps only the NEWEST seek target while a seek is in flight. A fixed
  // cadence (the old 120ms throttle) therefore issued `/seek 3s`, `/seek 6s`,
  // `/seek 9s` … and mpv dropped every one that arrived while the previous was
  // still decoding — the picture sat on the previous frame and then jumped
  // straight to the last target ("+3+6+9+12 中间的没显示"). A precise seek on
  // such content costs a few hundred ms, far more than any usable cadence.
  //
  // [StepSeekChain] instead issues exactly ONE engine seek at a time and sends
  // the next only after the previous target was OBSERVED in the position
  // stream, so every requested step really lands and paints — in order:
  //  * a landed frame is held for [kStepLandedDwell] before the next seek, or
  //    the next discontinuity would freeze it before the eye sees it;
  //  * a queue bounded by [kStepChainMaxPending] drops the OLDEST pending step
  //    when a held key (~30/s) outpaces the painter, so the picture keeps
  //    advancing through the freshest targets;
  //  * [kStepSeekHardTimeout] releases a landing that is never observed;
  //  * the seek stays PRECISE (`hr-seek=yes` + `hr-seek-framedrop=yes`, set by
  //    applyMpvSeekTuning) so every press lands exactly on its target. The
  //    keyframe-seek relaxation used to live here (an inexact `seek absolute`
  //    lands on the keyframe BEFORE the target, so a held / re-tapped ←/→
  //    re-showed the previous GOP — 回跳重播) and is gated off by
  //    [kStepBurstRelaxesPreciseSeek];
  //  * when the input goes idle nothing is re-issued — the queue simply drains
  //    (each remaining step was really requested; a held key is bounded by
  //    [kStepChainMaxPending]) and the DB progress was already written to the
  //    last press's exact target by persistUserSeekBurst.
  // The intent target still accumulates on EVERY press (see StepIntent), so a
  // press the engine has not reached yet is never lost.
  //
  // VERIFIED (2026-09-29 run, 4K local file): the settle never re-seeks
  // (12/12 `(chain empty, no re-seek)`; ZERO `src=burst-settle` in the whole
  // capture), the hard timeout never fired, and 206 of 216 presses each got
  // their own issue + landing. Repro-log signature for a future regression:
  //   `[step] target=` (presses) ≈ `[step] issue` ≈ `[step] landed`, and no
  //   settle seek at all.
  // Deliberately NOT fixed here: the OSD target is still the stale snapshot
  // built in potplayer_key_executor (it can read ahead of the picture during a
  // burst), and the queue cap drops the OLDEST press when the input outpaces
  // the painter (see StepSeekChain).
  final stepBurst = useRef(StepBurst());
  final stepBurstTimer = useRef<Timer?>(null);
  final stepBurstTargetMs = useRef<int?>(null);
  // Lock-independent step accumulation: the position lock unlocks on its
  // ±2s landing tolerance (or its fail-open paths), and the REPORTED position
  // lags a seek that is still decoding toward its target — chaining onto
  // either makes N presses recompute the SAME target (see StepIntent).
  final stepIntent = useRef(StepIntent());
  final stepChain = useRef(StepSeekChain());
  final stepDwellTimer = useRef<Timer?>(null);
  final stepHardTimeoutTimer = useRef<Timer?>(null);
  // One-shot per media: which decoder mpv actually picked (a silent software
  // fallback is what makes a precise 4K seek take hundreds of ms).
  final stepHwdecLogged = useRef(false);
  // Late-bound handle to [seek] so the chain can re-enter it (Dart forbids
  // referencing a local function before its declaration, and the re-entry must
  // go through the VM decomposition, not the raw engine call).
  final seekFn = useRef<Future<void> Function(Duration, [String, bool])?>(null);

  Future<void> setExactSeek(bool exact) async {
    // Soft kill switch (see kStepBurstRelaxesPreciseSeek): the burst must NOT
    // relax mpv's precision — `hr-seek=no` lands on the keyframe BEFORE the
    // target, so a held / re-tapped ←/→ re-showed the previous GOP instead of
    // advancing (回跳重播). All call sites stay in place for an easy rollback;
    // while the flag is false this is a no-op and `hr-seek` keeps the
    // `hr-seek=yes` + `hr-seek-framedrop=yes` baseline applyMpvSeekTuning set.
    if (!kStepBurstRelaxesPreciseSeek) return;
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    await platform.setProperty('hr-seek', exact ? 'yes' : 'no');
  }

  /// Hands the next queued step target to the engine (through [seek], so a
  /// virtual-media target is decomposed onto its segment) and arms the hard
  /// timeout that keeps an unobserved landing from wedging the chain.
  void pumpStepChain() {
    stepDwellTimer.value?.cancel();
    stepDwellTimer.value = null;
    final StepSeekRequest? next = stepChain.value.takeNext(DateTime.now());
    if (next == null) return;
    diagLog.d('[step] issue target=${next.targetMs} '
        'engine=${next.engineTargetMs} pending=${stepChain.value.pendingCount} '
        'forward=${next.forward}');
    if (!stepHwdecLogged.value) {
      stepHwdecLogged.value = true;
      final platform = player.platform;
      if (platform is NativePlayer) {
        unawaited(() async {
          try {
            final String hwdec = await platform.getProperty('hwdec-current');
            diagLog.d('[step] mpv hwdec-current=$hwdec '
                '(precise seeks decode from the previous keyframe when "no")');
            // Empty right after a media switch (decoder not configured yet) is
            // expected and harmless.
          } catch (_) {
            // A backend without the property keeps mpv's own defaults.
          }
        }());
      }
    }
    stepHardTimeoutTimer.value?.cancel();
    stepHardTimeoutTimer.value = Timer(kStepSeekHardTimeout, () {
      if (!stepChain.value.tickTimeout(DateTime.now())) return;
      diagLog.w('[step] landing not observed target=${next.targetMs} '
          'pending=${stepChain.value.pendingCount} -> next step');
      pumpStepChain();
    });
    // 'step-issue' keeps the step accumulation alive (unlike an absolute jump).
    unawaited(seekFn.value!(
        Duration(milliseconds: next.targetMs), 'step-issue', next.forward));
  }

  /// Position-stream hook for the chain: a landed target releases the next
  /// queued step after [kStepLandedDwell], so the landed frame is actually
  /// visible before the next seek freezes the picture again.
  void onStepChainPosition(int posMs) {
    if (!stepChain.value.notePosition(posMs)) return;
    stepHardTimeoutTimer.value?.cancel();
    stepHardTimeoutTimer.value = null;
    diagLog.d('[step] landed engine=$posMs '
        'pending=${stepChain.value.pendingCount}');
    if (stepChain.value.pendingCount == 0) return;
    stepDwellTimer.value?.cancel();
    stepDwellTimer.value = Timer(kStepLandedDwell, pumpStepChain);
  }

  stepChainOnPosition.value = onStepChainPosition;

  void noteStepSeek(int targetMs) {
    final bool rapid = stepBurst.value.note(DateTime.now());
    stepBurstTargetMs.value = targetMs;
    if (rapid) unawaited(setExactSeek(false));
    diagLog.d('[step] target=$targetMs rapid=$rapid');
    stepBurstTimer.value?.cancel();
    stepBurstTimer.value = Timer(kStepBurstWindow, () {
      stepBurstTimer.value = null;
      final int? finalMs = stepBurstTargetMs.value;
      final bool wasRapid = stepBurst.value.isRapid;
      stepBurstTargetMs.value = null;
      stepBurst.value.reset();
      if (!wasRapid) return;
      unawaited(setExactSeek(true));
      // Idle settle. The chain owns the engine seeks now, and a target that
      // ALREADY landed is never re-issued: the old `seek(finalMs,
      // 'burst-settle')` here re-sought the position that had just landed and
      // paid one more decoder discontinuity exactly when the user stopped —
      // the "收尾卡一下" (in the 2026-09-29 log: `lock landed 180633` is
      // immediately followed by `[seek] target=180633ms src=burst-settle`).
      if (stepChain.value.isEmpty) {
        diagLog.d(
            '[step] burst settle target=$finalMs (chain empty, no re-seek)');
        return;
      }
      // Still draining: the queue holds steps the user really asked for (a
      // held key is already coalesced by [kStepChainMaxPending], which drops
      // the OLDEST pending target), so none of them is skipped here — the
      // chain lands them in order and stops. A seek in flight is left alone.
      diagLog.d('[step] burst settle target=$finalMs '
          'pending=${stepChain.value.pendingCount} '
          'inFlight=${stepChain.value.inFlightMs}');
      pumpStepChain();
    });
  }

  /// Stops any in-flight burst and clears its bookkeeping (media change /
  /// unmount). With [kStepBurstRelaxesPreciseSeek] off there is no engine
  /// precision to restore; the call site is kept for the A/B rollback.
  void resetStepBurst() {
    stepBurstTimer.value?.cancel();
    stepBurstTimer.value = null;
    stepBurstTargetMs.value = null;
    stepDwellTimer.value?.cancel();
    stepDwellTimer.value = null;
    stepHardTimeoutTimer.value?.cancel();
    stepHardTimeoutTimer.value = null;
    stepChain.value.reset();
    stepIntent.value.reset();
    stepHwdecLogged.value = false;
    final bool wasRapid = stepBurst.value.isRapid;
    stepBurst.value.reset();
    if (wasRapid) unawaited(setExactSeek(true));
  }

  // Attribution-only [src]: every seek lands in the log with its caller
  // (dial-tap / dial-commit / step / release-commit / resume / lock-retry /
  // player for every other MediaPlayer.seek caller). Zero behaviour change;
  // the tear-off still satisfies `Future<void> Function(Duration)`.
  Future<void> seek(Duration newPosition,
      [String src = 'player', bool forward = true]) async {
    // 'step' (a press) and 'step-issue' (the chain handing that press to the
    // engine) are the two halves of one step: an absolute jump re-anchors the
    // NEXT relative step on the fresh position and invalidates a queued walk,
    // but a step must keep the accumulation alive.
    final bool stepSrc = src == 'step' || src == 'step-issue';
    if (!stepSrc) {
      stepIntent.value.reset();
      stepChain.value.reset();
    }
    // Virtual Media session: dragging the scrubber produces virtual
    // positions; decompose onto the physical segment before seeking (spec
    // §9.3). Cross-segment targets open WITH the intra-segment offset
    // (pendingSeekMs handoff) instead of flashing 0% first — unless the
    // drag strategy says to hold the picture until release (spec §6).
    if (VirtualMediaController.instance.isActive) {
      final vm = VirtualMediaController.instance;
      final item = vm.state.item;
      if (item != null) {
        final (segIdx, localMs) = item.locate(newPosition.inMilliseconds);
        final curSeg = vm.state.segmentIndex;
        // CLOSE_DEBUG_LOG: vm seek-coordinate attribution — a local position
        // misrouted as virtual lands on an earlier segment (the 回第1个视频
        // symptom); one repro log must make that visible.
        diagLog.d('[vm-seek] target=${newPosition.inMilliseconds}V '
            'resolved seg=$segIdx local=$localMs cur=$curSeg src=$src');
        if (segIdx != curSeg &&
            newPosition.inMilliseconds < item.offsetOf(curSeg)) {
          diagLog.w('[vm-seek] backward cross-segment '
              'target=${newPosition.inMilliseconds}V seg=$segIdx cur=$curSeg '
              '(legal for chapter/rewind; investigate otherwise)');
        }
        if (segIdx == vm.state.segmentIndex) {
          final clamped =
              clampVmLocalMs(item.segments[segIdx].durationMs, localMs);
          // Step accumulation on the SEGMENT-LOCAL axis: this is what the
          // next relative step adds to. The chain queues the target on the
          // VIRTUAL axis instead (different axis, on purpose: its re-entry
          // through seek() re-decomposes it onto the right segment).
          if (src == 'step') stepIntent.value.note(clamped);
          userSeekPending.value = true;
          lastSanePosMs.value = null;
          // Position-intent lock + save-once: the user's explicit target is
          // the authoritative progress from this moment. A burst collapses to
          // leading+trailing writes (see persistUserSeekBurst).
          // A chain issue must not re-run the lock/persist below: its target
          // can be an OLDER queued step than the press that already armed the
          // lock and persisted the progress (see the non-VM path).
          if (src != 'step-issue') {
            positionLock.value.armTarget(clamped);
            persistUserSeekBurst(Duration(milliseconds: clamped));
          }
          // Keyboard / double-tap steps inside a VM segment take the SAME chain
          // treatment as the non-VM path. The queued target is VIRTUAL — the
          // chain re-enters seek() so it is decomposed onto the right segment —
          // while the engine axis (what the landing check compares against) is
          // the segment-local [clamped].
          if (src == 'step') {
            stepChain.value.push(
              newPosition.inMilliseconds,
              engineTargetMs: clamped,
              forward: forward,
            );
            noteStepSeek(newPosition.inMilliseconds);
            pumpStepChain();
            return;
          }
          await player.seek(Duration(milliseconds: clamped));
        } else {
          final dragging = useScrubDragStore().state.any;
          // A cross-segment step lands on ANOTHER segment: the local axis the
          // accumulator was recorded in no longer applies, and a queued walk
          // [(StepSeekChain)] is stale for the same reason.
          stepIntent.value.reset();
          stepChain.value.reset();
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
    // A user-initiated jump resets the position-sanitizer guard so the new
    // position (possibly backward) is accepted on the next sample.
    userSeekPending.value = true;
    lastSanePosMs.value = null;
    if (duration == Duration.zero) {
      // No duration yet: the clamp below would silently land the seek at 0
      // (the fvp hook already drops this case). Drop it — the open-resume
      // path re-issues a proper seek once the duration arrives.
      return;
    }
    diagLog.d('[seek] target=${newPosition.inMilliseconds}ms src=$src '
        'dur=${duration.inMilliseconds}ms');
    final target = clampSeekTarget(newPosition, duration);
    if (src == 'step') stepIntent.value.note(target.inMilliseconds);
    // Position-intent lock + save-once: the user's explicit target is the
    // authoritative progress from this moment — persist it BEFORE the seek
    // lands (a kill mid-seek cannot lose it) and block writes until the
    // player is observed at the target. A burst collapses to leading+trailing
    // writes (see persistUserSeekBurst).
    //
    // 'step-issue' (the chain handing a queued step to the engine) must NOT
    // re-run this: its target can be an OLDER step than the press that already
    // armed the lock, and re-persisting it would overwrite the newest progress
    // with a position the user has already stepped past.
    if (src != 'step-issue') {
      positionLock.value.armTarget(target.inMilliseconds);
      persistUserSeekBurst(target);
    }
    // Keyboard / double-tap steps enqueue on the caller's axis and let
    // [pumpStepChain] hand them to the engine ONE at a time: mpv keeps only
    // the newest in-flight target, so a fixed-cadence burst painted nothing but
    // the last target (see StepSeekChain).
    if (src == 'step') {
      stepChain.value.push(
        target.inMilliseconds,
        engineTargetMs: target.inMilliseconds,
        forward: forward,
      );
      noteStepSeek(target.inMilliseconds);
      pumpStepChain();
      return;
    }
    await player.seek(target);
  }

  // Late-bound so [pumpStepChain] can hand a queued step to seek() (see the
  // seekFn declaration above).
  seekFn.value = seek;

  /// Which base a relative step chained onto — makes a non-advancing burst
  /// (step-vs-lock-vs-reported confusion) diagnosable from the console alone.
  void logStepBase(int baseMs, int? lockMs, int reportedMs, int deltaMs) {
    final String from = stepIntent.value.lastMs != null
        ? 'step'
        : lockMs != null
            ? 'lock'
            : 'reported';
    diagLog.d('[step-base] base=$baseMs from=$from '
        'lock=$lockMs reported=$reportedMs delta=$deltaMs');
  }

  /// Relative skip on the VIRTUAL timeline (ms precision, clamped).
  ///
  /// The exposed [position] is raw local inside the current segment while a
  /// VM session is active; adding the delta to it and feeding it to [seek]
  /// (which interprets it as virtual) lands on the wrong segment. Translate
  /// local -> virtual first via the shared [VirtualSeekHandler] choke point.
  Future<void> seekRelative(int deltaMs) async {
    final vm = VirtualMediaController.instance;
    final item = vm.state.item;
    if (vm.isActive && item != null) {
      const handler = VirtualSeekHandler();
      // Accumulate onto the last REQUESTED step target first: the lock's
      // intent unlocks on its ±2s landing tolerance and the raw position lags
      // a seek that is still decoding — chaining onto either made every repeat
      // recompute the same target (N presses advanced nothing, then one jump).
      // Only when no step is in flight does the lock intent (then the reported
      // position) anchor the jump.
      final int? pendingIntent =
          positionLock.value.blocksWrites ? positionLock.value.targetMs : null;
      final int reportedMs = position.inMilliseconds;
      final int baseMs = stepIntent.value
          .baseFor(reportedMs: reportedMs, lockIntentMs: pendingIntent);
      logStepBase(baseMs, pendingIntent, reportedMs, deltaMs);
      final target = handler.resolveRelativeSeek(
        item,
        segmentIndex: vm.state.segmentIndex,
        localMs: baseMs,
        deltaMs: deltaMs,
      );
      await seek(Duration(milliseconds: target.virtualMs), 'step',
          deltaMs >= 0);
      return;
    }
    final totalMs = duration.inMilliseconds;
    if (totalMs <= 0) return;
    // Same accumulation contract as the VM branch above.
    final int? pendingIntent =
        positionLock.value.blocksWrites ? positionLock.value.targetMs : null;
    final int reportedMs = position.inMilliseconds;
    final int baseMs = stepIntent.value
        .baseFor(reportedMs: reportedMs, lockIntentMs: pendingIntent);
    logStepBase(baseMs, pendingIntent, reportedMs, deltaMs);
    final target = (baseMs + deltaMs).clamp(0, totalMs);
    await seek(Duration(milliseconds: target), 'step', deltaMs >= 0);
  }

  Future<void> backward(int seconds) async =>
      seekRelative(-seconds * 1000);

  Future<void> forward(int seconds) async =>
      seekRelative(seconds * 1000);

  Future<void> stepBackward() async {
    final nativePlayer = player.platform;
    if (nativePlayer is NativePlayer && file?.type == ContentType.video) {
      // PotPlayer parity: entering frame mode pauses first, then steps.
      // Must also clear autoPlay so the scenario-resume effect does not
      // immediately re-play (全平台：按帧后保持暂停，长按多帧松手仍暂停).
      await useAppStore().updateAutoPlay(false);
      await player.pause();
      await nativePlayer.command(['frame-back-step']);
      areaKeyLog.i('Step backward');
    }
  }

  Future<void> stepForward() async {
    final nativePlayer = player.platform;
    if (nativePlayer is NativePlayer && file?.type == ContentType.video) {
      // PotPlayer parity: entering frame mode pauses first, then steps.
      await useAppStore().updateAutoPlay(false);
      await player.pause();
      await nativePlayer.command(['frame-step']);
      areaKeyLog.i('Step forward');
    }
  }

  // Virtual Media: expose the unified timeline to the entire UI (spec §4.2).
  final vmCtrlMk = VirtualMediaController.instance;
  final isVmMk = vmCtrlMk.isActive;
  // Stale-session self-heal: a store item that is NOT the active session
  // means playback moved to a normal file without the VM stop/step paths
  // (storage/history direct open). Clear it after the frame so every progress
  // surface drops the phantom dual time / segment marks. Guarded inside the
  // controller against in-flight feeds and transitions.
  final vmStaleMk = vmCtrlMk.state.item != null && !isVmMk;
  useEffect(() {
    if (vmStaleMk) vmCtrlMk.reconcileStaleSession();
    return null;
  }, [vmStaleMk]);
  final vmDurationMk = isVmMk
      ? Duration(milliseconds: vmCtrlMk.totalDurationMs)
      : duration;
  // While a switch is in flight the new file reports 0% pre-seek: freeze
  // the exposed position on the jump target instead of flashing backward.
  final vmFrozenMk = isVmMk &&
      vmCtrlMk.state.transitioning &&
      vmCtrlMk.state.pendingSeekMs != null;
  final vmPositionMk = isVmMk
      ? (vmFrozenMk
          ? Duration(
              milliseconds: vmCtrlMk.currentOffsetMs +
                  (vmCtrlMk.state.pendingSeekMs ?? 0))
          : vmCtrlMk.translatePosition(position))
      : position;
  // Gated on the position lock: while a target is pending/locked the raw
  // position is a pre-land sample — feeding it to the controller would
  // pollute the anchor flush with the leaving file's offset.
  if (isVmMk && !positionLock.value.blocksWrites) {
    vmCtrlMk.noteTick(position.inMilliseconds);
  }
  // Buffer lives on the same axis as position: raw local buffered bytes mean
  // nothing against a virtual total — translate so the bar fills correctly.
  final vmBufferMk = isVmMk && vmCtrlMk.state.item != null
      ? Duration(
          milliseconds: const VirtualSeekHandler().virtualBufferMs(
            vmCtrlMk.state.item!,
            segmentIndex: vmCtrlMk.state.segmentIndex,
            rawBufferMs: buffer.inMilliseconds,
          ))
      : buffer;

  // Central drag-release commit (spec §6): a stashed cross-segment target
  // (preview strategy, or a throttled direct tick) lands exactly once when
  // the drag ends. Covers every slider — none needs its own commit path.
  // The re-invoked seek re-gates with dragging=false, so it always acts.
  final dragActiveMk = useScrubDragStore().select(context, (s) => s.any);
  useEffect(() {
    if (!dragActiveMk) {
      // Drag ended: land the collapsed trailing progress write immediately
      // (the seek itself is committed by the VM stash path below).
      flushUserSeekBurst();
      final stashed = VirtualMediaController.instance.takeDragTarget();
      if (stashed != null &&
          VirtualMediaController.instance.isActive) {
        diagLog.d('[bg-scrub] drag-release commit stashed=$stashed');
        seek(Duration(milliseconds: stashed), 'release-commit');
      }
    }
    return;
  }, [dragActiveMk]);

  // Media identity changed: a pending burst write must still reach the file it
  // was recorded for, and an in-flight step burst must not leak keyframe
  // seeking into the next media.
  final mediaUriMk = file?.uri;
  useEffect(() {
    flushUserSeekBurst();
    resetStepBurst();
    lastUserSeekWrite.value = null;
    return;
  }, [mediaUriMk]);

  // Unmount: cancel the debounce timer and land the last pending write.
  useEffect(() {
    resetStepBurst();
    flushUserSeekBurst();
    return;
  }, []);

  final mediaKitPlayer = useMemoized(
    () => MediaKitPlayer(
      player: player,
      controller: controller,
      subtitle: subtitle,
      subtitles: subtitles,
      externalSubtitles: externalSubtitles ?? [],
      audio: audio,
      audios: audios,
      isInitializing: isInitializing.value,
      isPlaying: playing,
      position: vmDurationMk == Duration.zero ? Duration.zero : vmPositionMk,
      duration: vmDurationMk,
      buffer: vmDurationMk == Duration.zero ? Duration.zero : vmBufferMk,
      width: videoParams?.w?.toDouble() ?? 0,
      height: videoParams?.h?.toDouble() ?? 0,
      saveProgress: saveProgress,
      play: play,
      pause: pause,
      backward: backward,
      forward: forward,
      stepBackward: stepBackward,
      stepForward: stepForward,
      seek: seek,
    ),
    [
      player,
      controller,
      subtitle,
      subtitles,
      externalSubtitles,
      audio,
      audios,
      isInitializing.value,
      playing,
      position,
      duration,
      vmPositionMk,
      vmDurationMk,
      vmBufferMk,
      buffer,
      videoParams?.w,
      videoParams?.h,
      saveProgress,
      play,
      pause,
      backward,
      forward,
      stepBackward,
      stepForward,
      seek,
    ],
  );

  // AB-loop engine binding: lifecycle-driven so backend swaps rebind and a
  // disposed player never leaves a zombie loop (see AbLoopEngine). Declared
  // last so its cleanup runs FIRST on unmount, before player.dispose().
  useEffect(() {
    AbLoopEngine.instance
        .attach(player: mediaKitPlayer, precise: positionStream);
    return AbLoopEngine.instance.detach;
  }, []);

  return mediaKitPlayer;
}


