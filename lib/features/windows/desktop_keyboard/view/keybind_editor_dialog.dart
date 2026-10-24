import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/potplayer_key_map.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/resolve_keybinds.dart';
import 'package:iris/features/windows/desktop_keyboard/model/keybind_codec.dart';
import 'package:iris/features/windows/desktop_keyboard/model/potplayer_action.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyStore);

/// Menu-only actions are hidden from the rebindable list: binding
/// [PotPlayerAction.seekStepPopover] would resurrect the modal popover that
/// gated off every other shortcut. Its keyboard alternative is
/// seekStepIncrease / seekStepDecrease (direct OSD, no window).
/// [PotPlayerAction.revealCurrentFileInExplorer] is likewise a right-click
/// command (shell hand-off), not a transport action.
const Set<PotPlayerAction> kMenuOnlyPotPlayerActions = <PotPlayerAction>{
  PotPlayerAction.seekStepPopover,
  PotPlayerAction.revealCurrentFileInExplorer,
};

/// Human-readable names for actions (localized via `keybind_act_*` keys).
String keybindActionLabel(PotPlayerAction a, AppLocalizations t) => switch (a) {
      PotPlayerAction.playPause => t.keybind_act_play_pause,
      PotPlayerAction.previousItem => t.keybind_act_previous,
      PotPlayerAction.nextItem => t.keybind_act_next,
      PotPlayerAction.frameBackward => t.keybind_act_frame_backward,
      PotPlayerAction.frameForward => t.keybind_act_frame_forward,
      PotPlayerAction.seekBackward => t.keybind_act_seek_backward,
      PotPlayerAction.seekForward => t.keybind_act_seek_forward,
      PotPlayerAction.bigSeekBackward => t.keybind_act_big_seek_backward,
      PotPlayerAction.bigSeekForward => t.keybind_act_big_seek_forward,
      PotPlayerAction.largeSeekBackward => t.keybind_act_large_seek_backward,
      PotPlayerAction.largeSeekForward => t.keybind_act_large_seek_forward,
      PotPlayerAction.hugeSeekBackward => t.keybind_act_huge_seek_backward,
      PotPlayerAction.hugeSeekForward => t.keybind_act_huge_seek_forward,
      PotPlayerAction.seekStepPopover => t.keybind_act_seek_step_popover,
      PotPlayerAction.seekStepIncrease => t.keybind_act_seek_step_increase,
      PotPlayerAction.seekStepDecrease => t.keybind_act_seek_step_decrease,
      PotPlayerAction.revealCurrentFileInExplorer => t.open_in_explorer,
      PotPlayerAction.restart => t.keybind_act_restart,
      PotPlayerAction.jumpToTime => t.keybind_act_jump_to_time,
      PotPlayerAction.volumeUp => t.keybind_act_volume_up,
      PotPlayerAction.volumeDown => t.keybind_act_volume_down,
      PotPlayerAction.mute => t.keybind_act_mute,
      PotPlayerAction.speedDown => t.keybind_act_speed_down,
      PotPlayerAction.speedUp => t.keybind_act_speed_up,
      PotPlayerAction.speedReset => t.keybind_act_speed_reset,
      PotPlayerAction.fitCycle => t.keybind_act_fit_cycle,
      PotPlayerAction.cycleSubtitleTrack => t.keybind_act_cycle_subtitle,
      PotPlayerAction.cycleAudioTrack => t.keybind_act_cycle_audio,
      PotPlayerAction.toggleSubtitleVisibility => t.keybind_act_toggle_subtitle,
      PotPlayerAction.subtitleSyncForward => t.keybind_act_sub_sync_forward,
      PotPlayerAction.subtitleSyncBackward => t.keybind_act_sub_sync_backward,
      PotPlayerAction.subtitleSyncReset => t.keybind_act_sub_sync_reset,
      PotPlayerAction.audioSyncForward => t.keybind_act_audio_sync_forward,
      PotPlayerAction.audioSyncBackward => t.keybind_act_audio_sync_backward,
      PotPlayerAction.audioSyncReset => t.keybind_act_audio_sync_reset,
      PotPlayerAction.jumpToMiddle => t.keybind_act_jump_middle,
      PotPlayerAction.jumpNearEnd => t.keybind_act_jump_near_end,
      PotPlayerAction.deletePhysicalFile => t.keybind_act_delete_file,
      PotPlayerAction.screenshotFrame => t.keybind_act_screenshot,
      PotPlayerAction.abSetPointA => t.keybind_act_ab_a,
      PotPlayerAction.abSetPointB => t.keybind_act_ab_b,
      PotPlayerAction.abQuickToggle => t.keybind_act_ab_quick,
      PotPlayerAction.abToggleSectionRepeat => t.keybind_act_ab_section,
      PotPlayerAction.tagChordAdd => t.keybind_act_tag_add,
      PotPlayerAction.tagChordRemove => t.keybind_act_tag_remove,
      PotPlayerAction.tagChordSwitchView => t.keybind_act_tag_switch,
      PotPlayerAction.subtitlesPanel => t.keybind_act_subtitles_panel,
      PotPlayerAction.audioTracksPanel => t.keybind_act_audio_panel,
      PotPlayerAction.settings => t.keybind_act_settings,
      PotPlayerAction.playQueue => t.keybind_act_play_queue,
      PotPlayerAction.togglePlaylistDockMode => t.keybind_act_dock_mode,
      PotPlayerAction.storagesBrowser => t.keybind_act_storages,
      PotPlayerAction.historyPanel => t.keybind_act_history,
      PotPlayerAction.moreMenu => t.keybind_act_more_menu,
      PotPlayerAction.openFile => t.keybind_act_open_file,
      PotPlayerAction.openLink => t.keybind_act_open_link,
      PotPlayerAction.closePlayback => t.keybind_act_close_playback,
      PotPlayerAction.toggleRepeatMode => t.keybind_act_toggle_repeat,
      PotPlayerAction.toggleShuffleMode => t.keybind_act_toggle_shuffle,
      PotPlayerAction.alwaysOnTop => t.keybind_act_always_on_top,
      PotPlayerAction.toggleAutoResize => t.keybind_act_auto_resize,
      PotPlayerAction.fullscreen => t.keybind_act_fullscreen,
      PotPlayerAction.exitFullscreen => t.keybind_act_exit_fullscreen,
      PotPlayerAction.exitApp => t.keybind_act_exit_app,
    };

