import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/utils/platform.dart' show debugIsMobilePlatformOverride;

/// The corner-hide direction is stored PER PLATFORM and each platform offers an
/// entry for its own row only, so [resolveSidePanelCornerHideMode] is the one
/// place that says which value the overlay obeys.
///
/// Before the split a single shared row drove both: a desktop choice reached a
/// phone through the settings transfer, and the phone — whose panel is always
/// corner-anchored, so the value is genuinely live there — had no way to change
/// it back. That unrecoverable state is what the split removes.
void main() {
  void runOn({required bool phone}) {
    debugIsMobilePlatformOverride = phone;
    addTearDown(() => debugIsMobilePlatformOverride = null);
  }

  const AppState split = AppState(
    sidePanelCornerHideMode: SidePanelCornerHideMode.diagonal,
    mobileSidePanelCornerHideMode: SidePanelCornerHideMode.horizontal,
  );

  group('resolveSidePanelCornerHideMode — each platform reads its own row', () {
    test('a phone obeys the phone row and ignores the desktop one', () {
      runOn(phone: true);
      expect(
        resolveSidePanelCornerHideMode(split),
        SidePanelCornerHideMode.horizontal,
      );
    });

    test('the desktop obeys the desktop row and ignores the phone one', () {
      runOn(phone: false);
      expect(
        resolveSidePanelCornerHideMode(split),
        SidePanelCornerHideMode.diagonal,
      );
    });

    test('the AppState overload delegates to the narrow-slice one', () {
      runOn(phone: true);
      expect(
        resolveSidePanelCornerHideMode(split),
        resolveSidePanelCornerHideModeFrom(
          isPhone: true,
          desktop: split.sidePanelCornerHideMode,
          phone: split.mobileSidePanelCornerHideMode,
        ),
      );
      runOn(phone: false);
      expect(
        resolveSidePanelCornerHideMode(split),
        resolveSidePanelCornerHideModeFrom(
          isPhone: false,
          desktop: split.sidePanelCornerHideMode,
          phone: split.mobileSidePanelCornerHideMode,
        ),
      );
    });
  });

  group('a fresh install defaults both rows to the vertical drop', () {
    test('neither platform starts on a non-default direction', () {
      expect(const AppState().sidePanelCornerHideMode,
          SidePanelCornerHideMode.vertical);
      expect(const AppState().mobileSidePanelCornerHideMode,
          SidePanelCornerHideMode.vertical);
    });
  });
}
