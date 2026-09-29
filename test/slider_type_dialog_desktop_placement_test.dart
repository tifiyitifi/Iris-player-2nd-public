import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/sideway_panel_layout.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/dialogs/show_slider_type_dialog.dart';

// Desktop mounts the side panel in EITHER orientation, anchored by the 9-grid
// the dialog itself edits — so its free region has to follow that anchor and
// clear the 副音 strip the layout magnetically attaches to the panel's
// centre-facing side.
//
// One `testWidgets` on purpose: `StoreScope.dispose()` disposes every store the
// locator manages, so a second test in this file could only mutate a closed
// store.
void main() {
  // A deliberately SMALL window: the 380px panel plus its 副音 strip eat 492px
  // of it, so a card that ignores the panel really does land on top of it (in a
  // wide window the centred card would dodge it by luck and prove nothing).
  const Size screen = Size(900, 700);
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

  Rect panelFor(Alignment anchor) => sidePanelRectForWindow(
        windowSize: screen,
        anchor: anchor,
        isPhone: false,
        widthPct: 40,
        heightPct: 90,
        widthPx: 380,
        heightPx: 420,
      );

  /// Panel box plus the 副音 strip on its centre-facing side, sized from the
  /// layout's own budget: 420px of panel height fits 8 rows, so the 10 actions
  /// need the strip's 2-column cap (108px).
  Rect footprintFor(Alignment anchor, {required bool quickBar}) {
    final Rect panel = panelFor(anchor);
    if (!quickBar) return panel;
    final double extra = kSidewayQuickGap +
        sidewayQuickColumnWidth(
          quickAvail: sidewayQuickAvailWidth(
              layoutWidth: screen.width, panelW: panel.width),
          panelH: panel.height,
        );
    return anchor.x > 0
        ? Rect.fromLTRB(panel.left - extra, panel.top, panel.right, panel.bottom)
        : Rect.fromLTRB(panel.left, panel.top, panel.right + extra, panel.bottom);
  }

  testWidgets('the free region mirrors the real desktop panel footprint',
      (tester) async {
    // The test host is a desktop; pin the seam so "phone" and "desktop" can
    // never both be true (only the seam can do that).
    debugIsMobilePlatformOverride = false;
    addTearDown(() => debugIsMobilePlatformOverride = null);
    // 1:1 so `screen` IS the logical size the panel geometry is derived from
    // (the default dpr of 3 would shrink the window under the panel).
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = screen;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    useAppStore().set(const AppState(
      useMetadataSettings: true,
      phoneLandscapeUseMode: PhoneLandscapeUseMode.rightSide,
      phoneSidePositionH: PhoneSidePositionH.left,
      phoneSidePositionV: PhoneSidePositionV.bottom,
    ));
    useBackgroundPlaybackStore().set(
        useBackgroundPlaybackStore().state.copyWith(quickBarEnabled: true));
    await tester.pump();

    // ── Panel docked LEFT, 副音 strip attached ───────────────────────────
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final Rect left = tester.getRect(find.byKey(cardKey));
    expect(left.overlaps(footprintFor(Alignment.bottomLeft, quickBar: true)),
        isFalse,
        reason: 'the panel the dialog edits must stay visible');
    expect(
        left.left,
        greaterThanOrEqualTo(
            footprintFor(Alignment.bottomLeft, quickBar: true).right),
        reason: 'the 副音 strip hangs LEFT of a left-docked panel, so clearing '
            'the panel box alone is not enough');

    // ── Re-anchor RIGHT from inside the dialog ───────────────────────────
    // The parent must subscribe to the DESKTOP 9-grid, not just the phone-side
    // one, or the region stays frozen on the old strip.
    await tester
        .tap(find.byKey(const ValueKey<String>('slider-posH-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('右'));
    await tester.pumpAndSettle();
    expect(useAppStore().state.phoneSidePositionH, PhoneSidePositionH.right,
        reason: 'sanity: the dropdown really moved the anchor');

    final Rect right = tester.getRect(find.byKey(cardKey));
    expect(
        right.overlaps(footprintFor(Alignment.bottomRight, quickBar: true)),
        isFalse);
    expect(
        right.right,
        lessThanOrEqualTo(
            footprintFor(Alignment.bottomRight, quickBar: true).left));

    // ── 副音 strip switched off: no column is reserved any more ──────────
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    useBackgroundPlaybackStore().set(
        useBackgroundPlaybackStore().state.copyWith(quickBarEnabled: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final Rect noStrip = tester.getRect(find.byKey(cardKey));
    expect(
        noStrip.overlaps(footprintFor(Alignment.bottomRight, quickBar: false)),
        isFalse);
    expect(
        noStrip.left,
        lessThan(
            footprintFor(Alignment.bottomRight, quickBar: true).left),
        reason: 'a hidden 副音 strip must hand its width back to the card');
  });
}
