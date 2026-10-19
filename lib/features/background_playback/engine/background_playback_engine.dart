import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart' show PlayerBackend;
import 'package:iris/models/storages/storage.dart'
    show StorageType, WebDAVStorage;
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/features/webdav_discovery/services/webdav_playback_uri.dart';
import 'package:iris/utils/check_data_source_type.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart' show sanitizePlayableUri;
import 'package:media_kit/media_kit.dart' as media_kit;
import 'package:media_kit_video/media_kit_video.dart' as media_kit_video;
import 'package:media_stream/media_stream.dart' show MediaStream;
import 'package:video_player/video_player.dart';

final _log = AreaKeyLog(LogKeys.player);

/// Snapshot notification cadence for the high-rate `position` stream. Transport
/// state changes bypass it entirely (see [BackgroundPlaybackEngine._notify]).
const Duration _kNotifyInterval = Duration(milliseconds: 100);

/// Secondary (副音) engine — one real, independent playback runtime per
/// process, mirroring the foreground hook's engine usage but with none of the
/// foreground-only behaviors (no AB loop, no VM session, no history/progress
/// DB writes, no wakelock). The engine never talks to another player; the
/// only cross link is the [onCompleted] callback the host scope wires to the
/// background store's advance logic.
///
/// Snapshot fields are mutated from engine events and notifications are
/// throttled to ~10/s so the control bindings (slider/progress) stay smooth
/// without flooding the widget tree.
class BackgroundPlaybackEngine extends ChangeNotifier {
  BackgroundPlaybackEngine({
    required this.backend,
    bool attachNative = true,
    bool warmOnly = false,
  }) {
    if (attachNative) _create(warmOnly: warmOnly);
  }

  final PlayerBackend backend;

  media_kit.Player? _mk;
  media_kit_video.VideoController? _mkVideo;
  VideoPlayerController? _fvp;
  VoidCallback? _fvpListener;

  final List<StreamSubscription<dynamic>> _subs = [];

  /// Called once when the current media finishes naturally. The host scope
  /// decides (repeat-one replay vs advancing the queue).
  VoidCallback? onCompleted;

  FileItem? file;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool isPlaying = false;
  bool isInitializing = false;
  String? errorText;

  double _rate = 1.0;
  int _volume0to100 = 100;
  bool _ended = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _trailingNotify;
  int _openGen = 0;

  bool get hasVideoSurface =>
      backend == PlayerBackend.mediaKit ? _mkVideo != null : _fvp != null;

  /// Current playback rate (the progress-lock jump detection needs it to know
  /// how far the position may legitimately advance between samples).
  double get rate => _rate;

  media_kit_video.VideoController? get mediaKitVideoController => _mkVideo;

  VideoPlayerController? get fvpVideoController => _fvp;

  // ── Backend construction ──

  void _create({bool warmOnly = false}) {
    if (backend == PlayerBackend.mediaKit) {
      final player = media_kit.Player(
        configuration: const media_kit.PlayerConfiguration(libass: true),
      );
      _mk = player;
      _mkVideo = media_kit_video.VideoController(player);
      // Audio-first: no subtitle track while 副音 (subs belong to the
      // foreground surface).
      player.setSubtitleTrack(media_kit.SubtitleTrack.no());

      _subs.add(player.stream.playing.listen((v) {
        isPlaying = v;
        if (v) _ended = false;
        // Transport state drives the fg↔bg mirror; never let the throttle drop
        // the final sample (a swallowed pause leaves the other side playing).
        _notify();
      }));
      _subs.add(player.stream.position.listen((v) {
        position = v;
        _notifyThrottled();
      }));
      _subs.add(player.stream.duration.listen((v) {
        duration = v;
        _ended = false;
        _notify();
      }));
      _subs.add(player.stream.completed.listen((_) => _fireCompleted()));
      _subs.add(player.stream.error.listen((e) {
        errorText = e;
        _log.w('background engine error: $e');
        _notify();
      }));
      return;
    }
    // fvp — the controller is created lazily per open (like the fg hook).
    // A warm-only engine allocates nothing: the empty placeholder would be
    // pointless (open() replaces it) and starting one at launch buys nothing
    // for fvp, whose heavy work happens per open anyway.
    if (warmOnly) return;
    _fvp = VideoPlayerController.networkUrl(Uri.parse(''));
  }

