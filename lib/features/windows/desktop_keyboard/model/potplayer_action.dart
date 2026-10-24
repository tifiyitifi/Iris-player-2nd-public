/// Semantic actions of the PotPlayer-aligned desktop keyboard scheme.
///
/// The key tables (potplayer_key_map, potplayer_sequence_map) map physical
/// input onto these ids; the executor is the only place that knows how to
/// perform them. Keeping actions semantic lets round 2 re-wire the same
/// capabilities to phone UI without touching the binding layer.
enum PotPlayerAction {
  // ── Playback ──
  playPause,
  previousItem,
  nextItem,
  frameBackward,
  frameForward,

  // ── Seeking ──
  seekBackward,
  seekForward,
  bigSeekBackward,
  bigSeekForward,
  restart,
  jumpToTime,

  // ── Volume / speed / video ──
  volumeUp,
  volumeDown,
  mute,
  speedDown,
  speedUp,
  speedReset,
  fitCycle,

  // ── Track cycling / visibility (P0) ──
  cycleSubtitleTrack,
  cycleAudioTrack,
  toggleSubtitleVisibility,

  // ── Sync adjustment (P0, mediaKit-only at runtime) ──
  subtitleSyncForward,
  subtitleSyncBackward,
  subtitleSyncReset,
  audioSyncForward,
  audioSyncBackward,
  audioSyncReset,

  // ── Quick jumps (P0) ──
  jumpToMiddle,
  jumpNearEnd,

  // ── Physical file deletion (Windows playback view only, §5) ──
  deletePhysicalFile,

  // ── Frame capture (mediaKit-only) ──
  screenshotFrame,

  // ── A-B section repeat (pure Flutter loop engine) ──
  abSetPointA,
  abSetPointB,
  abQuickToggle,
  abToggleSectionRepeat,

  // ── tag_play entry keys (Windows numpad): each opens the tag play sheet
  //    with the numeric command bar prefilled with its operator. Names kept
  //    from the retired inline-chord buffer because keybind overrides are
  //    persisted BY NAME — renaming them would silently reset user bindings.
  tagChordAdd,
  tagChordRemove,
  tagChordSwitchView,

  // ── Panels ──
  subtitlesPanel,
  audioTracksPanel,
  settings,
  playQueue,
  togglePlaylistDockMode,
  storagesBrowser,
  historyPanel,
  moreMenu,

  // ── Session / window ──
  openFile,
  openLink,
  closePlayback,
  toggleRepeatMode,
  toggleShuffleMode,
  alwaysOnTop,
  toggleAutoResize,
  fullscreen,
  exitFullscreen,
  exitApp,

  // ── Multi-tier seeking + base-step adjust (appended, never reordered:
  //    keybind overrides persist by NAME). Tiers are derived from the single
  //    AppState.seekStepSeconds via controller/seek_tiers.dart. ──
  largeSeekBackward,
  largeSeekForward,
  hugeSeekBackward,
  hugeSeekForward,

  /// Menu-only (Windows right-click > Playback): opens the seek-step popover.
  /// Deliberately NOT bound to any key — the modal popover would gate off the
  /// other player shortcuts; the keyboard path uses [seekStepIncrease] /
  /// [seekStepDecrease] with direct OSD instead.
  seekStepPopover,
  // Menu-only (Windows video-area right-click): reveals the currently played
  // file in Explorer with the file selected. Appended so name-persisted keybind
  // overrides stay valid; never bound to a key.
  revealCurrentFileInExplorer,
  // Direct base-step adjust (±1s / Shift ±10s) with OSD, no window.
  seekStepIncrease,
  seekStepDecrease,
}
