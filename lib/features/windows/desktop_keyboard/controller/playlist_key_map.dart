import 'package:flutter/services.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/potplayer_key_map.dart';
import 'package:iris/features/windows/desktop_keyboard/model/playlist_action.dart';

/// PotPlayer-aligned playlist (list) key bindings, derived from the `PL >`
/// context-menu section of PotPlayer's official default shortcuts.
///
/// These bindings apply ONLY while a playlist-style list (the scenario queue /
/// preview) holds keyboard focus, and ONLY in the metadata-driven era. The list
/// OWNS them: the global player handler skips any key owned here, so e.g.
/// `↑/↓` navigate the list instead of changing volume.
///
/// Keys whose PotPlayer action has no IRIS equivalent are present as no-op
/// actions on purpose — consuming them keeps a conflicting global binding from
/// firing ("不绑定就是什么都不做").
///
/// Deliberately ABSENT (stay global): `Space` play/pause, `PgUp/PgDn`
/// prev/next file, `Enter` fullscreen, `←/→` seek, `F5` settings.
final Map<KeyCombo, PlaylistAction> kPotPlayerPlaylistMap =
    <KeyCombo, PlaylistAction>{
  // ── Navigation ──
  KeyCombo(LogicalKeyboardKey.arrowUp): PlaylistAction.cursorUp,
  KeyCombo(LogicalKeyboardKey.arrowDown): PlaylistAction.cursorDown,
  KeyCombo(LogicalKeyboardKey.home): PlaylistAction.cursorFirst,
  KeyCombo(LogicalKeyboardKey.end): PlaylistAction.cursorLast,

  // ── Selection ──
  KeyCombo(LogicalKeyboardKey.keyA, ctrl: true): PlaylistAction.selectAll,
  KeyCombo(LogicalKeyboardKey.keyJ, ctrl: true): PlaylistAction.invertSelection,

  // ── Playback ──
  KeyCombo(LogicalKeyboardKey.keyP): PlaylistAction.play,

  // ── Remove ──
  KeyCombo(LogicalKeyboardKey.delete): PlaylistAction.removeSelected,
  KeyCombo(LogicalKeyboardKey.delete, ctrl: true):
      PlaylistAction.removeUnselected,
  KeyCombo(LogicalKeyboardKey.keyT, ctrl: true): PlaylistAction.removeMissing,

  // ── Sort by ──
  KeyCombo(LogicalKeyboardKey.digit1, ctrl: true): PlaylistAction.sortAscending,
  KeyCombo(LogicalKeyboardKey.digit2, ctrl: true): PlaylistAction.sortDescending,
  KeyCombo(LogicalKeyboardKey.digit0, ctrl: true): PlaylistAction.sortByFolder,
  KeyCombo(LogicalKeyboardKey.digit3, ctrl: true): PlaylistAction.sortByName,
  KeyCombo(LogicalKeyboardKey.digit4, ctrl: true): PlaylistAction.sortByName,
  KeyCombo(LogicalKeyboardKey.digit5, ctrl: true): PlaylistAction.sortByName,
  KeyCombo(LogicalKeyboardKey.digit6, ctrl: true): PlaylistAction.sortBySize,
  KeyCombo(LogicalKeyboardKey.digit7, ctrl: true): PlaylistAction.sortByDuration,
  KeyCombo(LogicalKeyboardKey.digit8, ctrl: true): PlaylistAction.sortByDate,
  KeyCombo(LogicalKeyboardKey.digit9, ctrl: true): PlaylistAction.sortRandom,

  // ── Information / navigation ──
  KeyCombo(LogicalKeyboardKey.f1, ctrl: true): PlaylistAction.fileInformation,
  KeyCombo(LogicalKeyboardKey.keyF, ctrl: true): PlaylistAction.openLocation,
  KeyCombo(LogicalKeyboardKey.keyS, ctrl: true): PlaylistAction.search,
  KeyCombo(LogicalKeyboardKey.keyG, ctrl: true): PlaylistAction.jumpToPage,

  // ── Playlist / queue / sources ──
  KeyCombo(LogicalKeyboardKey.f2): PlaylistAction.savePlaylist,
  KeyCombo(LogicalKeyboardKey.f3): PlaylistAction.openPlaylist,
  KeyCombo(LogicalKeyboardKey.f6): PlaylistAction.closePlaylist,
  KeyCombo(LogicalKeyboardKey.f4): PlaylistAction.detectDurations,
  KeyCombo(LogicalKeyboardKey.keyQ): PlaylistAction.addToPlaybackQueue,
  KeyCombo(LogicalKeyboardKey.keyI, ctrl: true): PlaylistAction.addFiles,
  KeyCombo(LogicalKeyboardKey.keyO, ctrl: true): PlaylistAction.addFolder,
  KeyCombo(LogicalKeyboardKey.keyU, ctrl: true): PlaylistAction.addUrl,

  // ── Consumed no-ops (PotPlayer PL actions IRIS has no flow for) ──
  KeyCombo(LogicalKeyboardKey.keyC, ctrl: true): PlaylistAction.copy,
  KeyCombo(LogicalKeyboardKey.keyV, ctrl: true): PlaylistAction.paste,
  KeyCombo(LogicalKeyboardKey.keyV, ctrl: true, alt: true):
      PlaylistAction.pasteRecent,
  KeyCombo(LogicalKeyboardKey.keyE, ctrl: true): PlaylistAction.editTitle,
  KeyCombo(LogicalKeyboardKey.keyM, ctrl: true): PlaylistAction.renameFile,
  KeyCombo(LogicalKeyboardKey.keyN, ctrl: true): PlaylistAction.albumNew,
  KeyCombo(LogicalKeyboardKey.keyR, ctrl: true): PlaylistAction.albumEdit,
  KeyCombo(LogicalKeyboardKey.keyD, ctrl: true): PlaylistAction.albumDelete,
};

