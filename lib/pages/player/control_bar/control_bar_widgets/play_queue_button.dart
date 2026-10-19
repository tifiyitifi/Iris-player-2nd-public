import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/background_playback_gate.dart';
import 'package:iris/features/background_playback/model/enum/control_target.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/background_queue_panel.dart';
import 'package:iris/features/scenario_playback/view/coordinator/scenario_browser.dart';
import 'package:iris/features/window/playlist_dock/resolve_playlist_dock.dart';
import 'package:iris/features/windows/desktop_keyboard/view/shortcut_hints.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/control_bar_constants.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/a11y_tooltip.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/popup.dart';
import 'package:iris/widgets/popups/play_queue.dart';

/// Opens the play-queue surface from the control bar (button OR the More-menu
/// fallback when the button is collapsed). Single authority for the docking /
/// 副音-queue / legacy / scenario routing so both entry points stay identical.
Future<void> openPlayQueueFromControlBar(
  BuildContext context, {
  required Future<void> Function(Future<void>) showControlForHover,
}) async {
  final AppState app = useAppStore().state;
  final bool useMetadataSettings = app.useMetadataSettings;
  final PlaylistPanelMode playlistPanelMode = app.playlistPanelMode;
  final bool isFullScreen = usePlayerUiStore().state.isFullScreen;

  bool shouldDockToggle() {
    if (!isDesktop) return false;
    if (!useMetadataSettings) return false;
    // The desktop dock is a meta-era feature; the legacy-storage backend has no
    // side panel, so P / the button must fall through to the popup.
    if (app.useLegacyStoragePersistence) return false;
    if (playlistPanelMode != PlaylistPanelMode.dockedRight) return false;
    return true;
  }

  if (shouldDockToggle()) {
    if (isFullscreenDockOverlayEnabled(
      isDesktop: isDesktop,
      useMetadataSettings: useMetadataSettings,
      mode: playlistPanelMode,
      isFullScreen: isFullScreen,
      legacyStorage: app.useLegacyStoragePersistence,
    )) {
      final bool pinned = usePlayerUiStore().state.isFullscreenDockPinned;
      usePlayerUiStore().updateIsFullscreenDockPeeking(false);
      usePlayerUiStore().updateIsFullscreenDockPinned(!pinned);
      return;
    }
    useAppStore().togglePlaylistPanelVisible();
    return;
  }

  final bg = useBackgroundPlaybackStore();
  final bool bgEnabled = bg.state.enabled &&
      bg.state.controlTarget == ControlTarget.background;
  if (BackgroundPlaybackGate.enabled && bgEnabled) {
    await showControlForHover(
      showPopup(
        context: context,
        child: const BackgroundQueuePanel(),
        direction: app.defaultPopupDirection,
      ),
    );
    return;
  }
  if (app.useLegacyStoragePersistence) {
    await showControlForHover(
      showPopup(
        context: context,
        child: const PlayQueue(),
        direction: app.defaultPopupDirection,
      ),
    );
  } else {
    // The paged queue is retired; the meta-era queue surface is the scenario
    // browser.
    showScenarioBrowser(context, direction: app.defaultPopupDirection);
  }
}

class PlayQueueButton extends HookWidget {
  const PlayQueueButton({
    super.key,
    required this.showControlForHover,
    this.color,
    this.overlayColor,
  });

  final Future<void> Function(Future<void>) showControlForHover;
  final Color? color;
  final WidgetStateProperty<Color?>? overlayColor;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final scheme = useEffectiveKeyboardScheme(context);
    final playlistPanelMode = useAppStore().select(context, (s) => s.playlistPanelMode);

    final bool isDockMode = playlistPanelMode == PlaylistPanelMode.dockedRight;
    final String hintForMode = isDockMode
        ? t.dock_mode_docked
        : t.dock_mode_floating;
    return a11yTooltipIconButton(
      context: context,
      tooltip: '${t.play_queue} ( ${shortcutHintLabelFor(ShortcutHintKind.playQueue, scheme)} ) — $hintForMode',
      icon: Icon(
        Icons.playlist_play_rounded,
        size: kPlayQueueIconSize,
        color: color,
      ),
      onPressed: () {
        // ignore: discarded_futures
        openPlayQueueFromControlBar(context, showControlForHover: showControlForHover);
      },
      style: ButtonStyle(overlayColor: overlayColor),
    );
  }
}