  void _onFvpValue(VideoPlayerController c) {
    final v = c.value;
    final bool transportChanged =
        isPlaying != v.isPlaying || duration != v.duration;
    isPlaying = v.isPlaying;
    position = v.position;
    duration = v.duration;
    if (v.isCompleted) {
      _fireCompleted();
    } else {
      _ended = false;
    }
    if (transportChanged) {
      _notify();
    } else {
      _notifyThrottled();
    }
  }

  // ── Commands ──

  /// Opens [file] (replicating the foreground open's uri/auth/FTP/local
  /// repair — keep this in sync with the foreground hook's `init`).
  Future<void> open(FileItem next, {required bool autoplay}) async {
    // An empty uri (deleted/unscanned/mapping residue) must never stall the
    // queue silently: record the failed file and the reason so the host can
    // report it and the next step re-fires on a new file identity. The
    // previous file must also stop sounding — otherwise the engine keeps
    // playing a ghost while `file` points at the entry that never opened.
    if (next.uri.isEmpty) {
      await _haltPlayback();
      file = next;
      isInitializing = false;
      errorText = 'empty uri (${backgroundMediaKey(next)})';
      _log.w('background open refused $errorText');
      _notify();
      return;
    }
    // Generation token: rapid step/seek can interleave two opens, and only the
    // LAST one may clear isInitializing / publish an error.
    final int gen = ++_openGen;
    file = next;
    isInitializing = true;
    _ended = false;
    errorText = null;
    _notify();

    final mediaKey = backgroundMediaKey(next);

    // Resolve a wildcard WebDAV entry once and rebuild the address from the
    // storage record before either backend dials it. Failures land in
    // [errorText] — this surface has no dialog of its own.
    var playUri = next.uri;
    final bgStorage = useStorageStore().findById(next.storageId);
    if (bgStorage is WebDAVStorage) {
      final target = await webdavPlaybackTarget(bgStorage, next.path);
      if (target.uri == null) {
        if (gen == _openGen) {
          await _haltPlayback();
          errorText = target.failure!.errorDetail ??
              'webdav host unresolved (${bgStorage.host})';
          _log.w('background webdav unresolved $mediaKey: $errorText');
          isInitializing = false;
          _notify();
        }
        return;
      }
      playUri = target.uri!;
    }

    if (backend == PlayerBackend.mediaKit) {
      final player = _mk;
      if (player == null) {
        if (gen == _openGen) {
          isInitializing = false;
          _notify();
        }
        return;
      }
      final storage = bgStorage;
      final auth = storage?.getAuth();
      final needsLocalRepair = checkDataSourceType(next) == DataSourceType.file;
      final media = media_kit.Media(
        next.storageType == StorageType.ftp
            ? '${MediaStream().url}/$playUri'
            : needsLocalRepair
                ? sanitizePlayableUri(playUri)
                : playUri,
        httpHeaders: auth != null ? {'authorization': auth} : {},
      );
      try {
        // A newer open superseded this one while we awaited (WebDAV resolve, a
        // rapid step): never dial the stale media over the new one.
        if (gen != _openGen) return;
        await player.open(media, play: autoplay);
        // The idempotent setters above skip a re-issue, so re-apply the current
        // volume/rate here in case the reused Player reset them on open.
        await player.setRate(_rate);
        await player.setVolume(_volume0to100.toDouble());
      } catch (e) {
        if (gen == _openGen) {
          await _haltPlayback();
          errorText = '$e';
          _log.w('background mk open failed $mediaKey: $e');
        }
      }
    } else {
      final controller = switch (checkDataSourceType(next)) {
        DataSourceType.file =>
          VideoPlayerController.file(File(sanitizePlayableUri(playUri))),
        DataSourceType.contentUri =>
          VideoPlayerController.contentUri(Uri.parse(playUri)),
        _ => VideoPlayerController.networkUrl(Uri.parse(playUri)),
      };
      final old = _fvp;
      if (old != null && _fvpListener != null) {
        old.removeListener(_fvpListener!);
      }
      _fvp = controller;
      _fvpListener = () => _onFvpValue(controller);
      controller.addListener(_fvpListener!);
      try {
        await controller.initialize();
        // Generation-gated configuration: a newer open may have superseded
        // this one while we awaited. A stale controller must never be
        // configured or played — that was the double-sound path (playing a
        // controller the newer open already replaced). The gates below fall
        // through instead of returning early so the stray disposal at the
        // end still runs for every open.
        if (gen == _openGen) await controller.setPlaybackSpeed(_rate);
        if (gen == _openGen) await controller.setVolume(_volume0to100 / 100);
        if (gen == _openGen) await controller.setLooping(false);
        if (gen == _openGen && autoplay) {
          await controller.play();
        }
      } catch (e) {
        if (gen == _openGen) {
          await _haltPlayback();
          errorText = '$e';
          _log.w('background fvp open failed $mediaKey: $e');
        }
      }
      // Only dispose a controller we actually replaced and that is no longer
      // installed (a newer open may have taken over meanwhile).
      if (old != null && old != controller && old != _fvp) {
        old.dispose();
      }
    }
    if (gen != _openGen) return;
    isInitializing = false;
    _notify();
  }

