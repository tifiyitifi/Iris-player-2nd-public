import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';

/// The factory defaults must be self-consistent.
///
/// `phoneLandscapeUseMode` defaults to [PhoneLandscapeUseMode.normal] while
/// `phoneLandscapeSliderType` defaults to
/// [PhoneLandscapeSliderType.circleRight] — so a brand-new install rendered a
/// right-docked circle slider while the settings dialog read "normal", a pair
/// no UI choice could reach again. The slider type is now derived from the
/// mode, so the default must follow.
void main() {
  test('the default state is a pair the UI can actually express', () {
    const AppState fresh = AppState();

    expect(
      fresh.phoneLandscapeUseMode.usesOneHandedControls,
      isFalse,
      reason: 'a fresh install starts on the normal (non-one-handed) bar',
    );
    expect(
      fresh.phoneLandscapeSliderType,
      PhoneLandscapeSliderType.normal,
      reason: 'normal mode must not ship a legacy circle corner',
    );
  });
}
