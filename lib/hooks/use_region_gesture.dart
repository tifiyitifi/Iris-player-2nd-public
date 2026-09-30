import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:iris/features/speed/model/enum/speed_gesture_mode.dart';
import 'package:iris/features/speed/model/speed_gesture_math.dart';
import 'package:iris/features/speed/model/speed_gesture_resolver.dart';
import 'package:iris/globals.dart' show speedStops;
import 'package:iris/features/tag_play/commands/tag_play_actions.dart';
import 'package:iris/hooks/use_brightness.dart';
import 'package:iris/hooks/use_gesture.dart';
import 'package:iris/hooks/use_volume.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/resolve_keyboard_scheme.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/gesture_region.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/pages/player/overlays/gesture_region_editor/gesture_editor_models.dart'
    show TapHitKind, resolveTapHit;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/utils/live_seek_throttle.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyGesture);

class GestureExecContext {
  /// BuildContext is required to re-resolve MediaPlayer
  /// because MediaPlayer identity is NOT stable across
  /// Android cloned / secondary user environments.
  final BuildContext context;

  MediaPlayer get player => context.read<MediaPlayer>();

  final AppStore app;
  final PlayerUiStore ui;
  final GestureRuntimeState state;

  GestureExecContext({
    required this.context,
    required this.app,
    required this.ui,
    required this.state,
  });
}

class GestureRuntimeState {
  bool isTouch = false;
  bool isDragging = false;
  bool isLongPress = false;
  bool isTransientSelector = false;

  Axis? panDirection;

  Offset? startNormalizedPos;
  Offset startPanOffset = Offset.zero;
  Offset? lastTapDownPos;

  Duration startSeekPosition = Duration.zero;
  int initialSpeedIndex = 0;
  Axis? speedLiveAxis;
  int startSeekStepSeconds = 0;
  double speedDy = 0.0;

  void resetPan() {
    isDragging = false;
    panDirection = null;
    startNormalizedPos = null;
  }

  void resetAll() {
    isTouch = false;
    isLongPress = false;
    isTransientSelector = false;
    speedLiveAxis = null;
    speedDy = 0.0;
    resetPan();
  }
}

typedef GestureExecutor = void Function(
  GestureAction action,
  Offset globalPos,
  Offset totalDelta,
  Offset frameDelta,
  GestureExecContext ctx,
);

enum ValueGestureAdjustMode {
  none,
  brightness,
  volume,
  seekStep,
}

