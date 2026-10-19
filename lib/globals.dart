// ignore: unnecessary_library_name
library my_app.globals;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

List<String> arguments = [];
String? initUri;

/// Desktop-entry launch latch (app_identity feature): set during startup
/// from the Android shortcut intent; consumed exactly once by the launch
/// router in Home.
String? entryLaunchId;

/// Live storage-permission state.
///
/// A `ValueNotifier` (not a bare variable) because the file browser has to
/// SWITCH to the grant surface the moment access is discovered to be denied
/// (see `StorageBrowserDataSource.loadFromStorage`) and back once the user
/// grants it. Widgets listen to [storagePermissionStatusNotifier]; the
/// [storagePermissionStatus] getter/setter keeps the historical call shape.
final ValueNotifier<PermissionStatus?> storagePermissionStatusNotifier =
    ValueNotifier<PermissionStatus?>(null);

PermissionStatus? get storagePermissionStatus =>
    storagePermissionStatusNotifier.value;

set storagePermissionStatus(PermissionStatus? status) {
  if (storagePermissionStatusNotifier.value == status) return;
  storagePermissionStatusNotifier.value = status;
}

/// Live key of the MORE / rate popup-menu buttons, published by the button that
/// is actually mounted (see [usePublishedGlobalKey] for why these are per-mount
/// rather than shared). The keyboard shortcuts open whichever button is live.
final ValueNotifier<GlobalKey<PopupMenuButtonState>?> moreMenuKeyNotifier =
    ValueNotifier<GlobalKey<PopupMenuButtonState>?>(null);
final ValueNotifier<GlobalKey<PopupMenuButtonState>?> rateMenuKeyNotifier =
    ValueNotifier<GlobalKey<PopupMenuButtonState>?>(null);

/// Live key of the one-handed side PANEL box, published by
/// `CircleSliderLayout` while the panel is mounted (null otherwise).
///
/// Readers take a fresh lookup at use time (`value?.currentContext`) exactly
/// like a shared key would: `showRingDialStyleControlPopover` /
/// `showCircleStyleControlPopover` anchor their cards to the panel's
/// centre-facing edge.
///
/// WHY a published PER-MOUNT key instead of one shared [GlobalKey]
/// (flutter/flutter #177693 / #188500, the #182444 family): a shared key lets a
/// NEW panel element re-take the OLD, deactivated one
/// (`Element._retakeInactiveElement`, framework.dart:4481 — it even steals a
/// still-active child). Re-activating it re-activates every `OverlayPortal`
/// inside (the buttons' Tooltips, a Slider's value indicator), and
/// `_OverlayPortalElement.activate` grafts the deferred child into the root
/// overlay BEFORE the new parent is attached, so the mutation lands with no
/// actively-laying-out ancestor: `_RenderLayoutBuilder was mutated in
/// performLayout`, then a poisoned element tree
/// (`Lost connection to device`, bogus `RenderFlex overflowed by 97890
/// pixels`). A per-mount key object can never be re-taken, so the panel always
/// mounts fresh and nothing is ever re-activated.
final ValueNotifier<GlobalKey?> sidePanelKeyNotifier =
    ValueNotifier<GlobalKey?>(null);

/// Width of the zone the one-handed control bar is ACTUALLY laid out in, as
/// `CircleSliderLayout` sees it (its own bounded `constraints.maxWidth`).
/// Null while no side bar is mounted.
///
/// WHY a width and not the panel's screen-space rect: the 副音 quick strip's
/// cross-axis budget is derived from this, and a docked playlist shrinks the
/// bar's zone below the window width — so a consumer that re-derives the panel
/// footprint (the side-panel settings dialog) must read the real zone or it
/// reserves a strip the layout dropped or sized for a wider one.
///
/// WHY a width and not a measured `localToGlobal` rect: the bar's hide
/// animation slides the panel off screen but never changes the zone it is laid
/// out in, so a width can never be fooled by a panel that is mid-hide — whereas
/// a rect would drag the dialog's free region off with it.
final ValueNotifier<double?> sidePanelLayoutWidthNotifier =
    ValueNotifier<double?>(null);

/// Whether the one-handed side panel currently carries the magnetically
/// attached 副音 quick column (published by `CircleSliderLayout`; false while no
/// side panel is mounted).
///
/// The 副音 control group and this column are two routes to the same controls:
/// while the column is attached the floating bottom-group switch button is
/// redundant and would overlap the strip, so it stands down (see
/// `ControlGroupFloatingButton`). The column's own decision chain (feature gate,
/// `quickBarEnabled`, the active control group, the cross-axis budget) already
/// excludes phones, so the flag is desktop-only by construction — the SAME
/// `showsSidewayQuickColumn` call the layout renders from, never a re-derivation.
final ValueNotifier<bool> sidewayQuickColumnAttachedNotifier =
    ValueNotifier<bool>(false);

/// The APB align editor's own side-panel box.
///
/// The editor and the normal one-handed panel are mutually exclusive subtrees
/// rendered by `ControlsOverlay`; a per-mount key keeps the editor subtree
/// purely mount/unmount — never an activation (see [usePublishedGlobalKey]).
final ValueNotifier<GlobalKey?> apbEditorPanelKeyNotifier =
    ValueNotifier<GlobalKey?>(null);

/// Live key of the shared CONTROL BAR panel box (the one-handed side total
/// panel, or the linear bottom bar), published by `ControlsOverlay` while it is
/// mounted (null otherwise).
///
/// The picture-fullscreen playlist dock reads it to EXCLUDE the bar from its
/// right-edge summon strip: the side panel is anchored against that same edge,
/// so hovering its slider used to summon the queue over the very control the
/// user was operating. Because the bar is translated off-screen while hidden,
/// the published box reports an off-screen rect at that point and the exclusion
/// self-disables.
final ValueNotifier<GlobalKey?> controlPanelKeyNotifier =
    ValueNotifier<GlobalKey?>(null);

/// Bottom isolation height (logical px) of the current CONTROL BAR, published
/// by `ControlsOverlay` while a bar is in play (null otherwise).
///
/// The picture-fullscreen playlist dock's right-edge summon strip suppresses
/// reveal inside this band whether or not the bar is currently shown: the bar's
/// LIVE rect slides off-screen when it auto-hides, so the live-rect exclusion
/// alone let a pointer moved toward the bar pop the queue before the user could
/// reach its control. The zone applies only while the queue is HIDDEN — once it
/// is shown, the pointer over the list behaves as before. Value = the bar's
/// height + a settings percentage of the area height; see
/// `resolveControlBarIsolationHeight` (`sidePanelIsolationPct` /
/// `linearBarIsolationPct`).
final ValueNotifier<double?> controlBarIsolationHeightNotifier =
    ValueNotifier<double?>(null);

const double speedSelectorItemWidth = 64.0;
const List<double> speedStops = [
  0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, //
  1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9,
  2.0, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9,
  3.0, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9,
  4.0, 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8, 4.9,
  5.0, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9,
  6.0, 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7, 6.8, 6.9,
  7.0, 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.8, 7.9,
  8.0, 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7, 8.8, 8.9,
  9.0, 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7, 9.8, 9.9,
  10.0,
];
