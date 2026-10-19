import 'package:flutter/material.dart';
import 'package:iris/models/file.dart';
import 'package:iris/pages/player/control_bar/control_bar_slider.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/control_bar_circle_slider.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/fit_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/fullscreen_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/more_menu_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/next_previous_buttons.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/play_pause_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/play_queue_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/playlist_dock_mode_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/rate_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/repeat_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/rotate_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/screen_lock_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/shuffle_button.dart';
import 'package:iris/features/background_playback/model/enum/bg_quick_bar_align.dart';
import 'package:iris/features/background_playback/view/background_quick_bar.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/resolve_control_bar_overflow.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/background_playback_menu_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/stop_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/storage_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/subtitle_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/volume_widget.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/window_fit_mode_button.dart';
import 'package:iris/utils/platform.dart';

class ControlBarControls {
  ControlBarControls({
    required this.showControl,
    required this.showControlForHover,
    required this.color,
    required this.overlayColor,
    required this.file,
    required this.circleScale,
    this.quickBarAlign = BgQuickBarAlign.right,
    this.collapsed = const <ControlBarSlot>{},
  });

  final VoidCallback showControl;
  final Future<void> Function(Future<void> callback) showControlForHover;
  final Color? color;
  final WidgetStateProperty<Color?>? overlayColor;
  final FileItem? file;
  final double circleScale; // 0.0 → 1.0

  /// Where the 副音 quick row sits in the linear layouts.
  final BgQuickBarAlign quickBarAlign;

  /// Optional slots the bar must push into the More menu at the current width
  /// (see `resolveControlBarOverflow`). Every builder here filters on it, so a
  /// collapsed control disappears from the bar AND appears in More.
  final Set<ControlBarSlot> collapsed;

  bool isCollapsed(ControlBarSlot slot) => collapsed.contains(slot);


  bool get showFit => file?.type != ContentType.audio;

  /// Mobile-only screen-lock entry (phone + tablet video). A desktop pointer
  /// cannot mis-touch the surface the way a palm can, and an audio item has
  /// no full-screen video to guard. Carried by the playback ROW on phones (it
  /// took the slot the 副音 menu button vacated); desktop keeps the 副音 menu
  /// there and never arms the guard.
  bool get showScreenLock =>
      isMobilePlatform && file?.type == ContentType.video;

  /// Desktop-only 窗口适应模式 toggle (gate-ON era; legacy mode keeps the
  /// autoResize settings checkbox). Videos only — a fixed-size audio cover
  /// has nothing to fit.
  bool get showWindowFit => isDesktop && file?.type != ContentType.audio;

  Widget get playPause =>
      PlayPauseButton(showControl: showControl, color: color, overlayColor: overlayColor);
  Widget get stop => StopButton(showControl: showControl, color: color, overlayColor: overlayColor);
  Widget get prev => PrevButton(showControl: showControl, color: color, overlayColor: overlayColor);
  Widget get next => NextButton(showControl: showControl, color: color, overlayColor: overlayColor);
  Widget get shuffle =>
      ShuffleButton(showControl: showControl, color: color, overlayColor: overlayColor);
  Widget get repeat =>
      RepeatButton(showControl: showControl, color: color, overlayColor: overlayColor);
  Widget get fit => FitButton(showControl: showControl, color: color, overlayColor: overlayColor);
  Widget get windowFitMode => WindowFitModeButton(
      showControl: showControl, color: color, overlayColor: overlayColor);
  Widget get rate => RateButton(showControl: showControl, color: color, overlayColor: overlayColor);
  Widget get rotate =>
      RotateButton(showControl: showControl, color: color, overlayColor: overlayColor);

  Widget get volume => AdaptiveVolumeControl(
        showControl: showControl,
        showControlForHover: showControlForHover,
        color: color,
        overlayColor: overlayColor,
      );

  /// Mobile-only screen-lock toggle. It occupies the slot the 副音 menu button
  /// used to hold on the playback row (that menu now lives in the 副音 control
  /// group), so it follows the same condition the old More-menu entry did —
  /// phone + tablet video only. Desktop never arms the touch guard, and it keeps
  /// the 副音 menu in that slot instead.
  Widget get screenLock => ScreenLockButton(
      showControl: showControl, color: color, overlayColor: overlayColor);

