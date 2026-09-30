import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/app_identity/actions/app_identity_actions.dart';
import 'package:iris/features/app_identity/services/shortcut_channel_service.dart';
import 'package:iris/features/background_playback/engine/background_playback_scope.dart';
import 'package:iris/features/media_library/scan/view/scan_progress_overlay.dart';
import 'package:iris/features/scenario_playback/scan/view/scenario_source_refresh_overlay.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_actions.dart';
import 'package:iris/features/window/playlist_dock/fullscreen_playlist_dock_overlay.dart';
import 'package:iris/features/window/playlist_dock/playlist_dock_panel.dart';
import 'package:iris/features/window/playlist_dock/resolve_playlist_dock.dart';
import 'package:iris/globals.dart'
    show controlBarIsolationHeightNotifier, controlPanelKeyNotifier;
import 'package:iris/hooks/ui/use_immersive_rearm.dart';
import 'package:iris/hooks/ui/use_keep_window_in_bounds.dart';
import 'package:iris/hooks/ui/use_keyboard_state_resync.dart';
import 'package:iris/hooks/ui/use_orientation.dart';
import 'package:iris/hooks/ui/use_resize_window.dart';
import 'package:iris/hooks/ui/use_window_state.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/pages/home/player_dock_shell.dart';
import 'package:iris/pages/player/player_view.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/utils/window_resize_guard.dart';
import 'package:iris/widgets/dialogs/show_app_overview_dialog.dart';
import 'package:iris/widgets/dialogs/show_storage_password_locked_dialog.dart';
import 'package:window_manager/window_manager.dart';
import 'package:window_size/window_size.dart' show getCurrentScreen;

final _homeLog = AreaKeyLog(LogKeys.legacyMain);

