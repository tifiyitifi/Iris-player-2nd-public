import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/model/enum/bg_quick_panel.dart';
import 'package:iris/features/background_playback/model/enum/ratio_scope.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/bg_quick_panel_host.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/widgets/controls/vertical_value_strip.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

/// 第 4 轮问题 3/4: the quick 副音 cards are NON-MODAL, draggable floating
/// panels mounted in the player Stack — the video is never dimmed and the
/// ratio strips finally accept a vertical drag.
Widget _hostHarness({
  Size size = const Size(360, 640),
  TextScaler textScaler = TextScaler.noScaling,
  double viewInsetsBottom = 0,
}) {
  return InheritedProvider<StoreLocator>.value(
    value: StoreLocator(),
    startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
      final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
      return sub.cancel;
    },
    lazy: false,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: size,
            textScaler: textScaler,
            viewInsets: EdgeInsets.only(bottom: viewInsetsBottom),
          ),
          child: const Scaffold(
            body: Stack(children: [BgQuickPanelHost()]),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUp(() {
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: true,
          useLegacyStoragePersistence: false,
        ));
  });

  tearDown(() => StoreLocator().delete(BackgroundPlaybackStore));

  Future<BackgroundPlaybackStore> enable() async {
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    bg.set(bg.state.copyWith(enabled: true));
    return bg;
  }

  testWidgets('scope card opens non-modally and closes via X', (tester) async {
    final bg = await enable();
    await tester.pumpWidget(_hostHarness());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bg_quick_panel')), findsNothing);

    bg.toggleQuickPanel(BgQuickPanel.scope);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('bg_quick_panel')), findsOneWidget);
    expect(find.text('Scope'), findsOneWidget);
    expect(find.text('This video'), findsOneWidget);
    // Non-modal: every barrier is transparent (the base route carries a
    // colorless one), so no scrim ever dims the video.
    final barriers = tester.widgetList<ModalBarrier>(find.byType(ModalBarrier));
    expect(barriers.every((b) => b.color == null), isTrue,
        reason: 'a modal scrim would dim the video');

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bg_quick_panel')), findsNothing);
    expect(bg.state.openQuickPanel, BgQuickPanel.none);
  });

  testWidgets('the quick button toggles the same panel closed', (tester) async {
    final bg = await enable();
    await tester.pumpWidget(_hostHarness());
    await tester.pumpAndSettle();

    bg.toggleQuickPanel(BgQuickPanel.scope);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bg_quick_panel')), findsOneWidget);

    bg.toggleQuickPanel(BgQuickPanel.scope);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bg_quick_panel')), findsNothing);
  });

  testWidgets('the card is draggable by its header', (tester) async {
    final bg = await enable();
    await tester.pumpWidget(_hostHarness());
    await tester.pumpAndSettle();
    bg.showQuickPanel(BgQuickPanel.scope);
    await tester.pumpAndSettle();

    final before =
        tester.getTopLeft(find.byKey(const ValueKey('bg_quick_panel')));
    await tester.drag(
        find.byIcon(Icons.drag_indicator_rounded), const Offset(-40, -60));
    await tester.pumpAndSettle();
    final after =
        tester.getTopLeft(find.byKey(const ValueKey('bg_quick_panel')));

    expect(after.dx, lessThan(before.dx));
    expect(after.dy, lessThan(before.dy));
  });

  testWidgets('ratio strips respond to a vertical drag (no scroll ancestor)',
      (tester) async {
    final bg = await enable();
    bg.set(bg.state.copyWith(
      ratioExplicitSave: false,
      ratioScope: RatioScope.global,
    ));
    await tester.pumpWidget(_hostHarness());
    await tester.pumpAndSettle();
    bg.showQuickPanel(BgQuickPanel.ratio);
    await tester.pumpAndSettle();

    final before = bg.state.fgVolumePercent;
    await tester.drag(
        find.byType(VerticalValueStrip).first, const Offset(0, -80));
    await tester.pumpAndSettle();

    expect(bg.state.fgVolumePercent, greaterThan(before),
        reason: 'the vertical drag must reach the strip, not a scroll view');
  });

  testWidgets('the card drops out when the legacy-storage switch closes the gate',
      (tester) async {
    final bg = await enable();
    await tester.pumpWidget(_hostHarness());
    await tester.pumpAndSettle();
    bg.showQuickPanel(BgQuickPanel.scope);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bg_quick_panel')), findsOneWidget);

    // The host is mounted `const` in the player Stack, so `updateChild`
    // short-circuits on the identical const instance and an ancestor rebuild
    // never re-runs this build: the feature gate has to arrive through its OWN
    // subscription, or a 副音 card stays on screen — still draggable and
    // interactive — after the subsystem was switched off. Nothing else clears
    // `openQuickPanel` (`EffectsRegistry.legacyStorageBackend` only swaps the
    // storage / play-queue backends).
    await _mutate(tester, () => useAppStore().set(useAppStore().state.copyWith(
          useLegacyStoragePersistence: true,
        )));
    expect(find.byKey(const ValueKey('bg_quick_panel')), findsNothing);

    // Positive control: the host DOES react to the gate now. Without it a blind
    // harness could pass the line above for the wrong reason.
    await _mutate(tester, () => useAppStore().set(useAppStore().state.copyWith(
          useLegacyStoragePersistence: false,
        )));
    expect(find.byKey(const ValueKey('bg_quick_panel')), findsOneWidget);
  });

  testWidgets('no overflow on a 360x640 phone with large font + keyboard',
      (tester) async {
    await enable();
    await tester.pumpWidget(_hostHarness(
      size: const Size(360, 640),
      textScaler: const TextScaler.linear(1.3),
      viewInsetsBottom: 200,
    ));
    await tester.pumpAndSettle();
    useBackgroundPlaybackStore().showQuickPanel(BgQuickPanel.ratio);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}

/// Escapes the FakeAsync zone so the zustand change stream actually delivers,
/// then lets the marked-dirty elements build. MANDATORY for an AppState write
/// under `testWidgets`: `Store.set` -> `StoreLocator._onChange` ->
/// `_controller.add` are async hops FakeAsync never flushes, so a plain
/// `set()` + `pumpAndSettle()` delivers nothing and every assertion after it
/// would be vacuous. Completes on a REAL change event rather than a guessed
/// delay — "the write landed" must be a fact here. See the delivery note in
/// `app_state_select_narrowing_test.dart`, which this mirrors.
Future<void> _mutate(WidgetTester tester, void Function() write) async {
  await tester.runAsync(() async {
    final Completer<void> delivered = Completer<void>();
    final StreamSubscription<dynamic> sub = StoreLocator().changes.listen((_) {
      if (!delivered.isCompleted) delivered.complete();
    });
    write();
    await delivered.future;
    await sub.cancel();
  });
  await tester.pump();
}