String _categoryFor(PotPlayerAction a, AppLocalizations t) {
  if (const {
    PotPlayerAction.playPause,
    PotPlayerAction.previousItem,
    PotPlayerAction.nextItem,
    PotPlayerAction.frameBackward,
    PotPlayerAction.frameForward,
  }.contains(a)) return t.keybind_cat_playback;
  if (const {
    PotPlayerAction.seekBackward,
    PotPlayerAction.seekForward,
    PotPlayerAction.bigSeekBackward,
    PotPlayerAction.bigSeekForward,
    PotPlayerAction.largeSeekBackward,
    PotPlayerAction.largeSeekForward,
    PotPlayerAction.hugeSeekBackward,
    PotPlayerAction.hugeSeekForward,
    PotPlayerAction.seekStepPopover,
    PotPlayerAction.seekStepIncrease,
    PotPlayerAction.seekStepDecrease,
    PotPlayerAction.restart,
    PotPlayerAction.jumpToTime,
    PotPlayerAction.jumpToMiddle,
    PotPlayerAction.jumpNearEnd,
  }.contains(a)) return t.keybind_cat_seeking;
  if (const {
    PotPlayerAction.volumeUp,
    PotPlayerAction.volumeDown,
    PotPlayerAction.mute,
    PotPlayerAction.speedDown,
    PotPlayerAction.speedUp,
    PotPlayerAction.speedReset,
    PotPlayerAction.fitCycle,
  }.contains(a)) return t.keybind_cat_av;
  if (const {
    PotPlayerAction.cycleSubtitleTrack,
    PotPlayerAction.cycleAudioTrack,
    PotPlayerAction.toggleSubtitleVisibility,
    PotPlayerAction.subtitleSyncForward,
    PotPlayerAction.subtitleSyncBackward,
    PotPlayerAction.subtitleSyncReset,
    PotPlayerAction.audioSyncForward,
    PotPlayerAction.audioSyncBackward,
    PotPlayerAction.audioSyncReset,
  }.contains(a)) return t.keybind_cat_tracks;
  if (const {
    PotPlayerAction.deletePhysicalFile,
    PotPlayerAction.screenshotFrame,
  }.contains(a)) return t.keybind_cat_capture;
  if (const {
    PotPlayerAction.abSetPointA,
    PotPlayerAction.abSetPointB,
    PotPlayerAction.abQuickToggle,
    PotPlayerAction.abToggleSectionRepeat,
  }.contains(a)) return t.keybind_cat_ab;
  if (const {
    PotPlayerAction.tagChordAdd,
    PotPlayerAction.tagChordRemove,
    PotPlayerAction.tagChordSwitchView,
  }.contains(a)) return t.keybind_cat_tag;
  if (const {
    PotPlayerAction.subtitlesPanel,
    PotPlayerAction.audioTracksPanel,
    PotPlayerAction.settings,
    PotPlayerAction.playQueue,
    PotPlayerAction.togglePlaylistDockMode,
    PotPlayerAction.storagesBrowser,
    PotPlayerAction.historyPanel,
    PotPlayerAction.moreMenu,
  }.contains(a)) return t.keybind_cat_panels;
  return t.keybind_cat_session;
}

