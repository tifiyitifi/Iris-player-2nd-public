import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/widgets/dialogs/show_slider_type_dialog.dart';

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

Future<void> _pickDropdown(
    WidgetTester tester, Key fieldKey, String label) async {
  await tester.tap(find.byKey(fieldKey));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'merged slider-type dialog: live group 2 while sideway, grayed reset for normal',
      (tester) async {
    await tester.pumpWidget(_harness());
    // Deferred l10n delegates load async — settle once before tapping.
    await tester.pumpAndSettle();
    // Seed after the tree (and its store scope) exists.
    useAppStore().set(const AppState(
      phoneLandscapeUseMode: PhoneLandscapeUseMode.rightSide,
      phoneOneHandedScrubberKind: PhoneSideScrubberKind.dial,
    ));
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Single shell: the draggable card supplies surface + header + close, so
    // there must be no nested AlertDialog and exactly one title.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('侧滑面板设置'), findsOneWidget);

    final AppStore store = useAppStore();

    // ── Group 2 exists and is live while Sideway ──
    expect(find.byKey(const ValueKey('slider-posH-dropdown')), findsOneWidget);
    expect(find.byKey(const ValueKey('slider-posV-dropdown')), findsOneWidget);
    expect(find.byKey(const ValueKey('slider-design-segmented')), findsOneWidget);

    // Horizontal position left → dual-writes the legacy left placement.
    await _pickDropdown(
        tester, const ValueKey('slider-posH-dropdown'), '左');
    expect(store.state.phoneSidePositionH, PhoneSidePositionH.left);
    expect(store.state.phoneLandscapeUseMode, PhoneLandscapeUseMode.leftSide);
    expect(store.state.phoneLandscapeSliderType,
        PhoneLandscapeSliderType.circleLeft);

    // Vertical position top → anchor row only.
    await _pickDropdown(tester, const ValueKey('slider-posV-dropdown'), '上');
    expect(store.state.phoneSidePositionV, PhoneSidePositionV.top);

    // Design segmented flips dial ↔ classic (single-choice enum, extensible).
    await tester.tap(find.text('简易圆弧'));
    await tester.pumpAndSettle();
    expect(store.state.phoneOneHandedScrubberKind,
        PhoneSideScrubberKind.classic);
    await tester.tap(find.text('拨环'));
    await tester.pumpAndSettle();
    expect(store.state.phoneOneHandedScrubberKind, PhoneSideScrubberKind.dial);

    // ── Bottom button-bar position: one shared knob (dial AND circle) bound
    // to the store, living in the common panel section ──
    final Finder barPosSlider = find.byKey(
      const ValueKey<String>('slider-bar-pos-control'),
    );
    expect(barPosSlider, findsOneWidget,
        reason: 'the shared bar-position knob must be present');
    expect(store.state.sidewayBarPos, 0.0);
    await tester.drag(
      find.descendant(of: barPosSlider, matching: find.byType(Slider)),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();
    expect(store.state.sidewayBarPos, greaterThan(0.0),
        reason: 'dragging the knob must move the block position');

    // ── Picking Normal resets side fields and grays group 2 ──
    await _pickDropdown(
        tester, const ValueKey('slider-mode-dropdown'), '普通 · 底部整条');
    expect(store.state.phoneLandscapeUseMode, PhoneLandscapeUseMode.normal);
    expect(
        store.state.phoneLandscapeSliderType, PhoneLandscapeSliderType.normal);

    final bool hasGrayedOpacity = find
        .ancestor(
          of: find.byKey(const ValueKey('slider-posH-dropdown')),
          matching: find.byType(Opacity),
        )
        .evaluate()
        .any((Element e) => (e.widget as Opacity).opacity < 1.0);
    expect(hasGrayedOpacity, isTrue);
  });
}
