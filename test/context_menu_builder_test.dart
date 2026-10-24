import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/windows/context_menu/controller/context_menu_builder.dart';
import 'package:iris/features/windows/context_menu/model/context_menu_entry.dart';
import 'package:iris/features/windows/desktop_keyboard/model/potplayer_action.dart';

/// Helpers to flatten entries for assertions.

List<ContextMenuItem> flattenItems(List<ContextMenuEntry> entries) {
  final List<ContextMenuItem> out = [];
  for (final e in entries) {
    if (e is ContextMenuItem) {
      out.add(e);
    } else if (e is ContextMenuSubmenu) {
      out.addAll(flattenItems(e.children));
    }
  }
  return out;
}

List<ContextMenuSubmenu> topSubmenus(List<ContextMenuEntry> entries) =>
    entries.whereType<ContextMenuSubmenu>().toList();

ContextMenuSubmenu? findSubmenu(List<ContextMenuEntry> entries, String label) {
  for (final e in entries) {
    if (e is ContextMenuSubmenu && e.label == label) return e;
    if (e is ContextMenuSubmenu) {
      final nested = findSubmenu(e.children, label);
      if (nested != null) return nested;
    }
  }
  return null;
}

void main() {
  group('buildPotPlayerContextMenu', () {
    test('contains all top-level sections in PotPlayer-like order', () {
      final entries = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: true,
        supportsTrack: true,
        isFullScreen: false,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );

      final labels = entries
          .whereType<ContextMenuSubmenu>()
          .map((s) => s.label)
          .toList();

      // Expected top-level submenus: Open, Playback, Video, Audio, Subtitle, Window
      expect(labels, containsAll(['Open', 'Playback', 'Video', 'Audio', 'Subtitle', 'Window']));
      expect(labels.indexOf('Open'), lessThan(labels.indexOf('Playback')));
      expect(labels.indexOf('Playback'), lessThan(labels.indexOf('Video')));
      expect(labels.indexOf('Video'), lessThan(labels.indexOf('Audio')));
      expect(labels.indexOf('Audio'), lessThan(labels.indexOf('Subtitle')));
      expect(labels.indexOf('Subtitle'), lessThan(labels.indexOf('Window')));
    });

    test('screenshot item hidden on fvp (isMediaKit=false)', () {
      final mediaKit = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: true,
        supportsTrack: true,
        isFullScreen: false,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );
      final fvp = buildPotPlayerContextMenu(
        isMediaKit: false,
        supportsSync: false,
        supportsTrack: false,
        isFullScreen: false,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );

      final mkItems = flattenItems(mediaKit);
      final fvpItems = flattenItems(fvp);

      expect(mkItems.any((i) => i.action == PotPlayerAction.screenshotFrame), isTrue);
      expect(fvpItems.any((i) => i.action == PotPlayerAction.screenshotFrame), isFalse);
    });

    test('sync submenus hidden when supportsSync=false', () {
      final withSync = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: true,
        supportsTrack: true,
        isFullScreen: false,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );
      final withoutSync = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: false,
        supportsTrack: true,
        isFullScreen: false,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );

      expect(findSubmenu(withSync, 'Subtitle sync (+/-0.5s)'), isNotNull);
      expect(findSubmenu(withSync, 'Audio sync (+/-0.5s)'), isNotNull);
      expect(findSubmenu(withoutSync, 'Subtitle sync (+/-0.5s)'), isNull);
      expect(findSubmenu(withoutSync, 'Audio sync (+/-0.5s)'), isNull);
    });

    test('track items hidden when supportsTrack=false', () {
      final withTrack = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: true,
        supportsTrack: true,
        isFullScreen: false,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );
      final withoutTrack = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: true,
        supportsTrack: false,
        isFullScreen: false,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );

      final withItems = flattenItems(withTrack);
      final withoutItems = flattenItems(withoutTrack);

      expect(withItems.any((i) => i.action == PotPlayerAction.cycleSubtitleTrack), isTrue);
      expect(withoutItems.any((i) => i.action == PotPlayerAction.cycleSubtitleTrack), isFalse);
      expect(withItems.any((i) => i.action == PotPlayerAction.cycleAudioTrack), isTrue);
      expect(withoutItems.any((i) => i.action == PotPlayerAction.cycleAudioTrack), isFalse);
    });

    test('fullscreen label toggles with isFullScreen', () {
      final windowed = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: true,
        supportsTrack: true,
        isFullScreen: false,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );
      final fullscreen = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: true,
        supportsTrack: true,
        isFullScreen: true,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );

      final windowMenu = findSubmenu(windowed, 'Window')!;
      final fullscreenMenu = findSubmenu(fullscreen, 'Window')!;

      final windowedItem = windowMenu.children.whereType<ContextMenuItem>().firstWhere(
            (i) => i.action == PotPlayerAction.fullscreen,
          );
      final fullscreenItem = fullscreenMenu.children.whereType<ContextMenuItem>().firstWhere(
            (i) => i.action == PotPlayerAction.exitFullscreen,
          );

      expect(windowedItem.label, contains('Fullscreen'));
      expect(fullscreenItem.label, contains('Exit fullscreen'));
    });

    test('always-on-top label reflects state', () {
      final off = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: true,
        supportsTrack: true,
        isFullScreen: false,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );
      final on = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: true,
        supportsTrack: true,
        isFullScreen: false,
        isAlwaysOnTop: true,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );

      String labelFor(List<ContextMenuEntry> entries) {
        final win = findSubmenu(entries, 'Window')!;
        return win.children.whereType<ContextMenuItem>().firstWhere(
              (i) => i.action == PotPlayerAction.alwaysOnTop,
            ).label;
      }

      expect(labelFor(off), contains('Always on top'));
      expect(labelFor(on), contains('✓'));
    });

    test('playback submenu contains speed and A-B loop submenus', () {
      final entries = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: true,
        supportsTrack: true,
        isFullScreen: false,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );
      final playback = findSubmenu(entries, 'Playback')!;
      expect(findSubmenu(playback.children, 'Speed'), isNotNull);
      expect(findSubmenu(playback.children, 'A-B loop'), isNotNull);
    });

    test('playback submenu carries the seek-step popover item after jump-to-time', () {
      final entries = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: true,
        supportsTrack: true,
        isFullScreen: false,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );
      final playback = findSubmenu(entries, 'Playback')!;
      final items = playback.children.whereType<ContextMenuItem>().toList();

      final jumpIndex =
          items.indexWhere((i) => i.action == PotPlayerAction.jumpToTime);
      final seekStepIndex =
          items.indexWhere((i) => i.action == PotPlayerAction.seekStepPopover);
      expect(jumpIndex, isNonNegative);
      expect(seekStepIndex, greaterThan(jumpIndex),
          reason: 'seek-step entry sits right after jump-to-time');
      expect(items[seekStepIndex].label, 'Seek step');
      expect(items[seekStepIndex].hint, 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s');
    });

    test('reveal-in-explorer is a top-level entry right after Open', () {
      final entries = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: true,
        supportsTrack: true,
        isFullScreen: false,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
        canRevealInExplorer: true,
        revealInExplorerLabel: 'Open in Explorer',
      );

      final openIndex = entries.indexWhere(
        (e) => e is ContextMenuSubmenu && e.label == 'Open',
      );
      final revealIndex = entries.indexWhere(
        (e) =>
            e is ContextMenuItem &&
            e.action == PotPlayerAction.revealCurrentFileInExplorer,
      );

      expect(openIndex, isNonNegative);
      expect(revealIndex, openIndex + 1,
          reason: 'reveal entry sits directly below the Open submenu');
      final item = entries[revealIndex] as ContextMenuItem;
      expect(item.label, 'Open in Explorer');
      // The divider still separates the reveal entry from Playback.
      expect(entries[revealIndex + 1], isA<ContextMenuDivider>());
    });

    test('reveal-in-explorer entry is absent when the media is not revealable',
        () {
      final entries = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: true,
        supportsTrack: true,
        isFullScreen: false,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );

      expect(
        flattenItems(entries)
            .any((i) => i.action == PotPlayerAction.revealCurrentFileInExplorer),
        isFalse,
      );
      expect(entries.first, isA<ContextMenuSubmenu>());
    });

    test('includes exit at bottom', () {
      final entries = buildPotPlayerContextMenu(
        isMediaKit: true,
        supportsSync: true,
        supportsTrack: true,
        isFullScreen: false,
        isAlwaysOnTop: false,
        seekStepLabel: 'Seek step',
        seekStepHint: 'Ctrl+↑/↓ ±1s, Ctrl+Shift ±10s',
      );
      final lastItem = flattenItems(entries).last;
      expect(lastItem.action, PotPlayerAction.exitApp);
    });
  });
}
