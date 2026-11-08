import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/potplayer_key_map.dart';
import 'package:iris/features/windows/desktop_keyboard/model/potplayer_action.dart';

/// Anchor assertions for the PotPlayer-aligned single-key table plus
/// structural invariants (no shadowed combos, repeatable subset).
void main() {
  group('kPotPlayerKeyMap anchors', () {
    final cases = <(KeyCombo, PotPlayerAction)>[
      (const KeyCombo(LogicalKeyboardKey.space), PotPlayerAction.playPause),
      (const KeyCombo(LogicalKeyboardKey.enter), PotPlayerAction.fullscreen),
      (
        const KeyCombo(LogicalKeyboardKey.enter, alt: true),
        PotPlayerAction.fullscreen,
      ),
      (const KeyCombo(LogicalKeyboardKey.escape), PotPlayerAction.exitFullscreen),
      (const KeyCombo(LogicalKeyboardKey.arrowUp), PotPlayerAction.volumeUp),
      (const KeyCombo(LogicalKeyboardKey.arrowDown), PotPlayerAction.volumeDown),
      (const KeyCombo(LogicalKeyboardKey.arrowLeft), PotPlayerAction.seekBackward),
      (const KeyCombo(LogicalKeyboardKey.arrowRight), PotPlayerAction.seekForward),
      (
        const KeyCombo(LogicalKeyboardKey.arrowLeft, ctrl: true),
        PotPlayerAction.bigSeekBackward,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.arrowRight, ctrl: true),
        PotPlayerAction.bigSeekForward,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.arrowLeft, shift: true),
        PotPlayerAction.largeSeekBackward,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.arrowRight, shift: true),
        PotPlayerAction.largeSeekForward,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.arrowLeft, ctrl: true, alt: true),
        PotPlayerAction.hugeSeekBackward,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.arrowRight, ctrl: true, alt: true),
        PotPlayerAction.hugeSeekForward,
      ),
      // ── Base-step adjust (direct OSD, no window) ──
      (
        const KeyCombo(LogicalKeyboardKey.arrowUp, ctrl: true),
        PotPlayerAction.seekStepIncrease,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.arrowDown, ctrl: true),
        PotPlayerAction.seekStepDecrease,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.arrowUp, ctrl: true, shift: true),
        PotPlayerAction.seekStepIncrease,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.arrowDown, ctrl: true, shift: true),
        PotPlayerAction.seekStepDecrease,
      ),
      (const KeyCombo(LogicalKeyboardKey.pageUp), PotPlayerAction.previousItem),
      (const KeyCombo(LogicalKeyboardKey.pageDown), PotPlayerAction.nextItem),
      // ── Multi-window neighbour playback ──
      (
        const KeyCombo(LogicalKeyboardKey.pageUp, shift: true),
        PotPlayerAction.openPreviousInNewWindow,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.pageDown, shift: true),
        PotPlayerAction.openNextInNewWindow,
      ),
      // ── 副音 gate for the current foreground media ──
      // Bound under the canonical apostrophe id; Windows delivers the same
      // physical key as `quote` (0x22) and `canonicalKeyCombo` folds it in.
      (
        const KeyCombo(kApostropheKey, alt: true),
        PotPlayerAction.toggleBackgroundGate,
      ),
      // ── fg/bg control target (the quick bar's T0 control button) ──
      (
        const KeyCombo(LogicalKeyboardKey.semicolon, alt: true),
        PotPlayerAction.toggleControlTarget,
      ),
      (const KeyCombo(LogicalKeyboardKey.keyD), PotPlayerAction.frameBackward),
      (const KeyCombo(LogicalKeyboardKey.keyF), PotPlayerAction.frameForward),
      (const KeyCombo(LogicalKeyboardKey.keyZ), PotPlayerAction.speedReset),
      (const KeyCombo(LogicalKeyboardKey.keyX), PotPlayerAction.speedDown),
      (const KeyCombo(LogicalKeyboardKey.keyC), PotPlayerAction.speedUp),
      (const KeyCombo(LogicalKeyboardKey.keyM), PotPlayerAction.mute),
      (const KeyCombo(LogicalKeyboardKey.backspace), PotPlayerAction.restart),
      (const KeyCombo(LogicalKeyboardKey.keyG), PotPlayerAction.jumpToTime),
      (const KeyCombo(LogicalKeyboardKey.keyL), PotPlayerAction.subtitlesPanel),
      (const KeyCombo(LogicalKeyboardKey.keyA), PotPlayerAction.audioTracksPanel),
      (const KeyCombo(LogicalKeyboardKey.keyJ), PotPlayerAction.fitCycle),
      (const KeyCombo(LogicalKeyboardKey.f3), PotPlayerAction.openFile),
      (
        const KeyCombo(LogicalKeyboardKey.keyO, ctrl: true),
        PotPlayerAction.openFile,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.keyU, ctrl: true),
        PotPlayerAction.openLink,
      ),
      (const KeyCombo(LogicalKeyboardKey.f4), PotPlayerAction.closePlayback),
      (const KeyCombo(LogicalKeyboardKey.f5), PotPlayerAction.settings),
      (const KeyCombo(LogicalKeyboardKey.f6), PotPlayerAction.playQueue),
      (
        const KeyCombo(LogicalKeyboardKey.keyT, ctrl: true),
        PotPlayerAction.alwaysOnTop,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.keyR, ctrl: true),
        PotPlayerAction.toggleAutoResize,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.keyX, alt: true),
        PotPlayerAction.exitApp,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.contextMenu),
        PotPlayerAction.moreMenu,
      ),
      // ── P0 extensions: track cycling / visibility ──
      (
        const KeyCombo(LogicalKeyboardKey.keyL, alt: true),
        PotPlayerAction.cycleSubtitleTrack,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.keyA, alt: true),
        PotPlayerAction.cycleAudioTrack,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.keyH, alt: true),
        PotPlayerAction.toggleSubtitleVisibility,
      ),
      // ── P0 extensions: sync triads (`>` `<` `/` subtitle, Shift+… audio) ──
      (
        const KeyCombo(LogicalKeyboardKey.period),
        PotPlayerAction.subtitleSyncForward,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.comma),
        PotPlayerAction.subtitleSyncBackward,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.slash),
        PotPlayerAction.subtitleSyncReset,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.period, shift: true),
        PotPlayerAction.audioSyncForward,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.comma, shift: true),
        PotPlayerAction.audioSyncBackward,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.slash, shift: true),
        PotPlayerAction.audioSyncReset,
      ),
      // ── P0 extensions: quick jumps ──
      (
        const KeyCombo(LogicalKeyboardKey.home, ctrl: true),
        PotPlayerAction.jumpToMiddle,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.backspace, shift: true),
        PotPlayerAction.jumpNearEnd,
      ),
      // ── A-B section repeat ──
      (const KeyCombo(LogicalKeyboardKey.keyB), PotPlayerAction.abQuickToggle),
      (
        const KeyCombo(LogicalKeyboardKey.bracketLeft),
        PotPlayerAction.abSetPointA,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.bracketRight),
        PotPlayerAction.abSetPointB,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.backslash),
        PotPlayerAction.abToggleSectionRepeat,
      ),
      // ── Physical delete (Windows playback view) ──
      (
        const KeyCombo(LogicalKeyboardKey.delete, shift: true),
        PotPlayerAction.deletePhysicalFile,
      ),
      // ── Capture ──
      (const KeyCombo(LogicalKeyboardKey.keyK), PotPlayerAction.screenshotFrame),
      (
        const KeyCombo(LogicalKeyboardKey.keyE, ctrl: true),
        PotPlayerAction.screenshotFrame,
      ),
      // ── tag_play numpad chord entries (buffer-input) ──
      (
        const KeyCombo(LogicalKeyboardKey.numpadAdd),
        PotPlayerAction.tagChordAdd,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.numpadSubtract),
        PotPlayerAction.tagChordRemove,
      ),
      (
        const KeyCombo(LogicalKeyboardKey.numpadMultiply),
        PotPlayerAction.tagChordSwitchView,
      ),
    ];

    test('every anchor resolves to its documented action', () {
      for (final (combo, action) in cases) {
        expect(kPotPlayerKeyMap[combo], action, reason: 'combo: $combo');
      }
    });

    test('table size equals anchor coverage (no undocumented entries)', () {
      expect(kPotPlayerKeyMap.length, cases.toSet().length);
    });

    test('F11 stays strictly unbound', () {
      expect(
        kPotPlayerKeyMap.keys.where((c) => c.key == LogicalKeyboardKey.f11),
        isEmpty,
      );
    });

    test('the Windows apostrophe id folds onto the bound combo', () {
      // Windows resolves VK_OEM_7 to `quote` (0x22, labelled `"`); a raw
      // lookup of that combo against the table used to miss, so Alt+' did
      // nothing at all. `canonicalKeyCombo` is the single fold point.
      const windowsCombo = KeyCombo(LogicalKeyboardKey.quote, alt: true);
      final canonical = canonicalKeyCombo(windowsCombo);
      expect(canonical, const KeyCombo(kApostropheKey, alt: true));
      expect(
        kPotPlayerKeyMap[canonical],
        PotPlayerAction.toggleBackgroundGate,
        reason: 'Alt+apostrophe must resolve on Windows too',
      );
      // Non-apostrophe combos pass through untouched.
      expect(
        canonicalKeyCombo(const KeyCombo(LogicalKeyboardKey.keyK, ctrl: true)),
        const KeyCombo(LogicalKeyboardKey.keyK, ctrl: true),
      );
    });
  });

  group('repeatable actions', () {
    test('are a subset of mapped actions', () {
      expect(kRepeatablePotPlayerActions.difference(kPotPlayerKeyMap.values.toSet()),
          isEmpty);
    });

    test('cover exactly the continuous-adjustment actions', () {
      expect(
        kRepeatablePotPlayerActions,
        equals(
          const <PotPlayerAction>{
            PotPlayerAction.volumeUp,
            PotPlayerAction.volumeDown,
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
            PotPlayerAction.seekStepIncrease,
            PotPlayerAction.seekStepDecrease,
            PotPlayerAction.frameBackward,
            PotPlayerAction.frameForward,
            PotPlayerAction.subtitleSyncForward,
            PotPlayerAction.subtitleSyncBackward,
            PotPlayerAction.audioSyncForward,
            PotPlayerAction.audioSyncBackward,
          },
        ),
      );
    });
  });
}
