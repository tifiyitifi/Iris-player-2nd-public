import 'package:flutter/material.dart';
import 'package:iris/models/file.dart';
import 'package:media_kit/media_kit.dart' as media_kit;
import 'package:media_kit_video/media_kit_video.dart' as media_kit_video;
import 'package:video_player/video_player.dart';

/// One sync nudge = 0.5s — the canonical step shared by the keyboard scheme
/// (features/windows/desktop_keyboard) and any track-panel controls.
const Duration kSyncStep = Duration(milliseconds: 500);

class MediaPlayer {
  final bool isInitializing;
  final bool isPlaying;
  final List<Subtitle> externalSubtitles;
  final Duration position;
  final Duration duration;
  final Duration buffer;
  final double width;
  final double height;
  final Future<void> Function() saveProgress;
  final Future<void> Function() play;
  final Future<void> Function() pause;
  final Future<void> Function(int) backward;
  final Future<void> Function(int) forward;
  final Future<void> Function() stepBackward;
  final Future<void> Function() stepForward;
  final Future<void> Function(Duration) seek;

  /// Latest accumulated step-seek target (ms, on the same axis as [position])
  /// while a ← / → / double-tap step is heading to its target, else null. The
  /// OSD reads this instead of the pre-seek [position] snapshot so the shown
  /// time matches where the seek is heading rather than where it just was.
  final int? Function()? stepIntentTargetMs;

  /// Collapses a held step-seek burst to its final target when the ← / →
  /// key is released, so the walk stops within one landing instead of draining
  /// every auto-repeated press. Null on backends without the chained step
  /// scheduler (fvp), where there is nothing to collapse.
  final Future<void> Function()? endStepBurst;

  // ── Capability stubs (P0 track/sync features) ──
  //
  // Backends without the underlying capability keep these as silent no-ops;
  // UI entry points consult the getters so unsupported controls are never
  // offered (fvp: no multi-track sync / delay properties).
  bool get supportsTrackSelection => false;
  bool get supportsSyncAdjustment => false;

  /// Live visibility of the subtitle layer (hide = select the "no" track).
  bool get subtitlesVisible => true;

  Future<void> cycleSubtitleTrack() async {}
  Future<void> cycleAudioTrack() async {}
  Future<void> setSubtitlesVisible(bool visible) async {}

  /// [direction] is +1 (advance/later) or -1 (delay/earlier), one 0.5s step
  /// per call (see desktop_keyboard/controller/sync_steps.dart).
  Future<void> nudgeSubtitleSync(int direction) async {}
  Future<void> resetSubtitleSync() async {}
  Future<void> nudgeAudioSync(int direction) async {}
  Future<void> resetAudioSync() async {}

  MediaPlayer({
    required this.isInitializing,
    required this.isPlaying,
    required this.externalSubtitles,
    required this.position,
    required this.duration,
    required this.buffer,
    required this.width,
    required this.height,
    required this.saveProgress,
    required this.play,
    required this.pause,
    required this.backward,
    required this.forward,
    required this.stepBackward,
    required this.stepForward,
    required this.seek,
    this.stepIntentTargetMs,
    this.endStepBurst,
  });
}

class MediaKitPlayer extends MediaPlayer {
  final media_kit.Player player;
  final media_kit_video.VideoController controller;
  final media_kit.SubtitleTrack subtitle;
  final List<media_kit.SubtitleTrack> subtitles;
  final media_kit.AudioTrack audio;
  final List<media_kit.AudioTrack> audios;

  double _subtitleDelaySeconds = 0;
  double _audioDelaySeconds = 0;
  media_kit.SubtitleTrack? _trackBeforeHide;

  static const String _kSubDelayProp = 'sub-delay';
  static const String _kAudioDelayProp = 'audio-delay';

  @override
  bool get supportsTrackSelection => true;

  @override
  bool get supportsSyncAdjustment => true;

  @override
  bool get subtitlesVisible => subtitle.id != 'no';

  Future<void> _applyDelay(String property, double seconds) async {
    final platform = player.platform;
    if (platform is media_kit.NativePlayer) {
      await platform.setProperty(property, seconds.toString());
    }
  }

  @override
  Future<void> cycleSubtitleTrack() async {
    if (subtitles.isEmpty) return;
    final idx = subtitles.indexOf(subtitle);
    final next = subtitles[(idx + 1) % subtitles.length];
    await player.setSubtitleTrack(next);
  }

  @override
  Future<void> cycleAudioTrack() async {
    if (audios.isEmpty) return;
    final idx = audios.indexOf(audio);
    final next = audios[(idx + 1) % audios.length];
    await player.setAudioTrack(next);
  }

  @override
  Future<void> setSubtitlesVisible(bool visible) async {
    if (!visible) {
      if (subtitle.id != 'no') _trackBeforeHide = subtitle;
      await player.setSubtitleTrack(media_kit.SubtitleTrack.no());
      return;
    }
    await player.setSubtitleTrack(_trackBeforeHide ?? media_kit.SubtitleTrack.auto());
    _trackBeforeHide = null;
  }

  @override
  Future<void> nudgeSubtitleSync(int direction) async {
    _subtitleDelaySeconds =
        _subtitleDelaySeconds + direction * (kSyncStep.inMilliseconds / 1000.0);
    await _applyDelay(_kSubDelayProp, _subtitleDelaySeconds);
  }

  @override
  Future<void> resetSubtitleSync() async {
    _subtitleDelaySeconds = 0;
    await _applyDelay(_kSubDelayProp, 0);
  }

  @override
  Future<void> nudgeAudioSync(int direction) async {
    _audioDelaySeconds = _audioDelaySeconds + direction * (kSyncStep.inMilliseconds / 1000.0);
    await _applyDelay(_kAudioDelayProp, _audioDelaySeconds);
  }

  @override
  Future<void> resetAudioSync() async {
    _audioDelaySeconds = 0;
    await _applyDelay(_kAudioDelayProp, 0);
  }

  MediaKitPlayer({
    required this.player,
    required this.controller,
    required this.subtitle,
    required this.subtitles,
    required super.externalSubtitles,
    required this.audio,
    required this.audios,
    required super.isInitializing,
    required super.isPlaying,
    required super.position,
    required super.duration,
    required super.buffer,
    required super.width,
    required super.height,
    required super.saveProgress,
    required super.play,
    required super.pause,
    required super.backward,
    required super.forward,
    required super.stepBackward,
    required super.stepForward,
    required super.seek,
    super.stepIntentTargetMs,
    super.endStepBurst,
  });
}

class FvpPlayer extends MediaPlayer {
  final VideoPlayerController controller;
  final ValueNotifier<int?> externalSubtitle;

  FvpPlayer({
    required this.controller,
    required super.isInitializing,
    required super.isPlaying,
    required this.externalSubtitle,
    required super.externalSubtitles,
    required super.position,
    required super.duration,
    required super.buffer,
    required super.width,
    required super.height,
    required super.saveProgress,
    required super.play,
    required super.pause,
    required super.backward,
    required super.forward,
    required super.stepBackward,
    required super.stepForward,
    required super.seek,
  });
}
