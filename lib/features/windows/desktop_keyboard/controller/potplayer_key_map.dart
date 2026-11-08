import 'package:flutter/services.dart';
import 'package:iris/features/windows/desktop_keyboard/model/potplayer_action.dart';

/// One physical key plus the held modifiers. Pure value type used as the
/// key-map lookup key (structural == / hashCode, const-constructible).
class KeyCombo {
  final LogicalKeyboardKey key;
  final bool ctrl;
  final bool alt;
  final bool shift;

  const KeyCombo(
    this.key, {
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
  });

  @override
  bool operator ==(Object other) =>
      other is KeyCombo &&
      other.key == key &&
      other.ctrl == ctrl &&
      other.alt == alt &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(key, ctrl, alt, shift);

  @override
  String toString() =>
      '${ctrl ? 'Ctrl+' : ''}${alt ? 'Alt+' : ''}${shift ? 'Shift+' : ''}'
      '${key.keyLabel}';
}

/// Canonical id of the apostrophe key, the ONE key bindings may name.
///
/// The Windows embedder resolves the physical `'` key (VK_OEM_7 / scan 222) to
/// [LogicalKeyboardKey.quote] — id 0x22, whose own label is `"` — while Linux
/// and macOS report [LogicalKeyboardKey.quoteSingle] (0x27) for the same
/// physical key. Looking a raw Windows event up against a `quoteSingle`
/// binding therefore misses silently (`key unbound: Alt+"` in the console).
/// [canonicalKeyCombo] folds the Windows id onto this one so a single default
/// binding, a recorded override and a live event all agree on every desktop
/// platform.
const LogicalKeyboardKey kApostropheKey = LogicalKeyboardKey.quoteSingle;

/// Collapses platform-specific key ids onto the binding identity they share.
/// See [kApostropheKey]; a no-op for every other key.
KeyCombo canonicalKeyCombo(KeyCombo combo) {
  if (combo.key != LogicalKeyboardKey.quote) return combo;
  return KeyCombo(
    kApostropheKey,
    ctrl: combo.ctrl,
    alt: combo.alt,
    shift: combo.shift,
  );
}