/// Plain keys the focused list must NOT capture via type-ahead: the speed
/// ladder (`X`/`C`) and reset (`Z`) are high-frequency playback controls the
/// user expects to stay live even while the queue holds focus. Without this the
/// list owns every bare letter and the global handler never sees X/C/Z, so the
/// speed keys silently die whenever the playlist has focus.
final Set<LogicalKeyboardKey> kPlaylistTypeAheadExemptKeys =
    <LogicalKeyboardKey>{
  LogicalKeyboardKey.keyZ,
  LogicalKeyboardKey.keyX,
  LogicalKeyboardKey.keyC,
};

/// Type-ahead (incremental search) support: PotPlayer's playlist jumps to the
/// item whose name starts with what you type while the list is focused.
///
/// A key qualifies when it is a printable character without Ctrl/Alt, is not
/// one of the explicitly bound list/global control keys, and is not exempted by
/// [kPlaylistTypeAheadExemptKeys]. This is why the list owns plain letters while
/// focused (`D`, `M`, ... no longer reach the player) — matching PotPlayer's
/// focus model — with the speed keys deliberately excluded.
bool isPlaylistTypeAheadKey(KeyEvent event) {
  if (event is! KeyDownEvent) return false;
  final key = event.logicalKey;
  if (kPlaylistTypeAheadExemptKeys.contains(key)) return false;
  if (HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isAltPressed) {
    return false;
  }
  final label = key.keyLabel;
  if (label.length != 1) return false;
  final code = label.codeUnitAt(0);
  final isLower = code >= 0x61 && code <= 0x7A;
  final isUpper = code >= 0x41 && code <= 0x5A;
  final isDigit = code >= 0x30 && code <= 0x39;
  return isLower || isUpper || isDigit;
}

/// Resolves the playlist action for [event], if the focused list owns it.
PlaylistAction? resolvePlaylistAction(KeyEvent event) {
  final combo = KeyCombo(
    event.logicalKey,
    ctrl: HardwareKeyboard.instance.isControlPressed,
    alt: HardwareKeyboard.instance.isAltPressed,
    shift: HardwareKeyboard.instance.isShiftPressed,
  );
  return kPotPlayerPlaylistMap[combo];
}
