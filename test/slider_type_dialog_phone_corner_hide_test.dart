import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/dialogs/show_slider_type_dialog.dart';

/// A phone MUST be able to change the corner-hide direction.
///
/// The segment used to be hidden behind `if (!isPhone)` while the overlay
/// obeyed the value regardless — and because the row was shared with the
/// desktop, a desktop choice could even reach a phone through the settings
/// transfer, leaving the panel sliding in a direction the phone could not undo.
///
/// One `testWidgets` on purpose: `StoreScope.dispose()` disposes every store the
/// locator manages, so a second test here could only mutate a closed store.
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
  testWidgets('a phone gets the corner-hide entry, and it writes its own row',
      (tester) async {
    debugIsMobilePlatformOverride = true;
    addTearDown(() => debugIsMobilePlatformOverride = null);
    tester.view.physicalSize = const Size(1600, 720); // logical 800 x 360
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    // The desktop row already holds a non-default value, as it would after the
    // user set it on a PC — the phone must neither show nor touch it.
    useAppStore().set(const AppState(
      useMetadataSettings: true,
      phoneLandscapeUseMode: PhoneLandscapeUseMode.rightSide,
      mobileSidePositionH: PhoneSidePositionH.right,
      sidePanelCornerHideMode: SidePanelCornerHideMode.horizontal,
    ));
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The entry exists on a phone, and it shows the PHONE value (vertical),
    // not the desktop row it is about to overwrite.
    final Finder segment = find
        .byKey(const ValueKey<String>('slider-corner-hide-mode'));
    expect(segment, findsOneWidget,
        reason: 'a phone panel is always corner-anchored, so this is live there');
    final SegmentedButton<SidePanelCornerHideMode> button =
        tester.widget<SegmentedButton<SidePanelCornerHideMode>>(segment);
    expect(button.selected, <SidePanelCornerHideMode>{
      SidePanelCornerHideMode.vertical,
    });

    // It lives inside the scrollable card, below the fold in a 360px-tall
    // landscape strip, so it has to be scrolled into view before tapping.
    await tester.ensureVisible(segment);
    await tester.pumpAndSettle();
    await tester.tap(find.text('对角'));
    await tester.pumpAndSettle();

    final AppStore store = useAppStore();
    expect(store.state.mobileSidePanelCornerHideMode,
        SidePanelCornerHideMode.diagonal);
    expect(store.state.sidePanelCornerHideMode,
        SidePanelCornerHideMode.horizontal,
        reason: 'the phone write must leave the desktop row alone');
  });
}
