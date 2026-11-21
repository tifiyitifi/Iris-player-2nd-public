import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:iris/features/background_playback/view/player_control_target_scope.dart';
import 'package:iris/features/speed/model/speed_gesture_math.dart';
import 'package:iris/features/speed/model/speed_gesture_resolver.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/resolve_keyboard_scheme.dart';
import 'package:iris/globals.dart' show speedStops;
import 'package:iris/hooks/use_brightness.dart';
import 'package:iris/hooks/use_volume.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
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

class Gesture {
  final void Function(TapDownDetails) onTapDown;
  final void Function() onTap;
  final void Function(TapDownDetails) onDoubleTapDown;
  final void Function(LongPressStartDetails) onLongPressStart;
  final void Function(LongPressMoveUpdateDetails) onLongPressMoveUpdate;
  final void Function(LongPressEndDetails) onLongPressEnd;
  final void Function() onLongPressCancel;
  final void Function(DragStartDetails) onPanStart;
  final void Function(DragUpdateDetails) onPanUpdate;
  final void Function(DragEndDetails) onPanEnd;
  final void Function() onPanCancel;
  final void Function(PointerHoverEvent) onHover;

  final bool isLongPress;
  final bool isLeftGesture;
  final bool isRightGesture;
  final double? brightness;
  final double? volume;

  final bool isStepSeconds;
  final int? seekStepSeconds;

  Gesture({
    required this.onTapDown,
    required this.onTap,
    required this.onDoubleTapDown,
    required this.onLongPressStart,
    required this.onLongPressMoveUpdate,
    required this.onLongPressEnd,
    required this.onLongPressCancel,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.onPanCancel,
    required this.onHover,
    required this.isLongPress,
    required this.isLeftGesture,
    required this.isRightGesture,
    required this.brightness,
    required this.volume,
    this.isStepSeconds = false,
    this.seekStepSeconds = 5,
  });
}

