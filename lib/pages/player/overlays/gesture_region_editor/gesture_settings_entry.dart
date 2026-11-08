import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iris/models/store/gesture/gesture_region_layout.dart';
import 'package:iris/models/store/gesture_region.dart';
import 'package:iris/pages/player/overlays/gesture_region_editor/gesture_editor_models.dart';
import 'package:iris/pages/player/overlays/gesture_region_editor/gesture_editor_view.dart';
import 'package:iris/pages/player/overlays/gesture_region_editor/gesture_settings_dialog.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyGesture);

/// Resolves profile enum to storage key, orientation-aware.
/// Portrait defaultProfile → portrait key; landscape defaultProfile → landscape region key.
String _profileToKey(GestureProfile profile, bool isLandscape) {
  return switch (profile) {
    GestureProfile.defaultProfile =>
      isLandscape ? kLayoutRegion : kLayoutRegionPortrait,
    GestureProfile.rightSide => kLayoutRegionRightSide,
    GestureProfile.leftSide => kLayoutRegionLeftSide,
    // ignore: deprecated_member_use
    GestureProfile.rightHand => kLayoutRegionRightSide,
    // ignore: deprecated_member_use
    GestureProfile.leftHand => kLayoutRegionLeftSide,
    GestureProfile.tagPlay =>
      isLandscape ? kLayoutRegion : kLayoutRegionPortrait,
  };
}

Future<void> _pushEditor({
  required BuildContext context,
  required NavigatorState navigator,
  required String profileKey,
  required GestureIntent intent,
  required AppStore appStore,
  required bool shouldForceLandscape,
}) async {
  final layout = appStore.state.gestureLayoutProfiles[profileKey]?[intent] ??
      defaultGestureLayoutProfiles[profileKey]![intent]!;
  final lines = LayoutTopology.computeEditableLines(layout);
  if (shouldForceLandscape) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }
  try {
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => GestureEditorOverlay(
          profileKey: profileKey,
          intent: intent,
          initialLayout: layout,
          initialLines: lines,
          allowedActions: getAllowedActions(intent),
          onSave: (newLayout, _) async {
            try {
              await appStore.updateGestureIntentLayout(
                profileKey: profileKey,
                intent: intent,
                layout: newLayout,
              );
            } catch (e) {
              areaKeyLog.e('Failed to save gesture layout: $e');
            } finally {
              navigator.pop();
            }
          },
          onCancel: () => navigator.pop(),
        ),
      ),
    );
  } finally {
    if (shouldForceLandscape) {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }
}

/// Entry point used by General (and anywhere else).
/// Shows orientation-filtered selection dialog, then pushes editor.
Future<void> openGestureRegionSettings(BuildContext context) async {
  final navigator = Navigator.of(context);
  final appStore = useAppStore();

  final runtimeOrientation = appStore.state.runtimeOrientation;
  final realOrientation = MediaQuery.of(context).orientation;
  final bool isLandscape = isLandscapeOrientation(
    runtimeOrientation: runtimeOrientation,
    realOrientation: realOrientation,
  );

  final selection = await showGestureSettingsDialog(
    context,
    isLandscape: isLandscape,
  );
  if (!navigator.mounted || selection == null) return;

  final profileKey = _profileToKey(selection.profile, isLandscape);

  final intent = switch (selection.intent) {
    GestureIntentType.tap => GestureIntent.tap,
    GestureIntentType.doubleTap => GestureIntent.doubleTap,
    GestureIntentType.panVertical => GestureIntent.panVertical,
    GestureIntentType.longPress => GestureIntent.longPress,
  };

  final bool needsLandscape =
      profileKey == kLayoutRegionRightSide || profileKey == kLayoutRegionLeftSide;
  final bool shouldForceLandscape = needsLandscape && !isLandscape;

  await _pushEditor(
    context: context,
    navigator: navigator,
    profileKey: profileKey,
    intent: intent,
    appStore: appStore,
    shouldForceLandscape: shouldForceLandscape,
  );
}

/// Direct entry: bypasses selection dialog, uses the currently effective
/// profile+intent from the gesture guide. Respects orientation isolation:
/// a portrait guide never pushes a landscape/right/left editor.
Future<void> openGestureRegionEditorDirectly(
  BuildContext context, {
  required String profileKey,
  required GestureIntent intent,
}) async {
  final navigator = Navigator.of(context);
  final appStore = useAppStore();
  final runtimeOrientation = appStore.state.runtimeOrientation;
  final realOrientation = MediaQuery.of(context).orientation;
  final bool isLandscape = isLandscapeOrientation(
    runtimeOrientation: runtimeOrientation,
    realOrientation: realOrientation,
  );
  // Orientation guard: portrait must stay portrait, landscape must stay landscape/right/left.
  if (!isLandscape && profileKey != kLayoutRegionPortrait) return;
  if (isLandscape && profileKey == kLayoutRegionPortrait) return;
  final bool needsLandscape =
      profileKey == kLayoutRegionRightSide || profileKey == kLayoutRegionLeftSide;
  final bool shouldForceLandscape = needsLandscape && !isLandscape;
  await _pushEditor(
    context: context,
    navigator: navigator,
    profileKey: profileKey,
    intent: intent,
    appStore: appStore,
    shouldForceLandscape: shouldForceLandscape,
  );
}

/// The actions the editor may assign to [intent].
///
/// Must be TOTAL over [GestureIntent]: the phone gesture guide's pencil opens
/// this editor directly for every page it shows (pan / long-press-pan pages
/// included), so a missing case is a reachable build failure, not a dead
/// branch. Each list must also contain every action the default layouts
/// configure for that intent, or the picker could not even display the current
/// value (`test/gesture_allowed_actions_test.dart` pins both rules).
List<GestureActionType> getAllowedActions(GestureIntent intent) {
  switch (intent) {
    case GestureIntent.tap:
      // `none` is allowed (single-hand dead zone under the holding thumb)
      // but a layout with zero `toggleControls` is rejected at save time —
      // otherwise the control bar could never be summoned again.
      return [GestureActionType.toggleControls, GestureActionType.none];
    case GestureIntent.doubleTap:
      return [
        GestureActionType.none,
        GestureActionType.playPause,
        GestureActionType.seekForward,
        GestureActionType.seekBackward,
        GestureActionType.openTagPlaySheet,
      ];
    case GestureIntent.panVertical:
      return [
        GestureActionType.none,
        GestureActionType.adjustBrightness,
        GestureActionType.adjustSeekStep,
        GestureActionType.adjustVolume,
      ];
    case GestureIntent.longPress:
      return [
        GestureActionType.none,
        GestureActionType.activateTransientSpeed,
        GestureActionType.showPlaybackRateSelector,
      ];
    case GestureIntent.panHorizontal:
      // A horizontal drag feeds `dx` to the timeline (see the `seekTo`
      // executor). The vertical adjusters read `dy`, so they would barely react
      // to a horizontal vector and are deliberately not offered.
      return [
        GestureActionType.none,
        GestureActionType.seekTo,
      ];
    case GestureIntent.longPressPanHorizontal:
    case GestureIntent.longPressPanVertical:
      // The long press arms a speed gesture; this pan keeps updating it.
      return [
        GestureActionType.none,
        GestureActionType.updateTransientSpeed,
        GestureActionType.updatePlaybackRateFromSelector,
      ];
    case GestureIntent.hover:
      // Desktop hover is a discrete "point at the picture" gesture; the default
      // (and only shipped use) is summoning the controls.
      return [
        GestureActionType.none,
        GestureActionType.toggleControls,
      ];
  }
}
