import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';

/// The factory defaults must be self-consistent.
///
/// A fresh install ships the right-side one-handed panel, so
/// `phoneLandscapeUseMode` defaults to [PhoneLandscapeUseMode.rightSide] and
/// `phoneLandscapeSliderType` to [PhoneLandscapeSliderType.circleRight]. The
/// slider type is derived from the mode, so the two must stay paired — an
/// unpaired default renders a placement no UI choice can reach again.
void main() {
  test('the default state is a pair the UI can actually express', () {
    const AppState fresh = AppState();

    expect(
      fresh.phoneLandscapeUseMode.usesOneHandedControls,
      isTrue,
      reason: 'a fresh install starts on the right-side one-handed panel',
    );
    expect(
      fresh.phoneLandscapeSliderType,
      PhoneLandscapeSliderType.circleRight,
      reason: 'the right-side mode must pair with the right circle corner',
    );
    expect(
      fresh.landscapeGestureProfile,
      LandscapeGestureProfile.rightSide,
      reason: 'fresh-install landscape gestures default to the right side',
    );
  });
}
