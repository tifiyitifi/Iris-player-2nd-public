import 'package:flutter/widgets.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/resolve_keyboard_scheme.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/resolve_keybinds.dart';
import 'package:iris/features/windows/desktop_keyboard/model/keybind_codec.dart';
import 'package:iris/features/windows/desktop_keyboard/model/potplayer_action.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';

/// More-menu trailing shortcut hints per target and active scheme (SRS §9).
///
/// The menu renders on every platform, so labels follow the EFFECTIVE scheme
/// (resolveKeyboardScheme output), never the raw stored value — a stale
/// potplayer selection with the gate off must keep showing legacy labels.
enum DesktopShortcutHintTarget { openFile, openLink, history, settings, exit, jumpToTime }

String? shortcutHintLabel(
  DesktopShortcutHintTarget target,
  KeyboardShortcutScheme scheme,
) =>
    switch (target) {
      DesktopShortcutHintTarget.openFile => 'Ctrl + O',
      DesktopShortcutHintTarget.openLink => scheme == KeyboardShortcutScheme.potplayer
          ? 'Ctrl + U'
          : 'Ctrl + L',
      DesktopShortcutHintTarget.history =>
        scheme == KeyboardShortcutScheme.potplayer ? '; H' : 'Ctrl + H',
      DesktopShortcutHintTarget.settings =>
        scheme == KeyboardShortcutScheme.potplayer ? 'F5' : 'Ctrl + P',
      DesktopShortcutHintTarget.exit => 'Alt + X',
      // G exists only in the potplayer table; legacy has no jump binding.
      DesktopShortcutHintTarget.jumpToTime =>
        scheme == KeyboardShortcutScheme.potplayer ? 'G' : null,
    };

/// Semantic control-bar tooltip targets. Labels follow the EFFECTIVE scheme so
/// the hints never contradict the live bindings (the `P`-key sync fix: the
/// legacy play-queue hint was shown while potplayer left `P` unbound).
enum ShortcutHintKind {
  playPause,
  stop,
  previous,
  next,
  shuffle,
  repeat,
  fit,
  subtitleAudio,
  playQueue,
  playlistDockMode,
  storage,
  mute,
  fullscreen,
  alwaysOnTop,
  autoResize,
  previousInNewWindow,
  nextInNewWindow,
  // 副音 T0 buttons (quick bar). Keyboard-only actions: the legacy scheme has
  // no binding, so the hints resolve to null there.
  bgGate,
  bgControlTarget,
}

String? shortcutHintLabelFor(
  ShortcutHintKind kind,
  KeyboardShortcutScheme scheme,
) =>
    switch (kind) {
      ShortcutHintKind.playPause => 'Space',
      ShortcutHintKind.stop =>
        scheme == KeyboardShortcutScheme.potplayer ? 'F4' : 'Ctrl + C',
      ShortcutHintKind.previous =>
        scheme == KeyboardShortcutScheme.potplayer ? 'PageUp' : 'Ctrl + ←',
      ShortcutHintKind.next =>
        scheme == KeyboardShortcutScheme.potplayer ? 'PageDown' : 'Ctrl + →',
      ShortcutHintKind.shuffle =>
        scheme == KeyboardShortcutScheme.potplayer ? '; X' : 'Ctrl + X',
      ShortcutHintKind.repeat =>
        scheme == KeyboardShortcutScheme.potplayer ? '; R' : 'Ctrl + R',
      ShortcutHintKind.fit =>
        scheme == KeyboardShortcutScheme.potplayer ? 'J' : 'Ctrl + V',
      ShortcutHintKind.subtitleAudio =>
        scheme == KeyboardShortcutScheme.potplayer ? 'A / L' : 'S',
      ShortcutHintKind.playQueue =>
        scheme == KeyboardShortcutScheme.potplayer ? 'F6' : 'P',
      ShortcutHintKind.playlistDockMode =>
        scheme == KeyboardShortcutScheme.potplayer ? '; P' : 'Ctrl + \\',
      ShortcutHintKind.storage =>
        scheme == KeyboardShortcutScheme.potplayer ? '; F' : 'F',
      ShortcutHintKind.mute =>
        scheme == KeyboardShortcutScheme.potplayer ? 'M' : 'Ctrl + M',
      ShortcutHintKind.fullscreen => scheme == KeyboardShortcutScheme.potplayer
          ? 'Enter / Esc'
          : 'F11, Enter, Esc',
      ShortcutHintKind.alwaysOnTop =>
        scheme == KeyboardShortcutScheme.potplayer ? 'Ctrl + T' : 'F10',
      ShortcutHintKind.autoResize =>
        scheme == KeyboardShortcutScheme.potplayer ? 'Ctrl + R' : null,
      // New-window stepping exists only in the potplayer table (Shift+PgUp/Dn).
      // The legacy scheme has no binding, so the menu entry stays hint-less
      // instead of advertising a key that does nothing.
      ShortcutHintKind.previousInNewWindow =>
        scheme == KeyboardShortcutScheme.potplayer ? 'Shift + PageUp' : null,
      ShortcutHintKind.nextInNewWindow => scheme == KeyboardShortcutScheme.potplayer
          ? 'Shift + PageDown'
          : null,
      // Alt+' / Alt+; are potplayer-table bindings only; legacy leaves both
      // actions unreachable from the keyboard, so no hint is advertised.
      ShortcutHintKind.bgGate =>
        scheme == KeyboardShortcutScheme.potplayer ? "Alt + '" : null,
      ShortcutHintKind.bgControlTarget =>
        scheme == KeyboardShortcutScheme.potplayer ? 'Alt + ;' : null,
    };

