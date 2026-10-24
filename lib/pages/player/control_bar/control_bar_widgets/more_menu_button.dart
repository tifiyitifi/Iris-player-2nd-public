import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/actions/background_playback_actions.dart';
import 'package:iris/features/app_instance/services/new_window_launcher.dart';
import 'package:iris/features/app_instance/services/new_window_requests.dart';
import 'package:iris/features/app_instance/view/new_window_dialogs.dart';
import 'package:iris/features/background_playback/background_playback_gate.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/playback_tools/view/screenshot_capture_flow.dart';
import 'package:iris/features/playback_tools/store/playback_tools_store.dart';
import 'package:iris/features/playback_tools/view/screenshot_feedback.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart'
    show SortDirection;
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/features/scenario_playback/scan/commands/scenario_source_scan_command.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/commands/tag_play_actions.dart';
import 'package:iris/features/virtual_media/commands/vm_actions.dart';
import 'package:iris/features/virtual_media/vm_gate.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/resolve_keyboard_scheme.dart';
import 'package:iris/features/windows/desktop_keyboard/view/show_jump_to_time_dialog.dart';
import 'package:iris/features/windows/desktop_keyboard/view/shortcut_hints.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/resolve_keybinds.dart';
import 'package:iris/features/windows/desktop_keyboard/model/keybind_codec.dart';
import 'package:iris/features/windows/desktop_keyboard/model/potplayer_action.dart';
import 'package:iris/globals.dart' show moreMenuKeyNotifier;
import 'package:iris/hooks/use_published_global_key.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/control_bar_slot_actions.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/resolve_control_bar_overflow.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/background_playback_menu_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/control_bar_constants.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/play_queue_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/seek_step_popover.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/utils/app_exit.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/layout_breakpoints.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/bottom_sheets/show_open_link_bottom_sheet.dart';
import 'package:iris/widgets/dialogs/show_open_link_dialog.dart';
import 'package:iris/widgets/dialogs/show_control_group_floating_dialog.dart';
import 'package:iris/widgets/dialogs/show_slider_type_dialog.dart';
import 'package:iris/widgets/dialogs/show_rate_dialog.dart';
import 'package:iris/widgets/popup.dart';
import 'package:iris/widgets/popups/history.dart';
import 'package:iris/widgets/popups/settings/settings.dart';
import 'package:iris/widgets/popups/track/subtitle_and_audio_track.dart';
import 'package:provider/provider.dart';

class MoreMenuButton extends HookWidget {
  const MoreMenuButton({
    super.key,
    required this.showControl,
    required this.showControlForHover,
    this.color,
    this.overlayColor,
    this.collapsed = const <ControlBarSlot>{},
  });

  final void Function() showControl;
  final Future<void> Function(Future<void>) showControlForHover;
  final Color? color;
  final WidgetStateProperty<Color?>? overlayColor;

  /// Optional bar slots pushed here at the current width (see
  /// `resolveControlBarOverflow`). They render as extra entries at the TOP of
  /// the menu, above a divider, so a collapsed control stays one tap away.
  final Set<ControlBarSlot> collapsed;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    // Per-mount key published for the keyboard shortcuts (see
    // `usePublishedGlobalKey`): never a shared object.
    final GlobalKey<PopupMenuButtonState> menuKey =
        usePublishedGlobalKey(moreMenuKeyNotifier);

    final rate = useAppStore().select(context, (s) => s.rate);
    final runtimeOrientation = useAppStore().select(context, (s) => s.runtimeOrientation);
    final popupDirection = useAppStore().select(context, (s) => s.defaultPopupDirection);
    final int seekStepSec = useAppStore().select(context, (s) => s.seekStepSeconds);

    final width = MediaQuery.sizeOf(context).width;
    final realOrientation = MediaQuery.of(context).orientation;

    final bool isLandscape = () {
      switch (runtimeOrientation) {
        case ScreenOrientation.landscape:
          return true;
        case ScreenOrientation.portrait:
          return false;
        case ScreenOrientation.device:
          return realOrientation == Orientation.landscape;
      }
    }();

