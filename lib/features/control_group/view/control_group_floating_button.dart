import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/control_group/model/enum/player_control_group.dart';
import 'package:iris/features/control_group/store/use_control_group_store.dart';
import 'package:iris/globals.dart' show sidewayQuickColumnAttachedNotifier;
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/platform.dart';

/// The narrow AppState slice [ControlGroupFloatingButton] subscribes to.
///
/// Named record fields give structural equality, so the button rebuilds only
/// when one of these actually changes — not on every AppState mutation.
typedef _FloatingButtonAppSlice = ({
  bool metaOn,
  bool desktopHoverShowControlBar,
  bool sidewayRequireClick,
  bool oneHandedControls,
  bool desktopPhoneMode,
  ScreenOrientation runtimeOrientation,
});

/// Draggable one-handed bottom-group switch button.
///
/// Lives in the player Stack; drag anywhere and the fraction (of the host box)
/// is committed once on release. Visibility (per orientation) and position are
/// persisted by [ControlGroupStore]; the More menu owns the visibility editor.
///
/// The switch RIDES the control panel: it fades in and out with the bar (see
/// [resolveControlPanelVisible], the very rule the bar itself is gated with) and
/// only accepts pointers while the bar is up, so it can never float alone over
/// a hidden control bar. [showControl] keeps the auto-hide timer alive while the
/// button is being used, so the bar cannot vanish under the finger mid-drag.
///
/// Contract (mirroring [BgQuickPanelHost] / [FrameToolsFloatPanel]): EVERY
/// build path returns a [Positioned] — the player Stack only sizes via
/// `constraints.biggest` while it stays all-positioned.
class ControlGroupFloatingButton extends HookWidget {
  const ControlGroupFloatingButton({super.key, this.showControl});

  /// Called on tap / drag / hover to refresh the control bar's auto-hide timer,
  /// exactly like the bar's own buttons do.
  final void Function()? showControl;

  static const double _buttonSize = 46;

