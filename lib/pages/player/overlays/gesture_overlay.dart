import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/speed/model/enum/speed_gesture_mode.dart';
import 'package:iris/features/speed/model/speed_gesture_resolver.dart';
import 'package:iris/globals.dart';
import 'package:iris/features/windows/context_menu/controller/context_menu_builder.dart';
import 'package:iris/features/windows/context_menu/view/potplayer_context_menu_anchor.dart';
import 'package:iris/hooks/use_gesture.dart';
import 'package:iris/hooks/use_gesture_mode.dart';
import 'package:iris/hooks/use_region_gesture.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/gesture_region.dart';
import 'package:iris/pages/player/overlays/gesture_value_overlay.dart';
import 'package:iris/pages/player/overlays/dual_axis_speed_selector.dart';
import 'package:iris/pages/player/overlays/speed_selector.dart';
import 'package:iris/pages/player/overlays/transient_speed_tip.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/platform.dart';
import 'package:provider/provider.dart';

// NOTE:
// Switching between classic and region gesture engines can cause the
// first long press gesture after the switch to behave incorrectly due to retained
// recognizer state.
//
// This is a known limitation.
// Fixing it would require deeper changes to
// gesture lifecycle management with high cost and low user benefit.
// For now, the behavior is accepted and documented for future work.

IconData brightnessIconFor(double value) {
  if (value == 0) return Icons.brightness_low_rounded;
  if (value < 1) return Icons.brightness_medium_rounded;
  return Icons.brightness_high_rounded;
}

IconData volumeIconFor(double value) {
  if (value == 0) return Icons.volume_mute_rounded;
  if (value < 0.5) return Icons.volume_down_rounded;
  return Icons.volume_up_rounded;
}

class GestureOverlay extends HookWidget {
  const GestureOverlay({
    super.key,
    required this.showControl,
    required this.hideControl,
    required this.showProgress,
    this.showControlForHover,
    this.showTitleOnly,
  });

  final Function() showControl;
  final Function() hideControl;
  final Function() showProgress;
  final Future<void> Function(Future<void>)? showControlForHover;
  final Function()? showTitleOnly;

