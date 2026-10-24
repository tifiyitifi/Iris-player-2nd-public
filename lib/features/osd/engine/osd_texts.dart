import 'package:flutter/material.dart' show Icons, IconData;
import 'package:iris/features/osd/model/osd_entry.dart';
import 'package:iris/l10n/app_localizations.dart';

/// PotPlayer-aligned OSD text helpers. Each helper returns an [OsdEntry]
/// with line1/line2/icon/progress already formatted — the executor owns
/// `when` to show, this module owns `what` to show (pure, no store access).
abstract final class OsdTexts {
  static String _fmtClock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  static String _fmtDelta(Duration d) {
    final sign = d.isNegative ? '-' : '+';
    final a = d.abs();
    return '$sign${_fmtClock(a)}';
  }

  // ── Generic ────────────────────────────────────────────────────────────
  static OsdEntry generic(String title, String? value,
          {IconData? icon, double? progress}) =>
      OsdEntry(line1: title, line2: value, icon: icon, progress: progress);

  // ── Volume / mute ──────────────────────────────────────────────────────
  static OsdEntry volume(int v, AppLocalizations t) => OsdEntry(
        line1: t.osd_volume,
        line2: '$v%',
        icon: v == 0 ? Icons.volume_off : v < 50 ? Icons.volume_down : Icons.volume_up,
        progress: (v / 100).clamp(0.0, 1.0),
      );

  static OsdEntry mute(bool muted, AppLocalizations t) => OsdEntry(
        line1: muted ? t.osd_muted : t.osd_unmuted,
        line2: muted ? '—' : null,
        icon: muted ? Icons.volume_off : Icons.volume_up,
      );

  // ── Speed ──────────────────────────────────────────────────────────────
  static OsdEntry speed(double rate, AppLocalizations t, {bool reset = false}) =>
      OsdEntry(
        line1: reset ? t.osd_speed_reset : t.osd_speed,
        line2: '${rate.toStringAsFixed(1)}×',
        icon: Icons.speed_rounded,
      );

  // ── Seek (delta + absolute) ────────────────────────────────────────────
  static OsdEntry seek(
    AppLocalizations t, {
    required Duration delta,
    required Duration position,
    required Duration duration,
  }) {
    final pos = _fmtClock(position);
    final dur = duration > Duration.zero ? ' / ${_fmtClock(duration)}' : '';
    return OsdEntry(
      line1: t.osd_seek_delta(_fmtDelta(delta)),
      line2: '$pos$dur',
      icon: delta.isNegative ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
    );
  }

  static OsdEntry seekTo(
      AppLocalizations t, Duration target, Duration duration) {
    final dur = duration > Duration.zero ? ' / ${_fmtClock(duration)}' : '';
    return OsdEntry(
      line1: t.osd_seek,
      line2: '${_fmtClock(target)}$dur',
      icon: Icons.place_rounded,
    );
  }

  /// Base-step adjust feedback (Ctrl+↑/↓ ±1s, Ctrl+Shift+↑/↓ ±10s).
  static OsdEntry seekStep(int seconds, AppLocalizations t) => OsdEntry(
        line1: t.osd_seek_step,
        line2: '${seconds}s',
        icon: Icons.update,
      );

  // ── Frame step ─────────────────────────────────────────────────────────
  static OsdEntry frame(bool forward, AppLocalizations t) => OsdEntry(
        line1: forward ? t.osd_next_frame : t.osd_prev_frame,
        line2: forward ? '+1' : '-1',
        icon: forward ? Icons.skip_next_rounded : Icons.skip_previous_rounded,
      );

  // ── Sync ───────────────────────────────────────────────────────────────
  static OsdEntry subtitleSync(double seconds, AppLocalizations t) => OsdEntry(
        line1: t.osd_sub_sync,
        line2: '${seconds >= 0 ? '+' : ''}${seconds.toStringAsFixed(1)}s',
        icon: Icons.subtitles_rounded,
      );

  static OsdEntry audioSync(double seconds, AppLocalizations t) => OsdEntry(
        line1: t.osd_audio_sync,
        line2: '${seconds >= 0 ? '+' : ''}${seconds.toStringAsFixed(1)}s',
        icon: Icons.audiotrack_rounded,
      );

  // ── AB loop ────────────────────────────────────────────────────────────
  static OsdEntry abPointA(Duration a) => OsdEntry(
        line1: 'A',
        line2: _fmtClock(a),
        icon: Icons.cut_rounded,
      );

  static OsdEntry abPointB(Duration b) => OsdEntry(
        line1: 'B',
        line2: _fmtClock(b),
        icon: Icons.cut_rounded,
      );

  static OsdEntry abLoop(
          bool enabled, Duration? a, Duration? b, AppLocalizations t) =>
      OsdEntry(
        line1: enabled ? t.osd_loop_on : t.osd_loop_off,
        line2: (a != null && b != null) ? '${_fmtClock(a)} ↔ ${_fmtClock(b)}' : null,
        icon: Icons.repeat_rounded,
      );

