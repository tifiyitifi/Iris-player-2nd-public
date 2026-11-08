/// Actions a focused playlist-style list (the scenario queue / preview) can
/// perform, aligned with PotPlayer's `PL >` (playlist) context menu.
///
/// The list OWNS these keys while it holds keyboard focus, so the same keys do
/// not also drive the global player (e.g. `↑/↓` must move the list cursor, not
/// change volume). Actions with no IRIS equivalent are mapped and consumed as
/// no-ops so the global binding cannot fire either (see [kPotPlayerPlaylistMap]).
enum PlaylistAction {
  // Navigation
  cursorUp,
  cursorDown,
  cursorFirst,
  cursorLast,

  // Selection
  selectAll,
  invertSelection,

  // Playback
  play,

  // Remove
  removeSelected,
  removeUnselected,
  removeMissing,

  // Sort
  sortAscending,
  sortDescending,
  sortByFolder,
  sortByName,
  sortBySize,
  sortByDuration,
  sortByDate,
  sortRandom,

  // Information / navigation of the media
  fileInformation,
  openLocation,
  search,
  // Page navigation: opens the numeric "jump to page" prompt. The page owns
  // the prompt (it has the data source), so data sources consume this as a
  // no-op — see `PaginatedBrowserPage._runPlaylistAction`.
  jumpToPage,

  // Playlist / queue / sources
  savePlaylist,
  openPlaylist,
  closePlaylist,
  addToPlaybackQueue,
  addFiles,
  addFolder,
  addUrl,
  detectDurations,

  // Consumed no-ops (no IRIS equivalent — pressing does nothing, and must not
  // fall through to a conflicting global shortcut).
  copy,
  paste,
  pasteRecent,
  editTitle,
  renameFile,
  albumNew,
  albumEdit,
  albumDelete,
}

extension PlaylistActionSemantics on PlaylistAction {
  /// Whether a held key may auto-repeat this action.
  ///
  /// ONLY cursor movement qualifies: each repeat is a deliberate one-row step
  /// and is what makes a held arrow feel alive. Every other action either
  /// mutates the list (remove-*: the row under the cursor changes after each
  /// removal, so a held Delete used to walk down the queue deleting row after
  /// row), toggles state (invertSelection would flip once per repeat), or opens
  /// UI (dialogs / Explorer / pickers, which a held key would stack one copy
  /// per repeat). Those repeats are swallowed instead of re-firing.
  bool get repeatsSafely =>
      this == PlaylistAction.cursorUp ||
      this == PlaylistAction.cursorDown ||
      this == PlaylistAction.cursorFirst ||
      this == PlaylistAction.cursorLast;
}