Future<void> showKeybindEditorDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _KeybindEditorDialog(),
  );
}

class _KeybindEditorDialog extends HookWidget {
  const _KeybindEditorDialog();

  @override
  Widget build(BuildContext context) {
    final store = useAppStore();
    final t = getLocalizations(context);
    final overridesJson = useAppStore().select(context, (s) => s.keybindOverridesJson);
    final overrides = KeybindCodec.decodeOverrides(overridesJson);
    final effective = groupedEffectiveCombos(overrides: overrides, metadataEnabled: true);

    // Defaults grouped for fallback display.
    final Map<PotPlayerAction, List<KeyCombo>> defaultsGrouped =
        <PotPlayerAction, List<KeyCombo>>{};
    for (final entry in kPotPlayerKeyMap.entries) {
      (defaultsGrouped[entry.value] ??= <KeyCombo>[]).add(entry.key);
    }

    final List<PotPlayerAction> sorted = PotPlayerAction.values.toList()
      ..sort((a, b) {
        final ca = _categoryFor(a, t);
        final cb = _categoryFor(b, t);
        final c = ca.compareTo(cb);
        if (c != 0) return c;
        return keybindActionLabel(a, t).compareTo(keybindActionLabel(b, t));
      });

    String currentCategory = '';
    final List<Widget> tiles = <Widget>[];
    for (final action in sorted) {
      if (kMenuOnlyPotPlayerActions.contains(action)) continue;
      final cat = _categoryFor(action, t);
      if (cat != currentCategory) {
        currentCategory = cat;
        tiles.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(cat,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    )),
          ),
        );
      }
      final List<KeyCombo>? eff = effective[action];
      final List<KeyCombo>? def = defaultsGrouped[action];
      final bool hasOverride = overrides.containsKey(action.name);
      final bool isUnbound = hasOverride && (eff == null || eff.isEmpty);
      tiles.add(
        _ActionTile(
          action: action,
          effectiveCombos: eff ?? const <KeyCombo>[],
          defaultCombos: def ?? const <KeyCombo>[],
          hasOverride: hasOverride,
          isUnbound: isUnbound,
          overrides: overrides,
        ),
      );
    }

    return AlertDialog(
      title: Text(t.keybind_title),
      content: SizedBox(
        width: 560,
        height: 520,
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    t.keybind_hint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.restart_alt_rounded, size: 16),
                  label: Text(t.keybind_reset_all),
                  onPressed: overrides.isEmpty
                      ? null
                      : () async {
                          final bool? ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) {
                              final t = getLocalizations(ctx);
                              return AlertDialog(
                                title: Text(t.keybind_reset_all_title),
                                content: Text(t.keybind_reset_all_body),
                                actions: <Widget>[
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: Text(t.cancel),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: Text(t.keybind_reset),
                                  ),
                                ],
                              );
                            },
                          );
                          if (ok == true) {
                            await store.resetAllKeybinds();
                          }
                        },
                ),
              ],
            ),
            const Divider(height: 12),
            Expanded(
              child: ListView(
                children: tiles,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.close),
        ),
      ],
    );
  }
}