class _PlaylistSplitter extends HookWidget {
  const _PlaylistSplitter({required this.clampedWidth, required this.maxWidth});
  final double clampedWidth;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final hovering = useState(false);
    return ExcludeSemantics(
      child: MouseRegion(
        onEnter: (_) => hovering.value = true,
        onExit: (_) => hovering.value = false,
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (details) {
            final double next = clampPlaylistPanelWidth(clampedWidth - details.delta.dx, maxWidth);
            useAppStore().updatePlaylistPanelWidth(next);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 6,
            color: hovering.value ? const Color(0x1AFFFFFF) : Colors.transparent,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(
                  3,
                  (_) => Container(
                    width: 2,
                    height: 2,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    decoration: BoxDecoration(
                      color: hovering.value ? Colors.white38 : Colors.white24,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class Home extends HookWidget {
  const Home({super.key});

  @override
  Widget build(BuildContext context) {
    useOrientation();
    useResizeWindow();
    useKeepWindowInBounds();
    // Re-arm player immersion once the soft keyboard closes (it force-shows the
    // system bars and Android will not restore immersion on its own).
    useImmersiveRearm();
    // Reactive 窗口全屏 (maximized) tracking — completes the three-state
    // model (窗口非全屏 / 窗口全屏 / 画面全屏).
    useWindowMaximized();
    // Drop stale pressed keys (lost KeyUp while unfocused) so the PotPlayer
    // scheme never resolves plain Z/X/C against a phantom modifier.
    useKeyboardStateResync();

    final playerBackend =
        useAppStore().select(context, (state) => state.playerBackend);

    // Startup playback routing. Order matters:
    // 1. A desktop-entry launch (Android shortcut extra) consumes the latch
    //    and plays the entry's bound configuration.
    // 2. Otherwise, when an entry currently owns the SystemPlaying workspace,
    //    restore the backed-up default state first.
    // 3. Finally the generic startup resume runs (existing contract).
    useEffect(() {
      final navigator = Navigator.of(context);
      () async {
        try {
          final routed =
              await AppIdentityActions.consumeStartupLaunch(navigator);
          if (routed == ActivationResult.notApplicable) {
            await AppIdentityActions.restoreDefaultBeforeResume();
            await ScenarioPlaybackActions.resumeScenarioPlayback();
          }
        } catch (e, s) {
          _homeLog.e('Startup routing failed: $e', e, s);
        }
      }();
      return null;
    }, []);

    // First-launch feature tour. Home mounts after BootstrapGate finishes
    // startup init, but AppStore.load() runs concurrently with that bootstrap —
    // await it so the suppression list is real before deciding (otherwise a
    // suppressed tour can spuriously reappear and block every player shortcut
    // behind its modal route). Shows once; reopenable from Settings → About.
    useEffect(() {
      final navigator = Navigator.of(context, rootNavigator: true);
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await useAppStore().initialized;
        if (!navigator.mounted) return;
        await showAppOverviewDialog(navigator.context, firstRun: true);
      });
      return null;
    }, []);

    // Storage-password decrypt failures: those entries were kept verbatim
    // (never silently degraded to local storage), so tell the user once. The
    // fix is to re-enter the password on the affected entry.
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await useStorageStore().initialized;
        if (!context.mounted) return;
        await showStoragePasswordLockedDialogIfNeeded(context);
      });
      return null;
    }, []);

    // Warm-start entry launches (shortcut tapped while the app is alive).
    useEffect(() {
      if (!AppIdentityActions.available) return null;
      final navigator = Navigator.of(context);
      final service = ShortcutChannelService()..ensureInitialized();
      final sub = service.entryLaunchStream.listen((id) {
        () async {
          try {
            // Warm launch: the app already owns a live player session, so
            // preserve its current play intent instead of forcing playback.
            await AppIdentityActions.activateEntry(navigator, id,
                coldStart: false);
          } catch (e, s) {
            _homeLog.e('Warm entry launch failed: $e', e, s);
          }
        }();
      });
      return sub.cancel;
    }, []);

    final playlistPanelMode = useAppStore().select(context, (s) => s.playlistPanelMode);
    final playlistPanelVisible = useAppStore().select(context, (s) => s.playlistPanelVisible);
    final playlistPanelWidth = useAppStore().select(context, (s) => s.playlistPanelWidth);
    final sideFullscreenBehavior = useAppStore().select(context, (s) => s.sideFullscreenBehavior);
    final fullscreenDockEdgeRevealPct =
        useAppStore().select(context, (s) => s.fullscreenDockEdgeRevealPct);
    final useMetadataSettings =
        useAppStore().select(context, (s) => s.useMetadataSettings);
    final isFullScreen = usePlayerUiStore().select(context, (s) => s.isFullScreen);
    final fsDockPeeking =
        usePlayerUiStore().select(context, (s) => s.isFullscreenDockPeeking);
    final fsDockPinned =
        usePlayerUiStore().select(context, (s) => s.isFullscreenDockPinned);
    // Control-bar isolation zone (published by `ControlsOverlay`): the summon
    // strip must not reveal the queue inside it, whether or not the bar is
    // currently shown.
    final double fsDockIsolationHeight =
        useValueListenable(controlBarIsolationHeightNotifier) ?? 0;

    // Picture-fullscreen (画面全屏) right-edge overlay — strictly its own path.
    // Window fullscreen / windowed keep the side-by-side Row dock; floating
    // popup mode is never affected.
    final bool fullscreenOverlayEnabled = isFullscreenDockOverlayEnabled(
      isDesktop: isDesktop,
      useMetadataSettings: useMetadataSettings,
      mode: playlistPanelMode,
      isFullScreen: isFullScreen,
    );

    // On entering picture fullscreen, seed the pinned state from the setting
    // (keepPanel = stay open, hidePanel = hidden but hover-summonable). Leaving
    // picture fullscreen always drops both runtime flags so the windowed dock
    // resumes its persisted `playlistPanelVisible`.
    useEffect(() {
      if (!isDesktop) return null;
      usePlayerUiStore().updateIsFullscreenDockPeeking(false);
      usePlayerUiStore().updateIsFullscreenDockPinned(
        isFullScreen &&
            isFullscreenDockPinnedOnEntry(sideFullscreenBehavior),
      );
      return null;
    }, [isFullScreen]);

    // PotPlayer parity: when dock appears in windowed (neither maximized nor
    // fullscreen) and there is spare screen space, grow the window to keep the
    // video 100% unobstructed; otherwise shift left; only when horizontally
    // fullscreen do we let the video shrink (Row will divide the width).
    final prevShowDock = usePrevious(playlistPanelVisible && playlistPanelMode == PlaylistPanelMode.dockedRight);
    useEffect(() {
      if (!isDesktop) return null;
      final bool nowDock = playlistPanelVisible && playlistPanelMode == PlaylistPanelMode.dockedRight && !isFullScreen;
      if (!nowDock || prevShowDock == true) return null;
      // Transition false -> true in windowed mode: try to expand window.
      () async {
        try {
          if (await windowManager.isFullScreen()) return;
          if (await windowManager.isMaximized()) return;
          final oldBounds = await windowManager.getBounds();
          final screen = await getCurrentScreen();
          if (screen == null) return;
          final scale = screen.scaleFactor;
          final screenFrame = screen.frame; // physical pixels
          final screenLeft = screenFrame.left / scale;
          final screenRight = screenFrame.right / scale;
          // dock chrome: hairline divider + drag splitter + clamped width.
          // clamp against current window width so we don't overgrow.
          final maxW = MediaQuery.sizeOf(context).width;
          final clamped = clampPlaylistPanelWidth(playlistPanelWidth, maxW);
          final dockChrome = clamped + playlistDockChrome;
          final needed = dockChrome;
          final rightSpace = screenRight - oldBounds.right;
          double newLeft = oldBounds.left;
          double newWidth = oldBounds.width + needed;
          // Case 1: right side enough — simply extend to the right.
          if (rightSpace >= needed) {
            // newLeft unchanged, newWidth grown.
          } else {
            // Case 2: shift left to make room, clamping at screen left.
            final shortage = needed - rightSpace;
            newLeft = (oldBounds.left - shortage).clamp(screenLeft, oldBounds.left);
            final actualLeftShift = oldBounds.left - newLeft;
            // If even shifting fully left is insufficient (horizontally fullscreen),
            // let the window grow to screen width and let Row shrink the video.
            final achievableWidth = oldBounds.width + rightSpace + actualLeftShift;
            if (achievableWidth < needed) {
              // Don't force window beyond screen; just align to screen left/right
              // so video will be proportion-shrink via Row layout.
              newLeft = screenLeft;
              newWidth = (screenRight - screenLeft);
              // But we still want to keep height, only width adapts.
              // If newWidth is already max, just don't resize via windowManager;
              // Row division handles it.
              if ((newWidth - oldBounds.width).abs() < 1) return;
            }
          }
          final newBounds = Rect.fromLTWH(newLeft, oldBounds.top, newWidth, oldBounds.height);
          await WindowResizeGuard.instance.run(
            () => windowManager.setBounds(newBounds, animate: true),
          );
        } catch (e) {
          _homeLog.w('dock window expand failed: $e');
        }
      }();
      return null;
    }, [playlistPanelMode, playlistPanelVisible, isFullScreen, playlistPanelWidth]);

    return BackgroundPlaybackScope(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth;
          final showDock = shouldShowPlaylistDock(
            isDesktop: isDesktop,
            maxWidth: maxWidth,
            mode: playlistPanelMode,
            visible: playlistPanelVisible,
            isFullScreen: isFullScreen,
            behavior: sideFullscreenBehavior,
          );

          // Stable player identity — switching dock must not recreate MediaPlayer.
          final playerView = PlayerView(key: const ValueKey('iris_player'), playerBackend: playerBackend);

          // STRUCTURAL STABILITY (flutter/flutter #177693 / #188500, the #182444
          // family): the player subtree owns GlobalKeys (`sidePanelKey`) and
          // Tooltip OverlayPortals, so its wrapper must keep ONE shape in every
          // dock state. `PlayerDockShell` does that; a dock toggle only adds or
          // removes trailing children. For the previous `Stack`/`Row` split, the
          // flip deactivated the player subtree and the new panel box re-took its
          // GlobalKey element, grafting the panel from inside a `LayoutBuilder`
          // layout callback (`_RenderLayoutBuilder was mutated in performLayout`,
          // then a poisoned element tree and a dead process).
          final Widget playerArea = Stack(
            children: <Widget>[
              playerView,
              const ScanProgressOverlayManager(),
              const ScenarioSourceRefreshOverlayManager(),
            ],
          );

          final double clampedWidth =
              clampPlaylistPanelWidth(playlistPanelWidth, maxWidth);

          // Picture-fullscreen overlay: occludes the video instead of shrinking
          // it. Visibility is the caller-owned pin OR the transient hover peek.
          final Widget? dockOverlay = fullscreenOverlayEnabled
              ? FullscreenPlaylistDockOverlay(
                  shown: fsDockPinned || fsDockPeeking,
                  pinned: fsDockPinned,
                  width: clampedWidth,
                  edgeWidth: resolveFullscreenDockEdgeWidth(
                    pct: fullscreenDockEdgeRevealPct,
                    maxWidth: maxWidth,
                  ),
                  // The control bar is excluded from the summon strip, so
                  // hovering its slider never pulls the queue over it.
                  controlPanelKey: controlPanelKeyNotifier,
                  // …and the control bar's isolation band stays reserved even
                  // while the bar is hidden, so the pointer can be moved there
                  // to operate the bar.
                  controlBarIsolationHeight: fsDockIsolationHeight,
                  onReveal: () =>
                      usePlayerUiStore().updateIsFullscreenDockPeeking(true),
                  onConceal: () =>
                      usePlayerUiStore().updateIsFullscreenDockPeeking(false),
                  child: PlaylistDockPanel(
                    onClose: () {
                      usePlayerUiStore().updateIsFullscreenDockPinned(false);
                      usePlayerUiStore().updateIsFullscreenDockPeeking(false);
                    },
                  ),
                )
              : null;

          // Row side-by-side (PotPlayer spec): video 100% in its own Expanded
          // when window space allows (window was grown above); when already
          // maximized / fullscreen-horizontally, the row divides width and the
          // video proportionally shrinks but remains fully presented, not
          // occluded. No overlay shadow, single divider line, no transparent gap.
          return PlayerDockShell(
            playerArea: playerArea,
            overlay: dockOverlay,
            dockSlots: !showDock
                ? const <Widget>[]
                : <Widget>[
                    Container(width: 1, color: const Color(0xFF333333)),
                    _PlaylistSplitter(
                      clampedWidth: clampedWidth,
                      maxWidth: maxWidth,
                    ),
                    SizedBox(
                      width: clampedWidth,
                      child: Material(
                        color: const Color(0xFF1E1E1E),
                        child: ExcludeSemantics(
                          child: PlaylistDockPanel(
                            onClose: () =>
                                useAppStore().updatePlaylistPanelVisible(false),
                          ),
                        ),
                      ),
                    ),
                  ],
          );
          },
        ),
      ),
    );
  }
}