  @override
  Widget build(BuildContext context) {
    // ─────────────────────────────
    // External state
    // ─────────────────────────────
    final isPlaying =
        context.select<MediaPlayer, bool>((player) => player.isPlaying);

    final playerUiStore = usePlayerUiStore();
    final isShowControl = playerUiStore.select(context, (s) => s.isShowControl);
    final isTransientSpeedActive =
        playerUiStore.select(context, (s) => s.isTransientSpeedActive);

    // ─────────────────────────────
    // Environment
    // ─────────────────────────────
    final orientation = MediaQuery.of(context).orientation;
    final bool isMobile = Platform.isAndroid || Platform.isIOS;

    // ─────────────────────────────
    // Cursor behavior
    // ─────────────────────────────
    final cursor = useMemoized(
      () => isShowControl || !isPlaying
          ? SystemMouseCursors.basic
          : SystemMouseCursors.none,
      [isShowControl, isPlaying],
    );

    // ─────────────────────────────
    // Speed selector state
    // ─────────────────────────────
    final isSpeedSelectorVisible = useState(false);
    final selectedSpeed = useState(1.0);
    final speedSelectorPosition = useState(Offset.zero);
    final visualOffset = useState(0.0);
    final visualOffsetY = useState(0.0);
    final initialSpeed = useRef(1.0);

    // ─────────────────────────────
    // Transient tip state
    // ─────────────────────────────
    final showTransientTip = useState(false);
    final isFadingOut = useState(false);

    // NOTE: This is a local hook wrapper.
    // Must be called unconditionally to preserve hook order.
    // Hooks are about call order, not values.
    void useTransientSpeedTipLifecycle(bool active) {
      useEffect(() {
        if (!active) return null;

        showTransientTip.value = true;
        isFadingOut.value = false;

        final fadeTimer = Timer(const Duration(seconds: 1), () {
          if (context.mounted) {
            isFadingOut.value = true;
          }
        });

        final hideTimer = Timer(const Duration(seconds: 9), () {
          if (context.mounted) {
            showTransientTip.value = false;
          }
        });

        return () {
          fadeTimer.cancel();
          hideTimer.cancel();
        };
      }, [active]);
    }

    useTransientSpeedTipLifecycle(isTransientSpeedActive);

    // ─────────────────────────────
    // Speed selector control
    // ─────────────────────────────
    // Reactive resolution: useGestureMode subscribes to the meta gate and both
    // profiles, so a late store load or a gate/profile toggle switches engines
    // immediately instead of staying cached until an orientation flip.
    final gestureMode = useGestureMode(
      orientation: orientation,
      isPhone: isMobile,
    );

    final bool supportsTransientSpeed = gestureMode != GestureMode.classic;

    void showSpeedSelector(Offset position, double startSpeed) {
      isSpeedSelectorVisible.value = true;
      speedSelectorPosition.value = position;
      visualOffset.value = 0.0;
      visualOffsetY.value = 0.0;
      initialSpeed.value = startSpeed;
    }

    void hideSpeedSelectorCallback(double finalSpeed) {
      final initialIndex = speedStops.indexOf(initialSpeed.value);
      final finalIndex = speedStops.indexOf(finalSpeed);

      if (initialIndex == -1 || finalIndex == -1) return;

      visualOffset.value = (finalIndex - initialIndex) * speedSelectorItemWidth;

      Future.delayed(
        const Duration(milliseconds: 200),
        () {
          if (context.mounted) {
            isSpeedSelectorVisible.value = false;
          }
        },
      );
    }

    void showSpeedSelectorCallback(Offset p) =>
        showSpeedSelector(p, useAppStore().state.rate);

    void showTransientSelectorCallBack(Offset p) =>
        showSpeedSelector(p, useAppStore().state.transientRate);

    // name for semantic intent, not mechanics:
    final showSpeedSelectorForGesture = supportsTransientSpeed
        ? showTransientSelectorCallBack
        : showSpeedSelectorCallback;

    void updateSelectedSpeedCallback(double speed, double newVisualOffset) {
      selectedSpeed.value = speed;
      visualOffset.value = newVisualOffset;
    }

    // Retained for future dual-axis path; currently unified via visualOffset/visualOffsetY managed directly.
    // ignore: unused_element
    void updateDualAxisSpeedCallback(double speed, double dx, double dy) {
      selectedSpeed.value = speed;
      visualOffset.value = dx;
      visualOffsetY.value = dy;
    }

    // final gestureLayouts = useAppStore().select(
    //   context,
    //   (state) => resolveActiveLayouts(
    //     state,
    //     MediaQuery.of(context).orientation,
    //   ),
    // );
    final gestureLayouts = useAppStore().useActiveGestureLayouts(context);

    // Subscribe to the RESOLVED mode, not the state. A whole-state
    // `select(context, (s) => s)` is not an inert read here: `Store.set` emits
    // unconditionally and the selector's `==` is Freezed's deep compare, so this
    // whole overlay — the gesture recognisers, the overlay stack, every value
    // overlay — re-ran on every AppState mutation, including the
    // `transientRate` writes the speed gesture below makes several times per
    // pan. The resolver reads one field, so the enum IS the subscription.
    final SpeedGestureMode speedGestureMode = useAppStore().select(
      context,
      (s) => resolveSpeedGestureMode(
        s,
        metadataEnabled: s.useMetadataSettings,
      ),
    );
    final bool isDualAxis = speedGestureMode == SpeedGestureMode.dualAxis;

    void handleDualAxisSpeed(double speed, double dx, double dy) {
      selectedSpeed.value = speed;
      visualOffset.value = dx;
      visualOffsetY.value = dy;
    }

    final gesture = useUnifiedGesture(
      showControl: showControl,
      hideControl: hideControl,
      showProgress: showProgress,
      showSpeedSelector: showSpeedSelectorCallback,
      showTransientSpeedSelector: showSpeedSelectorForGesture,
      hideSpeedSelector: hideSpeedSelectorCallback,
      updateSelectedSpeed: updateSelectedSpeedCallback,
      updateDualAxisSpeed: handleDualAxisSpeed,
      mode: gestureMode,
      layouts: gestureLayouts,
      showTitleOnly: showTitleOnly,
    );

    useEffect(() {
      // UI cleanup
      final app = useAppStore();
      final ui = usePlayerUiStore();

      // Exit transient semantics
      if (ui.state.isTransientSpeedActive) {
        app.updateRate(app.state.playbackRateBeforeTransient);
        ui.updateIsTransientSpeedActive(false);
      }

      isSpeedSelectorVisible.value = false;
      visualOffset.value = 0.0;
      visualOffsetY.value = 0.0;
      showTransientTip.value = false;
      isFadingOut.value = false;

      // CRITICAL: ensure classic starts from canonical rate
      initialSpeed.value = app.state.rate;
      selectedSpeed.value = app.state.rate;

      visualOffset.value = 0.0;
      return null;
    }, [gestureMode]);

    // ── PotPlayer-style Windows context menu (desktop only) ──
    // Hooks must be called unconditionally to preserve order.
    final menuController = useMemoized(() => MenuController(), const []);
    final isMediaKitForMenu =
        context.select<MediaPlayer, bool>((p) => p is MediaKitPlayer);
    final supportsSyncForMenu =
        context.select<MediaPlayer, bool>((p) => p.supportsSyncAdjustment);
    final supportsTrackForMenu =
        context.select<MediaPlayer, bool>((p) => p.supportsTrackSelection);
    final isFullScreenForMenu =
        playerUiStore.select(context, (s) => s.isFullScreen);
    final isAlwaysOnTopForMenu =
        playerUiStore.select(context, (s) => s.isAlwaysOnTop);
    final playerForMenu = context.read<MediaPlayer>();
    final l10n = getLocalizations(context);
    final menuEntries = useMemoized(
      () => buildPotPlayerContextMenu(
        isMediaKit: isMediaKitForMenu,
        supportsSync: supportsSyncForMenu,
        supportsTrack: supportsTrackForMenu,
        isFullScreen: isFullScreenForMenu,
        isAlwaysOnTop: isAlwaysOnTopForMenu,
        seekStepLabel: l10n.context_menu_seek_step,
        seekStepHint: l10n.context_menu_seek_step_hint,
      ),
      [
        isMediaKitForMenu,
        supportsSyncForMenu,
        supportsTrackForMenu,
        isFullScreenForMenu,
        isAlwaysOnTopForMenu,
        // Rebuild the label/hint when the language changes. Deliberately NOT
        // keyed on seekStepSeconds: the label is static, so the full-screen
        // overlay never rebuilds on each held Ctrl+↑/↓ live update.
        Localizations.localeOf(context),
      ],
    );
    Future<void> effectiveShowControlForHover(Future<void> cb) async {
      if (showControlForHover != null) {
        await showControlForHover!(cb);
      } else {
        showControl();
        await cb;
        showControl();
      }
    }

    final overlay = MouseRegion(
      cursor: cursor,
      onHover: gesture.onHover,
      child: GestureDetector(
        // CRITICAL: Force GestureDetector rebuild with a Key
        // Changing gesture mode requires resetting Flutter's gesture arena.
        // Key change forces recognizer disposal and prevents cross-mode leakage.
        key: ValueKey(gestureMode),
        behavior: HitTestBehavior.opaque,
        onTap: gesture.onTap,
        onTapDown: gesture.onTapDown,
        onDoubleTapDown: gesture.onDoubleTapDown,
        onLongPressStart: gesture.onLongPressStart,
        onLongPressMoveUpdate: gesture.onLongPressMoveUpdate,
        onLongPressEnd: gesture.onLongPressEnd,
        onLongPressCancel: gesture.onLongPressCancel,
        onPanStart: gesture.onPanStart,
        onPanUpdate: gesture.onPanUpdate,
        onPanEnd: gesture.onPanEnd,
        onPanCancel: gesture.onPanCancel,
        onSecondaryTapUp: isDesktop
            ? (details) {
                showControl();
                menuController.open(position: details.globalPosition);
              }
            : null,
        child: Stack(
          children: [
            // 临时倍速提示 — dualAxis 时追加 ↑+1.0 提示，帮助发现纵向粗调
            if (!isSpeedSelectorVisible.value &&
                supportsTransientSpeed &&
                isTransientSpeedActive &&
                showTransientTip.value)
              Builder(builder: (context) {
                // Only the rate comes from the store here: the axis hint was
                // already resolved once for the whole overlay, so this tip
                // needs no second whole-state subscription to render.
                final double transientRate = useAppStore().select(
                  context,
                  (s) => s.transientRate,
                );
                return TransientSpeedTip(
                  speed: transientRate,
                  fading: isFadingOut.value,
                  showDualHint: isDualAxis,
                );
              }),
            // 播放速度 — dualAxis 时替换为新的双轴显眼组件，单轴保持旧组件
            if (isSpeedSelectorVisible.value)
              Positioned.fill(
                child: isDualAxis
                    ? DualAxisSpeedSelector(
                        selectedSpeed: selectedSpeed.value,
                        visualOffset: visualOffset.value,
                        visualOffsetY: visualOffsetY.value,
                        initialSpeed: initialSpeed.value,
                      )
                    : SpeedSelector(
                        selectedSpeed: selectedSpeed.value,
                        visualOffset: visualOffset.value,
                        initialSpeed: initialSpeed.value,
                      ),
              ),
            if (gesture.isStepSeconds && gesture.seekStepSeconds != null)
              GestureValueOverlay(
                value: gesture.seekStepSeconds! / 120.0,
                icon: Icons.update,
                valueFormatter: (_) => '${gesture.seekStepSeconds}s',
              ),

            // 屏幕亮度
            if (gesture.isLeftGesture && gesture.brightness != null)
              GestureValueOverlay(
                value: gesture.brightness!,
                icon: brightnessIconFor(gesture.brightness!),
                valueFormatter: (v) => '${(v * 100).round()}%',
              ),
            // 音量
            if (gesture.isRightGesture && gesture.volume != null)
              GestureValueOverlay(
                value: gesture.volume!,
                icon: volumeIconFor(gesture.volume!),
                valueFormatter: (v) => '${(v * 100).round()}%',
              ),
          ],
        ),
      ),
    );
    final menuWidgets = buildPotPlayerMenuWidgets(
      context,
      entries: menuEntries,
      player: playerForMenu,
      showControl: showControl,
      showControlForHover: effectiveShowControlForHover,
      showProgress: showProgress,
    );
    final Widget wrappedOverlay = isDesktop
        ? MenuAnchor(
            controller: menuController,
            menuChildren: menuWidgets,
            child: overlay,
          )
        : overlay;
    // fb/bg align edit mode: the full-screen gesture surface is switched off
    // (the panel itself owns play/pause, seek and the sliders), so taps/seeks
    // cannot fight the locked pair.
    final editing = useBackgroundPlaybackStore()
        .select(context, (s) => s.segmentEditMode);

    // Windows AXTree-crash mitigation (#103808 family): pointer-only gesture
    // canvas — taps/swipes carry no announceable semantics, and feeding its
    // per-frame churn to the accessibility bridge is pure crash exposure.
    return ExcludeSemantics(
      child: IgnorePointer(ignoring: editing, child: wrappedOverlay),
    );
  }
}

