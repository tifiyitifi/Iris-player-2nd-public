import 'dart:ui' show Rect;

import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/models/store/player_ui_state.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/utils/window_transition_guard.dart';
import 'package:iris/utils/windows_maximize.dart';
import 'package:window_manager/window_manager.dart';

final _log = AreaKeyLog(LogKeys.legacyStore);

class PlayerUiStore extends Store<PlayerUiState> {
  PlayerUiStore() : super(const PlayerUiState());

  /// How long the transition guard stays armed after a native window-state
  /// change returns, so the maximize/unmaximize event burst the Windows plugin
  /// queues behind the method channel is still treated as programmatic.
  static const Duration _transitionSettle = Duration(milliseconds: 350);

  /// Set when entering picture fullscreen had to first restore this window from
  /// maximized (see [needsRestoreBeforeFullScreen]); exit then re-maximizes.
  bool _restoreMaximizedAfterFullScreen = false;

  void updateAspectRatio(double ratio) {
    set(state.copyWith(aspectRatio: ratio));
  }

  /// Publishes the decoded video resolution alongside [updateAspectRatio]
  /// (physical pixels; 0/0 = unknown). Consumed by the desktop window-fit.
  void updateVideoSize(double width, double height) {
    if (state.videoWidth == width && state.videoHeight == height) return;
    set(state.copyWith(videoWidth: width, videoHeight: height));
  }

  /// Reactive mirror of the OS maximized state (窗口全屏). Never persisted.
  void setWindowMaximized(bool value) {
    if (state.isWindowMaximized == value) return;
    set(state.copyWith(isWindowMaximized: value));
  }

  Future<void> toggleIsAlwaysOnTop() async {
    if (isDesktop) {
      windowManager.setAlwaysOnTop(!state.isAlwaysOnTop);
      set(state.copyWith(isAlwaysOnTop: !state.isAlwaysOnTop));
    }
  }

  Future<void> updateFullScreen(bool value) async {
    if (!isDesktop) return;
    final guard = WindowTransitionGuard.instance;
    // Busy → drop the press: two interleaved native transitions desync the
    // plugin's global fullscreen bookkeeping and can re-enter the window proc.
    if (guard.isTransitioning) return;
    await guard.run(() async {
      final bool nativeFullScreen = await windowManager.isFullScreen();
      final bool alreadyAtTarget = state.isFullScreen == value && nativeFullScreen == value;
      if (alreadyAtTarget) {
        await reconcileWindowState();
        return;
      }

      if (value && !nativeFullScreen) {
        // Windows: entering fullscreen from a maximized window hits
        // window_manager's deadlocking native branch. Restore first; exit will
        // re-maximize so the round-trip semantics survive.
        //
        // window_manager's `isMaximized()` reports `showCmd`, but the native
        // `SetFullScreen` branches on `IsZoomed()` (the WS_MAXIMIZE style) —
        // when they disagree, the old check skipped the restore and still hit
        // the broken branch. Consult BOTH, then force the restore directly
        // (bypassing the plugin's showCmd-gated `Unmaximize()`).
        final int hwnd = isWindows ? await windowManager.getId() : 0;
        final bool reportedMaximized = await windowManager.isMaximized();
        final bool zoomed = windowsIsZoomed(hwnd);
        _restoreMaximizedAfterFullScreen = needsRestoreBeforeFullScreen(
          entering: true,
          reportedMaximized: reportedMaximized,
          zoomed: zoomed,
        );
        if (_restoreMaximizedAfterFullScreen) {
          _log.i(
            'player.ui.fullscreen detour: maximize detected '
            '(reported=$reportedMaximized, zoomed=$zoomed)',
          );
          if (isWindows) {
            windowsRequestRestore(hwnd);
          } else {
            await windowManager.unmaximize();
          }
          // Restore() posts SC_RESTORE asynchronously — wait until the OS
          // really reports restored, otherwise setFullScreen re-enters the
          // broken maximized branch.
          await _awaitRestored(hwnd);
          _log.i('player.ui.fullscreen detour: restore settled, entering FS');
        }
      }

      // Write the store FIRST: on Windows the native call emits a burst of
      // maximize/unmaximize events, and the listener must already see the
      // target fullscreen flag so it does not mirror them as 窗口全屏.
      _syncIsFullScreen(value);
      if (!value) {
        // Leaving picture fullscreen: window_manager's native restore does a
        // combined move+resize, re-extends the DWM frame and re-issues
        // SWP_FRAMECHANGED, which deadlocks if it lands while the window is
        // still moving (e.g. the video surface refit right after entry). Drain
        // any motion first.
        await _awaitBoundsSettled();
      }
      await windowManager.setFullScreen(value);

      if (!value && _restoreMaximizedAfterFullScreen) {
        _restoreMaximizedAfterFullScreen = false;
        // Same hazard on the re-maximize — wait for the restore to settle.
        await _awaitBoundsSettled();
        await windowManager.maximize();
        await _awaitMaximized(true);
      }
      await reconcileWindowState();
    }, settle: _transitionSettle);
  }

