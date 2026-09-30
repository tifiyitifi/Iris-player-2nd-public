import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/window/playlist_dock/resolve_playlist_dock.dart';

/// Right-edge overlay playlist dock for picture fullscreen (画面全屏).
///
/// PotPlayer-style: the panel slides in over the fullscreen video (occluding
/// it, never shrinking it). While hidden, a thin activation strip at the right
/// edge reveals it on hover; the pointer may then move into the panel and
/// operate it normally. Once the pointer leaves the panel plus
/// [kFullscreenDockHideMargin] px it hides again.
///
/// The hover zone is a SINGLE persistent region anchored to the right edge,
/// whose width is [edgeWidth] while hidden and the panel + margin while shown.
/// It must never be re-mounted under a stationary pointer: with the previous
/// design the strip only existed while hidden, so any transient conceal (e.g. a
/// fullscreen geometry change emitting `onExit` and then `onEnter` in the same
/// frame) re-revealed immediately — the panel looped reveal/conceal while the
/// cursor sat still on the edge. The panel visuals are a separate, moving child
/// that never owns hover, and a conceal is debounced by
/// [kFullscreenDockConcealDelay] so a brief skirting of the boundary is absorbed.
///
/// Reveal fires on both `onEnter` AND `onHover`: a conceal that lands while the
/// pointer is still inside the region leaves the annotation active, so no fresh
/// `onEnter` can arrive — movement within the region must be able to wake it.
/// Conversely an `onExit` whose reported position still lies inside the region
/// rect is spurious (media-switch rebuild burst, dialog barrier above the dock)
/// and must NOT conceal — see [shouldConcealAfterExit].
///
/// The summon strip EXCLUDES the control bar while the panel is hidden
/// ([controlPanelKey]): the one-handed side panel is anchored against this same
/// right edge, so an unfiltered hover summoned the queue over the slider the
/// user was reaching for. Once the panel is out it owns the strip — the two
/// rects overlap by design, so excluding them there would conceal the panel the
/// instant it appeared.
///
/// Purely presentational: visibility is owned by the caller ([shown]/[pinned])
/// so this widget can be exercised without the app's stores.
class FullscreenPlaylistDockOverlay extends HookWidget {
  const FullscreenPlaylistDockOverlay({
    super.key,
    required this.shown,
    required this.pinned,
    required this.width,
    required this.edgeWidth,
    required this.child,
    required this.onReveal,
    required this.onConceal,
    this.controlPanelKey,
    this.controlBarIsolationHeight = 0,
  });

  /// Panel visible (pinned or transient peek). Off-screen right otherwise.
  final bool shown;

  /// Pinned open: hover-out must not conceal it.
  final bool pinned;

  /// Panel width in logical px.
  final double width;

  /// Right-edge activation strip width in logical px.
  final double edgeWidth;

  /// The panel body (typically `PlaylistDockPanel`).
  final Widget child;

  /// Pointer entered the edge strip or the panel.
  final VoidCallback onReveal;

  /// Pointer left the panel (+margin); caller decides based on pin.
  final VoidCallback onConceal;

  /// Live control-bar box (see `controlPanelKeyNotifier`), or null when the
  /// caller publishes none — then the whole strip is summonable, as before.
  final ValueNotifier<GlobalKey?>? controlPanelKey;

  /// Bottom isolation zone (logical px) reserved for the current control bar,
  /// whether or not it is currently shown. Hover inside the bottom band does
  /// not reveal the queue while it is hidden; `0` disables the zone. See
  /// `controlBarIsolationHeightNotifier`.
  final double controlBarIsolationHeight;

