import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/platform.dart' show debugIsMobilePlatformOverride;
import 'package:iris/widgets/dialogs/show_slider_type_dialog.dart';

/// A `left`/`right` side mode plus the legacy `circleLeft`/`circleRight`
/// placement are the SAME decision written to two different fields, and
/// `PhoneLandscapeSliderType` is still persisted in the legacy blob. Writing
/// one without the other is what let the two states drift apart, so both
/// setters now dual-write and this test pins the invariant.
void main() {
  Widget harness() => StoreScope(
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (BuildContext context) => TextButton(
                  onPressed: () => showSliderTypeDialog(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

  Future<void> pickDropdown(
      WidgetTester tester, Key fieldKey, String label) async {
    await tester.tap(find.byKey(fieldKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('picking a desktop side keeps mode and slider type in lockstep',
      (tester) async {
    debugIsMobilePlatformOverride = false;
    addTearDown(() => debugIsMobilePlatformOverride = null);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    useAppStore().set(const AppState(
      useMetadataSettings: true,
      phoneLandscapeUseMode: PhoneLandscapeUseMode.rightSide,
      phoneSidePositionH: PhoneSidePositionH.right,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await pickDropdown(tester, const ValueKey('slider-posH-dropdown'), '左');
    final AppState afterLeft = useAppStore().state;
    expect(afterLeft.phoneSidePositionH, PhoneSidePositionH.left);
    expect(afterLeft.phoneLandscapeUseMode, PhoneLandscapeUseMode.leftSide);
    expect(afterLeft.phoneLandscapeSliderType,
        PhoneLandscapeSliderType.circleLeft,
        reason: 'the legacy circle placement must follow the side, or the '
            'stale right-corner value steers resolveControlPanelAnchor');

    await pickDropdown(tester, const ValueKey('slider-posH-dropdown'), '右');
    final AppState afterRight = useAppStore().state;
    expect(afterRight.phoneLandscapeUseMode, PhoneLandscapeUseMode.rightSide);
    expect(afterRight.phoneLandscapeSliderType,
        PhoneLandscapeSliderType.circleRight);
  });

  testWidgets('turning the sideway mode off resets the legacy placement',
      (tester) async {
    debugIsMobilePlatformOverride = false;
    addTearDown(() => debugIsMobilePlatformOverride = null);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    useAppStore().set(const AppState(
      useMetadataSettings: true,
      phoneLandscapeUseMode: PhoneLandscapeUseMode.leftSide,
      phoneSidePositionH: PhoneSidePositionH.left,
      phoneLandscapeSliderType: PhoneLandscapeSliderType.circleLeft,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await pickDropdown(
        tester, const ValueKey('slider-mode-dropdown'), '普通 · 底部整条');
    final AppState after = useAppStore().state;
    expect(after.phoneLandscapeUseMode, PhoneLandscapeUseMode.normal);
    expect(after.phoneLandscapeSliderType, PhoneLandscapeSliderType.normal,
        reason: 'normal mode must not leave a circle corner behind');
  });
}