//Hooks are about call order, not return values.
Gesture useUnifiedGesture({
  required GestureMode mode,
  required Map<GestureIntent, GestureLayout> layouts,
  required void Function() showControl,
  required void Function() hideControl,
  required void Function() showProgress,
  required void Function(Offset position) showSpeedSelector,
  required void Function(Offset position) showTransientSpeedSelector,
  required void Function(double finalSpeed) hideSpeedSelector,
  required void Function(double speed, double visualOffset) updateSelectedSpeed,
  void Function(double speed, double dx, double dy)? updateDualAxisSpeed,
  void Function()? showTitleOnly,
}) {
  final classic = useGesture(
    showControl: showControl,
    hideControl: hideControl,
    showProgress: showProgress,
    showSpeedSelector: showSpeedSelector,
    hideSpeedSelector: hideSpeedSelector,
    updateSelectedSpeed: updateSelectedSpeed,
    showTitleOnly: showTitleOnly,
  );

  final region = useRegionGesture(
    layouts: layouts,
    showControl: showControl,
    hideControl: hideControl,
    showProgress: showProgress,
    showSpeedSelector: showSpeedSelector,
    showTransientSpeedSelector: showTransientSpeedSelector,
    hideSpeedSelector: hideSpeedSelector,
    updateSelectedSpeed: updateSelectedSpeed,
    updateDualAxisSpeed: updateDualAxisSpeed,
    showTitleOnly: showTitleOnly,
  );

  switch (mode) {
    case GestureMode.classic:
      return classic;
    case GestureMode.region:
    case GestureMode.rightSideLandscape:
    case GestureMode.leftSideLandscape:
    // ignore: deprecated_member_use
    case GestureMode.rightHandLandscape:
    // ignore: deprecated_member_use
    case GestureMode.leftHandLandscape:
      return region;
  }
}
