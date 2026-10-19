import 'dart:ui';

import 'package:iris/models/store/app_state.dart';

/// Dock intent without any width gate: the user's explicit dock choice.
///
/// Width must not gate the dock — portrait fitVideo shrinks the window below
/// the old tablet breakpoint (e.g. 720x1280 @150% is 480 logical + chrome),
/// and gating on the current width self-locks: a hidden dock reserves no
/// chrome, so the next fit stays narrow and the dock never returns.
bool isDockIntentVisible({
  required bool isDesktop,
  required PlaylistPanelMode mode,
  required bool visible,
  required bool isFullScreen,
  required bool useMetadataSettings,
  required bool legacyStorage,
}) {
  if (!isDesktop) return false;
  // The desktop dock is a meta-era feature: it exists only while the metadata
  // subsystem is ON AND the legacy-storage backend is OFF. Either legacy state
  // (master gate OFF, or the legacy-storage switch ON) means "no side panel" —
  // there is no queue surface for the dock to show there.
  if (!useMetadataSettings || legacyStorage) return false;
  if (mode != PlaylistPanelMode.dockedRight) return false;
  if (!visible) return false;
  // Video fullscreen: only floating list, never side dock (spec §3).
  if (isFullScreen) return false;
  return true;
}

/// Determines whether the PotPlayer-style right dock should be visible.
///
/// Sidebar-first: an explicit dock intent always wins, even in a narrow
/// portrait window — the video letterboxes beside the panel instead of the
/// queue silently degrading to a floating popup. Maximized (window
/// fullscreen, middle button) DOES show the dock: it only changes the
/// available width so the video shrinks to fit beside the panel.
bool shouldShowPlaylistDock({
  required bool isDesktop,
  required double maxWidth,
  required PlaylistPanelMode mode,
  required bool visible,
  required bool isFullScreen,
  required SideFullscreenBehavior behavior,
  required bool useMetadataSettings,
  required bool legacyStorage,
}) {
  // `maxWidth`/`behavior` kept for call-site compatibility; width no longer
  // gates the dock (see above).
  return isDockIntentVisible(
    isDesktop: isDesktop,
    mode: mode,
    visible: visible,
    isFullScreen: isFullScreen,
    useMetadataSettings: useMetadataSettings,
    legacyStorage: legacyStorage,
  );
}

/// Horizontal chrome the dock adds between the video area and the panel:
/// a 1px hairline divider + the 6px drag splitter. Single source of truth —
/// home's Row layout and the window-resize math must agree or a letterbox
/// gap appears next to the panel.
const double playlistDockChrome = 7.0;

/// Clamps dock width to allowed range and at most half the available width.
double clampPlaylistPanelWidth(double raw, double maxWidth) {
  final double upper = (maxWidth * 0.5).clamp(240.0, 600.0);
  return raw.clamp(240.0, upper);
}

// ── Picture-fullscreen (画面全屏) side-dock overlay ────────────────────────
//
// Strictly scoped: this only affects [PlaylistPanelMode.dockedRight] while
// [isFullScreen] is true. Window fullscreen ([isWindowMaximized]) and windowed
// mode keep the existing side-by-side Row dock untouched; floating popup mode
// keeps its own route. Legacy mode (metadata gate OFF) and the legacy-storage
// backend never enable it.

/// Right-edge hover activation strip width, expressed as a percentage of the
/// playback-area width. A percentage (not px) keeps the summon target ergonomic
/// across DPI and window sizes; the strip is a translucent hit-test only, so it
/// never steals clicks from the video beneath. `0` disables hover summoning
/// (pin mode / leaving picture fullscreen still works).
const double kFullscreenDockEdgeDefaultPct = 10.0;
const double kFullscreenDockEdgeMinPct = 0.0;
const double kFullscreenDockEdgeMaxPct = 50.0;

/// Extra distance the pointer must travel past the panel's left edge before
/// the transient peek hides — a small buffer that prevents flicker when the
/// pointer skirts the boundary.
const double kFullscreenDockHideMargin = 5.0;

/// How long the pointer must stay outside the hover region before the transient
/// peek actually conceals. Absorbs the transient `onExit` that a fullscreen
/// geometry change can emit while the pointer is effectively stationary; without
/// it a conceal re-arms the edge strip under the pointer and the panel loops
/// reveal/conceal forever.
const Duration kFullscreenDockConcealDelay = Duration(milliseconds: 200);

/// Whether a hover-region `onExit` should conceal the panel.
///
/// The pointer did not necessarily leave: a media switch fires a burst of
/// rebuilds and may raise a confirm/progress dialog whose `ModalBarrier` sits
/// above the dock, stealing the hover region while the pointer is still over
/// the list. Such an exit reports a position *inside* the region and must be
/// ignored — otherwise "tap a row to switch video" hides the queue. Only an
/// exit whose position is truly outside the region conceals.
///
/// Both arguments share one coordinate space (the caller converts the global
/// exit position to the region's local space first).
bool shouldConcealAfterExit({
  required Size regionSize,
  required Offset exitLocalPosition,
}) =>
    !(Offset.zero & regionSize).contains(exitLocalPosition);