  /// Halts the CURRENT runtime AND unloads its media.
  ///
  /// A refused/failed open (empty uri, unresolved WebDAV host, backend error)
  /// must never leave the previous file sounding under a ghost [file]: a bare
  /// `pause()` would let the autoplay path resume the stale media. Unloading
  /// releases the decoder/file handle while keeping `file`/`errorText` as the
  /// failure record; the next successful open re-creates the runtime.
  Future<void> _haltPlayback() async {
    try {
      if (backend == PlayerBackend.mediaKit) {
        await _mk?.stop();
      } else {
        final controller = _fvp;
        if (controller != null) {
          if (_fvpListener != null) controller.removeListener(_fvpListener!);
          _fvpListener = null;
          _fvp = null;
          await controller.dispose();
        }
      }
    } catch (e) {
      _log.w('background halt failed: $e');
    }
    isPlaying = false;
    position = Duration.zero;
    duration = Duration.zero;
  }

  Future<void> play() async {
    if (_ended) {
      await replay();
      return; // replay() already resumed playback.
    }
    // No loaded runtime (a refused/failed open unloaded it): playing would
    // either be a no-op or resume stale media. The host re-opens on the next
    // successful target; here it is simply nothing to start.
    if (backend == PlayerBackend.mediaKit) {
      if (_mk == null) return;
      await _mk!.play();
    } else {
      if (_fvp == null) return;
      await _fvp!.play();
    }
  }

  Future<void> pause() async {
    if (backend == PlayerBackend.mediaKit) {
      await _mk?.pause();
    } else {
      await _fvp?.pause();
    }
  }

  /// True STOP (not just pause): unloads the media and releases the
  /// decoder/file handle while keeping the warm native instance (MediaKit
  /// Player, FVP warm-empty) for the next open. Used when 副音 is switched
  /// off so the subsystem reaches a definite stopped state instead of leaving
  /// the previous file loaded — and invalidates any in-flight open, which a
  /// bare pause could never do.
  Future<void> stop() async {
    // A newer generation: an open racing this stop must not publish its file
    // or configure a runtime we just unloaded.
    _openGen++;
    _ended = false;
    if (backend == PlayerBackend.mediaKit) {
      await _mk?.stop();
    } else {
      final controller = _fvp;
      if (controller != null) {
        if (_fvpListener != null) controller.removeListener(_fvpListener!);
        _fvpListener = null;
        _fvp = null;
        await controller.dispose();
      }
    }
    file = null;
    errorText = null;
    isInitializing = false;
    isPlaying = false;
    position = Duration.zero;
    duration = Duration.zero;
    _notify();
  }

  Future<void> seek(Duration target) async {
    // A seek means "no longer parked at the natural end": drop the completion
    // latch so a following [play] resumes AT the sought position instead of
    // re-entering [replay] (which would jump to 00:00). The cross-file
    // continuation parks the pair inside the file that is already open, where
    // no re-open would ever clear the latch.
    _ended = false;
    final clamped = _clamp(target);
    if (backend == PlayerBackend.mediaKit) {
      await _mk?.seek(clamped);
    } else {
      await _fvp?.seekTo(clamped);
    }
  }

  Future<void> backward(int seconds) async {
    await seek(position - Duration(seconds: seconds));
  }

  Future<void> forward(int seconds) async {
    await seek(position + Duration(seconds: seconds));
  }

