import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/dialogs/show_slider_type_dialog.dart';

/// The card is POSITIONED by its parent (`Positioned(left: initialTopLeft)`,
/// derived from the stored fraction + the free region), while the card itself
/// keeps a private `topLeft` that only the header pan reads and writes. The
/// parent's copy is re-derived on every rebuild, so it always tracks the
/// region; the private one is a `useState` seed that only its own effect
/// touches — and that effect CLAMPED the stale value instead of adopting where
/// the parent had actually put the card.
///
/// The two therefore drifted apart as soon as the region moved (a 9-grid
/// re-anchor from inside this very dialog), and the drift surfaced on the next
/// header drag: the card snapped to the stale base before following the finger.
/// It also left the persisted fraction describing a spot the card was no
/// longer at.
///
/// Desktop is the only host that can re-anchor horizontally here (the phone
/// offers left/right segments), and a 260px panel against an 800px window makes
/// the drift large enough to assert on.
///
/// One `testWidgets` on purpose: `StoreScope.dispose()` disposes every store the
/// locator manages, so a second test in this file could only mutate a closed
/// store.
void main() {
  // 1:1 so the logical size IS the geometry the panel rect is derived from.
  const Size screen = Size(800, 360);
  const Key cardKey = Key('side-slider-panel-card');

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

  testWidgets(
      're-anchoring the panel must not make the next header drag snap',
      (tester) async {
    // Pin the seam so "phone" and "desktop" can never both be true (only the
    // seam can do that); the default runner already answers desktop.
    debugIsMobilePlatformOverride = false;
    addTearDown(() => debugIsMobilePlatformOverride = null);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = screen;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    useAppStore().set(const AppState(
      useMetadataSettings: true,
      phoneLandscapeUseMode: PhoneLandscapeUseMode.rightSide,
      phoneSidePositionH: PhoneSidePositionH.right,
      phoneSidePositionV: PhoneSidePositionV.bottom,
      sidewayPanelWidthPx: 260,
      sidewayPanelHeightPx: 320,
    ));
    // No 副音 strip: its attachment widens the footprint and would make the
    // drift depend on the background store's default as well.
    useBackgroundPlaybackStore().set(
        useBackgroundPlaybackStore().state.copyWith(quickBarEnabled: false));
    await tester.pump();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final double docked = tester.getRect(find.byKey(cardKey)).left;

    // Re-anchor from under the card's own feet, through the store rather than
    // the dropdown: the dialog subscribes to the 9-grid either way, and this
    // keeps the case free of localized labels.
    useAppStore().set(useAppStore()
        .state
        .copyWith(phoneSidePositionH: PhoneSidePositionH.left));
    await tester.pumpAndSettle();
    final double moved = tester.getRect(find.byKey(cardKey)).left;
    expect(moved, isNot(closeTo(docked, 1.0)),
        reason: 'precondition: the free strip really moved, so the card has '
            'two disagreeing positions to choose between');

    // The first header drag after the move must continue from where the card
    // actually IS, not from the stale base its own state was holding.
    await tester.drag(
        find.byIcon(Icons.drag_indicator_rounded), const Offset(10, 0));
    await tester.pumpAndSettle();
    final double dragged = tester.getRect(find.byKey(cardKey)).left;
    expect(dragged, closeTo(moved + 10, 1.0),
        reason: 'the card has to follow the finger from its rendered position');
  });
}
