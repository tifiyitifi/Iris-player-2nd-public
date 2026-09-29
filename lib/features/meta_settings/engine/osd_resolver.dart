import 'package:flutter/widgets.dart' show Alignment;
import 'package:iris/models/store/app_state.dart';

// Pure resolver for the PotPlayer-style keyboard OSD.
// Follows the same contract as `resolveBrowseMediaScope`:
// when the metadata gate is OFF, the OSD degrades to hidden.

bool resolveOsdEnabled(AppState state, bool metadataEnabled) =>
    metadataEnabled ? state.osdEnabled : false;

bool resolveOsdShouldShow(
  AppState state,
  bool metadataEnabled, {
  required bool isShowControl,
}) =>
    resolveOsdShouldShowFrom(
      osdEnabled: state.osdEnabled,
      visibilityMode: state.osdVisibilityMode,
      metadataEnabled: metadataEnabled,
      isShowControl: isShowControl,
    );

/// [resolveOsdShouldShow] over already-selected fields. The AppState overload
/// delegates here — this stays the single authority.
///
/// Lets the toast subscribe to a record of fields instead of the whole state, so
/// an AppState mutation it does not read (the per-frame gesture writes, a volume
/// or rate change) does not rebuild it.
bool resolveOsdShouldShowFrom({
  required bool osdEnabled,
  required OsdVisibilityMode visibilityMode,
  required bool metadataEnabled,
  required bool isShowControl,
}) {
  if (!metadataEnabled || !osdEnabled) return false;
  if (visibilityMode == OsdVisibilityMode.hideWhenControlVisible &&
      isShowControl) {
    return false;
  }
  return true;
}

Alignment resolveOsdAlignment(OsdHAlign h, OsdVAlign v) {
  final double x = switch (h) {
    OsdHAlign.left => -1.0,
    OsdHAlign.center => 0.0,
    OsdHAlign.right => 1.0,
  };
  final double y = switch (v) {
    OsdVAlign.top => -1.0,
    OsdVAlign.middle => 0.0,
    OsdVAlign.bottom => 1.0,
  };
  return Alignment(x, y);
}