/// PotPlayer-aligned single-key bindings (strict replacement scheme).
///
/// Sources: `.ai_knowledge/tmp/potplayer_shortcuts/parsed/default_shortcuts.tsv`
/// (official build 260819). Keys whose PotPlayer functions IRIS cannot
/// perform yet are intentionally ABSENT — strict replacement means unbound
/// keys do nothing instead of falling back to legacy.
///
/// `final`, not `const`: Dart forbids constant-map keys that override `==`;
/// lookups rely on the structural equality above instead.
final Map<KeyCombo, PotPlayerAction> kPotPlayerKeyMap =
    <KeyCombo, PotPlayerAction>{
  // ── Playback ──
  KeyCombo(LogicalKeyboardKey.space): PotPlayerAction.playPause,
  KeyCombo(LogicalKeyboardKey.pageUp): PotPlayerAction.previousItem,
  KeyCombo(LogicalKeyboardKey.pageDown): PotPlayerAction.nextItem,
  // Shift+PageUp/Down: keep THIS player in place (paused) and open the
  // neighbour in a second window sharing the same playback context. Never
  // repeatable — an auto-repeated key would spawn a window per repeat.
  KeyCombo(LogicalKeyboardKey.pageUp, shift: true):
      PotPlayerAction.openPreviousInNewWindow,
  KeyCombo(LogicalKeyboardKey.pageDown, shift: true):
      PotPlayerAction.openNextInNewWindow,
  KeyCombo(LogicalKeyboardKey.keyD): PotPlayerAction.frameBackward,
  KeyCombo(LogicalKeyboardKey.keyF): PotPlayerAction.frameForward,

  // ── Seeking (four tiers: base × 1/3/6/12, controller/seek_tiers.dart) ──
  KeyCombo(LogicalKeyboardKey.arrowLeft): PotPlayerAction.seekBackward,
  KeyCombo(LogicalKeyboardKey.arrowRight): PotPlayerAction.seekForward,
  KeyCombo(LogicalKeyboardKey.arrowLeft, ctrl: true): PotPlayerAction.bigSeekBackward,
  KeyCombo(LogicalKeyboardKey.arrowRight, ctrl: true): PotPlayerAction.bigSeekForward,
  KeyCombo(LogicalKeyboardKey.arrowLeft, shift: true): PotPlayerAction.largeSeekBackward,
  KeyCombo(LogicalKeyboardKey.arrowRight, shift: true): PotPlayerAction.largeSeekForward,
  KeyCombo(LogicalKeyboardKey.arrowLeft, ctrl: true, alt: true):
      PotPlayerAction.hugeSeekBackward,
  KeyCombo(LogicalKeyboardKey.arrowRight, ctrl: true, alt: true):
      PotPlayerAction.hugeSeekForward,
  KeyCombo(LogicalKeyboardKey.backspace): PotPlayerAction.restart,
  KeyCombo(LogicalKeyboardKey.keyG): PotPlayerAction.jumpToTime,

  // ── Base-step adjust: direct OSD, no window (keeps every other shortcut
  //    live). Ctrl+↑/↓ = ±1s, Ctrl+Shift+↑/↓ = ±10s; repeatable so a held
  //    key walks the range. ──
  KeyCombo(LogicalKeyboardKey.arrowUp, ctrl: true): PotPlayerAction.seekStepIncrease,
  KeyCombo(LogicalKeyboardKey.arrowDown, ctrl: true): PotPlayerAction.seekStepDecrease,
  KeyCombo(LogicalKeyboardKey.arrowUp, ctrl: true, shift: true):
      PotPlayerAction.seekStepIncrease,
  KeyCombo(LogicalKeyboardKey.arrowDown, ctrl: true, shift: true):
      PotPlayerAction.seekStepDecrease,

  // ── Volume / speed / video ──
  KeyCombo(LogicalKeyboardKey.arrowUp): PotPlayerAction.volumeUp,
  KeyCombo(LogicalKeyboardKey.arrowDown): PotPlayerAction.volumeDown,
  KeyCombo(LogicalKeyboardKey.keyM): PotPlayerAction.mute,
  KeyCombo(LogicalKeyboardKey.keyX): PotPlayerAction.speedDown,
  KeyCombo(LogicalKeyboardKey.keyC): PotPlayerAction.speedUp,
  KeyCombo(LogicalKeyboardKey.keyZ): PotPlayerAction.speedReset,
  KeyCombo(LogicalKeyboardKey.keyJ): PotPlayerAction.fitCycle,

  // ── Track cycling / visibility (P0) ──
  KeyCombo(LogicalKeyboardKey.keyL, alt: true): PotPlayerAction.cycleSubtitleTrack,
  KeyCombo(LogicalKeyboardKey.keyA, alt: true): PotPlayerAction.cycleAudioTrack,
  KeyCombo(LogicalKeyboardKey.keyH, alt: true): PotPlayerAction.toggleSubtitleVisibility,

  // ── Sync triads (P0): `>` `<` `/` subtitle, Shift+… audio ──
  KeyCombo(LogicalKeyboardKey.period): PotPlayerAction.subtitleSyncForward,
  KeyCombo(LogicalKeyboardKey.comma): PotPlayerAction.subtitleSyncBackward,
  KeyCombo(LogicalKeyboardKey.slash): PotPlayerAction.subtitleSyncReset,
  KeyCombo(LogicalKeyboardKey.period, shift: true): PotPlayerAction.audioSyncForward,
  KeyCombo(LogicalKeyboardKey.comma, shift: true): PotPlayerAction.audioSyncBackward,
  KeyCombo(LogicalKeyboardKey.slash, shift: true): PotPlayerAction.audioSyncReset,

  // ── Quick jumps (P0) ──
  KeyCombo(LogicalKeyboardKey.home, ctrl: true): PotPlayerAction.jumpToMiddle,
  KeyCombo(LogicalKeyboardKey.backspace, shift: true): PotPlayerAction.jumpNearEnd,

  // ── Physical delete (Windows playback view; Shift+Del PotPlayer parity) ──
  KeyCombo(LogicalKeyboardKey.delete, shift: true): PotPlayerAction.deletePhysicalFile,

  // ── Capture (PotPlayer K / Ctrl+E parity; single capture path in IRIS) ──
  KeyCombo(LogicalKeyboardKey.keyK): PotPlayerAction.screenshotFrame,
  KeyCombo(LogicalKeyboardKey.keyE, ctrl: true): PotPlayerAction.screenshotFrame,

  // ── A-B section repeat (B quick toggle, [/] points, \ section on|off) ──
  KeyCombo(LogicalKeyboardKey.keyB): PotPlayerAction.abQuickToggle,
  KeyCombo(LogicalKeyboardKey.bracketLeft): PotPlayerAction.abSetPointA,
  KeyCombo(LogicalKeyboardKey.bracketRight): PotPlayerAction.abSetPointB,
  KeyCombo(LogicalKeyboardKey.backslash): PotPlayerAction.abToggleSectionRepeat,

  // ── tag_play entry keys (Windows): open the tag play sheet with the
  // command bar prefilled. Bare numpad +/−/* are unbound in PotPlayer (only
  // Ctrl+Alt variants are used), so there is no muscle-memory conflict.
  KeyCombo(LogicalKeyboardKey.numpadAdd): PotPlayerAction.tagChordAdd,
  KeyCombo(LogicalKeyboardKey.numpadSubtract): PotPlayerAction.tagChordRemove,
  KeyCombo(LogicalKeyboardKey.numpadMultiply):
      PotPlayerAction.tagChordSwitchView,

  // ── 副音 gate for the current foreground media ──
  // The quick bar's T0 play/stop button in keyboard form. Alt+' is unbound in
  // PotPlayer's default table and outside the `;` sequence prefix, so it
  // collides with nothing. Not repeatable: holding the key must not flip the
  // gate on/off repeatedly. [kApostropheKey], not `quoteSingle` inline: Windows
  // reports the same physical key as `quote` (0x22), see [canonicalKeyCombo].
  KeyCombo(kApostropheKey, alt: true): PotPlayerAction.toggleBackgroundGate,

  // ── fg/bg control target (the quick bar's T0 control button) ──
  // `;` alone arms the sequence buffer (R1 requires NO modifier), so Alt+;
  // never opens it and collides with nothing. Windows/Linux/macOS all report
  // the physical semicolon key as `semicolon` (0x3B), so no fold is needed
  // here. Not repeatable: holding the key must not ping-pong the target.
  KeyCombo(LogicalKeyboardKey.semicolon, alt: true):
      PotPlayerAction.toggleControlTarget,

  // ── Panels ──
  KeyCombo(LogicalKeyboardKey.keyL): PotPlayerAction.subtitlesPanel,
  KeyCombo(LogicalKeyboardKey.keyA): PotPlayerAction.audioTracksPanel,
  KeyCombo(LogicalKeyboardKey.f5): PotPlayerAction.settings,
  KeyCombo(LogicalKeyboardKey.f6): PotPlayerAction.playQueue,
  KeyCombo(LogicalKeyboardKey.contextMenu): PotPlayerAction.moreMenu,

  // ── Session / window ──
  KeyCombo(LogicalKeyboardKey.f3): PotPlayerAction.openFile,
  KeyCombo(LogicalKeyboardKey.keyO, ctrl: true): PotPlayerAction.openFile,
  KeyCombo(LogicalKeyboardKey.keyU, ctrl: true): PotPlayerAction.openLink,
  KeyCombo(LogicalKeyboardKey.f4): PotPlayerAction.closePlayback,
  KeyCombo(LogicalKeyboardKey.keyT, ctrl: true): PotPlayerAction.alwaysOnTop,
  KeyCombo(LogicalKeyboardKey.keyR, ctrl: true): PotPlayerAction.toggleAutoResize,
  KeyCombo(LogicalKeyboardKey.enter): PotPlayerAction.fullscreen,
  KeyCombo(LogicalKeyboardKey.enter, alt: true): PotPlayerAction.fullscreen,
  KeyCombo(LogicalKeyboardKey.escape): PotPlayerAction.exitFullscreen,
  KeyCombo(LogicalKeyboardKey.keyX, alt: true): PotPlayerAction.exitApp,
};