  Future<void> setRate(double rate) async {
    if (rate == _rate) return;
    _rate = rate;
    if (backend == PlayerBackend.mediaKit) {
      await _mk?.setRate(rate);
    } else {
      await _fvp?.setPlaybackSpeed(rate);
    }
  }

  Future<void> setVolume(int volume0to100) async {
    if (volume0to100 == _volume0to100) return;
    _volume0to100 = volume0to100;
    if (backend == PlayerBackend.mediaKit) {
      await _mk?.setVolume(volume0to100.toDouble());
    } else {
      await _fvp?.setVolume(volume0to100 / 100);
    }
  }

  /// Natural-end handling: reseek to the start and resume. Clears the
  /// completed latch first so [play]'s ended-guard doesn't re-enter [replay].
  Future<void> replay() async {
    _ended = false;
    await seek(Duration.zero);
    await play();
  }

  void _fireCompleted() {
    if (_ended) return;
    _ended = true;
    isPlaying = false;
    _notify();
    onCompleted?.call();
  }

  // ── MediaPlayer bridge (shared controls read this while targeted) ──

  /// Builds a base [MediaPlayer] view of this engine for the shared control
  /// surface. Base only — the controls never downcast it, and the real
  /// video widgets read the raw controllers instead.
  ///
  /// [seekCeilingMs] caps every seek issued THROUGH THIS VIEW (slider,
  /// keyboard, gestures, step buttons) at a file-local position — the 仅当前
  /// + 高同步 bound keeping bg within the fg file 0–100%. [seekFloorMs] is its
  /// paired lower bound (the position mapped to fg 00:00; before it 副音 does
  /// not exist). Null = free. Internal engine seeks (alignment, tiling,
  /// mapping, replay) bypass the view and are unaffected.
  MediaPlayer asMediaPlayer({int? seekFloorMs, int? seekCeilingMs}) {
    Future<void> seekCapped(Duration target) async {
      var ms = target.inMilliseconds;
      final floor = seekFloorMs;
      final ceiling = seekCeilingMs;
      if (ceiling != null && floor != null && floor > ceiling) {
        // Empty playable window (the whole file sits outside the fg window):
        // park at the window edge instead of an out-of-range position.
        ms = ceiling;
      } else {
        if (floor != null && ms < floor) ms = floor;
        if (ceiling != null && ms > ceiling) ms = ceiling;
      }
      await seek(Duration(milliseconds: ms));
    }

    return MediaPlayer(
      isInitializing: isInitializing,
      isPlaying: isPlaying,
      externalSubtitles: const [],
      position: position,
      duration: duration,
      buffer: duration, // no buffer tracking for the secondary runtime
      width: 0,
      height: 0,
      saveProgress: () async {},
      play: play,
      pause: pause,
      backward: (seconds) => seekCapped(position - Duration(seconds: seconds)),
      forward: (seconds) => seekCapped(position + Duration(seconds: seconds)),
      stepBackward: () => seekCapped(position - const Duration(seconds: 5)),
      stepForward: () => seekCapped(position + const Duration(seconds: 5)),
      seek: seekCapped,
    );
  }

  @override
  void dispose() {
    _trailingNotify?.cancel();
    _trailingNotify = null;
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    if (_fvp != null && _fvpListener != null) {
      _fvp!.removeListener(_fvpListener!);
    }
    _fvpListener = null;
    _fvp?.dispose();
    _fvp = null;
    _mk?.dispose();
    _mk = null;
    _mkVideo = null;
    super.dispose();
  }

  Duration _clamp(Duration target) {
    if (duration <= Duration.zero) return target;
    if (target < Duration.zero) return Duration.zero;
    if (target > duration) return duration;
    return target;
  }

  void _notifyThrottled() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastNotify);
    if (elapsed >= _kNotifyInterval) {
      _notify();
      return;
    }
    // Keep a trailing notify so a coalesced burst never loses its LAST sample:
    // without it a dropped final position/state tick leaves the UI and the
    // mirror effect permanently stale.
    _trailingNotify ??= Timer(_kNotifyInterval - elapsed, () {
      _trailingNotify = null;
      _notify();
    });
  }

  void _notify() {
    _trailingNotify?.cancel();
    _trailingNotify = null;
    _lastNotify = DateTime.now();
    notifyListeners();
  }
}