class _ActionTile extends HookWidget {
  const _ActionTile({
    required this.action,
    required this.effectiveCombos,
    required this.defaultCombos,
    required this.hasOverride,
    required this.isUnbound,
    required this.overrides,
  });

  final PotPlayerAction action;
  final List<KeyCombo> effectiveCombos;
  final List<KeyCombo> defaultCombos;
  final bool hasOverride;
  final bool isUnbound;
  final Map<String, List<KeyCombo>> overrides;

  @override
  Widget build(BuildContext context) {
    final store = useAppStore();
    final bool canAdd = effectiveCombos.length < 4;

    Future<void> persist(List<KeyCombo> next) async {
      if (next.isEmpty) {
        // Explicitly unbound: store empty list.
        await store.setKeybindForAction(
          action.name,
          <dynamic>[],
        );
        return;
      }
      final List<Map<String, dynamic>> jsonList = next
          .map((c) => <String, dynamic>{
                'keyId': c.key.keyId,
                'ctrl': c.ctrl,
                'alt': c.alt,
                'shift': c.shift,
              })
          .toList();
      await store.setKeybindForAction(action.name, jsonList);
    }

    Future<void> handleConflict(KeyCombo combo) async {
      final PotPlayerAction? owner = conflictFor(
        combo,
        action,
        overrides: overrides,
        metadataEnabled: true,
      );
      if (owner != null) {
        final bool? overwrite = await showDialog<bool>(
          context: context,
          builder: (ctx) {
            final t = getLocalizations(ctx);
            return AlertDialog(
              title: Text(t.keybind_conflict_title),
              content: Text(
                t.keybind_conflict_body(KeybindCodec.labelFor(combo),
                    keybindActionLabel(owner, t)),
              ),
              actions: <Widget>[
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(t.cancel)),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(t.keybind_overwrite)),
              ],
            );
          },
        );
        if (overwrite != true) return;
        // Proceed: resolver will make last-writer win, so we just insert.
      }
      // Check if combo already in this action.
      if (effectiveCombos.contains(combo)) {
        _log.d('combo already bound to same action');
        return;
      }
      final List<KeyCombo> next = List<KeyCombo>.from(effectiveCombos)..add(combo);
      await persist(next);
    }

    return ListTile(
      dense: true,
      title: Text(keybindActionLabel(action, getLocalizations(context)),
          style: const TextStyle(fontSize: 13)),
      subtitle: Builder(
        builder: (_) {
          final t = getLocalizations(context);
          if (isUnbound) {
            return Text(t.keybind_unbound,
                style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 12));
          }
          if (effectiveCombos.isEmpty) {
            return Text(
                t.keybind_default_prefix(
                    defaultCombos.map(KeybindCodec.labelFor).join(' / ')),
                style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12));
          }
          final bool isCustom = hasOverride;
          final String label = effectiveCombos.map(KeybindCodec.labelFor).join('  ·  ');
          return Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: isCustom ? Theme.of(context).colorScheme.primary : null,
              fontWeight: isCustom ? FontWeight.w600 : FontWeight.w400,
            ),
          );
        },
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (hasOverride)
            IconButton(
              tooltip: getLocalizations(context).keybind_tip_reset,
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              onPressed: () async => store.removeKeybindForAction(action.name),
            ),
          if (effectiveCombos.isNotEmpty)
            IconButton(
              tooltip: getLocalizations(context).keybind_tip_clear,
              icon: const Icon(Icons.block_rounded, size: 18),
              onPressed: () async => persist(<KeyCombo>[]),
            ),
          IconButton(
            tooltip: canAdd
                ? getLocalizations(context).keybind_tip_add
                : getLocalizations(context).keybind_tip_maxed,
            icon: const Icon(Icons.edit_rounded, size: 18),
            onPressed: canAdd
                ? () async {
                    final KeyCombo? picked = await _pickKeyCombo(context);
                    if (picked == null) return;
                    await handleConflict(picked);
                  }
                : null,
          ),
        ],
      ),
      // Tap also opens picker.
      onTap: canAdd
          ? () async {
              final KeyCombo? picked = await _pickKeyCombo(context);
              if (picked == null) return;
              await handleConflict(picked);
            }
          : null,
    );
  }
}