  /// Matches the control panel's own show/hide transition so the fade and the
  /// bar's slide read as one motion.
  static const Duration _panelTransition = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context) {
    final store = useControlGroupStore();
    final PlayerControlGroup group =
        store.select(context, (s) => s.group);
    final double storedX = store.select(context, (s) => s.floatingX);
    final double storedY = store.select(context, (s) => s.floatingY);
    // Narrow AppState subscription (record selector → structural equality): the
    // button reads only the phone-mode opt-in, the orientation and the
    // click-to-show policy inputs. Selecting the whole AppState (as before)
    // rebuilt this persistent Stack child on EVERY app-state change.
    final _FloatingButtonAppSlice app = useAppStore().select(context, (s) => (
          metaOn: s.useMetadataSettings,
          desktopHoverShowControlBar: s.desktopHoverShowControlBar,
          sidewayRequireClick: s.sidewayPanelRequireClick,
          oneHandedControls: s.phoneLandscapeUseMode.usesOneHandedControls,
          desktopPhoneMode: s.desktopCenterZonePhoneMode,
          runtimeOrientation: s.runtimeOrientation,
        ));
    // The switch exists wherever a second group does: phones, or desktop
    // (classic desktop opts in through the button's own visibility flag; the
    // phone-mode opt-in still applies).
    final bool supported = isMobilePlatform || isDesktop || app.desktopPhoneMode;
    // Orientation decides WHICH phone visibility flag applies — the same single
    // authority the control bar / overlay use. Desktop is a separate,
    // orientation-independent flag (a resized window has no stable rotation).
    final bool isLandscape = isLandscapeOrientation(
      runtimeOrientation: app.runtimeOrientation,
      realOrientation: MediaQuery.orientationOf(context),
    );
    final bool enabled = isMobilePlatform
        ? store.select(
            context,
            (s) =>
                isLandscape ? s.floatingButtonLandscape : s.floatingButtonPortrait,
          )
        : store.select(context, (s) => s.floatingButtonDesktop);
    // Same rule the control bar is gated with, so the two cannot drift.
    final List<PlayQueueItem> playQueue =
        usePlayQueueStore().select(context, (s) => s.playQueue);
    final int currentIndex =
        usePlayQueueStore().select(context, (s) => s.currentIndex);
    final bool isVideo = useMemoized(() {
      final int index =
          playQueue.indexWhere((element) => element.index == currentIndex);
      return playQueue.isNotEmpty &&
          index >= 0 &&
          playQueue[index].file.type == ContentType.video;
    }, [playQueue, currentIndex]);
    final bool panelVisible = resolveControlPanelVisibleFrom(
      requireClick: shouldRequireClickToShowPanelFrom(
        useMetadataSettings: app.metaOn,
        desktopHoverShowControlBar: app.desktopHoverShowControlBar,
        sidewayPanelRequireClick: app.sidewayRequireClick,
        oneHandedControls: app.oneHandedControls,
      ),
      isShowControl: usePlayerUiStore().select(context, (s) => s.isShowControl),
      isHoverReveal:
          usePlayerUiStore().select(context, (s) => s.isHoverReveal),
      isPanelClickArmed:
          usePlayerUiStore().select(context, (s) => s.isPanelClickArmed),
      editing: useBackgroundPlaybackStore()
          .select(context, (s) => s.segmentEditMode),
      isVideo: isVideo,
      dragActive: useScrubDragStore().select(context, (s) => s.any),
    );

    final Size mediaSize = MediaQuery.sizeOf(context);
    final ValueNotifier<Offset?> frac = useState<Offset?>(null);
    final ValueNotifier<Size?> host = useState<Size?>(null);
    final ValueNotifier<bool> dragging = useState(false);

    // Present = the More menu wants it and the platform supports it. Active =
    // present AND the control panel is up.
    // The side panel's attached 副音 quick COLUMN is the other route to the same
    // controls: while it is on screen this button is redundant and would sit on
    // top of the strip, so it stands down. Published by `CircleSliderLayout` from
    // the very `showsSidewayQuickColumn` call that renders the column (phones are
    // excluded by that helper, so this can only ever be a desktop answer).
    final bool quickColumnAttached =
        useValueListenable(sidewayQuickColumnAttachedNotifier);
    final bool present = enabled && supported && !quickColumnAttached;
    final bool active = present && panelVisible;

    // Measure the hosting Stack so the button clamps to the VIDEO area, not
    // the raw screen (the playlist dock can shrink it).
    useEffect(() {
      if (!present) return null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final box = context.findRenderObject();
        if (box is! RenderBox || !box.hasSize) return;
        RenderBox? node =
            box.parent is RenderBox ? box.parent as RenderBox : null;
        while (node != null && node is! RenderStack) {
          node = node.parent is RenderBox ? node.parent as RenderBox : null;
        }
        final size = node?.size ?? MediaQuery.sizeOf(context);
        if (host.value != size) host.value = size;
      });
      return null;
    }, [present, mediaSize]);

    if (!present) {
      return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }

    final t = getLocalizations(context);
    final Size hostSize = host.value ?? mediaSize;
    final double availW =
        (hostSize.width - _buttonSize).clamp(0.0, double.infinity);
    final double availH =
        (hostSize.height - _buttonSize).clamp(0.0, double.infinity);
    final Offset f = frac.value ?? Offset(storedX, storedY);
    final double left = availW * f.dx.clamp(0.0, 1.0);
    final double top = availH * f.dy.clamp(0.0, 1.0);

    void onDragStart() {
      dragging.value = true;
      showControl?.call();
      // Seed the live frame from the persisted position. Writes still happen
      // once, on release, so a drag that never moves leaves the store alone.
      frac.value ??= Offset(storedX, storedY);
    }

    void onDragDelta(Offset delta) {
      // Keep the bar (and therefore this button) alive for the whole drag.
      showControl?.call();
      // Accumulate onto the LIVE fraction, never onto the value captured at
      // build time: several pan updates can land in one frame, before the
      // rebuild, and a stale base silently drops all but the last delta — the
      // button then lags behind the finger.
      final Offset base = frac.value ?? Offset(storedX, storedY);
      frac.value = Offset(
        (base.dx + (availW <= 0 ? 0 : delta.dx / availW)).clamp(0.0, 1.0),
        (base.dy + (availH <= 0 ? 0 : delta.dy / availH)).clamp(0.0, 1.0),
      );
    }

    void commit() {
      dragging.value = false;
      final Offset? current = frac.value;
      if (current == null) return;
      // ignore: discarded_futures
      store.setFloatingButtonFraction(current.dx, current.dy);
    }

    final bool isBackground = group == PlayerControlGroup.background;
    final Color accent = Theme.of(context).colorScheme.primary;

    return Positioned(
      key: const ValueKey<String>('control_group_floating_button'),
      left: left,
      top: top,
      // Hidden WITH the panel: no pointers, no semantics, and a fade timed to
      // the bar's own slide. The button stays MOUNTED while hidden so a drag in
      // flight is never torn down; a new pointer is simply refused.
      child: IgnorePointer(
        ignoring: !active,
        child: ExcludeSemantics(
          excluding: !active,
          child: AnimatedOpacity(
            opacity: active ? 1.0 : 0.0,
            duration: _panelTransition,
            curve: Curves.easeInOutCubicEmphasized,
            child: MouseRegion(
              onHover: (_) => showControl?.call(),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  // The switch is a bar action: reveal/keep the bar like every
                  // other control-bar button does.
                  showControl?.call();
                  // ignore: discarded_futures
                  store.cycleGroup();
                },
                onPanStart: (_) => onDragStart(),
                onPanUpdate: (DragUpdateDetails d) => onDragDelta(d.delta),
                onPanEnd: (_) => commit(),
                onPanCancel: commit,
                child: Tooltip(
                  message: t.control_group_button_tip,
                  // Touch has no hover, so the default long-press trigger would
                  // keep a LongPressRecognizer in the arena and let a
                  // press-and-hold beat the pan — the drag then never starts.
                  // Desktop hover ignores triggerMode, and the semantics label
                  // survives either way.
                  triggerMode:
                      isMobilePlatform ? TooltipTriggerMode.manual : null,
                  child: AnimatedScale(
                    scale: dragging.value ? 1.12 : 1.0,
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOut,
                    child: Material(
                      color: isBackground
                          ? accent
                          : Colors.black.withValues(alpha: 0.55),
                      shape: const CircleBorder(),
                      elevation: dragging.value ? 8 : 4,
                      child: SizedBox(
                        width: _buttonSize,
                        height: _buttonSize,
                        child: Icon(
                          Icons.swap_horiz_rounded,
                          size: 24,
                          color: isBackground ? Colors.white : Colors.white,
                        ),
                      ),
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