    final PhoneLandscapeUseMode phoneUseMode =
        useAppStore().select(context, (s) => s.phoneLandscapeUseMode);
    final bool metaSettingsOn =
        useAppStore().select(context, (s) => s.useMetadataSettings);
    // This button is instantiated by BOTH bars and `LegacyControlBar` builds
    // its own, so the menu has to ask which LAYOUT it is attached to — the bar
    // it lives in, not just the stored mode. `ControlBar.build` can read
    // `isSidewayPanelMounted` bare because the legacy bar is not in the tree
    // when it runs; here there is no such structural guarantee, so the veto has
    // to be applied here.
    final bool legacyControlBar =
        useAppStore().select(context, (s) => s.useLegacyControlBar);
    // Menu shortcut hints follow the EFFECTIVE keyboard scheme so the labels
    // never contradict the live bindings (D10).
    final effectiveScheme = resolveKeyboardScheme(
      stored: useAppStore().select(context, (s) => s.keyboardShortcutScheme),
      metadataEnabled: metaSettingsOn && MetaSettingsModule.ready,
    );
    final bool isPortraitHidden = isMobilePlatform && !isLandscape;
    final bool shouldShowSidePanelEntry = !isPortraitHidden;
    final bool oneHandedActive = isSidePanelLayoutMounted(
      mode: phoneUseMode,
      legacyControlBar: legacyControlBar,
      isPhone: isMobilePlatform,
      isLandscape: isLandscape,
    );
    // Is the rendered bar a CircleSliderLayout? Same expression as
    // `ControlBar.build` (`useOneHandedScrubber || useCircleSlider`), so the
    // menu never disagrees with the layout it is attached to — which is why
    // `oneHandedActive` above goes through the legacy veto and the raw mount
    // gate would not do. `LegacyControlBar`'s own circle column is covered by
    // the second term, and its linear branches carry a rate button of their own.
    final PhoneLandscapeSliderType sliderType =
        useAppStore().select(context, (s) => s.phoneLandscapeSliderType);
    final bool sidewayOrCirclePanel = oneHandedActive ||
        useLegacyCircleSliderPanel(
          metadataEnabled: metaSettingsOn,
          isPhone: isMobilePlatform,
          isLandscape: isLandscape,
          sliderType: sliderType,
        );
    // The speed row in More is a FALLBACK: show it exactly when the live bar
    // carries no RateButton of its own. CircleSliderLayout never renders one
    // (any width); the linear bars only get one from kMobileBreakpoint up.
    // Width alone was the old gate (600) — wrong for sideway mode and it left
    // a 600–640 hole where MobileControlLayout was active but the row hid.
    final bool layoutHasRateButton =
        !sidewayOrCirclePanel && width >= kMobileBreakpoint;

    // Playback-tools state must be read HERE (build phase): itemBuilder runs
    // during the tap gesture, where context.select() asserts and kills the
    // whole menu. Same precomputed-args convention as every other item below.
    final bool frameToolsVisible =
        usePlaybackToolsStore().select(context, (s) => s.frameToolsVisible);
    // Bottom control-group switch button: available on phones and on desktop
    // now (desktop opts in through the button's own per-orientation visibility,
    // configured by the dialog this item opens). State read in build — see note
    // above.

    // 副音 float-panel visibility toggle (shown only while 副音 runs).
    final bgStore = useBackgroundPlaybackStore();
    final bool bgEnabled = bgStore.select(context, (s) => s.enabled);
    final bool bgPanelVisible = bgStore.select(context, (s) => s.bgPanelVisible);

