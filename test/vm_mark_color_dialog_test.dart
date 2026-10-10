import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/virtual_media/rule/vm_tick_extent.dart';
import 'package:iris/features/virtual_media/view/vm_mark_color_dialog.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/store/use_app_store.dart';

// Production hangs the tree under StoreScope (main.dart). Widget tests here
// follow the repo-wide convention (mutate, re-pump, assert): after a store
// mutation the identical tree is re-pumped, preserving the open route while
// rebuilding it off fresh store state.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  // StoreScope disposes the locator on unmount, so (re)create per test.
  setUp(() async {
    useAppStore();
    await useAppStore().initialized;
  });

  tearDown(() async {
    await useAppStore().updateVmMarkTickColor(0xFFFFFFFF);
    await useAppStore().updateVmMarkTickExtent(kVmTickExtentDefaultPx);
  });

  Widget tree(Size surface, double keyboard) {
    return StoreScope(
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          // NOTE: size must be explicit — a bare MediaQueryData defaults
          // to Size.zero and would silently invalidate dialog constraints.
          data: MediaQueryData(
            size: surface,
            viewInsets: EdgeInsets.only(bottom: keyboard),
            // Phone-realistic: larger system font exposes fixed-width rows.
            textScaler: const TextScaler.linear(1.3),
          ),
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showVmMarkColorDialog(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pumpOpener(
    WidgetTester tester, {
    Size surface = const Size(360, 640),
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(tree(surface, keyboard));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('tick dialog 360px + keyboard + large font: no overflow',
      (tester) async {
    await pumpOpener(tester, keyboard: 300);
    expect(tester.takeException(), isNull);
    // Phone widths take the bottom-sheet shell; the header folds while an
    // input holds focus, so dismiss the keyboard state first (no focus yet
    // → header visible).
    expect(find.text('分段刻度颜色·长度'), findsOneWidget);
    // Default white + 7px label renders.
    expect(find.text('#FFFFFFFF · 7px'), findsOneWidget);
  });

  testWidgets('tapping a swatch writes the color to the store',
      (tester) async {
    await pumpOpener(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('vmTickSwatch_4294967295')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('vmTickSwatch_4294961979')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(useAppStore().state.vmMarkTickColor, 0xFFFFEB3B);
  });

  testWidgets('dialog renders the stored color + extent (seed before pump)',
      (tester) async {
    // Repo-wide convention: widget tests never observe select
    // notifications mid-tree, so seed the store BEFORE pumping.
    await useAppStore().updateVmMarkTickColor(0xFFFFEB3B);
    await useAppStore().updateVmMarkTickExtent(5);
    await pumpOpener(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('#FFFFEB3B · 5px'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsWidgets);
  });

  testWidgets('extent slider + number field are present', (tester) async {
    await pumpOpener(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('vmTickExtentSlider')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('vmTickExtentNumber')),
        findsOneWidget);
  });

  testWidgets('extent slider spans 0..MAX in 1px steps', (tester) async {
    // The range is part of the setting's contract, not an incidental detail:
    // a stale `max:` here silently makes the top of the range unreachable.
    await pumpOpener(tester);
    final Slider slider = tester.widget<Slider>(
        find.byKey(const ValueKey('vmTickExtentSlider')));
    expect(slider.min, 0.0);
    expect(slider.max, 15.0);
    expect(slider.max, kVmTickExtentMaxPx.toDouble());
    expect(slider.divisions, kVmTickExtentMaxPx - kVmTickExtentMinPx);
    // The handle must sit on the new default, not the old 3px.
    expect(slider.value, kVmTickExtentDefaultPx.toDouble());
  });

  testWidgets('RGB inputs + hex field are present', (tester) async {
    await pumpOpener(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('vmTickR')), findsOneWidget);
    expect(find.byKey(const ValueKey('vmTickG')), findsOneWidget);
    expect(find.byKey(const ValueKey('vmTickB')), findsOneWidget);
    expect(find.byKey(const ValueKey('vmTickHex')), findsOneWidget);
  });

  testWidgets('invalid hex shows an error dialog, store untouched',
      (tester) async {
    await pumpOpener(tester);
    expect(tester.takeException(), isNull);
    await tester.enterText(
        find.byKey(const ValueKey('vmTickHex')), '#GGGGGG');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('颜色格式错误'), findsOneWidget);
    expect(useAppStore().state.vmMarkTickColor, 0xFFFFFFFF);
  });

  testWidgets('focusing an input folds the header + preview away',
      (tester) async {
    await pumpOpener(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('分段刻度颜色·长度'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('vmTickHex')),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vmTickHex')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('分段刻度颜色·长度'), findsNothing);
    expect(find.byKey(const ValueKey('vmTickPreview')), findsNothing);
  });

  testWidgets('tapping the SV plane re-tints the tick', (tester) async {
    await pumpOpener(tester);
    expect(tester.takeException(), isNull);
    expect(useAppStore().state.vmMarkTickColor, 0xFFFFFFFF);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('vmTickSvPlane')),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vmTickSvPlane')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final after = useAppStore().state.vmMarkTickColor;
    expect(after, isNot(0xFFFFFFFF));
    expect(after & 0xFF000000, 0xFF000000);
  });

  testWidgets('reset restores white + 7px', (tester) async {
    await useAppStore().updateVmMarkTickColor(0xFFFF0000);
    await useAppStore().updateVmMarkTickExtent(15);
    await pumpOpener(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('vmTickReset')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(useAppStore().state.vmMarkTickColor, 0xFFFFFFFF);
    expect(useAppStore().state.vmMarkTickExtent, 7);
  });
}
