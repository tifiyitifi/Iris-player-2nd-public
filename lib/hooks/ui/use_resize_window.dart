import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/window/playlist_dock/resolve_playlist_dock.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/window_fit_mode.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/utils/drag_window_lock.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/utils/window_resize_guard.dart';
import 'package:iris/utils/window_transition_guard.dart';
import 'package:window_manager/window_manager.dart';
import 'package:window_size/window_size.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyUi);

Future<void> _applyResize(Rect newBounds) async {
  if (await windowManager.isFullScreen() || await windowManager.isMaximized()) {
    return;
  }
  await windowManager.setBounds(newBounds, animate: true);
}

/// Fires on every OS window resize; the hook decides whether it was a USER
/// resize (→ temporary fixedWindow for the current video) or our own
/// programmatic [setBounds] (guarded by a timed flag).
class _ManualResizeListener extends WindowListener {
  _ManualResizeListener({required this.onUserResize});
  final VoidCallback onUserResize;

  @override
  void onWindowResize() => onUserResize();
}

void useResizeWindow() {
  final context = useContext();

  final autoResize = useAppStore().select(context, (state) => state.autoResize);
  // Metadata era: WindowFitMode (窗口适应模式) replaces the legacy autoResize
  // blob knob as the window-sizing authority.
  final bool metadataOn =
      useAppStore().select(context, (s) => s.useMetadataSettings);
  final metadataGate = metadataOn && MetaSettingsModule.ready;
  final windowFitMode = useAppStore().select(context, (s) => s.windowFitMode);
  final isFullScreen =
      usePlayerUiStore().select(context, (state) => state.isFullScreen);
  final isWindowMaximized =
      usePlayerUiStore().select(context, (s) => s.isWindowMaximized);
  final aspectRatio =
      usePlayerUiStore().select(context, (state) => state.aspectRatio);
  final videoWidth = usePlayerUiStore().select(context, (s) => s.videoWidth);
  final videoHeight = usePlayerUiStore().select(context, (s) => s.videoHeight);
  // Scrub-drag window lock: any slider drag freezes window bounds so a
  // cross-segment drag never refits per segment mid-gesture; the video
  // adapts inside the fixed window instead. Release re-runs this effect
  // (dep below) and fits the landing segment once.
  final isDragging = useScrubDragStore().select(
    context,
    (s) => shouldSkipResizeDuringDrag(
      isScrubbing: s.isScrubbing,
      isHolding: s.isHolding,
    ),
  );

  // Dock-aware sizing: when dock is visible, the window width = video width + dock chrome.
  final playlistPanelMode = useAppStore().select(context, (s) => s.playlistPanelMode);
  final playlistPanelVisible = useAppStore().select(context, (s) => s.playlistPanelVisible);
  final playlistPanelWidth = useAppStore().select(context, (s) => s.playlistPanelWidth);
  final legacyStorage =
      useAppStore().select(context, (s) => s.useLegacyStoragePersistence);

  final currentPlay = usePlayQueueStore().select(context, (state) {
    final index =
        state.playQueue.indexWhere((e) => e.index == state.currentIndex);
    return index != -1 ? state.playQueue[index] : null;
  });
  final contentType = currentPlay?.file.type ?? ContentType.other;
  final fileUri = currentPlay?.file.uri;

  final prevIsFullScreen = usePrevious(isFullScreen);
  final prevAspectRatio = usePrevious(aspectRatio);

  // Manual window resize → temporary fixedWindow, valid for the CURRENT
  // video only (每次打开/切换视频重置为持久化的 WindowFitMode).
  final manualOverride = useRef(false);
  final latestFitMode = useRef(windowFitMode);
  latestFitMode.value = windowFitMode;
  final latestVideoPx = useRef<double>(0);
  latestVideoPx.value = videoWidth;

  // Reset BEFORE the main effect declares its own deps — hook order keeps
  // this effect ahead of the resize effect, so a video switch always clears
  // the temporary override before the fit decision runs. Keyed on the queue
  // entry URI too: switching between two videos of the SAME resolution must
  // still drop a manual override left over from the previous video.
  useEffect(() {
    manualOverride.value = false;
    return null;
  }, [fileUri, videoWidth, videoHeight]);

  final resizeListener = useMemoized(
      () => _ManualResizeListener(onUserResize: () {
            // Programmatic setBounds (fit / keep-in-bounds / dock expand) also
            // fires onWindowResize — the shared guard absorbs those; a local
            // timer could not see another hook's resize. Videos without known
            // dimensions never arm the override (nothing to fit anyway).
            if (!shouldArmManualOverride(
              isProgrammatic: WindowResizeGuard.instance.isApplying,
              videoWidthPx: latestVideoPx.value,
              mode: latestFitMode.value,
            )) {
              return;
            }
            manualOverride.value = true;
          }), const []);
  useEffect(() {
    if (!isDesktop) return null;
    windowManager.addListener(resizeListener);
    return () => windowManager.removeListener(resizeListener);
  }, [resizeListener]);

  useEffect(() {
    if (!isDesktop) return;

    Future<void> performResize() async {
      if (isFullScreen || isWindowMaximized) return;
      // Drag lock (all scrubbers, VM + single file): hold the window still
      // mid-drag; the landing fit happens on release via the dep change.
      if (isDragging) return;
      // A window-state transition is still settling → defer, then re-check the
      // live flags (the captured ones can be stale if the user re-entered
      // fullscreen during the wait). Without this the post-fullscreen refit
      // would race the native restore and land at the wrong size.
      for (var spins = 0;
          WindowTransitionGuard.instance.isTransitioning && spins < 20;
          spins++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final live = usePlayerUiStore().state;
      if (live.isFullScreen || live.isWindowMaximized) return;

      // ── Metadata era: WindowFitMode drives the window ──────────────────
      if (metadataGate) {
        if (contentType == ContentType.audio || aspectRatio <= 0) {
          await windowManager.setAspectRatio(0);
          return;
        }

        final bool wantsFit = windowFitMode == WindowFitMode.fitVideo &&
            !manualOverride.value;
        if (!wantsFit) {
          // Fixed window (or a manual resize this video): free user resize —
          // an aspect lock would fight the dock Row layout.
          await windowManager.setAspectRatio(0);
          return;
        }

        final screen = await getCurrentScreen();
        if (screen == null) return;
        final double scale = screen.scaleFactor;
        // Keep the visibleFrame ORIGIN: multi-monitor work areas are offset,
        // and the clamp below must use the same coordinate space as the
        // window bounds.
        final Rect workArea = Rect.fromLTWH(
          screen.visibleFrame.left / scale,
          screen.visibleFrame.top / scale,
          screen.visibleFrame.width / scale,
          screen.visibleFrame.height / scale,
        );

        // Intent-based: never gate on the current (possibly already narrow
        // portrait) width, or the fit self-locks with no chrome reserved.
        final bool dockVisible = isDockIntentVisible(
          isDesktop: isDesktop,
          mode: playlistPanelMode,
          visible: playlistPanelVisible,
          isFullScreen: isFullScreen,
          useMetadataSettings: metadataOn,
          legacyStorage: legacyStorage,
        );
        final double dockChrome = dockVisible
            ? clampPlaylistPanelWidth(playlistPanelWidth, workArea.width) +
                playlistDockChrome
            : 0.0;

        final oldBounds = await windowManager.getBounds();
        // WindowOptions.minimumSize from app_startup (window_manager 0.5.x
        // exposes no getMinimumSize getter).
        const Size minSize = Size(427, 240);
        // Fit AND clamp in one resolver: the fit must never be allowed to
        // push a near-edge window partially off-screen.
        final Rect? target = resolveWindowBounds(
          videoPx: Size(videoWidth, videoHeight),
          scaleFactor: scale,
          visibleFrame: workArea,
          dockChrome: dockChrome,
          minWindowSize: minSize,
          currentBounds: oldBounds,
        );
        if (target == null) return;
        if ((target.width - oldBounds.width).abs() < 1 &&
            (target.height - oldBounds.height).abs() < 1 &&
            (target.left - oldBounds.left).abs() < 1 &&
            (target.top - oldBounds.top).abs() < 1) {
          return; // already fits — no churn on identical videos
        }

        // The fitVideo window IS the video surface; locking the ratio would
        // fight dock grow/shrink and manual moves.
        await windowManager.setAspectRatio(0);
        // Shared guard: this resize must not be read as a user drag by the
        // listener above (or by the keep-in-bounds hook).
        await WindowResizeGuard.instance.run(() => _applyResize(target));
        return;
      }

      // ── Legacy era: the original autoResize behavior, untouched ────────
      if (!autoResize) {
        await windowManager.setAspectRatio(0);
        return;
      }

      if (contentType == ContentType.audio) {
        await windowManager.setAspectRatio(0);
        return;
      }

      if (contentType == ContentType.video) {
        if (aspectRatio <= 0) {
          await windowManager.setAspectRatio(0);
          return;
        }

        final oldBounds = await windowManager.getBounds();
        final screen = await getCurrentScreen();
        if (screen == null) return;

        // Compute dock chrome to subtract/add so video size is correct even when dock present.
        // Intent-based (no width gate): a narrow portrait window must still
        // reserve the panel, otherwise the fit self-locks dock-hidden.
        final bool dockVisibleForResize = isDockIntentVisible(
          isDesktop: isDesktop,
          mode: playlistPanelMode,
          visible: playlistPanelVisible,
          isFullScreen: isFullScreen,
          useMetadataSettings: metadataOn,
          legacyStorage: legacyStorage,
        );
        final double dockChrome = dockVisibleForResize
            ? clampPlaylistPanelWidth(
                    playlistPanelWidth,
                    screen.frame.width / screen.scaleFactor,
                  ) +
                playlistDockChrome
            : 0.0;

        // Video area is window minus dock chrome.
        final Size oldVideoSize = Size(
          (oldBounds.width - dockChrome).clamp(100.0, double.infinity),
          oldBounds.height,
        );

        if (oldVideoSize.aspectRatio.toStringAsFixed(2) ==
            aspectRatio.toStringAsFixed(2)) {
          return;
        }

        // Aspect lock applies to the WHOLE window; with the dock visible the
        // window is video-area + dock chrome, so the locked ratio must be the
        // whole-window ratio — locking the raw video ratio makes the window
        // manager fight the Row layout and letterboxes the video next to
        // the panel.
        await windowManager.setAspectRatio(
          dockChrome > 0
              ? (oldVideoSize.width + dockChrome) / oldVideoSize.height
              : aspectRatio,
        );

        Size newVideoSize;
        final bool isPreviousPortrait = (prevAspectRatio ?? 1.0) < 1.0;
        final bool isCurrentLandscape = aspectRatio >= 1.0;

        if (isPreviousPortrait && isCurrentLandscape) {
          areaKeyLog.i('Resize rule: Portrait to Landscape (Height-based)');
          double newHeight = oldVideoSize.height;
          double newWidth = newHeight * aspectRatio;
          newVideoSize = Size(newWidth, newHeight);
        } else {
          areaKeyLog.i('Resize rule: Standard (Normalized Area-based)');
          double currentArea = oldVideoSize.width * oldVideoSize.height;
          const double standardAspectRatio = 16.0 / 9.0;
          double normalizedHeight =
              math.sqrt(currentArea / standardAspectRatio);

          double newHeight = normalizedHeight;
          double newWidth = newHeight * aspectRatio;
          newVideoSize = Size(newWidth, newHeight);
        }

        // Screen caps apply to video area, not full window (window = video + dock).
        double maxVideoWidth = screen.frame.width / screen.scaleFactor * 0.95 - dockChrome;
        double maxVideoHeight = screen.frame.height / screen.scaleFactor * 0.95;
        // When video too large, cap to screen size; window becomes (maxVideo + dock) which may still equal
        // "window fullscreen size" but is NOT windowManager maximized (spec: still windowed).
        if (maxVideoWidth < 200) maxVideoWidth = 200;
        if (newVideoSize.width > maxVideoWidth) {
          newVideoSize = Size(maxVideoWidth, maxVideoWidth / aspectRatio);
        }
        if (newVideoSize.height > maxVideoHeight) {
          newVideoSize = Size(maxVideoHeight * aspectRatio, maxVideoHeight);
        }

        final Size newWindowSize = Size(newVideoSize.width + dockChrome, newVideoSize.height);

        final newPosition = Offset(
          oldBounds.left + (oldBounds.width - newWindowSize.width) / 2,
          oldBounds.top + (oldBounds.height - newWindowSize.height) / 2,
        );

        await _applyResize(Rect.fromLTWH(
            newPosition.dx, newPosition.dy, newWindowSize.width, newWindowSize.height));
      }
    }

    final wasFullScreen = prevIsFullScreen == true;
    if (wasFullScreen && !isFullScreen) {
      Future.delayed(const Duration(milliseconds: 50), performResize);
    } else {
      performResize();
    }

    return null;
  }, [
    metadataGate,
    windowFitMode,
    autoResize,
    isFullScreen,
    isWindowMaximized,
    aspectRatio,
    videoWidth,
    videoHeight,
    contentType,
    playlistPanelMode,
    playlistPanelVisible,
    playlistPanelWidth,
    legacyStorage,
    isDragging,
  ]);
}
