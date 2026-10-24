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
import 'package:iris/hooks/player/live_progress_attribution.dart';
import 'package:iris/hooks/player/media_info_writeback.dart';
import 'package:iris/hooks/player/seek_clamp.dart';
import 'package:iris/hooks/player/seek_tuning.dart';
import 'package:iris/hooks/player/use_playback_progress_claim.dart';
import 'package:iris/utils/seek_tail_guard.dart';
import 'package:iris/features/meta_settings/engine/step_tail_finish_mode.dart';
import 'package:iris/features/meta_settings/engine/video_cache_preset.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
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
import 'package:iris/utils/check_data_source_type.dart';
import 'package:iris/utils/app_instance.dart';
import 'package:iris/features/media_library/services/external_subtitle_loader.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/features/webdav_discovery/services/webdav_playback_uri.dart';
import 'package:iris/features/webdav_discovery/view/webdav_playback_error_dialog.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/widgets/dialogs/show_copyable_error_dialog.dart';
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

  // Tail-step policy (metadata AUX `playback.stepTailFinish`): what a FORWARD
  // step press does once its target reaches the media end — finish the item
  // (advance) while playing, hold the press while paused. Resolved through the
  // SAME gate-aware resolver the settings UI uses, so a gate-OFF run degrades
  // to `strict` instead of executing a `window` value left over from the meta
  // era. Selecting the resolved value (not the raw field) also rebuilds this
  // hook when the gate flips.
  final stepTailFinishMode = useAppStore().select(
    context,
    (state) => resolveStepTailFinishMode(
      state,
      metadataEnabled: state.useMetadataSettings && MetaSettingsModule.ready,
    ),
  );

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

      // mpv's per-instance audio identity: each window reports its own client
      // name, so the OS volume mixer lists "IRIS #2" separately from "IRIS"
      // (the same idea as mpv's --audio-client-name). Windows/WASAPI is the
      // target; the property is a no-op elsewhere. The fvp backend has no
      // equivalent knob — its instances are only separated per process.
      if (Platform.isWindows && player.platform is NativePlayer) {
        await (player.platform as NativePlayer).setProperty(
          'audio-client-name',
          AppInstance.isPrimary
              ? 'IRIS'
              : 'IRIS #${AppInstance.slotLabel}',
        );
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
  // Latest media bound to the hook, readable from timers that were created for
  // an EARLIER media (their closure keeps the old `file`). The live-progress
  // gate compares the two so a switch cannot attribute the previous file's
  // sample to the new entry (see shouldAttributeLiveProgress).
  final latestMediaUri = useRef<String?>(null);
  latestMediaUri.value = file?.uri;

  // Multi-instance progress ownership: claim this file before the open effect
  // reads its resume position (see MediaProgressClaim).
  usePlaybackProgressClaim(file);

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

  /// Media whose `player.open()` has COMPLETED — the only media whose
  /// `player.state` samples are trustworthy (see shouldAttributeLiveProgress).
  final openedMediaUri = useRef<String?>(null);

  /// mpv-parity tail state for the current media (see [MpvSeekTailState]) and
  /// the EOF window it arms.
  final stepTail = useRef(MpvSeekTailState());
  final tailCollapseTimer = useRef<Timer?>(null);

  /// One item-finished dispatch at a time: the engine's `completed` event and
  /// the tail collapse are two doors to the SAME advance
  /// (`playloop.c:1240-1243`) and must never advance the queue twice.
  final finishedDispatchInFlight = useRef<bool>(false);

  Future<void> init(FileItem file) async {
    if (file.uri == '') return;
    isInitializing.value = true;
    // Until this open completes, `player.state` still describes the previous
    // media: no sample may be attributed to this file yet. A RE-open of the
    // SAME media (queue rebuild during playback) keeps the flag — the engine
    // state still belongs to that uri, and dropping it would lose a genuine
    // `completed`.
    if (openedMediaUri.value != file.uri) openedMediaUri.value = null;
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
      // Only now does `player.state` belong to THIS media. A superseded open
      // (double-open race) must not claim the newer media either.
      if (latestMediaUri.value == file.uri) openedMediaUri.value = file.uri;

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
      // Attribution gate: the tick can land between "hook rebuilt for the next
      // entry" and "open completed", while `player.state` still holds THIS
      // (previous) file's tail. Writing that under the new file's key is the
      // "next episode resumes at the previous episode's end" defect — mpv has
      // no such window because `loadfile` resets the playback state.
      if (!shouldAttributeLiveProgress(
        sampleUri: current.uri,
        openUri: openedMediaUri.value,
        latestUri: latestMediaUri.value,
      )) {
        return;
      }
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
      // While an intent is in flight (open pending / resume seek / user seek)
      // the sample is a PRE-landing one: displaying it would flash a bogus
      // position (and a resume-ahead tick could be persisted from the store
      // by another surface). mpv's single media context has no such sample.
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
      // Same attribution gate as the tick: the dispose runs on the media
      // switch, when `player.state` still belongs to the media being left.
      if (player.state.duration != Duration.zero &&
          shouldAttributeLiveProgress(
            sampleUri: current.uri,
            openUri: openedMediaUri.value,
            latestUri: latestMediaUri.value,
          ) &&
          !positionLock.value.blocksWrites) {
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
          positionLock.value.armTarget(duration.inMilliseconds);
          await player.seek(duration);
        } else if ((wasCompleted || alwaysPlayFromBeginning) && !vmTargeted) {
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
        final sub = externalSubtitles[0];
        areaKeyLog.i('Set external subtitle: $sub');
        final storage = file == null
            ? null
            : useStorageStore().resolveStorageForNodeId(file.storageId);
        final uri = subtitlePlayableUri(
          storage,
          sub,
          mediaStreamUrl: mediaStream.url ?? '',
        );
        areaKeyLog.i('External subtitle uri: $uri');
        final loaded = await tryLoadExternalSubtitle(
          player,
          uri: uri,
          title: sub.name,
        );
        if (!loaded && context.mounted) {
          await showCopyableErrorDialog(
            context,
            message:
                getLocalizations(context).track_subtitle_load_failed(sub.name),
          );
        }
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
  //
  // The write-once mark is keyed by the FILE ([MediaInfoWritebackGate]): a
  // per-hook boolean stayed set for the whole session, so everything after the
  // first file was silently skipped.
  final mediaInfoGate = useRef(MediaInfoWritebackGate());
  final mediaInfoKey = file == null
      ? null
      : canonicalProgressKey(file.storageId, file.path, uri: file.uri);
  useEffect(() {
    final key = mediaInfoKey;
    if (file == null || key == null) return null;
    // ATTRIBUTION GUARD (see MediaInfoWritebackGate.belongsToOpenFile): on a
    // track switch this effect runs for the NEW key while `duration` /
    // `videoParams` still describe the PREVIOUS media (open() is awaited in the
    // effect above). Writing those values keyed by the new file poisoned
    // `media_nodes` — every row inherited its predecessor's duration and
    // dimensions — and the write-once mark then dropped the real values.
    if (!mediaInfoGate.value
        .belongsToOpenFile(mediaUri: file.uri, openedUri: openedMediaUri.value)) {
      return null;
    }
    final vp = videoParams;
    final vpW = vp?.w ?? 0;
    final vpH = vp?.h ?? 0;
    final gate = mediaInfoGate.value;
    final needDuration = gate.needsDuration(key, duration.inMilliseconds);
    final needDims = gate.needsDims(key, vpW, vpH);
    if (!needDuration && !needDims) return null;
    if (needDuration) gate.markDurationWritten(key);
    if (needDims) gate.markDimsWritten(key);
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
        if (dbPath.isEmpty) {
          // No segment path to key the write on (SAF single pick): nothing was
          // written, so release the mark instead of swallowing the backfill.
          gate.unmark(key);
          return;
        }
        final rows = await DbModule.mediaNodeRepo.updateFileMediaInfo(
          storageId: file.storageId,
          path: dbPath,
          durationMs:
              needDuration ? duration.inMilliseconds : null,
          width: needDims ? vpW : null,
          height: needDims ? vpH : null,
          pixelCount: needDims ? vpW * vpH : null,
        );
        if (rows <= 0) {
          // No `media_nodes` row matched (unscanned file, or a stored path-shape
          // mismatch such as the collapsed SAF scheme). The database was NOT
          // updated, so release the mark: keeping it would drop this file's
          // duration/dimensions for the rest of the session.
          gate.unmark(key);
          areaKeyLog.w(
              'Media info write-back matched no row: ${file.name}');
          return;
        }
        areaKeyLog.i('Saved media info to DB: ${file.name} '
            'dur=${needDuration ? duration.inMilliseconds : "-"}ms');
        // Only a write that CHANGED the row moves this file in a duration /
        // resolution sort (and out of the NULLS-LAST bucket), so only then is an
        // open list re-resolved. An already-correct value must stay free: this
        // runs once per played file.
        if (mediaInfoCorrects(
          storedDurationMs: file.durationMs,
          durationMs: duration.inMilliseconds,
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
    // open completed: a duration that arrived during `open()` is skipped by the
    // attribution guard above, and no further duration emission would come.
  }, [
    duration,
    videoParams?.w,
    videoParams?.h,
    mediaInfoKey,
    isInitializing.value,
  ]);

  /// Finishes the CURRENT item: the single advance path shared by the engine's
  /// `completed` event and the mpv-parity tail collapse.
  ///
  /// mpv ends a file exactly once (`player/playloop.c:1247-1250` gates EOF on
  /// "no queued seek", `1240-1243` turns a continuous past-EOF seek into EOF),
  /// so IRIS must not grow a second advance path for the tail. [fromEngine]
  /// only decides whether the scrub-drag latch applies: a drag parked at 100%
  /// keeps the item open until release, a tail STEP never does.
  ///
  /// [expectedUri] binds a caller to the media it decided about. A finish that
  /// arrives after the queue already moved on must die here — mpv clears the
  /// queued seek at the switch (`player/loadfile.c:1825-1826`), and IRIS's
  /// async advance otherwise let the abandoned tail arm collapse the entry that
  /// had just been opened.
  Future<void> dispatchItemFinished({
    required bool fromEngine,
    String? expectedUri,
  }) async {
    final String src = fromEngine ? 'engine' : 'step-eof';
    if (file == null) return;
    // Attribution: media_kit's `Player` outlives the media, so a `completed`
    // raised by the file being LEFT can reach the hook after the queue already
    // moved on — `player.state.position` would then be the old tail while
    // `file` is the new entry, i.e. it would mark the NEXT episode as finished
    // and store its tail as its progress. The fvp backend cannot leak this (it
    // replaces the controller per open), media_kit can.
    if (!shouldAttributeLiveProgress(
      sampleUri: file.uri,
      openUri: openedMediaUri.value,
      latestUri: latestMediaUri.value,
    )) {
      diagLog.d('completed dropped (media changed) src=$src file=${file.name}');
      return;
    }
    if (expectedUri != null && file.uri != expectedUri) {
      diagLog.d('completed dropped (stale finish) src=$src file=${file.name}');
      return;
    }
    if (fromEngine && useScrubDragStore().state.any) {
      diagLog.d('completed suppressed hold/seek '
          'holding=${useScrubDragStore().state.isHolding} '
          'scrubbing=${useScrubDragStore().state.isScrubbing}');
      usePlayerUiStore().updatePendingCompleted(true);
      return;
    }
    // One dispatch at a time: the `completed` event and the tail window may
    // race, and neither may advance the queue twice.
    if (finishedDispatchInFlight.value) return;
    // A-B editor open: the pair is locked to the CURRENT media — neither a
    // virtual segment switch nor a queue advance may happen. Pause on the
    // spot and wait for the user.
    if (SegmentEditGuard.transportFrozen) {
      diagLog.d('completed paused by segment-edit freeze src=$src');
      player.pause();
      return;
    }
    finishedDispatchInFlight.value = true;
    try {
      // The item is finished from here on: drop the tail arm so a repeat-one
      // loop of the SAME media can arm again.
      stepTail.value.reset();
      tailCollapseTimer.value?.cancel();
      tailCollapseTimer.value = null;
      // Virtual Media session: segment end never reaches Context.next()
      // (spec §9.1). Repeat-one stays on the backend loop by design.
      if (await VirtualMediaController.instance.maybeHandleCompleted()) return;
      // CLOSE_DEBUG_LOG: the sample this dispatch actually persists is
      // `player.state.position` — logging the hook's own `position` here used
      // to print a different value than the progress write below.
      diagLog.d(
          'completed fired src=$src pos=${player.state.position.inMilliseconds}ms dur=${player.state.duration.inMilliseconds}ms file=${file.name} repeat=$repeat mode=${useScenario ? 'scenario' : 'legacy'} curIdx=$currentPlayIndex total=${playQueue.length}');
      if (player.state.position != Duration.zero) {
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
      diagLog.d('completed advance handled=$handled src=$src');
      if (handled) return;
      await advancePlayQueueOnCompleted(repeat);
    } finally {
      finishedDispatchInFlight.value = false;
    }
  }

  useEffect(() {
    () async {
      if (completed) {
        await dispatchItemFinished(fromEngine: true);
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

  // ── Step seek (keyboard / double-tap ← →) ──
  //
  // Each press hands mpv a NATIVE RELATIVE keyframe seek
  // (`seek <±delta> relative+keyframes`, see stepSeekArgs) instead of an
  // ABSOLUTE + EXACT one.
  //
  // WHY (mpv-parity rework, 2026-10-16): `Player.seek()` issues
  // `seek <abs> absolute`, and mpv defaults `absolute` seeks to `exact`; with
  // IRIS's `hr-seek=yes` every step then decoded from the previous keyframe up
  // to the target and restarted the audio output (~300ms), so a single tap froze
  // the picture for the whole seek. The old Dart StepSeekChain made it worse:
  // it issued ONE seek at a time and waited for a landing, then collapsed the
  // backlog to its final target on release — so rapid taps swallowed every
  // intermediate target ("吞掉中途帧") and only the last one ever painted.
  //
  // mpv's own ←/→ are relative keyframe seeks, and mpv coalesces a held-key
  // burst itself: `queue_seek` sums the relative amounts and
  // `execute_queued_seek` paces execution so the last landed frame is shown in
  // between. The Dart side must therefore NOT serialize anything, and it keeps
  // NO long-lived accumulator either: the nominal landing used by the OSD and
  // the progress write is anchored on the engine's reported position for the
  // current press (stepSeekTargetMs), and the delta handed to mpv is forwarded
  // raw on the forward side (stepSeekSentDelta).
  // The engine position is mpv's: `time-pos` reports the seek target while a seek
  // is in flight (`last_seek_pts`), exactly like mpv's own OSD, so no Dart-side
  // display hold is needed either.
  //
  // EXCEPT the tail: a press whose target reaches the end still goes through
  // the relative path (mpv does the same), and the two playloop rules IRIS was
  // missing are layered on top by [MpvSeekTailState]: later presses are
  // swallowed instead of queued (mpv drops the queued seek,
  // `playloop.c:1240-1243`) and the press collapses to EOF when the engine does
  // not report the end within [kMpvSeekEofWindow] (`handle_eof()` defers while
  // a seek is queued, `playloop.c:1247-1250`). The old code issued an absolute
  // `finishAtEnd` seek per repeat, which is what parked the picture at the tail
  // for as long as the key was held.
  //
  // Newest pressed target on the CALLER axis (virtual while a VM session is
  // active) — read once by the OSD right after the press, then overwritten by
  // the next one.
  final stepOsdTargetMs = useRef<int?>(null);

  /// Hands mpv ONE native relative keyframe step seek (see the block above).
  /// [deltaMs] is signed; mpv clamps the landing into the media itself.
  ///
  /// A failed command drops the optimistic OSD target: the pair must not keep
  /// showing a landing that was never requested.
  Future<void> issueStepSeek(int deltaMs) async {
    final platform = player.platform;
    if (platform is! NativePlayer) {
      // No relative seek was issued, so the optimistic OSD target (written by
      // the caller BEFORE this call) describes a landing that will never
      // happen. The catch below drops it on a failure; this early return must
      // drop it too, or a non-native backend keeps showing the wrong step.
      stepOsdTargetMs.value = null;
      return;
    }
    final List<String> args = stepSeekArgs(deltaMs);
    diagLog.d('[step] native ${args.join(' ')}');
    try {
      await platform.command(args);
    } catch (e) {
      // A backend without the seek command must not wedge playback.
      diagLog.w('[step] native relative seek failed: $e');
      stepOsdTargetMs.value = null;
    }
  }

  /// Stops the step bookkeeping (media change / unmount / absolute seek /
  /// rewind). The relative seeks already handed to mpv are left to mpv to
  /// finish; a pending tail arm is dropped so the next media can finish again.
  void resetStepBurst() {
    stepOsdTargetMs.value = null;
    stepTail.value.reset();
    tailCollapseTimer.value?.cancel();
    tailCollapseTimer.value = null;
  }

  // Attribution-only [src]: every seek lands in the log with its caller
  // (dial-tap / dial-commit / step / release-commit / resume / lock-retry /
  // player for every other MediaPlayer.seek caller). Zero behaviour change;
  // the tear-off still satisfies `Future<void> Function(Duration)`.
  //
  // [intent] states what the caller wants at the media end (see [SeekIntent]):
  // a scrub drag residency stops short of the tail, only a release at 100% may
  // land ON it and advance. Defaulting to stopAtTail keeps every unlisted caller
  // (jump dialog, gestures, phone scrubbers) from ever firing `completed` by
  // accident.
  Future<void> seek(
    Duration newPosition, [
    String src = 'player',
    SeekIntent intent = SeekIntent.stopAtTail,
  ]) async {
    // A step press (`src == 'step'`) keeps the step bubble alive; any absolute
    // jump re-anchors playback and must drop the step bookkeeping so it cannot
    // leak into the NEXT press. [resetStepBurst] clears the OSD target.
    if (src != 'step') resetStepBurst();
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
          // An unknown segment duration makes the intra-segment target a
          // fabricated 0 (`clampVmLocalMs`), which the persist below would write
          // over the file's saved progress. Hold — the same contract as the
          // `duration == Duration.zero` guard further down.
          const handler = VirtualSeekHandler();
          if (!handler.segmentDurationKnown(item, segIdx)) return;
          // A "finish this item" seek (tail step while playing / scrub release
          // at 100%) may land ON the segment end so the physical file reaches
          // EOF and the virtual session advances; every other caller keeps the
          // shared tail guard.
          final clamped = clampVmLocalMs(item.segments[segIdx].durationMs,
              localMs, intent: intent);
          userSeekPending.value = true;
          lastSanePosMs.value = null;
          // Position-intent lock + save-once: the user's explicit target is
          // the authoritative progress from this moment; a burst collapses to
          // leading+trailing writes (see persistUserSeekBurst).
          positionLock.value.armTarget(clamped);
          persistUserSeekBurst(Duration(milliseconds: clamped));
          await player.seek(Duration(milliseconds: clamped));
        } else {
          final dragging = useScrubDragStore().state.any;
          // Cross-segment step: the next press re-anchors on the new segment's
          // live position (no accumulation is kept across a segment switch).
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
    if (duration == Duration.zero) {
      // No duration yet: the clamp below would silently land the seek at 0
      // (the fvp hook already drops this case). Drop it — the open-resume
      // path re-issues a proper seek once the duration arrives. Done BEFORE
      // arming `userSeekPending`: nothing moved, so the next sample must not be
      // treated as a user jump.
      return;
    }
    // A user-initiated jump resets the position-sanitizer guard so the new
    // position (possibly backward) is accepted on the next sample.
    userSeekPending.value = true;
    lastSanePosMs.value = null;
    diagLog.d('[seek] target=${newPosition.inMilliseconds}ms src=$src '
        'dur=${duration.inMilliseconds}ms intent=${intent.name}');
    final target = clampSeekTarget(newPosition, duration, intent: intent);
    // Position-intent lock + save-once: the user's explicit target is the
    // authoritative progress from this moment — persist it BEFORE the seek
    // lands (a kill mid-seek cannot lose it) and block writes until the
    // player is observed at the target. A burst collapses to leading+trailing
    // writes (see persistUserSeekBurst).
    positionLock.value.armTarget(target.inMilliseconds);
    persistUserSeekBurst(target);
    await player.seek(target);
  }

  /// Which base a relative step chained onto — makes a non-advancing burst
  /// (step-vs-lock-vs-reported confusion) diagnosable from the console alone.
  ///
  /// There is no `step` (accumulator) branch on this backend on purpose: mpv
  /// accumulates the relative seeks itself, so only the position lock and the
  /// engine's reported position can be the base (see [seekRelative]).
  void logStepBase(int baseMs, int? lockMs, int reportedMs, int deltaMs) {
    final String from = lockMs != null ? 'lock' : 'reported';
    diagLog.d('[step-base] base=$baseMs from=$from '
        'lock=$lockMs reported=$reportedMs delta=$deltaMs');
  }

  /// Applies mpv's EOF collapse to the tail press currently armed for [uri].
  ///
  /// Two independent guards keep a finish from touching the entry that replaced
  /// it: the arm itself carries [uri] ([MpvSeekTailState]), and this media's
  /// open must still be the completed one — mpv drops the queued seek at the
  /// switch (`player/loadfile.c:1825-1826`), IRIS makes it unusable instead.
  Future<void> collapseTailStepToEof(String uri) async {
    tailCollapseTimer.value?.cancel();
    tailCollapseTimer.value = null;
    if (latestMediaUri.value != uri) return;
    if (openedMediaUri.value != uri) return;
    if (!stepTail.value.consumeCollapse(mediaUri: uri)) return;
    await dispatchItemFinished(fromEngine: false, expectedUri: uri);
  }

  /// Arms mpv's EOF window for the tail press just issued.
  ///
  /// The window is what keeps a held key from parking at the tail forever:
  /// while presses keep arriving the engine may never publish EOF, so IRIS
  /// applies the playloop's own collapse
  /// ("Continuous seeks past EOF => treat as EOF instead of repeating seek",
  /// `player/playloop.c:1240-1243`) once the window expires. A real
  /// `completed` cancels it through [dispatchItemFinished].
  void armTailEofWindow() {
    tailCollapseTimer.value?.cancel();
    final String? uri = file?.uri;
    if (uri == null) return;
    tailCollapseTimer.value = Timer(kMpvSeekEofWindow, () {
      // A stale closure (next media already bound, engine already at EOF) must
      // never advance.
      if (latestMediaUri.value != uri) return;
      if (player.state.completed) return;
      unawaited(collapseTailStepToEof(uri));
    });
  }

  /// Applies the tail-step policy ([decideStepTail]) for a press whose target
  /// reaches the caller axis end. [end] is the CALLER axis end (the file
  /// duration, or the merged Virtual-Media total), [deltaMs] the press's signed
  /// step.
  ///
  /// mpv parity: the press is NOT converted into an absolute
  /// `seek <duration>`. That was IRIS's own third path and it starved EOF —
  /// every repeat re-queued a seek, and `handle_eof()` returns while a seek is
  /// queued (`player/playloop.c:1247-1250`). The press stays the ordinary
  /// RELATIVE keyframe seek mpv's own `→` issues, and [MpvSeekTailState]
  /// supplies the two playloop rules IRIS was missing:
  ///
  ///  * later presses are swallowed — mpv drops the queued seek instead of
  ///    repeating it (`playloop.c:1240-1243`);
  ///  * if the engine has not raised `completed` within [kMpvSeekEofWindow],
  ///    the press is collapsed to EOF: the same "treat as EOF" verdict, with
  ///    IRIS owning the queue advance ([collapseTailStepToEof]).
  ///
  /// `hold` (paused) swallows the press: nothing is sought and nothing is
  /// written, so the progress cannot roll backwards (「暂停时保留」).
  Future<void> applyTailStep(
      StepTailAction action, Duration end, int deltaMs) async {
    diagLog.d('[step-tail] action=${action.name} end=${end.inMilliseconds}ms '
        'pos=${position.inMilliseconds}ms playing=$playing '
        'mode=${stepTailFinishMode.name} delta=$deltaMs '
        'armed=${stepTail.value.armed}');
    switch (action) {
      case StepTailAction.step:
        return;
      case StepTailAction.hold:
        // A paused press must not arm a finish (it returns before
        // `armFirstPress`), and it must NOT drop an arm the playing press
        // already raised: that pending collapse is the item's real finish.
        stepOsdTargetMs.value = null;
        return;
      case StepTailAction.finishItem:
        stepOsdTargetMs.value = end.inMilliseconds;
        // Already armed for this media: swallow the press. This is the fix for
        // "rapid taps / held key parks at the tail and never advances" — every
        // repeat used to queue another absolute seek, so EOF never happened.
        final String? uri = file?.uri;
        if (uri == null) return;
        if (!stepTail.value.armFirstPress(uri, end.inMilliseconds)) return;
        userSeekPending.value = true;
        lastSanePosMs.value = null;
        // Observed position, not the nominal target (see [seekRelative]).
        persistUserSeekBurst(Duration(milliseconds: position.inMilliseconds));
        // Same raw, unclamped delta as any other step: mpv decides what it can
        // decode and, on the restart, whether EOF actually happened
        // (`playloop.c:530-535`).
        if (deltaMs != 0) await issueStepSeek(deltaMs);
        armTailEofWindow();
        return;
    }
  }

  /// Relative skip (← / →, double-tap): mpv's native RELATIVE keyframe seek.
  ///
  /// mpv accumulates a burst itself, so the Dart side keeps no long-lived
  /// intent: the OSD / progress-write target is anchored on the engine's last
  /// reported position for *this* press (stepSeekTargetMs), which bounds it to
  /// one press instead of drifting tens of seconds behind the picture. The delta
  /// handed to mpv is forwarded raw (stepSeekSentDelta). Only a rewind off the
  /// start is bounded. The virtual timeline is translated first so a
  /// segment-local step does not land on the wrong segment; a target that
  /// crosses into another segment goes through [seek], which opens it WITH the
  /// intra-segment offset.
  ///
  /// A press whose target reaches the END of the caller axis still takes the
  /// relative path (mpv's own `→` does), with the tail bookkeeping layered on
  /// top by [applyTailStep] — see [MpvSeekTailState].
  Future<void> seekRelative(int deltaMs) async {
    // mpv parity: a seek only applies to the entry whose demuxer is loaded
    // (`playloop.c:311`), and the switch clears whatever was queued
    // (`loadfile.c:1825-1826`). During IRIS's async advance the hook can hold
    // the NEXT entry while `player.state` still describes the previous one, so
    // a press here would combine the new file with the old duration/position
    // and finish the entry that just opened (see shouldAcceptStepPress). Drop
    // it — nothing is sought, armed, persisted or shown.
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
    final int? lockIntent =
        positionLock.value.blocksWrites ? positionLock.value.targetMs : null;
    final int reportedMs = position.inMilliseconds;
    // A rewind leaves the tail: the next forward tail press must be able to
    // arm its own finish (mpv re-evaluates EOF on every seek).
    if (deltaMs < 0) resetStepBurst();
    // Logged only: the anchor is the engine's own position — mpv accumulates
    // the presses natively, so no accumulator is needed here.
    logStepBase(reportedMs, lockIntent, reportedMs, deltaMs);

    if (vm.isActive && item != null) {
      const handler = VirtualSeekHandler();
      // Tail policy on the VIRTUAL axis, BEFORE `resolveRelativeSeek` clamps the
      // target into the last segment: a press that reaches the merged item's end
      // finishes the item instead of being parked inside the last segment's
      // final GOP (the clamp reported `segDur - kSeekTailGuardMs`, which can
      // never raise `completed`).
      final int vmSegIdx = vm.state.segmentIndex;
      if (handler.segmentDurationKnown(item, vmSegIdx)) {
        final int vmSegDur = item.segments[vmSegIdx].durationMs ?? 0;
        final StepTailAction vmTail = decideStepTail(
          reportedMs:
              item.offsetOf(vmSegIdx) + reportedMs.clamp(0, vmSegDur),
          deltaMs: deltaMs,
          durationMs: item.totalDurationMs,
          mode: stepTailFinishMode,
          playing: playing,
        );
        if (vmTail != StepTailAction.step) {
          await applyTailStep(
              vmTail, Duration(milliseconds: item.totalDurationMs), deltaMs);
          return;
        }
      }
      final target = handler.resolveRelativeSeek(
        item,
        segmentIndex: vm.state.segmentIndex,
        localMs: reportedMs,
        deltaMs: deltaMs,
      );
      // An unresolvable move (no probed duration on the target segment) must NOT
      // be turned into a step: the degenerate 0 used to be persisted over the
      // file's saved progress (「进度归 0」). It must also DROP any previous
      // press's OSD target — leaving it showed a landing this press never asked
      // for (the held-key-on-an-unknown-duration stale OSD).
      if (target == null) {
        stepOsdTargetMs.value = null;
        return;
      }
      // A jump really is being issued now, so arm the sanitizer: an early return
      // above must not leave `userSeekPending` stuck true for the next sample.
      userSeekPending.value = true;
      lastSanePosMs.value = null;
      // The OSD reads the CALLER (virtual) axis — it is DISPLAY only: it may sit
      // ahead of the picture, because a keyframe landing is deliberately off the
      // requested target.
      stepOsdTargetMs.value = target.virtualMs;
      // The PERSISTED position must never run ahead of what has actually played:
      // write the position the engine is OBSERVED at (the pre-seek sample), not
      // the nominal keyframe target. A kill inside the burst then resumes to a
      // frame that was really on screen, and the landing is picked up by the
      // throttled live save once it lands.
      persistUserSeekBurst(Duration(milliseconds: reportedMs));
      if (target.segIdx == vm.state.segmentIndex) {
        // mpv parity, same as the single-file path below: the delta is forwarded
        // UNCLAMPED. Clamping it to the segment's last seekable ms pinned a tail
        // press to `segDur - 100`, still inside the segment's final GOP, so the
        // engine landed on that GOP's key frame and the next press landed there
        // again — the same rollback-and-stick the single-file path had.
        //
        // Leaving the segment is NOT what this branch protects: a target that
        // belongs to another segment never reaches here (`resolveRelativeSeek`
        // resolves it and the cross-segment branch below opens it through
        // `jumpToSegment`, carrying the intra-segment offset). A press that
        // reaches the LAST segment's end is caught by the tail policy above, so
        // only in-range presses reach this delta.
        //
        // The segment duration is still the ANCHOR bound: `reportedMs` is
        // segment-local, and a stale sample past the segment end must not turn a
        // backward press into a bigger rewind than the segment allows.
        final int segDur = item.segments[target.segIdx].durationMs ?? 0;
        final int sent = stepSeekSentDelta(
          reportedMs: reportedMs,
          deltaMs: deltaMs,
          durationMs: segDur,
        );
        if (sent != 0) await issueStepSeek(sent);
      } else {
        // Cross-segment: land through seek(), which opens the segment WITH the
        // target offset.
        await seek(Duration(milliseconds: target.virtualMs), 'step');
      }
      return;
    }

    final int totalMs = duration.inMilliseconds;
    if (totalMs <= 0) {
      stepOsdTargetMs.value = null;
      return;
    }
    // Tail policy: a press whose target reaches the end FINISHES the item while
    // playing (the engine can never land there, see [decideStepTail]) and is
    // held while paused.
    final StepTailAction tail = decideStepTail(
      reportedMs: reportedMs,
      deltaMs: deltaMs,
      durationMs: totalMs,
      mode: stepTailFinishMode,
      playing: playing,
    );
    if (tail != StepTailAction.step) {
      await applyTailStep(tail, Duration(milliseconds: totalMs), deltaMs);
      return;
    }
    // A real step is being issued: reset the sanitizer so a keyframe landing
    // (possibly backward) is accepted on the next sample. NO position-intent
    // lock is armed — a keyframe landing deliberately differs from the target.
    userSeekPending.value = true;
    lastSanePosMs.value = null;
    // mpv parity: the forward delta is forwarded UNCLAMPED so the press keeps
    // its nominal landing (the tail case never reaches here — see
    // [decideStepTail] / [stepSeekSentDelta]).
    final int sent = stepSeekSentDelta(
      reportedMs: reportedMs,
      deltaMs: deltaMs,
      durationMs: totalMs,
    );
    // Display only: the HUD never shows a time past the media, even when the
    // delta just handed to mpv would.
    stepOsdTargetMs.value = stepSeekTargetMs(
        reportedMs: reportedMs, deltaMs: deltaMs, durationMs: totalMs);
    // Observed position, not the nominal target (see the VM branch above).
    persistUserSeekBurst(Duration(milliseconds: reportedMs));
    if (sent != 0) await issueStepSeek(sent);
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
  // mpv's `time-pos` already reports the seek TARGET while a seek is in flight
  // (`player/playloop.c`: `get_current_time` -> `last_seek_pts`), exactly like
  // mpv's own OSD, so the exposed position needs no Dart-side hold during a
  // step burst — the engine is the single source of truth.
  final Duration vmPositionMk = isVmMk
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
  // The work MUST be the returned dispose, not the effect body: flutter_hooks
  // runs the body at MOUNT and only calls the returned function at unmount, so
  // the previous body-form left the step timers running past player.dispose()
  // (line ~137) — a fired step timer then seeks on a disposed Player.
  useEffect(() {
    return () {
      resetStepBurst();
      flushUserSeekBurst();
    };
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
      // Bounded: a step seek hands mpv an unclamped delta, so `time-pos` can
      // report `last_seek_pts` past the duration while the seek is in flight.
      // The engine's own sample is untouched — only what the widgets see is
      // bounded (see clampPositionToMedia).
      position: vmDurationMk == Duration.zero
          ? Duration.zero
          : clampPositionToMedia(vmPositionMk, vmDurationMk),
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
      finishSeek: (target) =>
          seek(target, 'release-commit', SeekIntent.finishAtEnd),
      stepIntentTargetMs: () => stepOsdTargetMs.value,
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