    // Keybind-aware hints: precompute in build so itemBuilder stays select-free.
    final String keybindJson = useAppStore().select(context, (s) => s.keybindOverridesJson);
    String? hintForTarget(DesktopShortcutHintTarget target) {
      final String? base = shortcutHintLabel(target, effectiveScheme);
      if (effectiveScheme != KeyboardShortcutScheme.potplayer ||
          !metaSettingsOn ||
          !MetaSettingsModule.ready) return base;
      final PotPlayerAction? action = switch (target) {
        DesktopShortcutHintTarget.openFile => PotPlayerAction.openFile,
        DesktopShortcutHintTarget.openLink => PotPlayerAction.openLink,
        DesktopShortcutHintTarget.history => PotPlayerAction.historyPanel,
        DesktopShortcutHintTarget.settings => PotPlayerAction.settings,
        DesktopShortcutHintTarget.exit => PotPlayerAction.exitApp,
        DesktopShortcutHintTarget.jumpToTime => PotPlayerAction.jumpToTime,
      };
      if (action == null) return base;
      final overrides = KeybindCodec.decodeOverrides(keybindJson);
      if (!overrides.containsKey(action.name)) return base;
      final grouped = groupedEffectiveCombos(overrides: overrides, metadataEnabled: true);
      final combos = grouped[action];
      if (combos == null || combos.isEmpty) return null;
      return combos.map(KeybindCodec.labelFor).join(' / ');
    }

    final String? openFileHint = hintForTarget(DesktopShortcutHintTarget.openFile);
    final String? openLinkHint = hintForTarget(DesktopShortcutHintTarget.openLink);
    final String? historyHint = hintForTarget(DesktopShortcutHintTarget.history);
    final String? settingsHint = hintForTarget(DesktopShortcutHintTarget.settings);
    final String? exitHint = hintForTarget(DesktopShortcutHintTarget.exit);
    final String? jumpHint = hintForTarget(DesktopShortcutHintTarget.jumpToTime);
    final String? subtitleHint = shortcutHintLabelFor(ShortcutHintKind.subtitleAudio, effectiveScheme);

    final double sidewayW = useAppStore().select(context, (s) => s.sidewayPanelWidthPct);
    final double sidewayH = useAppStore().select(context, (s) => s.sidewayPanelHeightPct);
    final double sidewayWpx = useAppStore().select(context, (s) => s.sidewayPanelWidthPx);
    final double sidewayHpx = useAppStore().select(context, (s) => s.sidewayPanelHeightPx);
    // Desktop sizes the panel in absolute px (phone uses screen %); show what
    // is actually applied instead of always the phone percentages.
    final String sidePanelTitle = isDesktop
        ? t.menu_side_panel_px(
            sidewayWpx.toStringAsFixed(0), sidewayHpx.toStringAsFixed(0))
        : t.menu_side_panel(
            sidewayW.toStringAsFixed(0), sidewayH.toStringAsFixed(0));

    // Scenario-driven playback only: the current workspace scenario (the
    // active independent entry's own workspace, else SystemPlaying) is the
    // scan target. Read once here so itemBuilder stays select-free.
    final bool scenarioMode = useAppStore().select(
      context,
      (s) => !s.useLegacyStoragePersistence && s.useScenarioDrivenPlayback,
    );
    final String? scanScenarioId = scenarioMode
        ? currentPlaybackWorkspace(usePlaybackScenarioStore())?.id
        : null;

    // Multi-window: the file currently fed to the player, plus the workspace's
    // sort. Precomputed for the same reason as everything else in this build —
    // itemBuilder runs during the tap gesture, where context.select() asserts.
    final FileItem? currentFileForNewWindow = usePlayQueueStore().select(
      context,
      (s) {
        final i = s.playQueue.indexWhere((e) => e.index == s.currentIndex);
        return i < 0 ? null : s.playQueue[i].file;
      },
    );
    final (ScenarioSortField, SortDirection) workspaceSort =
        usePlaybackScenarioStore().select(context, (s) {
      for (final c in s.scenarios) {
        if (c.id == s.activeScenarioId) return (c.sortField, c.sortDirection);
      }
      return (ScenarioSortField.name, SortDirection.asc);
    });