Gesture useGesture({
  required void Function() showControl,
  required void Function() hideControl,
  required void Function() showProgress,
  required void Function(Offset position) showSpeedSelector,
  required void Function(double finalSpeed) hideSpeedSelector,
  required void Function(double speed, double visualOffset) updateSelectedSpeed,
  void Function()? showTitleOnly,
}) {
  final context = useContext();

  final gestureState = useRef({
    'isTouch': false,
    'isLongPress': false,
    'isDragging': false,
    'startPanOffset': Offset.zero,
    'startSeekPosition': Duration.zero,
    'panDirection': null, // null: 未确定, Axis.horizontal, Axis.vertical
  });

  final isLeftGesture = useState(false);
  final isRightGesture = useState(false);

  // Live pan-seek throttle + the newest target: an unthrottled per-update seek
  // floods the backend, and the release must still commit the exact final
  // position (the last tick can be dropped).
  final panSeekThrottle = useRef(LiveSeekThrottle());
  final pendingPanSeekMs = useRef<int?>(null);

  final brightness = useBrightness(isLeftGesture.value);
  final volume = useVolume(isRightGesture.value);

  void onTapDown(TapDownDetails details) {
    if (details.kind == PointerDeviceKind.touch) {
      gestureState.value['isTouch'] = true;
    }
  }

  void onTap() {
    final ui = usePlayerUiStore().state;
    final bool rc = shouldRequireClickToShowPanel(useAppStore().state);
    if (!ui.isShowControl) {
      if (rc) usePlayerUiStore().updateIsPanelClickArmed(true);
      showControl();
    } else if (rc && !ui.isPanelClickArmed) {
      usePlayerUiStore().updateIsPanelClickArmed(true);
      showControl();
    } else {
      hideControl();
    }
  }

  // NOTE:
  // Known limitation: the double-tap action is dispatched from
  // onDoubleTapDown — on the second press-down — while Flutter has not yet
  // confirmed the double tap (it may still be cancelled afterwards). A second
  // press that is then cancelled (dragged away / preempted) still fires one
  // action once, and it cannot be undone.
  // Accepted as a known limitation; no fix planned.
  void onDoubleTapDown(TapDownDetails details) {
    final player = context.read<MediaPlayer>();

    if (details.kind == PointerDeviceKind.touch) {
      final screenWidth = MediaQuery.sizeOf(context).width;
      final tapDx = details.globalPosition.dx;

      if (tapDx > screenWidth * 0.75) {
        // 右侧 25%
        showProgress();
        player.forward(10);
      } else if (tapDx < screenWidth * 0.25) {
        // 左侧 25%
        showProgress();
        player.backward(10);
      } else {
        // 中间 50%
        if (player.isPlaying) {
          setActiveTransportFlag(context, playing: false);
          player.pause();
          showControl();
        } else {
          setActiveTransportFlag(context, playing: true);
          player.play();
        }
      }
    } else if (isDesktop) {
      // Desktop double-click: PotPlayer scheme = play/pause (spec), legacy = toggle fullscreen.
      final scheme = resolveKeyboardScheme(
        stored: useAppStore().state.keyboardShortcutScheme,
        metadataEnabled: useAppStore().state.useMetadataSettings && MetaSettingsModule.ready,
      );
      if (scheme == KeyboardShortcutScheme.potplayer) {
        if (player.isPlaying) {
          setActiveTransportFlag(context, playing: false);
          player.pause();
        } else {
          setActiveTransportFlag(context, playing: true);
          player.play();
        }
      } else {
        usePlayerUiStore().updateFullScreen(!usePlayerUiStore().state.isFullScreen);
      }
    }
  }

  void onLongPressStart(LongPressStartDetails details) {
    if (gestureState.value['isTouch'] as bool && context.read<MediaPlayer>().isPlaying) {
      gestureState.value['isLongPress'] = true;
      gestureState.value['startPanOffset'] = details.globalPosition;

      final currentRate = useAppStore().state.rate;
      final closestSpeed = speedStops.reduce((a, b) => (a - currentRate).abs() < (b - currentRate).abs() ? a : b);
      gestureState.value['initialSpeedIndex'] = speedStops.indexOf(closestSpeed);

      showSpeedSelector(details.globalPosition);
      updateSelectedSpeed(closestSpeed, 0.0);
    }
  }

  void onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!(gestureState.value['isLongPress'] as bool)) return;

    final start = gestureState.value['startPanOffset'] as Offset;
    final total = details.globalPosition - start;

    final mode = resolveSpeedGestureMode(
      useAppStore().state,
      metadataEnabled:
          useAppStore().state.useMetadataSettings && MetaSettingsModule.ready,
    );
    final int initialIndex =
        gestureState.value['initialSpeedIndex'] as int? ?? speedStops.indexOf(1.0);
    final int finalIndex = resolveDualAxisSpeedIndex(
      baseIndex: initialIndex,
      total: total,
      mode: mode,
      isSelectorVisible: true,
    );
    double selectedSpeed = speedStops[finalIndex];

    updateSelectedSpeed(selectedSpeed, total.dx);
    if (useAppStore().state.rate != selectedSpeed) {
      HapticFeedback.selectionClick();
      useAppStore().updateRate(selectedSpeed);
    }
  }

  void onLongPressEnd(LongPressEndDetails details) {
    if (gestureState.value['isLongPress'] as bool) {
      hideSpeedSelector(useAppStore().state.rate);
    }
    gestureState.value['isLongPress'] = false;
    gestureState.value['isTouch'] = false;
  }

  void onLongPressCancel() {
    if (gestureState.value['isLongPress'] as bool) {
      hideSpeedSelector(useAppStore().state.rate);
    }
    gestureState.value['isLongPress'] = false;
    gestureState.value['isTouch'] = false;
  }

  void onPanStart(DragStartDetails details) {
    if (isDesktop && details.kind != PointerDeviceKind.touch) {
      windowManager.startDragging();
      return;
    }

    if (gestureState.value['isLongPress'] as bool) {
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

      gestureState.value['isTouch'] = true;
      gestureState.value['isDragging'] = true;
      gestureState.value['startPanOffset'] = details.globalPosition;
      gestureState.value['startSeekPosition'] = context.read<MediaPlayer>().position;
      gestureState.value['panDirection'] = null;
      isLeftGesture.value = false;
      isRightGesture.value = false;

      panSeekThrottle.value.reset();
      pendingPanSeekMs.value = null;
    }
  }

  void onPanUpdate(DragUpdateDetails details) {
    if (!(gestureState.value['isDragging'] as bool)) return;

    final startOffset = gestureState.value['startPanOffset'] as Offset;
    final totalDx = details.globalPosition.dx - startOffset.dx;
    final totalDy = details.globalPosition.dy - startOffset.dy;

    // 增加手势“死区”，防止误触
    const double panDeadzone = 8.0;
    if (gestureState.value['panDirection'] == null) {
      if (totalDx.abs() > panDeadzone || totalDy.abs() > panDeadzone) {
        gestureState.value['panDirection'] = totalDx.abs() > totalDy.abs() ? Axis.horizontal : Axis.vertical;
      }
    }

    final direction = gestureState.value['panDirection'];
    if (direction == null) return;

    // 水平滑动 (Seek)
    if (direction == Axis.horizontal) {
      useScrubDragStore().beginSeek(ScrubOwners.areaGesture);

      const double sensitivity = 3.0; // 每滑动3像素代表1秒
      final double seekSecondsOffset = totalDx / sensitivity;
      final startSeconds = (gestureState.value['startSeekPosition'] as Duration).inSeconds;

      int targetSeconds = (startSeconds + seekSecondsOffset).round();

      // 边界检查
      targetSeconds = targetSeconds.clamp(0, context.read<MediaPlayer>().duration.inSeconds);

      // Throttled live seek (one per 120ms); the exact final target is
      // committed on release in `_resetPanState`.
      pendingPanSeekMs.value = targetSeconds * 1000;
      if (panSeekThrottle.value.allow(DateTime.now())) {
        context.read<MediaPlayer>().seek(Duration(seconds: targetSeconds));
      }
      showProgress();
    }

    // 垂直滑动 (亮度和音量)
    if (direction == Axis.vertical) {
      // 仅在垂直滑动开始时判断一次左右区域
      if (!isLeftGesture.value && !isRightGesture.value) {
        isLeftGesture.value = startOffset.dx < MediaQuery.sizeOf(context).width / 2;
        isRightGesture.value = !isLeftGesture.value;

        if (isRightGesture.value) {
          FlutterVolumeController.updateShowSystemUI(false);
        }
      }

      final double dy = details.delta.dy;

      if (isLeftGesture.value && brightness.value != null) {
        final newBrightness = brightness.value! - dy / 200;
        brightness.value = newBrightness.clamp(0.0, 1.0);
      }

      if (isRightGesture.value && volume.value != null) {
        final newVolume = volume.value! - dy / 200;
        volume.value = newVolume.clamp(0.0, 1.0);
      }
    }
  }

  // ignore: no_leading_underscores_for_local_identifiers
  void _resetPanState() {
    useScrubDragStore().endSeek(ScrubOwners.areaGesture);

    // Commit the exact final drag target (live ticks are throttled and the last
    // one can be dropped). VM cross-segment targets keep the hooks' stashed
    // release-commit path instead.
    final int? pending = pendingPanSeekMs.value;
    pendingPanSeekMs.value = null;
    panSeekThrottle.value.reset();
    if (pending != null && !VirtualMediaController.instance.isActive) {
      context.read<MediaPlayer>().seek(Duration(milliseconds: pending));
    }

    gestureState.value = {
      ...gestureState.value,
      'isDragging': false,
      'panDirection': null,
    };
    isLeftGesture.value = false;
    isRightGesture.value = false;

    FlutterVolumeController.updateShowSystemUI(true);
  }

  void onPanEnd(DragEndDetails details) => _resetPanState();
  void onPanCancel() => _resetPanState();

  void onHover(PointerHoverEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      final bool rc = shouldRequireClickToShowPanel(useAppStore().state);
      final bool armed = usePlayerUiStore().state.isPanelClickArmed;
      final bool seeking = useScrubDragStore().state.isScrubbing;
      final bool holding = useScrubDragStore().state.isHolding;
      final bool hiddenForRc = rc && !seeking && !holding && !armed;
      if (hiddenForRc) {
        if (showTitleOnly != null) {
          showTitleOnly!.call();
        } else {
          usePlayerUiStore().updateIsShowControl(true);
          usePlayerUiStore().updateIsHovering(true);
          showControl();
        }
      } else {
        usePlayerUiStore().updateIsHovering(true);
        showControl();
      }
    }
  }

  return Gesture(
    onTapDown: onTapDown,
    onTap: onTap,
    onDoubleTapDown: onDoubleTapDown,
    onLongPressStart: onLongPressStart,
    onLongPressMoveUpdate: onLongPressMoveUpdate,
    onLongPressEnd: onLongPressEnd,
    onLongPressCancel: onLongPressCancel,
    onPanStart: onPanStart,
    onPanUpdate: onPanUpdate,
    onPanEnd: onPanEnd,
    onPanCancel: onPanCancel,
    onHover: onHover,
    isLongPress: gestureState.value['isLongPress'] as bool,
    isLeftGesture: isLeftGesture.value,
    isRightGesture: isRightGesture.value,
    brightness: brightness.value,
    volume: volume.value,
  );
}
