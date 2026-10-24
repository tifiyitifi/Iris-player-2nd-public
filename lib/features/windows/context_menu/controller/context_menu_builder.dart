import 'package:flutter/material.dart';
import 'package:iris/features/windows/context_menu/model/context_menu_entry.dart';
import 'package:iris/features/windows/desktop_keyboard/model/potplayer_action.dart';

/// Pure builder for the PotPlayer-style Windows context menu.
///
/// Inputs are capability/state flags only — no BuildContext, no store reads —
/// so the function is trivially unit-testable. Callers supply the flags
/// derived from MediaPlayer / AppState / PlayerUiState.
List<ContextMenuEntry> buildPotPlayerContextMenu({
  required bool isMediaKit,
  required bool supportsSync,
  required bool supportsTrack,
  required bool isFullScreen,
  required bool isAlwaysOnTop,
  required String seekStepLabel,
  required String seekStepHint,
  // Reveal-the-playing-file entry: hidden unless the caller resolved a
  // Windows-revealable current media (local/USB/network with an on-disk path).
  // The label is injected for localization; the default keeps pure builder
  // calls (tests, callers without l10n) usable.
  bool canRevealInExplorer = false,
  String revealInExplorerLabel = 'Open in Explorer',
}) {
  // ── Capability-gated submenus ──
  final bool showSyncSubmenus = supportsSync;
  final bool showTrackSubmenus = supportsTrack;
  final bool showScreenshot = isMediaKit;

  // Playback-speed submenu
  final List<ContextMenuEntry> speedChildren = [
    const ContextMenuItem(
      label: 'Speed up (\\ )',
      icon: Icons.speed_rounded,
      action: PotPlayerAction.speedUp,
    ),
    const ContextMenuItem(
      label: 'Speed down (Shift+\\ )',
      icon: Icons.speed_rounded,
      action: PotPlayerAction.speedDown,
    ),
    const ContextMenuItem(
      label: 'Reset speed (*)',
      icon: Icons.restart_alt_rounded,
      action: PotPlayerAction.speedReset,
    ),
  ];

  // A-B loop submenu
  final List<ContextMenuEntry> abChildren = [
    const ContextMenuItem(
      label: 'Set point A',
      icon: Icons.flag_rounded,
      action: PotPlayerAction.abSetPointA,
    ),
    const ContextMenuItem(
      label: 'Set point B',
      icon: Icons.flag_rounded,
      action: PotPlayerAction.abSetPointB,
    ),
    const ContextMenuItem(
      label: 'Quick A-B toggle',
      icon: Icons.repeat_rounded,
      action: PotPlayerAction.abQuickToggle,
    ),
    const ContextMenuItem(
      label: 'Toggle section repeat',
      icon: Icons.repeat_on_rounded,
      action: PotPlayerAction.abToggleSectionRepeat,
    ),
  ];

  final List<ContextMenuEntry> subtitleSyncChildren = [
    const ContextMenuItem(
      label: 'Earlier (-0.5s)',
      icon: Icons.timer_outlined,
      action: PotPlayerAction.subtitleSyncBackward,
    ),
    const ContextMenuItem(
      label: 'Later (+0.5s)',
      icon: Icons.timer_outlined,
      action: PotPlayerAction.subtitleSyncForward,
    ),
    const ContextMenuItem(
      label: 'Reset',
      icon: Icons.restart_alt_rounded,
      action: PotPlayerAction.subtitleSyncReset,
    ),
  ];

  final List<ContextMenuEntry> audioSyncChildren = [
    const ContextMenuItem(
      label: 'Earlier (-0.5s)',
      icon: Icons.timer_outlined,
      action: PotPlayerAction.audioSyncBackward,
    ),
    const ContextMenuItem(
      label: 'Later (+0.5s)',
      icon: Icons.timer_outlined,
      action: PotPlayerAction.audioSyncForward,
    ),
    const ContextMenuItem(
      label: 'Reset',
      icon: Icons.restart_alt_rounded,
      action: PotPlayerAction.audioSyncReset,
    ),
  ];

  return [
    // ── Open ──
    const ContextMenuSubmenu(
      label: 'Open',
      icon: Icons.folder_open_rounded,
      children: [
        ContextMenuItem(
          label: 'Open file...',
          icon: Icons.file_open_rounded,
          action: PotPlayerAction.openFile,
        ),
        ContextMenuItem(
          label: 'Open link...',
          icon: Icons.link_rounded,
          action: PotPlayerAction.openLink,
        ),
      ],
    ),
    // ── Reveal the playing file (Windows-only; gated by the caller) ──
    // Top-level placement: this is a direct "where is this file?" action, not
    // an open-a-new-media intent, so it sits next to Open rather than inside it.
    if (canRevealInExplorer)
      ContextMenuItem(
        label: revealInExplorerLabel,
        icon: Icons.desktop_windows_rounded,
        action: PotPlayerAction.revealCurrentFileInExplorer,
      ),
    const ContextMenuDivider(),

    // ── Playback ──
    ContextMenuSubmenu(
      label: 'Playback',
      icon: Icons.play_circle_outline_rounded,
      children: [
        const ContextMenuItem(
          label: 'Play / Pause (Space)',
          icon: Icons.play_arrow_rounded,
          action: PotPlayerAction.playPause,
        ),
        const ContextMenuItem(
          label: 'Previous (PgUp)',
          icon: Icons.skip_previous_rounded,
          action: PotPlayerAction.previousItem,
        ),
        const ContextMenuItem(
          label: 'Next (PgDn)',
          icon: Icons.skip_next_rounded,
          action: PotPlayerAction.nextItem,
        ),
        const ContextMenuItem(
          label: 'Jump to time (G)',
          icon: Icons.schedule_rounded,
          action: PotPlayerAction.jumpToTime,
        ),
        // Seek-step adjuster — same popover as the More menu. Menu-only action
        // (no key binding); the hint documents the direct keyboard path.
        ContextMenuItem(
          label: seekStepLabel,
          icon: Icons.update,
          action: PotPlayerAction.seekStepPopover,
          hint: seekStepHint,
        ),
        const ContextMenuDivider(),
        ContextMenuSubmenu(
          label: 'Speed',
          icon: Icons.speed_rounded,
          children: speedChildren,
        ),
        ContextMenuSubmenu(
          label: 'A-B loop',
          icon: Icons.repeat_rounded,
          children: abChildren,
        ),
        const ContextMenuDivider(),
        const ContextMenuItem(
          label: 'Toggle repeat',
          icon: Icons.repeat_rounded,
          action: PotPlayerAction.toggleRepeatMode,
        ),
        const ContextMenuItem(
          label: 'Toggle shuffle',
          icon: Icons.shuffle_rounded,
          action: PotPlayerAction.toggleShuffleMode,
        ),
      ],
    ),

    // ── Video ──
    ContextMenuSubmenu(
      label: 'Video',
      icon: Icons.videocam_rounded,
      children: [
        const ContextMenuItem(
          label: 'Cycle aspect ratio (J)',
          icon: Icons.aspect_ratio_rounded,
          action: PotPlayerAction.fitCycle,
        ),
        const ContextMenuItem(
          label: 'Frame step back (D)',
          icon: Icons.skip_previous_rounded,
          action: PotPlayerAction.frameBackward,
        ),
        const ContextMenuItem(
          label: 'Frame step forward (F)',
          icon: Icons.skip_next_rounded,
          action: PotPlayerAction.frameForward,
        ),
        if (showScreenshot)
          const ContextMenuItem(
            label: 'Capture frame (F1)',
            icon: Icons.camera_alt_rounded,
            action: PotPlayerAction.screenshotFrame,
          ),
      ],
    ),

    // ── Audio ──
    ContextMenuSubmenu(
      label: 'Audio',
      icon: Icons.volume_up_rounded,
      children: [
        if (showTrackSubmenus)
          const ContextMenuItem(
            label: 'Cycle audio track (A)',
            icon: Icons.audiotrack_rounded,
            action: PotPlayerAction.cycleAudioTrack,
          ),
        const ContextMenuItem(
          label: 'Mute (M)',
          icon: Icons.volume_off_rounded,
          action: PotPlayerAction.mute,
        ),
        if (showSyncSubmenus)
          ContextMenuSubmenu(
            label: 'Audio sync (+/-0.5s)',
            icon: Icons.timer_outlined,
            children: audioSyncChildren,
          ),
        if (showTrackSubmenus)
          const ContextMenuItem(
            label: 'Audio tracks panel',
            icon: Icons.queue_music_rounded,
            action: PotPlayerAction.audioTracksPanel,
          ),
      ],
    ),

    // ── Subtitle ──
    ContextMenuSubmenu(
      label: 'Subtitle',
      icon: Icons.subtitles_rounded,
      children: [
        if (showTrackSubmenus)
          const ContextMenuItem(
            label: 'Cycle subtitle track (S)',
            icon: Icons.subtitles_rounded,
            action: PotPlayerAction.cycleSubtitleTrack,
          ),
        if (showTrackSubmenus)
          const ContextMenuItem(
            label: 'Show / Hide subtitle',
            icon: Icons.visibility_rounded,
            action: PotPlayerAction.toggleSubtitleVisibility,
          ),
        if (showSyncSubmenus)
          ContextMenuSubmenu(
            label: 'Subtitle sync (+/-0.5s)',
            icon: Icons.timer_outlined,
            children: subtitleSyncChildren,
          ),
        if (showTrackSubmenus)
          const ContextMenuItem(
            label: 'Subtitle panel',
            icon: Icons.subtitles_rounded,
            action: PotPlayerAction.subtitlesPanel,
          ),
      ],
    ),

    const ContextMenuDivider(),

    // ── Window ──
    ContextMenuSubmenu(
      label: 'Window',
      icon: Icons.crop_square_rounded,
      children: [
        ContextMenuItem(
          label: isFullScreen ? 'Exit fullscreen (Esc)' : 'Fullscreen (Enter)',
          icon: isFullScreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
          action: isFullScreen ? PotPlayerAction.exitFullscreen : PotPlayerAction.fullscreen,
        ),
        ContextMenuItem(
          label: isAlwaysOnTop ? 'Always on top ✓' : 'Always on top (T)',
          icon: Icons.push_pin_rounded,
          action: PotPlayerAction.alwaysOnTop,
        ),
      ],
    ),

    const ContextMenuDivider(),

    // ── Panels ──
    const ContextMenuItem(
      label: 'Play queue',
      icon: Icons.playlist_play_rounded,
      action: PotPlayerAction.playQueue,
    ),
    const ContextMenuItem(
      label: 'History',
      icon: Icons.history_rounded,
      action: PotPlayerAction.historyPanel,
    ),
    const ContextMenuItem(
      label: 'Settings',
      icon: Icons.settings_rounded,
      action: PotPlayerAction.settings,
    ),

    const ContextMenuDivider(),

    const ContextMenuItem(
      label: 'Exit (Alt+X)',
      icon: Icons.exit_to_app_rounded,
      action: PotPlayerAction.exitApp,
    ),
  ];
}
