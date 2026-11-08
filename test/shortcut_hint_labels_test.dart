import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/windows/desktop_keyboard/view/shortcut_hints.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/store/app_state.dart';

void main() {
  group('shortcutHintLabelFor', () {
    test('legacy scheme keeps the original control-bar hints', () {
      expect(
        shortcutHintLabelFor(ShortcutHintKind.playPause, KeyboardShortcutScheme.legacy),
        'Space',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.stop, KeyboardShortcutScheme.legacy),
        'Ctrl + C',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.previous, KeyboardShortcutScheme.legacy),
        'Ctrl + ←',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.next, KeyboardShortcutScheme.legacy),
        'Ctrl + →',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.shuffle, KeyboardShortcutScheme.legacy),
        'Ctrl + X',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.repeat, KeyboardShortcutScheme.legacy),
        'Ctrl + R',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.fit, KeyboardShortcutScheme.legacy),
        'Ctrl + V',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.subtitleAudio, KeyboardShortcutScheme.legacy),
        'S',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.playQueue, KeyboardShortcutScheme.legacy),
        'P',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.storage, KeyboardShortcutScheme.legacy),
        'F',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.mute, KeyboardShortcutScheme.legacy),
        'Ctrl + M',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.fullscreen, KeyboardShortcutScheme.legacy),
        'F11, Enter, Esc',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.alwaysOnTop, KeyboardShortcutScheme.legacy),
        'F10',
      );
      // The 副音 T0 shortcuts are potplayer-table bindings only.
      expect(
        shortcutHintLabelFor(ShortcutHintKind.bgGate, KeyboardShortcutScheme.legacy),
        isNull,
      );
      expect(
        shortcutHintLabelFor(
            ShortcutHintKind.bgControlTarget, KeyboardShortcutScheme.legacy),
        isNull,
      );
    });

    test('potplayer scheme matches the live potplayer bindings (P-key fix)', () {
      expect(
        shortcutHintLabelFor(ShortcutHintKind.playPause, KeyboardShortcutScheme.potplayer),
        'Space',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.stop, KeyboardShortcutScheme.potplayer),
        'F4',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.previous, KeyboardShortcutScheme.potplayer),
        'PageUp',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.next, KeyboardShortcutScheme.potplayer),
        'PageDown',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.shuffle, KeyboardShortcutScheme.potplayer),
        '; X',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.repeat, KeyboardShortcutScheme.potplayer),
        '; R',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.fit, KeyboardShortcutScheme.potplayer),
        'J',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.subtitleAudio, KeyboardShortcutScheme.potplayer),
        'A / L',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.playQueue, KeyboardShortcutScheme.potplayer),
        'F6',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.storage, KeyboardShortcutScheme.potplayer),
        '; F',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.mute, KeyboardShortcutScheme.potplayer),
        'M',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.fullscreen, KeyboardShortcutScheme.potplayer),
        'Enter / Esc',
      );
      expect(
        shortcutHintLabelFor(ShortcutHintKind.alwaysOnTop, KeyboardShortcutScheme.potplayer),
        'Ctrl + T',
      );
      // 副音 T0 buttons: the gate and the fg/bg control toggle.
      expect(
        shortcutHintLabelFor(ShortcutHintKind.bgGate, KeyboardShortcutScheme.potplayer),
        "Alt + '",
      );
      expect(
        shortcutHintLabelFor(
            ShortcutHintKind.bgControlTarget, KeyboardShortcutScheme.potplayer),
        'Alt + ;',
      );
    });
  });

  group('withShortcutHint', () {
    test('keeps the label when the action has no live binding', () async {
      final t = await lookupAppLocalizations(const Locale('en'));

      expect(
        withShortcutHint('Control Sub Audio', null, t),
        'Control Sub Audio',
      );
    });

    test('appends the live shortcut in the ARB wrapper', () async {
      final t = await lookupAppLocalizations(const Locale('en'));

      expect(
        withShortcutHint('Control Sub Audio', 'Alt + ;', t),
        'Control Sub Audio (Alt + ;)',
      );
    });
  });
}