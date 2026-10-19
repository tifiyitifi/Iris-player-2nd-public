import 'package:flutter/material.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/utils/platform.dart';

import 'center_zone.dart';

/// Icon shown in one X-divided center sector for its configured action.
///
/// `none` maps to null so the sector stays empty; every other action maps to
/// the icon of the function button it triggers — except `toggleControls`, which
/// deliberately draws nothing: it is the legacy default of ALL four sectors, so
/// a glyph there only crowded the readout with four copies of the same hint
/// while the tap behavior is unchanged.
IconData? centerZoneActionIcon(CircleSliderCenterAction action) {
  return switch (action) {
    CircleSliderCenterAction.none => null,
    CircleSliderCenterAction.toggleControls => null,
    CircleSliderCenterAction.togglePlayPause => Icons.play_arrow_rounded,
    CircleSliderCenterAction.switchControlGroup => Icons.swap_horiz_rounded,
  };
}

/// Pixel offset of a sector icon from the hit-circle center.
///
/// [zone] is the logical zone; [inwardOnLeft] folds the logical
/// inward/outward pair onto the screen left/right (see [centerZoneForOffset]).
/// Top/bottom never mirror.
Offset centerZoneIconOffset({
  required CenterZone zone,
  required bool inwardOnLeft,
  required double radius,
}) {
  return switch (zone) {
    CenterZone.top => Offset(0, -radius),
    CenterZone.bottom => Offset(0, radius),
    CenterZone.inward =>
      inwardOnLeft ? Offset(-radius, 0) : Offset(radius, 0),
    CenterZone.outward =>
      inwardOnLeft ? Offset(radius, 0) : Offset(-radius, 0),
  };
}

/// Orbit radius for sector icons: midway between the readout hole and the
/// hit-circle edge, so icons sit on the X arms' free span without touching
/// the center time text.
double centerZoneIconOrbitRadius({
  required double hitRadius,
  required double gapRadius,
}) {
  if (hitRadius <= 0) return 0;
  final double inner = gapRadius.clamp(0.0, hitRadius).toDouble();
  return (inner + hitRadius) / 2;
}

/// Resolves all four sectors through the single [resolveCenterZoneAction]
/// rule (desktop legacy all-toggleControls unless phone/phone-mode).
///
/// Exists so the dial and the classic circle share one resolution without
/// each building a throwaway [AppState]; logic stays in [resolveCenterZoneAction].
Map<CenterZone, CircleSliderCenterAction> resolveCenterZoneActionMap({
  required CircleSliderCenterAction inward,
  required CircleSliderCenterAction outward,
  required CircleSliderCenterAction top,
  required CircleSliderCenterAction bottom,
  required bool desktopPhoneMode,
  bool? isMobileOverride,
}) {
  final bool phone = isMobileOverride ?? isMobilePlatform;
  if (!phone && !desktopPhoneMode) {
    return const <CenterZone, CircleSliderCenterAction>{
      CenterZone.inward: CircleSliderCenterAction.toggleControls,
      CenterZone.outward: CircleSliderCenterAction.toggleControls,
      CenterZone.top: CircleSliderCenterAction.toggleControls,
      CenterZone.bottom: CircleSliderCenterAction.toggleControls,
    };
  }
  return <CenterZone, CircleSliderCenterAction>{
    CenterZone.inward: inward,
    CenterZone.outward: outward,
    CenterZone.top: top,
    CenterZone.bottom: bottom,
  };
}
