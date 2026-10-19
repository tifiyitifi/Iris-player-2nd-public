import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/screen_lock/store/use_screen_lock_store.dart';
import 'package:iris/pages/player/control_bar/title_area.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';

/// Topmost locked-state surface of the player Stack.
///
/// While the guard is armed this layer is the ONLY thing that reacts to touch:
///
/// * the full-screen barrier swallows every gesture (tap toggles the chrome,
///   everything else is claimed and dropped), so no tap, swipe, long-press or
///   double-tap can reach the gesture layer, the control bar or the title bar
///   behind it — the requirement is explicit "no reaction anywhere, no
///   toast/dialog";
/// * the lock chrome (player title + the two edge unlock buttons) fades as one
///   unit, showControl-style: a tap anywhere shows it, another tap hides it,
///   and it auto-hides after [chromeVisibleDuration]. The two edge buttons are
///   offered for one-handed landscape holds on either thumb. Either button —
///   not both — releases the guard.
///
/// The chrome insets are derived from `max(padding, viewPadding)`: the player
/// runs immersive-sticky, where `padding` drops to zero but the camera cutout
/// stays in `viewPadding`. Pinning the buttons to the physical edge would park
/// one of them under the punch-hole camera in landscape.
class ScreenLockOverlay extends HookWidget {
  const ScreenLockOverlay({
    super.key,
    this.title = '',
    this.queueLabel,
    this.tagSuffix,
    this.bgTitleSuffix,
    this.bgTitleNoMedia = false,
    this.saveProgress,
  });

  /// Display fields mirror [ControlsOverlay]'s title inputs: the lock chrome
  /// reuses the normal player title content verbatim.
  final String title;
  final String? queueLabel;
  final String? tagSuffix;

  /// 副音 on-marker appended to the title (never a replacement).
  final String? bgTitleSuffix;

  /// 副音 is on but no media is loaded — the marker renders muted.
  final bool bgTitleNoMedia;

  /// Forwarded to the reused title bar (title buttons stay inert: the whole
  /// title is wrapped in [IgnorePointer] while locked).
  final Future<void> Function()? saveProgress;

  static const Key chromeKey = ValueKey<String>('screen_lock_chrome');
  static const Key barrierKey = ValueKey<String>('screen_lock_barrier');
  static const Key leftUnlockKey = ValueKey<String>('screen_lock_unlock_left');
  static const Key rightUnlockKey = ValueKey<String>('screen_lock_unlock_right');

  /// Visible window of the lock chrome after each show-tap.
  static const Duration chromeVisibleDuration = Duration(seconds: 3);

  /// Minimum clearance of the unlock buttons from the screen border. In
  /// cutout-free areas this is the inset; where a cutout intrudes, the
  /// intrusion wins (see [chromeInsets]).
  static const double _edgeInset = 10;

  /// Tap target of one unlock button.
  static const double _buttonSize = 48;

  /// Safe-area insets for the chrome: the worst of `padding`/`viewPadding`
  /// per side, so a landscape punch-hole camera never sits under a button.
  @visibleForTesting
  static EdgeInsets chromeInsets(MediaQueryData mq) {
    double side(double pad, double viewPad) =>
        math.max(_edgeInset, math.max(pad, viewPad));
    return EdgeInsets.only(
      left: side(mq.padding.left, mq.viewPadding.left),
      right: side(mq.padding.right, mq.viewPadding.right),
      top: math.max(mq.padding.top, mq.viewPadding.top),
      bottom: math.max(mq.padding.bottom, mq.viewPadding.bottom),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool locked = useScreenLockStore().select(context, (s) => s.locked);
    final bool visible =
        useScreenLockStore().select(context, (s) => s.uiVisible);

    // Auto-hide the chrome while the guard stays armed — the showControl
    // analogue for the lock surface. Re-armed on every show-tap because the
    // effect re-runs when [visible] flips false→true.
    useEffect(() {
      if (!locked || !visible) return null;
      final Timer timer = Timer(chromeVisibleDuration, () {
        useScreenLockStore().hideLockUi();
      });
      return timer.cancel;
    }, [locked, visible]);

    final contentColor = useMemoized(
        () => Theme.of(context).brightness == Brightness.dark
            ? Theme.of(context).colorScheme.onSurface
            : Theme.of(context).colorScheme.surface,
        [context]);
    final overlayColor = useMemoized(
        () => WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
              if (states.contains(WidgetState.pressed)) {
                return contentColor.withValues(alpha: 0.2);
              } else if (states.contains(WidgetState.hovered)) {
                return contentColor.withValues(alpha: 0.2);
              }
              return null;
            }),
        [contentColor]);
    final controlsTitleConfig =
        useAppStore().select(context, (state) => state.controlsTitleConfig);

    // Always return a Positioned: the player Stack only sizes via
    // `constraints.biggest` while every child stays positioned. Hidden →
    // a bare SizedBox, which paints nothing and hit-tests nothing.
    if (!locked) {
      return const Positioned.fill(child: SizedBox.shrink());
    }
    return Positioned.fill(
      child: Stack(
        children: [
          // Barrier: always live. A tap toggles the chrome; every other
          // gesture is claimed and dropped so nothing behind this overlay
          // (gesture canvas, controls, title) ever sees it. No double-tap
          // claimer: one would hold every toggle for the double-tap timeout,
          // while a double-tap on an opaque barrier is already fully
          // consumed (two toggles, net no-op, nothing leaks through).
          Positioned.fill(
            child: GestureDetector(
              key: barrierKey,
              behavior: HitTestBehavior.opaque,
              onTap: () => useScreenLockStore().toggleLockUi(),
              onLongPress: () {},
              onPanStart: (_) {},
              onPanUpdate: (_) {},
              onPanEnd: (_) {},
              onPanCancel: () {},
              child: const SizedBox.expand(),
            ),
          ),
          // Lock chrome: normal title content + both edge unlock buttons,
          // faded as one unit. Hidden → fully transparent AND ignored, so
          // taps fall through to the barrier (which re-shows the chrome).
          Positioned.fill(
            child: Padding(
              padding: chromeInsets(MediaQuery.of(context)),
              child: AnimatedOpacity(
                key: chromeKey,
                opacity: visible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !visible,
                  child: Stack(
                    children: [
                      // Display-only: window/title buttons must stay inert
                      // while the guard is armed; taps toggle via the barrier.
                      Align(
                        alignment: Alignment.topCenter,
                        child: IgnorePointer(
                          child: TitleArea(
                            title: title,
                            queueLabel: queueLabel,
                            tagSuffix: tagSuffix,
                            bgTitleSuffix: bgTitleSuffix,
                            bgTitleNoMedia: bgTitleNoMedia,
                            color: contentColor,
                            overlayColor: overlayColor,
                            saveProgress:
                                saveProgress ?? () async {},
                            config: controlsTitleConfig,
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _unlockButton(
                          context,
                          key: leftUnlockKey,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: _unlockButton(
                          context,
                          key: rightUnlockKey,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _unlockButton(
    BuildContext context, {
    required Key key,
  }) {
    final t = getLocalizations(context);
    return Tooltip(
      message: t.screen_lock_unlock,
      child: Material(
        key: key,
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          // Either edge releases the guard.
          onTap: () => useScreenLockStore().unlock(),
          child: const SizedBox(
            width: _buttonSize,
            height: _buttonSize,
            child: Icon(
              Icons.lock_open_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}