Future<KeyCombo?> _pickKeyCombo(BuildContext context) {
  return showDialog<KeyCombo>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _KeyCaptureDialog(),
  );
}

class _KeyCaptureDialog extends HookWidget {
  const _KeyCaptureDialog();

  @override
  Widget build(BuildContext context) {
    final focusNode = useFocusNode();
    final captured = useState<KeyCombo?>(null);
    final error = useState<String?>(null);

    useEffect(() {
      // Autofocus after frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => focusNode.requestFocus());
      return null;
    }, <Object?>[]);

    void onKeyEvent(KeyEvent event) {
      if (event is! KeyDownEvent) return;
      final LogicalKeyboardKey key = event.logicalKey;
      // Ignore pure modifiers.
      if (key == LogicalKeyboardKey.controlLeft ||
          key == LogicalKeyboardKey.controlRight ||
          key == LogicalKeyboardKey.altLeft ||
          key == LogicalKeyboardKey.altRight ||
          key == LogicalKeyboardKey.shiftLeft ||
          key == LogicalKeyboardKey.shiftRight ||
          key == LogicalKeyboardKey.metaLeft ||
          key == LogicalKeyboardKey.metaRight) {
        return;
      }
      // Esc cancels.
      if (key == LogicalKeyboardKey.escape) {
        Navigator.pop(context);
        return;
      }
      final bool ctrl = HardwareKeyboard.instance.isControlPressed;
      final bool alt = HardwareKeyboard.instance.isAltPressed;
      final bool shift = HardwareKeyboard.instance.isShiftPressed;
      final KeyCombo combo = KeyCombo(key, ctrl: ctrl, alt: alt, shift: shift);
      if (!KeybindCodec.isRecordable(combo)) {
        error.value = getLocalizations(context).keybind_capture_invalid;
        return;
      }
      captured.value = combo;
    }

    final t = getLocalizations(context);
    return AlertDialog(
      title: Text(t.keybind_capture_title),
      content: KeyboardListener(
        focusNode: focusNode,
        onKeyEvent: onKeyEvent,
        child: Container(
          width: 360,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.keyboard_rounded, size: 36, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              Text(
                captured.value == null ? t.keybind_capture_hint : KeybindCodec.labelFor(captured.value!),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (error.value != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(error.value!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
              ],
              const SizedBox(height: 12),
              Text(
                t.keybind_capture_cancel_hint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
        FilledButton(
          onPressed: captured.value == null ? null : () => Navigator.pop(context, captured.value),
          child: Text(t.save),
        ),
      ],
    );
  }
}