/// Actions that keep firing while their key is auto-repeated (held down).
const Set<PotPlayerAction> kRepeatablePotPlayerActions = <PotPlayerAction>{
  PotPlayerAction.volumeUp,
  PotPlayerAction.volumeDown,
  // Held X/C walk the speed stops continuously (PotPlayer parity): every
  // auto-repeat re-renders the OSD, release persists once via commitRate.
  PotPlayerAction.speedUp,
  PotPlayerAction.speedDown,
  PotPlayerAction.seekBackward,
  PotPlayerAction.seekForward,
  PotPlayerAction.bigSeekBackward,
  PotPlayerAction.bigSeekForward,
  PotPlayerAction.largeSeekBackward,
  PotPlayerAction.largeSeekForward,
  PotPlayerAction.hugeSeekBackward,
  PotPlayerAction.hugeSeekForward,
  // Base-step adjust repeats while held (live OSD updates, commit on release).
  PotPlayerAction.seekStepIncrease,
  PotPlayerAction.seekStepDecrease,
  // Frame stepping repeats with the held key (PotPlayer hold = fast frame
  // playback). The hook pauses first, so repeats keep stepping frame by frame.
  PotPlayerAction.frameBackward,
  PotPlayerAction.frameForward,
  // Sync nudges repeat with the held key, mirroring PotPlayer.
  PotPlayerAction.subtitleSyncForward,
  PotPlayerAction.subtitleSyncBackward,
  PotPlayerAction.audioSyncForward,
  PotPlayerAction.audioSyncBackward,
};