/// Effective desktop keyboard scheme (hook — must run unconditionally in
/// build). Tooltips/panels use this so hints always match live bindings.
KeyboardShortcutScheme useEffectiveKeyboardScheme(BuildContext context) {
  final stored = useAppStore().select(context, (s) => s.keyboardShortcutScheme);
  final metadataEnabled = useAppStore()
      .select(context, (s) => s.useMetadataSettings && MetaSettingsModule.ready);
  return resolveKeyboardScheme(
    stored: stored,
    metadataEnabled: metadataEnabled,
  );
}

// ── Keybind-aware effective hints (PotPlayer scheme only) ──

PotPlayerAction? _actionForTarget(DesktopShortcutHintTarget target) =>
    switch (target) {
      DesktopShortcutHintTarget.openFile => PotPlayerAction.openFile,
      DesktopShortcutHintTarget.openLink => PotPlayerAction.openLink,
      DesktopShortcutHintTarget.history => PotPlayerAction.historyPanel,
      DesktopShortcutHintTarget.settings => PotPlayerAction.settings,
      DesktopShortcutHintTarget.exit => PotPlayerAction.exitApp,
      DesktopShortcutHintTarget.jumpToTime => PotPlayerAction.jumpToTime,
    };

PotPlayerAction? _actionForKind(ShortcutHintKind kind) => switch (kind) {
      ShortcutHintKind.playPause => PotPlayerAction.playPause,
      ShortcutHintKind.stop => PotPlayerAction.closePlayback,
      ShortcutHintKind.previous => PotPlayerAction.previousItem,
      ShortcutHintKind.next => PotPlayerAction.nextItem,
      ShortcutHintKind.shuffle => null, // sequence ; X, not in main map
      ShortcutHintKind.repeat => null,
      ShortcutHintKind.fit => PotPlayerAction.fitCycle,
      ShortcutHintKind.subtitleAudio => null,
      ShortcutHintKind.playQueue => PotPlayerAction.playQueue,
      ShortcutHintKind.playlistDockMode => null, // sequence ; P, not in main map
      ShortcutHintKind.storage => null,
      ShortcutHintKind.mute => PotPlayerAction.mute,
      ShortcutHintKind.fullscreen => PotPlayerAction.fullscreen,
      ShortcutHintKind.alwaysOnTop => PotPlayerAction.alwaysOnTop,
      ShortcutHintKind.autoResize => PotPlayerAction.toggleAutoResize,
      ShortcutHintKind.previousInNewWindow =>
        PotPlayerAction.openPreviousInNewWindow,
      ShortcutHintKind.nextInNewWindow => PotPlayerAction.openNextInNewWindow,
      ShortcutHintKind.bgGate => PotPlayerAction.toggleBackgroundGate,
      ShortcutHintKind.bgControlTarget => PotPlayerAction.toggleControlTarget,
    };

/// Context-aware hint that reflects user custom keybinds when on PotPlayer scheme.
String? effectiveShortcutHintLabel(
  BuildContext context,
  DesktopShortcutHintTarget target,
) {
  final scheme = useEffectiveKeyboardScheme(context);
  final fallback = shortcutHintLabel(target, scheme);
  final action = _actionForTarget(target);
  // For non-action-mapped targets, just return static fallback.
  if (action == null) return fallback;
  final bool metadataEnabled =
      useAppStore().state.useMetadataSettings && MetaSettingsModule.ready;
  if (scheme != KeyboardShortcutScheme.potplayer || !metadataEnabled) return fallback;
  final overrides = KeybindCodec.decodeOverrides(
    useAppStore().state.keybindOverridesJson,
  );
  // Use select-free read; caller is already in build, but we want reactive via AppStore select.
  // For simplicity, recompute from current state; rebuild is driven by outer select on keybindOverridesJson elsewhere.
  final grouped = groupedEffectiveCombos(overrides: overrides, metadataEnabled: true);
  final combos = grouped[action];
  if (combos == null || combos.isEmpty) return null;
  return combos.map(KeybindCodec.labelFor).join(' / ');
}

String? effectiveShortcutHintLabelFor(
  BuildContext context,
  ShortcutHintKind kind,
) {
  final scheme = useEffectiveKeyboardScheme(context);
  final fallback = shortcutHintLabelFor(kind, scheme);
  final action = _actionForKind(kind);
  if (action == null) return fallback;
  final bool metadataEnabled =
      useAppStore().state.useMetadataSettings && MetaSettingsModule.ready;
  if (scheme != KeyboardShortcutScheme.potplayer || !metadataEnabled) return fallback;
  final overrides = KeybindCodec.decodeOverrides(
    useAppStore().state.keybindOverridesJson,
  );
  final grouped = groupedEffectiveCombos(overrides: overrides, metadataEnabled: true);
  final combos = grouped[action];
  if (combos == null || combos.isEmpty) return null;
  return combos.map(KeybindCodec.labelFor).join(' / ');
}

/// Appends the live shortcut to a tooltip label: `label ( shortcut )`.
///
/// A null [hint] (legacy scheme, explicitly unbound action) leaves [label]
/// untouched instead of advertising a key that does nothing. The wrapper lives
/// in ARB (`tooltip_with_shortcut`) so the parenthesis style stays localizable
/// rather than being concatenated at every call site.
String withShortcutHint(
  String label,
  String? hint,
  AppLocalizations t,
) =>
    hint == null ? label : t.tooltip_with_shortcut(label, hint);