  @override
  Widget build(BuildContext context) {
    // The hover region is the panel PLUS a transparent margin on its left, so
    // the pointer must clear the panel by [kFullscreenDockHideMargin] before
    // the panel hides.
    final double regionWidth = width + kFullscreenDockHideMargin;

    final concealTimer = useRef<Timer?>(null);
    // Read the *latest* pin inside the debounce callback; the timer outlives
    // the build that scheduled it.
    final pinnedRef = useRef<bool>(pinned);
    pinnedRef.value = pinned;
    // Stable key for the hover region's render box: an `onExit` reports a
    // pointer position that may still lie inside the region (spurious exit
    // from a rebuild or a dialog barrier), so the exit must be verified
    // against the region rect before it is allowed to conceal.
    final regionKey = useRef(GlobalKey());

    useEffect(() {
      return () => concealTimer.value?.cancel();
    }, const <Object?>[]);

    void reveal() {
      concealTimer.value?.cancel();
      concealTimer.value = null;
      onReveal();
    }

    void scheduleConceal() {
      if (pinnedRef.value) return;
      concealTimer.value?.cancel();
      concealTimer.value = Timer(kFullscreenDockConcealDelay, () {
        concealTimer.value = null;
        if (!pinnedRef.value) onConceal();
      });
    }

    /// Screen rect of the control bar, read LIVE at pointer time (never
    /// cached): the bar is translated off-screen while it is hidden, so it
    /// reports a rect that cannot contain the pointer and blocks nothing.
    Rect? controlBarRect() {
      final RenderObject? box =
          controlPanelKey?.value?.currentContext?.findRenderObject();
      if (box is RenderBox && box.attached && box.hasSize) {
        return box.localToGlobal(Offset.zero) & box.size;
      }
      return null;
    }

    /// The strip's reaction to pointer activity: summon, except while the
    /// pointer rests on the control bar itself. Guarded by `!shown` because a
    /// revealed panel is drawn OVER the bar and shares its rect — excluding it
    /// there would conceal the panel the moment it appeared.
    void onPointerActivity(Offset globalPosition) {
      if (!shown) {
        if (isPointerOverControlPanel(
          panelRect: controlBarRect(),
          pointer: globalPosition,
        )) {
          return;
        }
        // Control-bar isolation zone: the band stays reserved even while the
        // bar is translated off-screen, so the pointer can be moved there to
        // operate the bar instead of popping the queue. Only while HIDDEN —
        // once shown, the pointer over the list (which overlaps this band)
        // behaves exactly as before.
        if (controlBarIsolationHeight > 0) {
          final RenderObject? region =
              regionKey.value.currentContext?.findRenderObject();
          if (region is RenderBox && region.attached && region.hasSize) {
            if (isPointerInControlBarIsolationZone(
              localY: region.globalToLocal(globalPosition).dy,
              areaHeight: region.size.height,
              isolationHeight: controlBarIsolationHeight,
            )) {
              return;
            }
          }
        }
      }
      reveal();
    }

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        // Panel visuals only: they slide in/out but never own hover. While
        // hidden they are off-screen and ignore pointers, so taps reach the
        // video untouched.
        AnimatedPositioned(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOutCubicEmphasized,
          top: 0,
          bottom: 0,
          right: shown ? 0 : -regionWidth,
          width: regionWidth,
          child: IgnorePointer(
            ignoring: !shown,
            // IgnorePointer only blocks the POINTER: a panel that slid
            // off-screen kept the primary focus, so ↑/↓ kept driving an
            // invisible queue (and Delete still removed rows from it).
            // ExcludeFocus(excluding) flips `descendantsAreFocusable` off,
            // which unfocuses a focused descendant and moves the focus to the
            // scope OUTSIDE this widget — exactly "the hidden panel lets go of
            // the keyboard". It also stops a hidden panel from grabbing focus
            // in the first place.
            child: ExcludeFocus(
              excluding: !shown,
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: width,
                  child: Material(
                    color: const Color(0xFF1E1E1E),
                    child: ExcludeSemantics(child: child),
                  ),
                ),
              ),
            ),
          ),
        ),
        // The single, persistent hover region. It stays anchored at right:0 and
        // only changes width, so a conceal can never drop a fresh region under
        // a stationary pointer. It is the TOPMOST child and translucent: it is
        // always part of the hit-test (so its exit is reliable) yet never
        // swallows clicks meant for the panel below or the video.
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: shown ? regionWidth : edgeWidth,
          child: MouseRegion(
            key: regionKey.value,
            opaque: false,
            onEnter: (event) => onPointerActivity(event.position),
            // Also reveal on movement, not only on the enter edge. A conceal
            // that fires while the pointer never left the region cannot produce
            // a new `onEnter` (the annotation is still active), which read as
            // "hover often does nothing until I move far away and back". Waking
            // on hover is also exactly PotPlayer's behaviour.
            onHover: (event) => onPointerActivity(event.position),
            onExit: (event) {
              // A media switch (or a dialog barrier above the dock) can emit
              // onExit while the pointer is still over the list. That exit's
              // position lands inside the region rect, so it must not conceal
              // — otherwise "tap to switch video" hides the queue.
              final box =
                  regionKey.value.currentContext?.findRenderObject();
              if (box is RenderBox && box.attached) {
                final stillInside = !shouldConcealAfterExit(
                  regionSize: box.size,
                  exitLocalPosition: box.globalToLocal(event.position),
                );
                if (stillInside) return;
              }
              scheduleConceal();
            },
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}