Gesture useRegionGesture({
  required Map<GestureIntent, GestureLayout> layouts,
  required void Function() showControl,
  required void Function() hideControl,
  required void Function() showProgress,
  required void Function(Offset position) showSpeedSelector,
  required void Function(Offset position) showTransientSpeedSelector,
  required void Function(double finalSpeed) hideSpeedSelector,
  required void Function(double speed, double visualOffset) updateSelectedSpeed,
  void Function()? showTitleOnly,
  void Function(double speed, double dx, double dy)? updateDualAxisSpeed,
}) {
  final context = useContext();

  //useAppStore()/usePlayerUiStore() is a hook
  // Hooks must not be called imperatively inside callbacks
  final appStore = useAppStore();
  final uiStore = usePlayerUiStore();

  /// ─────────────────────────────────────────────
  /// Gesture runtime state (NOT persisted)
  /// ─────────────────────────────────────────────
  final gestureState = useRef(GestureRuntimeState());

  // Live pan-seek throttle + the newest target: an unthrottled per-update seek
  // floods the backend, and the release must still commit the exact final
  // position (the last tick can be dropped).
  final panSeekThrottle = useRef(LiveSeekThrottle());
  final pendingPanSeekMs = useRef<int?>(null);

  final valueAdjustMode = useState(ValueGestureAdjustMode.none);

  final brightness = useBrightness(valueAdjustMode.value == ValueGestureAdjustMode.brightness);
  final volume = useVolume(valueAdjustMode.value == ValueGestureAdjustMode.volume);
  final liveSeekStep = useState<int?>(null);

  // 1) Prevents unnecessary rebuilds / hook updates
  // 2) Centralizes meaning
  // A Philosophy of Software Design:
  // Make the module deeper by hiding policy behind a small interface.
  void setValueAdjustMode(ValueGestureAdjustMode mode) {
    if (valueAdjustMode.value != mode) {
      valueAdjustMode.value = mode;
    }
  }

  /// ─────────────────────────────────────────────
  /// Helpers
  /// ─────────────────────────────────────────────
  Offset normalized(Offset global) {
    final size = MediaQuery.sizeOf(context);
    return Offset(global.dx / size.width, global.dy / size.height);
  }

  double closestSpeedMatch(double rate) {
    return speedStops.reduce(
      (a, b) => (a - rate).abs() < (b - rate).abs() ? a : b,
    );
  }

  GestureIntent intentForPan(Axis axis, bool isLongPress) {
    if (isLongPress) {
      return axis == Axis.horizontal ? GestureIntent.longPressPanHorizontal : GestureIntent.longPressPanVertical;
    }
    return axis == Axis.horizontal ? GestureIntent.panHorizontal : GestureIntent.panVertical;
  }

  /// ─────────────────────────────────────────────
  /// Execution context holds shared mutable gesture state.
  ///
  /// This is intentional: gesture lifecycle is temporal.
  /// ─────────────────────────────────────────────
  final execCtx = GestureExecContext(
    context: context,
    app: appStore,
    ui: uiStore,
    state: gestureState.value,
  );

  /// ─────────────────────────────────────────────
  /// Action executors (deep logic lives here)
  /// ─────────────────────────────────────────────
  final Map<GestureActionType, GestureExecutor> executors = {
    GestureActionType.toggleControls: (_, __, ___, ____, ctx) {
      final bool rc = shouldRequireClickToShowPanel(ctx.app.state);
      final ui = ctx.ui.state;
      if (!ui.isShowControl) {
        if (rc) ctx.ui.updateIsPanelClickArmed(true);
        showControl();
      } else if (rc && !ui.isPanelClickArmed) {
        ctx.ui.updateIsPanelClickArmed(true);
        showControl();
      } else {
        hideControl();
      }
    },
    GestureActionType.playPause: (_, __, ___, ____, ctx) {
      if (ctx.player.isPlaying) {
        ctx.app.updateAutoPlay(false);
        ctx.player.pause();
        if (ctx.app.state.showControlsOnPlayToPause) {
          showControl();
        }
      } else {
        ctx.app.updateAutoPlay(true);
        ctx.player.play();
      }
    },
    GestureActionType.seekForward: (a, __, ___, ____, ctx) {
      showProgress();
      final step = ctx.app.state.seekStepSeconds;
      ctx.player.forward(step);
    },
    GestureActionType.seekBackward: (a, __, ___, ____, ctx) {
      showProgress();
      final step = ctx.app.state.seekStepSeconds;
      ctx.player.backward(step);
    },
    GestureActionType.seekTo: (_, __, total, ___, ctx) {
      final axis = ctx.state.panDirection;
      if (axis == null) return;

      if (!useScrubDragStore().state.isScrubbing) {
        useScrubDragStore().beginSeek(ScrubOwners.regionGesture);
      }
      // 每水平滑动3像素代表1秒，暂时，竖向2像素代表1秒(未实现)；
      final sensitivity = axis == Axis.horizontal ? 3.0 : 2.0;
      final offsetSeconds = (total.dx / sensitivity).round();
      final startSeconds = ctx.state.startSeekPosition.inSeconds;

      // 边界检查
      final targetSeconds = (startSeconds + offsetSeconds).clamp(0, ctx.player.duration.inSeconds);

      // Throttled live seek (one per 120ms); the exact final target is
      // committed on release in `_resetPanState`.
      pendingPanSeekMs.value = targetSeconds * 1000;
      if (panSeekThrottle.value.allow(DateTime.now())) {
        ctx.player.seek(Duration(seconds: targetSeconds));
      }
      showProgress();
    },
    GestureActionType.adjustSeekStep: (_, __, total, ___, ctx) {
      setValueAdjustMode(ValueGestureAdjustMode.seekStep);

      final base = ctx.state.startSeekStepSeconds;

      const double seekStepSensitivity = 10.0;
      final delta = (-total.dy / seekStepSensitivity).round();

      final next = (base + delta).clamp(1, 120);

      if (next != ctx.app.state.seekStepSeconds) {
        liveSeekStep.value = next; //  immediate UI feedback
        ctx.app.updateSeekStepSeconds(next); //  persisted
      }
    },
    GestureActionType.adjustBrightness: (_, __, ___, frame, ctx) {
      setValueAdjustMode(ValueGestureAdjustMode.brightness);

      if (brightness.value == null) return;
      brightness.value = (brightness.value! - frame.dy / 200).clamp(0.0, 1.0);
    },
    GestureActionType.adjustVolume: (_, __, ___, frame, ctx) {
      setValueAdjustMode(ValueGestureAdjustMode.volume);

      FlutterVolumeController.updateShowSystemUI(false);
      if (volume.value == null) return;
      volume.value = (volume.value! - frame.dy / 200).clamp(0.0, 1.0);
    },
    GestureActionType.activateTransientSpeed: (_, __, ___, ____, ctx) {
      final baseRate = ctx.app.state.rate;
      final transient = ctx.app.state.transientRate;

      final closest = closestSpeedMatch(transient);
      ctx.state.initialSpeedIndex = speedStops.indexOf(closest);

      gestureState.value.isTransientSelector = false;

      ctx.app.updatePlaybackRateBeforeTransient(baseRate);
      ctx.ui.updateIsTransientSpeedActive(true);
      ctx.app.updateRate(transient);
    },
    GestureActionType.updateTransientSpeed: (_, pos, total, ___, ctx) {
      final mode = resolveSpeedGestureMode(
        ctx.app.state,
        metadataEnabled:
            ctx.app.state.useMetadataSettings && MetaSettingsModule.ready,
      );
      final bool selectorVisible = ctx.ui.state.isTransientSpeedActive;
      final Axis? liveAxis =
          resolveSpeedLockedAxis(total, previous: ctx.state.speedLiveAxis);
      if (liveAxis != null) ctx.state.speedLiveAxis = liveAxis;
      final int prevIndex =
          speedStops.indexOf(ctx.app.state.transientRate);
      final int index = resolveDualAxisSpeedIndex(
        baseIndex: ctx.state.initialSpeedIndex,
        total: total,
        mode: mode,
        isSelectorVisible: selectorVisible,
        previousAxis: ctx.state.speedLiveAxis,
      );
      final speed = speedStops[index];
      ctx.state.speedDy = total.dy;
      if (index != prevIndex) HapticFeedback.selectionClick();
      if (mode == SpeedGestureMode.dualAxis && updateDualAxisSpeed != null) {
        updateDualAxisSpeed(speed, total.dx, total.dy);
      } else {
        updateSelectedSpeed(speed, total.dx);
      }
      if (!ctx.state.isTransientSelector &&
          selectorVisible &&
          shouldOpenTransientSpeedWindow(
            total: total,
            lockedAxis: ctx.state.speedLiveAxis,
          )) {
        ctx.state.isTransientSelector = true;
        showTransientSpeedSelector(pos);
      }

      if (ctx.app.state.transientRate != speed) {
        ctx.app.updateTransientRate(speed);
      }
    },
    GestureActionType.deactivateTransientSpeed: (_, __, ___, ____, ctx) {
      ctx.app.updateRate(
        ctx.app.state.playbackRateBeforeTransient,
      );
      ctx.ui.updateIsTransientSpeedActive(false);
    },
    GestureActionType.showPlaybackRateSelector: (_, pos, ___, ____, ctx) {
      final current = ctx.app.state.rate;
      final closest = closestSpeedMatch(current);
      ctx.state.initialSpeedIndex = speedStops.indexOf(closest);
      showSpeedSelector(pos);
    },
    GestureActionType.updatePlaybackRateFromSelector: (_, __, total, ___, ctx) {
      final mode = resolveSpeedGestureMode(
        ctx.app.state,
        metadataEnabled:
            ctx.app.state.useMetadataSettings && MetaSettingsModule.ready,
      );
      final Axis? liveAxis =
          resolveSpeedLockedAxis(total, previous: ctx.state.speedLiveAxis);
      if (liveAxis != null) ctx.state.speedLiveAxis = liveAxis;
      final int prevIndex = speedStops.indexOf(ctx.app.state.rate);
      final int index = resolveDualAxisSpeedIndex(
        baseIndex: ctx.state.initialSpeedIndex,
        total: total,
        mode: mode,
        isSelectorVisible: true,
        previousAxis: ctx.state.speedLiveAxis,
      );
      final speed = speedStops[index];
      if (index != prevIndex) HapticFeedback.selectionClick();
      ctx.state.speedDy = total.dy;
      if (mode == SpeedGestureMode.dualAxis && updateDualAxisSpeed != null) {
        updateDualAxisSpeed(speed, total.dx, total.dy);
      } else {
        updateSelectedSpeed(speed, total.dx);
      }

      if (ctx.app.state.rate != speed) {
        ctx.app.updateRate(speed);
      }
    },
    GestureActionType.openTagPlaySheet: (_, __, ___, ____, ctx) {
      openTagPlaySheet(ctx.context);
    },
  };

  /// ─────────────────────────────────────────────
  /// Dispatch
  /// ─────────────────────────────────────────────
  void dispatch(
    GestureIntent intent,
    Offset global,
    Offset total,
    Offset frame,
  ) {
    final normalizedPos = gestureState.value.startNormalizedPos ?? normalized(global);

    final action = resolveAction(
      intent: intent,
      normalizedPos: normalizedPos,
      layouts: layouts,
    );
    // guard against GestureActionType.none
    if (action.type == GestureActionType.none) return;

    final exec = executors[action.type];
    if (exec != null) {
      exec(action, global, total, frame, execCtx);
    }
  }

  /// ─────────────────────────────────────────────
  /// Gesture callbacks
  /// ─────────────────────────────────────────────
  void onTapDown(TapDownDetails details) {
    if (details.kind == PointerDeviceKind.touch) {
      gestureState.value.isTouch = true;
      gestureState.value.lastTapDownPos = details.globalPosition;
    }
    // gestureState.value.isTouch = details.kind == PointerDeviceKind.touch;
  }

  void onTap() {
    final pos = gestureState.value.lastTapDownPos;
    if (pos == null) return;
    final ui = uiStore.state;
    // Explicit `none` dead zone (single-hand): while the control panel is
    // hidden, swallow the tap so rapid double-tap seeking never flashes the
    // panel/dial ring. When the panel is already visible, fall through to the
    // legacy show/hide path unchanged.
    final hit = resolveTapHit(
      layouts[GestureIntent.tap],
      normalized(pos),
    );
    if (hit == TapHitKind.none && !ui.isShowControl) {
      gestureState.value.lastTapDownPos = null;
      return;
    }
    final action = resolveAction(
      intent: GestureIntent.tap,
      normalizedPos: normalized(pos),
      layouts: layouts,
    );
    if (action.type == GestureActionType.none) {
      // No region action -> fallback to panel click gate (任意处点击同显).
      // `outside` taps and `none` taps while the panel is shown land here.
      final bool rc = shouldRequireClickToShowPanel(appStore.state);
      if (!ui.isShowControl) {
        if (rc) uiStore.updateIsPanelClickArmed(true);
        showControl();
      } else if (rc && !ui.isPanelClickArmed) {
        uiStore.updateIsPanelClickArmed(true);
        showControl();
      } else if (ui.isShowControl) {
        // When already fully shown, a tap with no action should hide (keep toggle feel)
        hideControl();
      }
      gestureState.value.lastTapDownPos = null;
      return;
    }
    dispatch(
      GestureIntent.tap,
      pos,
      Offset.zero,
      Offset.zero,
    );
    gestureState.value.lastTapDownPos = null;
  }

  // NOTE:
  // Known limitation: the double-tap action is dispatched from
  // onDoubleTapDown — on the second press-down — while Flutter has not yet
  // confirmed the double tap (it may still be cancelled afterwards). A second
  // press that is then cancelled (dragged away / preempted) still fires one
  // action once, and it cannot be undone.
  // Accepted as a known limitation; no fix planned.
  void onDoubleTapDown(TapDownDetails details) {
    // Cancel pending tap
    gestureState.value.lastTapDownPos = null;

    if (details.kind == PointerDeviceKind.touch) {
      dispatch(
        GestureIntent.doubleTap,
        details.globalPosition,
        Offset.zero,
        Offset.zero,
      );
    } else if (isDesktop) {
      // Desktop: dispatch-FIRST — a region action under the pointer wins
      // (e.g. tag_play's openTags strip); only when NO region action exists
      // does the fallback apply. Legacy fallback = fullscreen toggle, PotPlayer
      // fallback = play/pause (spec: mouse double-click in potplayer scheme is
      // playPause, not window/fullscreen toggle).
      final pos = details.globalPosition;
      final action = resolveAction(
        intent: GestureIntent.doubleTap,
        normalizedPos: normalized(pos),
        layouts: layouts,
      );
      if (action.type == GestureActionType.none) {
        final scheme = resolveKeyboardScheme(
          stored: appStore.state.keyboardShortcutScheme,
          metadataEnabled: appStore.state.useMetadataSettings && MetaSettingsModule.ready,
        );
        if (scheme == KeyboardShortcutScheme.potplayer) {
          final player = context.read<MediaPlayer>();
          if (player.isPlaying) {
            appStore.updateAutoPlay(false);
            player.pause();
          } else {
            appStore.updateAutoPlay(true);
            player.play();
          }
        } else {
          uiStore.updateFullScreen(!uiStore.state.isFullScreen);
        }
      } else {
        dispatch(
          GestureIntent.doubleTap,
          pos,
          Offset.zero,
          Offset.zero,
        );
      }
    }
  }

  void onLongPressStart(LongPressStartDetails details) {
    gestureState.value.lastTapDownPos = null;

    if (context.read<MediaPlayer>().isPlaying) {
      gestureState.value.isTouch = true; // assert, don’t check
      gestureState.value.isLongPress = true;
      gestureState.value.startPanOffset = details.globalPosition;
      gestureState.value.startNormalizedPos = normalized(details.globalPosition);

      dispatch(
        GestureIntent.longPress,
        details.globalPosition,
        Offset.zero,
        Offset.zero,
      );
    }
  }

  void onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!(gestureState.value.isLongPress)) return;

    final start = gestureState.value.startPanOffset;
    final total = details.globalPosition - start;

    final mode = resolveSpeedGestureMode(
      appStore.state,
      metadataEnabled:
          appStore.state.useMetadataSettings && MetaSettingsModule.ready,
    );
    final bool inSpeedSession = uiStore.state.isTransientSpeedActive ||
        gestureState.value.isTransientSelector;
    if (mode == SpeedGestureMode.dualAxis && inSpeedSession) {
      final Axis? liveAxis = resolveSpeedLockedAxis(
        total,
        previous: gestureState.value.speedLiveAxis,
      );
      if (liveAxis != null) gestureState.value.speedLiveAxis = liveAxis;
      dispatch(
        liveAxis != Axis.vertical
            ? GestureIntent.longPressPanHorizontal
            : GestureIntent.longPressPanVertical,
        details.globalPosition,
        total,
        details.offsetFromOrigin,
      );
      return;
    }
    final axis = total.dx.abs() > total.dy.abs() ? Axis.horizontal : Axis.vertical;
    dispatch(
      intentForPan(axis, true),
      details.globalPosition,
      total,
      details.offsetFromOrigin,
    );
  }

  void onLongPressEnd(_) {
    if (gestureState.value.isLongPress) {
      if (gestureState.value.isTransientSelector) {
        hideSpeedSelector(appStore.state.transientRate);
      } else {
        hideSpeedSelector(appStore.state.rate);
      }
      //only revert transient speed if it was actually activated during this gesture
      if (execCtx.ui.state.isTransientSpeedActive) {
        executors[GestureActionType.deactivateTransientSpeed]!(
          GestureAction(type: GestureActionType.deactivateTransientSpeed),
          Offset.zero,
          Offset.zero,
          Offset.zero,
          execCtx,
        );
      }
    }
    gestureState.value.resetAll();
  }

  void onLongPressCancel() => onLongPressEnd(null);

  void onPanStart(DragStartDetails details) {
    if (isDesktop && details.kind != PointerDeviceKind.touch) {
      windowManager.startDragging();
      return;
    }

    if (gestureState.value.isLongPress) {
      return;
    }

    if (details.kind == PointerDeviceKind.touch) {
      const double edgeDeadZone = 48.0;
      final screenSize = MediaQuery.sizeOf(context);
      final startDx = details.globalPosition.dx;

      if (startDx < edgeDeadZone || startDx > screenSize.width - edgeDeadZone) {
        areaKeyLog.i("Edge swipe detected. Ignoring for system navigation.");
        return;
      }

      gestureState.value
        ..isTouch = true
        ..isDragging = true
        ..startPanOffset = details.globalPosition
        // IMPORTANT:
        // MediaPlayer instance may be recreated in Android cloned / secondary systems.
        // Do NOT capture it across frames; always re-resolve at execution time.
        ..startSeekPosition = context.read<MediaPlayer>().position
        ..panDirection = null
        ..startNormalizedPos = normalized(details.globalPosition)
        ..startSeekStepSeconds = appStore.state.seekStepSeconds;

      panSeekThrottle.value.reset();
      pendingPanSeekMs.value = null;

      setValueAdjustMode(ValueGestureAdjustMode.none);

//      gestureState.value.startSeekPosition = context.read<MediaPlayer>().position;
    }
  }

  void onPanUpdate(DragUpdateDetails details) {
    if (!(gestureState.value.isDragging)) return;

    final start = gestureState.value.startPanOffset;
    final total = details.globalPosition - start;

    final totalDx = total.dx;
    final totalDy = total.dy;

    // 增加手势“死区”，防止误触
    const double panDeadZone = 8.0;
    if (gestureState.value.panDirection == null) {
      if (totalDx.abs() > panDeadZone || totalDy.abs() > panDeadZone) {
        gestureState.value.panDirection ??= total.dx.abs() > total.dy.abs() ? Axis.horizontal : Axis.vertical;
      }
    }

    final axis = gestureState.value.panDirection;
    if (axis == null) return;

    final GestureIntent intent = intentForPan(
      gestureState.value.panDirection!,
      gestureState.value.isLongPress,
    );

    dispatch(intent, details.globalPosition, total, details.delta);
  }

  // ignore: no_leading_underscores_for_local_identifiers
  void _resetPanState() {
    useScrubDragStore().endSeek(ScrubOwners.regionGesture);

    // Commit the exact final drag target (live ticks are throttled and the last
    // one can be dropped). VM cross-segment targets keep the hooks' stashed
    // release-commit path instead — committing here too would double-fire the
    // segment jump.
    final int? pending = pendingPanSeekMs.value;
    pendingPanSeekMs.value = null;
    panSeekThrottle.value.reset();
    if (pending != null && !VirtualMediaController.instance.isActive) {
      execCtx.player.seek(Duration(milliseconds: pending));
    }

    gestureState.value.resetPan();

    setValueAdjustMode(ValueGestureAdjustMode.none);

    FlutterVolumeController.updateShowSystemUI(true);
  }

  void onPanEnd(DragEndDetails details) => _resetPanState();
  void onPanCancel() => _resetPanState();

  void onHover(PointerHoverEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      final bool rc = shouldRequireClickToShowPanel(appStore.state);
      final bool armed = uiStore.state.isPanelClickArmed;
      final bool seeking = useScrubDragStore().state.isScrubbing;
      final bool holding = useScrubDragStore().state.isHolding;
      final bool hiddenForRc = rc && !seeking && !holding && !armed;
      if (hiddenForRc) {
        if (showTitleOnly != null) {
          showTitleOnly!.call();
        } else {
          uiStore.updateIsShowControl(true);
          uiStore.updateIsHovering(true);
          showControl();
        }
      } else {
        uiStore.updateIsHovering(true);
        showControl();
      }
    }
  }

  /// ─────────────────────────────────────────────
  /// Return Gesture
  /// ─────────────────────────────────────────────
  return Gesture(
    onTapDown: onTapDown,
    onTap: onTap,
    onDoubleTapDown: onDoubleTapDown,
    onLongPressStart: onLongPressStart,
    onLongPressMoveUpdate: onLongPressMoveUpdate,
    onLongPressEnd: onLongPressEnd,
    onPanStart: onPanStart,
    onPanUpdate: onPanUpdate,
    onPanEnd: onPanEnd,
    onPanCancel: onPanCancel,
    onHover: onHover,
    isLongPress: gestureState.value.isLongPress,
    isLeftGesture: valueAdjustMode.value == ValueGestureAdjustMode.brightness,
    isRightGesture: valueAdjustMode.value == ValueGestureAdjustMode.volume,
    isStepSeconds: valueAdjustMode.value == ValueGestureAdjustMode.seekStep,
    brightness: brightness.value,
    volume: volume.value,
    seekStepSeconds: liveSeekStep.value,
    onLongPressCancel: onLongPressCancel,
  );
}