  // ── Fit / track ───────────────────────────────────────────────────────
  static OsdEntry fit(String label, AppLocalizations t) =>
      OsdEntry(line1: t.osd_fit, line2: label, icon: Icons.aspect_ratio_rounded);

  /// 视频显示模式变更反馈（metadata era；label 来自
  /// [desktopVideoDisplayModeLabel]/[mobileVideoDisplayModeLabel]）.
  static OsdEntry videoDisplayMode(String label, AppLocalizations t) =>
      OsdEntry(line1: t.osd_display_mode, line2: label, icon: Icons.aspect_ratio_rounded);

  /// 窗口适应模式变更反馈（Windows-only, metadata era）.
  static OsdEntry windowFitMode(AppLocalizations t,
          {required bool fitVideo}) =>
      OsdEntry(
        line1: fitVideo ? t.osd_window_fit : t.osd_window_fixed,
        line2: fitVideo ? t.osd_window_fit_desc : t.osd_window_fixed_desc,
        icon: fitVideo ? Icons.open_in_full_rounded : Icons.lock_outline_rounded,
      );

  static OsdEntry subtitleTrack(String label, AppLocalizations t) =>
      OsdEntry(line1: t.osd_subtitle, line2: label, icon: Icons.subtitles_rounded);

  static OsdEntry audioTrack(String label, AppLocalizations t) =>
      OsdEntry(line1: t.osd_audio, line2: label, icon: Icons.audiotrack_rounded);

  static OsdEntry subtitleVisibility(bool visible, AppLocalizations t) =>
      OsdEntry(
        line1: visible ? t.osd_subtitles_on : t.osd_subtitles_off,
        icon: visible ? Icons.subtitles_rounded : Icons.subtitles_off_rounded,
      );

  // ── Repeat / shuffle / always-on-top / fullscreen ─────────────────────
  static OsdEntry repeat(String mode, AppLocalizations t) =>
      OsdEntry(line1: t.osd_repeat, line2: mode, icon: Icons.repeat_rounded);
  static OsdEntry shuffle(bool on, AppLocalizations t) => OsdEntry(
      line1: on ? t.osd_shuffle_on : t.osd_shuffle_off,
      icon: Icons.shuffle_rounded);
  static OsdEntry alwaysOnTop(bool on, AppLocalizations t) => OsdEntry(
      line1: on ? t.osd_on_top_on : t.osd_on_top_off,
      icon: Icons.push_pin_rounded);
  static OsdEntry fullscreen(bool on, AppLocalizations t) => OsdEntry(
      line1: on ? t.osd_fullscreen : t.osd_windowed,
      icon: on ? Icons.fullscreen_rounded : Icons.fullscreen_exit_rounded);

  // ── Screenshot / delete ────────────────────────────────────────────────
  static OsdEntry screenshot(String path, AppLocalizations t) => OsdEntry(
      line1: t.osd_shot_saved, line2: path, icon: Icons.camera_alt_rounded);
  static OsdEntry screenshotFailed(AppLocalizations t) => OsdEntry(
      line1: t.osd_shot_failed, icon: Icons.error_outline_rounded);
  static OsdEntry deleted(AppLocalizations t) =>
      OsdEntry(line1: t.osd_moved_recycle, icon: Icons.delete_rounded);
  static OsdEntry deleteUnavailable(AppLocalizations t) => OsdEntry(
      line1: t.osd_delete_unavailable, icon: Icons.error_outline_rounded);

  // ── Playlist dock / playback / auto-fit ──────────────────────────────
  static OsdEntry dockVisibility(bool visible, AppLocalizations t) => OsdEntry(
      line1: visible ? t.osd_dock_shown : t.osd_dock_hidden,
      icon: Icons.playlist_play_rounded);
  static OsdEntry dockMode(bool docked, AppLocalizations t) => OsdEntry(
      line1: docked ? t.osd_dock_docked : t.osd_dock_floating,
      icon: docked
          ? Icons.view_sidebar_rounded
          : Icons.open_in_new_rounded);
  static OsdEntry playbackClosed(AppLocalizations t) =>
      OsdEntry(line1: t.osd_playback_closed, icon: Icons.stop_rounded);
  static OsdEntry autoFit(bool on, AppLocalizations t) => OsdEntry(
        line1: on ? t.osd_auto_fit_on : t.osd_auto_fit_off,
        line2: on ? t.osd_auto_fit_on_desc : t.osd_auto_fit_off_desc,
        icon: Icons.aspect_ratio_rounded,
      );

  // ── Transport ──────────────────────────────────────────────────────────
  static OsdEntry previous(AppLocalizations t) => OsdEntry(
      line1: t.osd_previous, icon: Icons.skip_previous_rounded);
  static OsdEntry next(AppLocalizations t) =>
      OsdEntry(line1: t.osd_next, icon: Icons.skip_next_rounded);
  static OsdEntry paused(AppLocalizations t) =>
      OsdEntry(line1: t.osd_paused, icon: Icons.pause_rounded);
  static OsdEntry playing(AppLocalizations t) =>
      OsdEntry(line1: t.osd_playing, icon: Icons.play_arrow_rounded);
}