    return PopupMenuButton(
      key: menuKey,
      icon: Icon(Icons.more_vert_rounded, size: kIconSizeSecondary, color: color),
      style: ButtonStyle(overlayColor: overlayColor),
      clipBehavior: Clip.hardEdge,
      constraints: const BoxConstraints(minWidth: kPopupMenuMinWidth),
      itemBuilder: (context) => [
        // Collapsed bar controls (narrow width) come first — they were primary
        // affordances on the bar, so they lead the menu.
        ..._collapsedItems(context, t, subtitleHint),
        if (collapsed.isNotEmpty) const PopupMenuDivider(),
        _openFileItemWithHint(context, t, openFileHint),
        _openLinkItemWithHint(context, t, openLinkHint),
        _jumpToTimeItemWithHint(context, t, jumpHint),
        // Seek step moved here from every control bar (sub_media §3): the
        // adjuster is a rarely-used setting, so it left the primary bar.
        _seekStepItem(context, t, seekStepSec),
        _tagPlayItem(context, t),
        if (NewWindowLauncher.isSupported && currentFileForNewWindow != null)
          _newWindowItem(context, t, currentFileForNewWindow, workspaceSort),
        if (scanScenarioId != null)
          _scanSourcesItem(context, t, scanScenarioId),
        // DEPRECATED (sub_media §2): the legacy More-menu 副音 entries are
        // sealed behind a permanently-false flag. Code kept for rollback;
        // the control-bar 副音 menu now owns these intents.
        if (BackgroundPlaybackGate.legacyMoreMenuEntryEnabled) ...[
          if (bgEnabled && BackgroundPlaybackGate.enabled)
            _bgPanelItem(context, t,
                visible: bgPanelVisible,
                onToggle: () => bgStore.setPanelVisible(!bgPanelVisible)),
          _backgroundPlaybackItem(context, t),
        ],
        // Legacy VirtualMedia sheet sealed (VirtualMediaGate.legacySheetEnabled
        // is permanently false): rule CRUD lives in meta-settings, playback
        // stays unaware single-video. Row hidden, definition kept as dead code.
        if (VirtualMediaGate.legacySheetEnabled) _virtualMediaItem(context, t),
        if (!layoutHasRateButton && !collapsed.contains(ControlBarSlot.rate))
          _rateItem(context, t, rate),
        if (shouldShowSidePanelEntry)
          _unifiedSidePanelItem(context, t, sidePanelTitle),
        // Fine-tune range retired — dial axis strip now mirrors global seek step.
        // (The More-menu entry is gone; the dialog itself is still reachable
        // from Settings → Play.)
        // Phone-only playback tools (float panel + capture).
        if (isMobilePlatform) ...[
          _frameToolsItem(context, t, frameToolsVisible),
          _screenshotItem(context, t),
        ],
        // Screen lock is NOT here any more: the guard moved back onto the
        // playback row (it took the slot the 副音 menu vacated), phone + tablet
        // video only — see `ScreenLockButton`.
        // Floating bottom-group switch button (phones / desktop).
        _controlGroupItem(context, t),
        // Subtitle & audio tracks — moved from control bar (now seek step) to More.
        // Industry standard grouping: playback tracks sit directly above History
        // (before system entries Settings/Exit), so they remain discoverable
        // without cluttering the main bar.
        _subtitleItemWithHint(context, t, popupDirection, subtitleHint),
        _historyItemWithHint(context, t, popupDirection, historyHint),
        _settingsItemWithHint(context, t, popupDirection, settingsHint),
        _exitItemWithHint(context, t, exitHint),
        if (isMobilePlatform) _gestureTipsItem(context, t),
      ],
    );
  }

  /// Seek-step adjuster (sub_media §3) — opens the same transparent popover
  /// that used to hang off the control bar's seek-step button.
  PopupMenuItem _seekStepItem(BuildContext context, t, int sec) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: const Icon(Icons.update, size: kMenuTileIconSizeTiny),
        title: Text('${t.menu_seek_step}: ${sec}s'),
      ),
      onTap: () => showControlForHover(showSeekStepPopover(context)),
    );
  }

  /// Tag play sheet — same feature as the region-gesture double-tap entry.
  PopupMenuItem _tagPlayItem(BuildContext context, t) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading:
            const Icon(Icons.style_rounded, size: kMenuTileIconSizeTiny),
        title: Text(t.menu_tag_play),
      ),
      onTap: () {
        showControlForHover(openTagPlaySheet(context));
      },
    );
  }

  /// Multi-window: plays the current file's folder scope in a fresh process,
  /// landing on that file (the same contract as tapping it in the browser).
  PopupMenuItem _newWindowItem(
    BuildContext context,
    AppLocalizations t,
    FileItem file,
    (ScenarioSortField, SortDirection) sort,
  ) {
    final List<String> path = file.path;
    final String folder =
        path.isEmpty ? '' : path.sublist(0, path.length - 1).join('/');
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: const Icon(Icons.open_in_new_rounded,
            size: kMenuTileIconSizeTiny),
        title: Text(t.lib_play_in_new_window),
      ),
      onTap: () => launchNewWindow(
        context,
        newWindowRequestForFile(
          item: file,
          folderPath: canonicalDbPath(folder),
          itemPath: canonicalOccurrencePath(path.join('/')),
          sortField: sort.$1,
          sortDirection: sort.$2,
        ),
      ),
    );
  }

  /// 扫描更新源数据 — re-scans the current workspace scenario's source
  /// storages and refreshes the resolved play queue. Greyed while every
  /// configured storage is known-unreachable.
  PopupMenuItem _scanSourcesItem(
      BuildContext context, t, String scenarioId) {
    final enabled = ScenarioSourceScanCommand.isEnabled();
    return PopupMenuItem(
      enabled: enabled,
      child: ListTile(
        enabled: enabled,
        mouseCursor: SystemMouseCursors.click,
        leading: Icon(
          Icons.autorenew_rounded,
          size: kMenuTileIconSizeTiny,
          color: enabled ? null : Theme.of(context).disabledColor,
        ),
        title: Text(t.scn_scan_sources),
      ),
      onTap: () async {
        showControl();
        final navigator = Navigator.of(context, rootNavigator: true);
        await ScenarioSourceScanCommand.run(
          // ignore: use_build_context_synchronously
          context,
          scenarioId: scenarioId,
        );
        // The scan may have opened dialogs on the root navigator; keep the
        // controls restored for when they dismiss.
        if (navigator.mounted) showControl();
      },
    );
  }

  /// 副音播放 — launches the independent background playback engine (gate
  /// OFF → explanatory dialog, same pattern as the tag play sheet).
  PopupMenuItem _backgroundPlaybackItem(BuildContext context, t) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading:
            const Icon(Icons.multitrack_audio_rounded, size: kMenuTileIconSizeTiny),
        title: Text(t.menu_background_playback),
      ),
      onTap: () {
        showControlForHover(BackgroundPlaybackActions.open(context));
      },
    );
  }

  /// 副音 float-panel show/hide (collapse pill state) while 副音 is running.
  /// Hiding the panel never stops playback — the X on the panel does.
  PopupMenuItem _bgPanelItem(BuildContext context, t,
      {required bool visible, required VoidCallback onToggle}) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: Icon(
          visible
              ? Icons.picture_in_picture_alt_rounded
              : Icons.picture_in_picture_alt_outlined,
          size: kMenuTileIconSizeTiny,
        ),
        title: Text(t.bg_panel_toggle),
        trailing: visible
            ? Icon(Icons.check_rounded,
                size: 18, color: Theme.of(context).colorScheme.primary)
            : null,
      ),
      onTap: onToggle,
    );
  }

  /// Virtual Media sheet — rules → virtual sequential items (spec v2).
  PopupMenuItem _virtualMediaItem(BuildContext context, t) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading:
            const Icon(Icons.auto_awesome_motion_rounded, size: kMenuTileIconSizeTiny),
        title: Text(t.menu_virtual_media),
      ),
      onTap: () {
        showControlForHover(openVirtualMediaSheet(context));
      },
    );
  }

  Widget? _hintFromLabel(BuildContext context, String? label) {
    if (label == null) return null;
    return Text(
      label,
      style: TextStyle(fontSize: kMenuTextFontSizeShortcut, color: Theme.of(context).dividerColor),
    );
  }

  PopupMenuItem _rateItem(BuildContext context, t, double rate) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: const Icon(Icons.speed_rounded, size: kMenuTileIconSize),
        title: Text('${t.playback_speed}: ${rate}X'),
      ),
      onTap: () => showControlForHover(showRatePickerDialog(context)),
    );
  }

  // Hint-precomputed variants (build-phase labels; itemBuilder stays select-free).
  PopupMenuItem _openFileItemWithHint(BuildContext context, t, String? hint) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: const Icon(Icons.file_open_rounded, size: kMenuTileIconSizeTiny),
        title: Text(t.open_file),
        trailing: _hintFromLabel(context, hint),
      ),
      onTap: () async {
        showControl();
        if (isAndroid) {
          await pickContentFile();
        } else {
          await pickLocalFile();
        }
        showControl();
      },
    );
  }

  PopupMenuItem _openLinkItemWithHint(BuildContext context, t, String? hint) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: const Icon(Icons.file_present_rounded, size: kMenuTileIconSizeTiny),
        title: Text(t.open_link),
        trailing: _hintFromLabel(context, hint),
      ),
      onTap: () async {
        isDesktop ? await showOpenLinkDialog(context) : await showOpenLinkBottomSheet(context);
        showControl();
      },
    );
  }

  PopupMenuItem _jumpToTimeItemWithHint(
      BuildContext context, t, String? hint) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: const Icon(Icons.schedule_rounded, size: kMenuTileIconSizeTiny),
        title: Text(t.menu_jump_to_time),
        trailing: _hintFromLabel(context, hint),
      ),
      onTap: () => showControlForHover(showJumpToTimeDialog(context, context.read<MediaPlayer>())),
    );
  }

  PopupMenuItem _historyItemWithHint(BuildContext context, t, PopupDirection dir, String? hint) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: const Icon(Icons.history_rounded, size: kMenuTileIconSize),
        title: Text(t.history),
        trailing: _hintFromLabel(context, hint),
      ),
      onTap: () => showControlForHover(showPopup(context: context, child: const History(), direction: dir)),
    );
  }

  PopupMenuItem _settingsItemWithHint(BuildContext context, t, PopupDirection dir, String? hint) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: const Icon(Icons.settings_rounded, size: kMenuTileIconSize),
        title: Text(t.settings),
        trailing: _hintFromLabel(context, hint),
      ),
      onTap: () => showControlForHover(showPopup(context: context, child: const Settings(), direction: dir)),
    );
  }

  PopupMenuItem _subtitleItemWithHint(BuildContext context, t, PopupDirection dir, String? hint) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: const Icon(Icons.subtitles_rounded, size: kMenuTileIconSize),
        title: Text(t.subtitle_and_audio_track),
        trailing: _hintFromLabel(context, hint),
      ),
      onTap: () => showControlForHover(showPopup(
        context: context,
        child: Provider<MediaPlayer>.value(
          value: context.read<MediaPlayer>(),
          child: const SubtitleAndAudioTrack(),
        ),
        direction: dir,
      )),
    );
  }

  PopupMenuItem _exitItemWithHint(BuildContext context, t, String? hint) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: const Icon(Icons.exit_to_app_rounded, size: kMenuTileIconSize),
        title: Text(t.exit),
        trailing: _hintFromLabel(context, hint),
      ),
      onTap: () => AppExit.run(context.read<MediaPlayer>().saveProgress),
    );
  }

  PopupMenuItem _gestureTipsItem(BuildContext context, t) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: const Icon(Icons.touch_app_rounded, size: kMenuTileIconSize),
        title: Text(t.show_gesture_overlay),
      ),
      onTap: () => usePlayerUiStore().updateIsShowGestureTips(true),
    );
  }

  PopupMenuItem _unifiedSidePanelItem(
    BuildContext context,
    t,
    String title,
  ) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: const Icon(Icons.aspect_ratio_rounded, size: kMenuTileIconSize),
        title: Text(title),
        subtitle: Text(t.menu_side_panel_desc),
      ),
      onTap: () => showControlForHover(showSliderTypeDialog(context)),
    );
  }

  /// Frame-tools float panel toggle — the phone vehicle for frame stepping
  /// (per decision: not in the control bar, not a gesture action).
  PopupMenuItem _frameToolsItem(BuildContext context, t, bool active) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: const Icon(Icons.slow_motion_video_rounded,
            size: kMenuTileIconSize),
        title: Text(t.menu_frame_tools),
        trailing: active
            ? Icon(Icons.check_rounded, size: kMenuTileIconSize)
            : null,
      ),
      onTap: () {
        showControl();
        usePlaybackToolsStore().toggleFrameTools();
      },
    );
  }

  /// Direct screenshot entry sharing the float-panel shutter logic.
  PopupMenuItem _screenshotItem(BuildContext context, t) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading:
            const Icon(Icons.photo_camera_rounded, size: kMenuTileIconSize),
        title: Text(t.menu_screenshot),
      ),
      onTap: () async {
        showControl();
        // Navigator captured BEFORE the await so the feedback dialog shows
        // even after the popup menu unmounts.
        final navigator = Navigator.of(context, rootNavigator: true);
        final t = getLocalizations(context);
        final result = await runScreenshotCapture(
          navigator: navigator,
          player: context.read<MediaPlayer>(),
          savingLabel: t.shot_saving,
        );
        await showScreenshotFeedback(navigator, result);
      },
    );
  }

  /// Floating bottom-group switch button visibility (phone / desktop
  /// phone-mode). Opens the per-orientation editor dialog.
  PopupMenuItem _controlGroupItem(BuildContext context, t) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: const Icon(Icons.swap_horiz_rounded,
            size: kMenuTileIconSize),
        title: Text(t.control_group_floating_button),
        subtitle: Text(t.control_group_floating_desc),
      ),
      onTap: () => showControlForHover(showControlGroupFloatingDialog(context)),
    );
  }

  /// Entries for the optional bar slots pushed into More at the current width.
  ///
  /// Ordered by [kControlBarCollapseOrder] so the least important control
  /// appears first. Subtitles are skipped: the menu already carries an
  /// unconditional subtitle/audio-track entry, and duplicating it here would
  /// list the same action twice.
  List<PopupMenuEntry> _collapsedItems(
    BuildContext context,
    t,
    String? subtitleHint,
  ) {
    if (collapsed.isEmpty) return const <PopupMenuEntry>[];
    final AppState app = useAppStore().state;
    final bg = useBackgroundPlaybackStore().state;
    final scenario = usePlaybackScenarioStore().state;
    final bool useScenario =
        !app.useLegacyStoragePersistence && app.useScenarioDrivenPlayback;
    final bool shuffleOn = bg.bgOwnsControls
        ? bg.shuffle
        : (useScenario ? scenario.activeScenarioShuffled : app.shuffle);
    final Repeat repeat =
        useScenario ? scenario.activeScenarioRepeat : app.repeat;

    final List<PopupMenuEntry> items = <PopupMenuEntry>[];
    for (final ControlBarSlot slot in kControlBarCollapseOrder) {
      if (!collapsed.contains(slot)) continue;
      switch (slot) {
        case ControlBarSlot.storage:
          items.add(_collapsedTile(
            context,
            icon: Icons.storage_rounded,
            title: t.storage,
            onTap: () => openStorageFromControlBar(context, showControlForHover),
          ));
        case ControlBarSlot.shuffle:
          items.add(_collapsedTile(
            context,
            icon: Icons.shuffle_rounded,
            title: '${t.shuffle}: ${shuffleOn ? t.on : t.off}',
            onTap: () {
              showControl();
              // ignore: discarded_futures
              toggleShuffleFromControlBar(context);
            },
          ));
        case ControlBarSlot.repeat:
          items.add(_collapsedTile(
            context,
            icon: repeat == Repeat.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            title: repeat == Repeat.one
                ? t.repeat_one
                : repeat == Repeat.all
                    ? t.repeat_all
                    : t.repeat_none,
            onTap: () {
              showControl();
              // ignore: discarded_futures
              toggleRepeatFromControlBar();
            },
          ));
        case ControlBarSlot.playQueue:
          items.add(_collapsedTile(
            context,
            icon: Icons.playlist_play_rounded,
            title: t.play_queue,
            onTap: () {
              showControl();
              // ignore: discarded_futures
              openPlayQueueFromControlBar(
                context,
                showControlForHover: showControlForHover,
              );
            },
          ));
        case ControlBarSlot.subtitle:
          // Already present as the unconditional subtitle/audio entry below.
          break;
        case ControlBarSlot.backgroundMenu:
          items.add(_collapsedBackgroundMenuTile(context, t));
        case ControlBarSlot.stop:
          items.add(_collapsedTile(
            context,
            icon: Icons.stop_rounded,
            title: t.stop,
            onTap: () {
              showControl();
              // ignore: discarded_futures
              stopFromControlBar(context);
            },
          ));
        case ControlBarSlot.fit:
          items.add(_collapsedTile(
            context,
            icon: Icons.fit_screen_rounded,
            title: t.video_zoom,
            onTap: () {
              showControl();
              // ignore: discarded_futures
              cycleFitFromControlBar(context);
            },
          ));
        case ControlBarSlot.windowFitMode:
          items.add(_collapsedTile(
            context,
            icon: Icons.open_in_full_rounded,
            title: t.window_label,
            onTap: () {
              showControl();
              // ignore: discarded_futures
              toggleWindowFitModeFromControlBar(context);
            },
          ));
        case ControlBarSlot.rate:
          items.add(_rateItem(context, t, app.rate));
        case ControlBarSlot.playPause:
        case ControlBarSlot.prev:
        case ControlBarSlot.next:
        case ControlBarSlot.volume:
        case ControlBarSlot.fullscreen:
        case ControlBarSlot.more:
          // Core slots never collapse.
          break;
      }
    }
    return items;
  }

  PopupMenuItem _collapsedTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        leading: Icon(icon, size: kMenuTileIconSize),
        title: Text(title),
        onTap: onTap,
      ),
    );
  }

  /// The 副音 menu collapsed into More: opens the SAME entry list as the on-bar
  /// 副音 button, anchored to this row.
  PopupMenuItem _collapsedBackgroundMenuTile(BuildContext context, t) {
    return PopupMenuItem(
      child: Builder(
        builder: (itemContext) => ListTile(
          mouseCursor: SystemMouseCursors.click,
          leading: const Icon(Icons.multitrack_audio_rounded,
              size: kMenuTileIconSize),
          title: Text(t.bg_menu_tooltip),
          onTap: () {
            showControl();
            final RenderBox? box =
                itemContext.findRenderObject() as RenderBox?;
            final RenderBox? overlay =
                Overlay.of(itemContext).context.findRenderObject() as RenderBox?;
            RelativeRect position = const RelativeRect.fromLTRB(0, 0, 0, 0);
            if (box != null && box.hasSize && overlay != null) {
              final Offset topLeft =
                  box.localToGlobal(Offset.zero, ancestor: overlay);
              final Offset bottomRight = box.localToGlobal(
                  box.size.bottomRight(Offset.zero),
                  ancestor: overlay);
              position = RelativeRect.fromRect(
                Rect.fromPoints(topLeft, bottomRight),
                Offset.zero & overlay.size,
              );
            }
            // ignore: discarded_futures
            showMenu<Object>(
              context: itemContext,
              position: position,
              items: buildBackgroundPlaybackMenuEntries(
                context: itemContext,
                showControl: showControl,
              ),
            );
          },
        ),
      ),
    );
  }
}