  /// Polls the OS maximized state until it equals [target] (bounded ~400ms).
  Future<void> _awaitMaximized(bool target) async {
    for (var i = 0; i < 25; i++) {
      if (await windowManager.isMaximized() == target) return;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  /// Polls BOTH native truths until the window is really out of 窗口全屏,
  /// then waits for the restore animation to finish.
  ///
  /// `IsZoomed()` clears at the START of the SC_RESTORE DWM animation, while
  /// window_manager's native `SetFullScreen` deadlocks its `SWP_FRAMECHANGED`
  /// reposition if it lands mid-animation. [hwnd] is the Windows handle (0 on
  /// other desktop OSes, where the win32 probe is skipped).
  Future<void> _awaitRestored(int hwnd) async {
    for (var i = 0; i < 40; i++) {
      final bool zoomed = windowsIsZoomed(hwnd);
      if (!zoomed && !await windowManager.isMaximized()) break;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    await _awaitBoundsSettled();
  }

  /// Waits (min ~300ms, bounded ~950ms) until the window bounds stop moving,
  /// i.e. the maximize/restore animation has drained.
  Future<void> _awaitBoundsSettled() async {
    final started = DateTime.now();
    Rect? prev;
    var stable = 0;
    for (var i = 0; i < 60; i++) {
      final Rect bounds = await windowManager.getBounds();
      final bool unchanged = prev != null &&
          (bounds.left - prev.left).abs() < 1 &&
          (bounds.top - prev.top).abs() < 1 &&
          (bounds.width - prev.width).abs() < 1 &&
          (bounds.height - prev.height).abs() < 1;
      if (unchanged &&
          _minRestoreSettle <= DateTime.now().difference(started)) {
        stable++;
        if (stable >= 3) return;
      } else {
        stable = 0;
      }
      prev = bounds;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  static const Duration _minRestoreSettle = Duration(milliseconds: 300);

  Future<void> toggleFullScreen() async {
    await updateFullScreen(!state.isFullScreen);
  }

  /// Toggles 窗口全屏 (OS maximize). Single owner for every maximize entry
  /// point (title bar, control bar, drag-area double-click) so a transition
  /// can never interleave with picture-fullscreen.
  Future<void> toggleWindowMaximize() async {
    if (!isDesktop) return;
    final guard = WindowTransitionGuard.instance;
    if (guard.isTransitioning) return;
    await guard.run(() async {
      // The maximize button is hidden in picture fullscreen; guard against a
      // stale gesture/route still reaching here.
      if (state.isFullScreen) return;
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
      await reconcileWindowState();
    }, settle: _transitionSettle);
  }

  /// Pulls the two window flags back from OS truth. Windows picture-fullscreen
  /// reports `isMaximized() == true` (it borrows the maximize machinery), so
  /// [reconcileWindowFlags] masks that off 窗口全屏.
  Future<void> reconcileWindowState() async {
    if (!isDesktop) return;
    final flags = reconcileWindowFlags(
      nativeFullScreen: await windowManager.isFullScreen(),
      nativeMaximized: await windowManager.isMaximized(),
    );
    set(state.copyWith(
      isFullScreen: flags.isFullScreen,
      isWindowMaximized: flags.isWindowMaximized,
    ));
  }

  void _syncIsFullScreen(bool value) {
    if (state.isFullScreen == value) return;
    set(state.copyWith(isFullScreen: value));
  }

  void updatePendingCompleted(bool bool) {
    set(state.copyWith(pendingCompleted: bool));
  }

  void updateIsHovering(bool bool) {
    if (state.isHovering == bool) return;
    set(state.copyWith(isHovering: bool));
  }

  void updateIsPanelClickArmed(bool bool) {
    if (state.isPanelClickArmed == bool) return;
    set(state.copyWith(isPanelClickArmed: bool));
  }

  /// Marks whether the current visible state came from a passive hover
  /// (`showTitleOnly`) rather than an explicit show. See
  /// [PlayerUiState.isHoverReveal].
  void updateIsHoverReveal(bool bool) {
    if (state.isHoverReveal == bool) return;
    set(state.copyWith(isHoverReveal: bool));
  }

  void updateIsShowControl(bool bool) {
    if (state.isShowControl == bool) return;
    set(state.copyWith(isShowControl: bool));
  }

  void updateIsShowProgress(bool bool) {
    if (state.isShowProgress == bool) return;
    set(state.copyWith(isShowProgress: bool));
  }

  void updateIsShowGestureTips(bool bool) {
    set(state.copyWith(isShowGestureTips: bool));
  }

  /// Runtime-only guide page memory; see [PlayerUiState.gestureGuidePage].
  void updateGestureGuidePage(int page) {
    if (state.gestureGuidePage == page) return;
    set(state.copyWith(gestureGuidePage: page));
  }

  void updateIsTransientSpeedActive(bool bool) {
    set(state.copyWith(isTransientSpeedActive: bool));
  }

  /// True while the picture-fullscreen queue overlay is on screen.
  bool get isFullscreenDockShown =>
      state.isFullscreenDockPinned || state.isFullscreenDockPeeking;

  /// Reveals the picture-fullscreen queue overlay.
  ///
  /// The overlay is TRANSIENT: this only makes it visible now. Leaving the
  /// panel, clicking the picture, `Esc`, the header X and the queue key hide it
  /// again, so there is no sticky "pinned" mode to get stuck in. One write for
  /// both flags keeps the caller from publishing a middle state (pinned left on
  /// while peeking cleared, which would look like "cannot be dismissed").
  void showFullscreenDock() {
    if (state.isFullscreenDockPeeking && !state.isFullscreenDockPinned) return;
    set(state.copyWith(
      isFullscreenDockPeeking: true,
      isFullscreenDockPinned: false,
    ));
  }

  /// Seeds the overlay state when picture fullscreen is entered or left.
  ///
  /// [reveal] is the `SideFullscreenBehavior.keepPanel` choice (start open);
  /// `false` starts hidden but hover-summonable. Only an INITIAL state: the
  /// overlay still auto-conceals afterwards.
  void seedFullscreenDockOnEntry(bool reveal) {
    if (!state.isFullscreenDockPeeking &&
        state.isFullscreenDockPinned == reveal) {
      return;
    }
    set(state.copyWith(
      isFullscreenDockPeeking: false,
      isFullscreenDockPinned: reveal,
    ));
  }

  /// Conceals the picture-fullscreen queue overlay (hover-out, picture click,
  /// `Esc`, the header X).
  void hideFullscreenDock() {
    if (!state.isFullscreenDockPeeking && !state.isFullscreenDockPinned) return;
    set(state.copyWith(
      isFullscreenDockPeeking: false,
      isFullscreenDockPinned: false,
    ));
  }
}

PlayerUiStore usePlayerUiStore() => create(() => PlayerUiStore());
