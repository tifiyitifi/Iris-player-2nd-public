import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/video_transform/model/enum/video_rotation.dart';
import 'package:iris/features/video_transform/store/video_transform_store.dart';
import 'package:iris/features/video_transform/view/video_transform_panel.dart';
import 'package:iris/l10n/app_localizations.dart';
// Test-only StoreLocator host (see pubspec dev_dependencies comment).
import 'package:zustand/zustand.dart';
import 'package:provider/provider.dart';

/// StoreScope-equivalent that does NOT dispose the global StoreLocator on
/// unmount (mirrors frame_tools_float_panel_test.providerScope).
Widget providerScope(Widget child) {
  return InheritedProvider<StoreLocator>.value(
    value: StoreLocator(),
    startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
      final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
      return sub.cancel;
    },
    lazy: false,
    child: child,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPanel(
    WidgetTester tester, {
    void Function(VideoTransformStore)? configure,
  }) async {
    useVideoTransformStore().resetAll();
    configure?.call(useVideoTransformStore());
    final Widget app = MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // A fresh key forces a REMOUNT: flutter_zustand's select -> rebuild chain
      // does not deliver under the widget-test FakeAsync zone.
      home: Scaffold(body: VideoTransformPanel(key: UniqueKey())),
    );
    await tester.pumpWidget(providerScope(app));
    await tester.pumpAndSettle();
  }

  /// The trailing reset icon of one row, named by its localized tooltip.
  /// `IconButton` is the Tooltip's ANCESTOR, not its descendant, so match the
  /// widget's own tooltip field rather than walking down from the Tooltip.
  Finder resetFinder(String label) => find.byWidgetPredicate(
        (Widget w) => w is IconButton && w.tooltip == 'Reset $label',
      );

  IconButton resetButton(WidgetTester tester, String label) =>
      tester.widget<IconButton>(resetFinder(label));

  setUp(() => useVideoTransformStore().resetAll());

  testWidgets('panel renders orientation and color controls', (tester) async {
    await pumpPanel(tester);

    expect(find.text('Picture adjustment'), findsOneWidget);
    expect(find.text('Mirror horizontally'), findsOneWidget);
    expect(find.text('Mirror vertically'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '90°'), findsOneWidget);
    expect(find.text('Brightness'), findsOneWidget);
    expect(find.text('Contrast'), findsOneWidget);
    expect(find.text('Saturation'), findsOneWidget);
  });

  testWidgets('toggling the horizontal mirror updates the store',
      (tester) async {
    await pumpPanel(tester);
    expect(useVideoTransformStore().state.flipHorizontal, isFalse);

    await tester.tap(find.byType(Switch).first);
    await tester.pump();

    expect(useVideoTransformStore().state.flipHorizontal, isTrue);
  });

  testWidgets('reset is disabled on the untouched picture', (tester) async {
    await pumpPanel(tester);

    final TextButton reset = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Reset all'),
    );
    expect(reset.onPressed, isNull);
  });

  testWidgets('per-item reset buttons are disabled only for default values',
      (tester) async {
    await pumpPanel(tester);

    for (final String label in <String>[
      'Mirror horizontally',
      'Mirror vertically',
      'Rotation',
      'Brightness',
      'Contrast',
      'Saturation',
    ]) {
      expect(resetButton(tester, label).onPressed, isNull,
          reason: '$label is at its default');
    }

    // Remount with two fields off-default: only those two enable.
    await pumpPanel(tester, configure: (store) {
      store.setFlipHorizontal(true);
      store.setBrightness(0.4);
    });
    expect(resetButton(tester, 'Mirror horizontally').onPressed, isNotNull);
    expect(resetButton(tester, 'Brightness').onPressed, isNotNull);
    expect(resetButton(tester, 'Mirror vertically').onPressed, isNull);
    expect(resetButton(tester, 'Rotation').onPressed, isNull);
    expect(resetButton(tester, 'Contrast').onPressed, isNull);
    expect(resetButton(tester, 'Saturation').onPressed, isNull);
  });

  testWidgets('tapping the switch row toggles the field', (tester) async {
    await pumpPanel(tester);

    // The label is part of the tile, so the whole row stays tappable after the
    // SwitchListTile -> ListTile rewrite.
    await tester.tap(find.text('Mirror horizontally'));
    await tester.pump();
    expect(useVideoTransformStore().state.flipHorizontal, isTrue);
  });

  testWidgets('a color shown as 0% keeps its reset disabled', (tester) async {
    await pumpPanel(tester, configure: (store) => store.setBrightness(0.003));

    // The row renders "0"; an enabled reset beside it would read as a no-op.
    expect(resetButton(tester, 'Brightness').onPressed, isNull);
  });

  testWidgets('tapping a per-item reset leaves the other fields intact',
      (tester) async {
    await pumpPanel(tester, configure: (store) {
      store.setFlipHorizontal(true);
      store.setRotation(VideoRotation.cw90);
      store.setBrightness(0.4);
      store.setContrast(-0.2);
    });

    await tester.tap(resetFinder('Brightness'));
    await tester.pump();

    final state = useVideoTransformStore().state;
    expect(state.brightness, 0);
    expect(state.flipHorizontal, isTrue);
    expect(state.rotation, VideoRotation.cw90);
    expect(state.contrast, -0.2);
  });
}