  Widget get subtitle => SubtitleButton(
      color: color, overlayColor: overlayColor, showControlForHover: showControlForHover);
  // 副音 menu replaces the former seek-step slot on every bar (sub_media
  // §3/§4): seek step moved into More, the secondary player got its own menu.
  Widget get backgroundPlaybackMenu => BackgroundPlaybackMenuButton(
      showControl: showControl, color: color, overlayColor: overlayColor);

  /// 副音 quick-control row (第 3 轮问题 5) — inserted between the slider and
  /// the button rows in the linear layouts. Alignment follows the
  /// `background_playback.quickBarAlign` meta row.
  Widget get backgroundQuickBar => BackgroundQuickBar(
        axis: Axis.horizontal,
        alignment: quickBarAlign == BgQuickBarAlign.left
            ? MainAxisAlignment.start
            : MainAxisAlignment.end,
        color: color,
        overlayColor: overlayColor,
      );
  Widget get playQueue => PlayQueueButton(
      color: color, overlayColor: overlayColor, showControlForHover: showControlForHover);
  Widget get playlistDockMode => PlaylistDockModeButton(
      showControl: showControl, color: color, overlayColor: overlayColor);
  Widget get storage => StorageButton(
      color: color, overlayColor: overlayColor, showControlForHover: showControlForHover);
  Widget get fullscreen =>
      FullscreenButton(showControl: showControl, color: color, overlayColor: overlayColor);
  Widget get more => MoreMenuButton(
      showControl: showControl,
      showControlForHover: showControlForHover,
      color: color,
      overlayColor: overlayColor,
      collapsed: collapsed);

  Widget get slider => ControlBarSlider(showControl: showControl, color: color);

  /// Seek bar for the stacked desktop layout: identical behavior, but the
  /// position/duration texts are omitted (they live on their own line
  /// above), so the axis claims the full row width.
  Widget get stackedSlider =>
      ControlBarSlider(showControl: showControl, color: color, showTimeLabels: false);

  /// Left transport group of the desktop bar — everything that sits before
  /// the seek axis in [DesktopControlLayout]. Single source of truth for the
  /// one-line AND stacked arrangements (order must never drift between them).
  List<Widget> get desktopLeftButtons => [
        if (!isCollapsed(ControlBarSlot.playPause)) playPause,
        if (!isCollapsed(ControlBarSlot.stop)) stop,
        if (!isCollapsed(ControlBarSlot.prev)) prev,
        if (!isCollapsed(ControlBarSlot.next)) next,
        if (!isCollapsed(ControlBarSlot.shuffle)) shuffle,
        if (!isCollapsed(ControlBarSlot.repeat)) repeat,
        if (showFit && !isCollapsed(ControlBarSlot.fit)) fit,
        if (showWindowFit && !isCollapsed(ControlBarSlot.windowFitMode))
          windowFitMode,
        if (!isCollapsed(ControlBarSlot.rate)) rate,
        if (!isCollapsed(ControlBarSlot.volume)) rotateOrVolume,
      ];

  /// Right group of the desktop bar — restores subtitle lost vs legacy.
  /// Playlist dock toggle lives ONLY in the side panel ([CircleSliderLayout]).
  ///
  /// The screen-lock toggle rides the same slot the phone bar puts it in (after
  /// the 副音 menu, before the queue): an Android tablet at desktop width — where
  /// the bar renders this group — must still be able to arm the touch guard.
  /// On the desktop app the condition is false, so the arrangement is unchanged.
  List<Widget> get desktopRightButtons => [
        if (!isCollapsed(ControlBarSlot.subtitle)) subtitle,
        if (!isCollapsed(ControlBarSlot.backgroundMenu)) backgroundPlaybackMenu,
        if (showScreenLock) screenLock,
        if (!isCollapsed(ControlBarSlot.playQueue)) playQueue,
        if (!isCollapsed(ControlBarSlot.storage)) storage,
        if (isDesktop && !isCollapsed(ControlBarSlot.fullscreen)) fullscreen,
        more,
      ];

  Widget get circleSlider => ControlBarCircleSlider(
        showControl: showControl,
        color: color,
        circleScale: circleScale,
      );

  Widget get rotateOrVolume => isMobilePlatform ? rotate : volume;
}