/// Whether a pointer at [pointer] (global/screen space) sits on the control
/// bar, whose live screen rect is [panelRect].
///
/// The picture-fullscreen dock's right-edge summon strip must NOT fire there:
/// with the one-handed side layout the total panel hugs the very same right
/// edge, so hovering the slider the user was reaching for slid the queue in on
/// top of it. A null rect excludes nothing — the bar is translated off-screen
/// while it is hidden (and other layouts publish no box at all), so the
/// exclusion self-disables exactly when there is no bar to protect.
bool isPointerOverControlPanel({
  required Rect? panelRect,
  required Offset pointer,
}) =>
    panelRect != null && panelRect.contains(pointer);

/// Whether the picture-fullscreen right-edge dock overlay is available.
///
/// Meta-driven desktop dock mode only; the overlay is *independent* of
/// [SideFullscreenBehavior], which now decides whether it starts pinned
/// (keepPanel) or hidden-but-hoverable (hidePanel, the default). This is what
/// makes "画面全屏默认也能呼出 queue" work.
bool isFullscreenDockOverlayEnabled({
  required bool isDesktop,
  required bool useMetadataSettings,
  required PlaylistPanelMode mode,
  required bool isFullScreen,
  required bool legacyStorage,
}) {
  if (!isDesktop) return false;
  if (!useMetadataSettings) return false;
  if (legacyStorage) return false;
  if (mode != PlaylistPanelMode.dockedRight) return false;
  return isFullScreen;
}

/// Initial pinned state when entering picture fullscreen.
bool isFullscreenDockPinnedOnEntry(SideFullscreenBehavior behavior) =>
    behavior == SideFullscreenBehavior.keepPanel;

/// Clamps the configurable edge-activation percentage to its hard bounds.
double clampFullscreenDockEdgePct(double raw) {
  if (raw.isNaN) return kFullscreenDockEdgeDefaultPct;
  return raw.clamp(kFullscreenDockEdgeMinPct, kFullscreenDockEdgeMaxPct);
}

/// Resolves the stored percentage to the pixel strip width for a playback area
/// of [maxWidth]. Non-finite widths (unbounded layouts) degrade to `0`, i.e. no
/// strip, rather than propagating infinity into layout.
double resolveFullscreenDockEdgeWidth({
  required double pct,
  required double maxWidth,
}) {
  if (!maxWidth.isFinite || maxWidth <= 0) return 0;
  return clampFullscreenDockEdgePct(pct) / 100.0 * maxWidth;
}

// ── Control-bar isolation zone (picture-fullscreen queue summon) ───────────
//
// The control bar hugs an edge or grows from the bottom, and the right-edge
// queue summon strip overlaps it. The LIVE control-bar rect
// (`isPointerOverControlPanel`) stops blocking the moment the bar auto-hides:
// it is translated off-screen, so a pointer moved toward the bar popped the
// queue before the user could reach it. This isolation zone is derived from the
// bar's own HEIGHT (its render-box size, which does NOT move when the bar is
// translated) plus a percentage of the area height, so it blocks whether or not
// the bar is currently shown.
//
// Both control-bar shapes share one formula, `height = barHeight + pct% of area`:
//  - the one-handed side-type panel: `barHeight` = the settings-derived panel
//    height (`panelSizeForWindow().panelH`);
//  - the normal long-strip bar: `barHeight` = the bar's measured render height.
// The percentage is user-adjustable (Windows-only rows; see
// `sidePanelIsolationPct` / `linearBarIsolationPct`).

/// Default isolation percentage for the one-handed side-type panel
/// ("side type 隔离不显 5%").
const double kSidePanelIsolationDefaultPct = 5.0;

/// Default isolation percentage for the normal long-strip control bar
/// ("normal 隔离不显 25%").
const double kLinearBarIsolationDefaultPct = 25.0;

/// Hard bounds for the side-panel isolation percentage (0..50).
double clampSidePanelIsolationPct(double raw) => raw.isNaN
    ? kSidePanelIsolationDefaultPct
    : raw.clamp(0.0, 50.0).toDouble();

/// Hard bounds for the normal-bar isolation percentage (0..100).
double clampLinearBarIsolationPct(double raw) => raw.isNaN
    ? kLinearBarIsolationDefaultPct
    : raw.clamp(0.0, 100.0).toDouble();

/// Bottom isolation height for the queue summon strip: the control bar's height
/// plus [pct] of the area height, clamped to `[0, areaHeight]`. A value of 0
/// (or less) disables the isolation zone.
double resolveControlBarIsolationHeight({
  required double controlBarHeight,
  required double areaHeight,
  required double pct,
}) {
  if (!areaHeight.isFinite || areaHeight <= 0) return 0;
  final double height = controlBarHeight + areaHeight * pct / 100.0;
  return height.clamp(0.0, areaHeight).toDouble();
}

/// Whether a pointer at [localY] (0 = top of the playback area) falls in the
/// bottom isolation zone. A non-positive [isolationHeight] never blocks.
bool isPointerInControlBarIsolationZone({
  required double localY,
  required double areaHeight,
  required double isolationHeight,
}) =>
    isolationHeight > 0 && localY >= areaHeight - isolationHeight;
