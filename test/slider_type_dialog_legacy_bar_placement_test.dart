import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart'
    show PhoneLandscapeUseModeHelper, isSidewayPanelMounted;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/dialogs/show_slider_type_dialog.dart';

/// The slider-type card is confined to the strip BESIDE the side panel so the
/// control it edits stays visible — but only when a side panel is really on
/// screen. `isSidewayPanelMounted` alone over-reports: it asks what a one-handed
/// mode would mount, while the bar actually rendering is chosen separately
/// (`useLegacy ? LegacyControlBar : ControlBar`), and `LegacyControlBar` is a
/// full-width linear layout. `useLegacyControlBar` has no gate on it, so the
/// combination is one tap away in the legacy-compat dialog, and the card then
/// squeezed itself into a strip avoiding nothing — the same class of phantom
/// dodge that a phone in portrait already had a guard against.
///
/// A phone-portrait counterpart lives in
/// `slider_type_dialog_phone_placement_test.dart`; one `testWidgets` per file,
/// because `StoreScope.dispose()` disposes every store the locator manages and a
/// later case could then only mutate a closed store.
Widget _harness() {
  return StoreScope(
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
}

void main() {
  testWidgets(
      'legacy control bar: a one-handed mode must not squeeze the card into a '
      'strip avoiding nothing', (tester) async {
    // BOTH seams: the panel's host gate reads `isDesktop`, so leaving it true on
    // this desktop runner would answer with the runner's own platform.
    debugIsMobilePlatformOverride = true;
    debugIsDesktopOverride = false;
    addTearDown(() {
      debugIsMobilePlatformOverride = null;
      debugIsDesktopOverride = null;
    });
    tester.view.physicalSize = const Size(1600, 720); // logical 800 x 360
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    // 70% of 800 leaves a 240px strip — narrower than the card's own 380, so
    // the phantom dodge is observable in the card's WIDTH. A slimmer panel
    // (the 40% the sibling test uses) leaves 480px and would leave the card
    // untouched, which is why this case would pass either way.
    useAppStore().set(const AppState(
      useMetadataSettings: true,
      useLegacyControlBar: true,
      phoneLandscapeUseMode: PhoneLandscapeUseMode.rightSide,
      mobileSidePositionH: PhoneSidePositionH.right,
      sidewayPanelWidthPct: 70,
      sidewayPanelHeightPct: 90,
    ));
    await tester.pump();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The legacy bar is a full-width linear layout, so the whole safe screen is
    // free: the card keeps its full 380 width instead of being cut down to the
    // 240px strip left of a panel that is not there.
    final Rect card =
        tester.getRect(find.byKey(const Key('side-slider-panel-card')));
    expect(card.width, 380,
        reason: 'no side panel on screen — no strip, no squeeze');

    // Precondition, so the case cannot pass for the wrong reason: the stored
    // mode really is one-handed and really would mount a panel on the real bar.
    expect(useAppStore().state.phoneLandscapeUseMode.usesOneHandedControls,
        isTrue);
    expect(
      isSidewayPanelMounted(
        oneHanded: true,
        isPhone: isMobilePlatform,
        isLandscape: true,
      ),
      isTrue,
      reason: 'the bare mount gate still says yes — only the layout gate can '
          'know the legacy bar is what renders',
    );
  });
}
