import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/background_quick_bar.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

/// Regression: the 副音 quick bar read its feature gate BARE
/// (`BackgroundPlaybackGate.enabled`) inside `build`, with no subscription.
///
/// The gate is `!useLegacyStoragePersistence && useMetadataSettings`, but every
/// ancestor of this bar (ControlsOverlay -> ControlBar -> CircleSliderLayout)
/// subscribes to `useMetadataSettings` only — none of them to
/// `useLegacyStoragePersistence`, which `toggleUseLegacyStoragePersistence()`
/// writes on its own. A bare read therefore survived a live legacy-storage
/// flip: the bar stayed on screen, draggable and tappable, for a subsystem the
/// user had just switched off, and nothing else clears `quickBarEnabled`
/// (`EffectsRegistry.legacyStorageBackend` only swaps the storage / play-queue
/// backends).
///
/// Kept in its OWN file on purpose: the shared `_providerScope` harness in
/// `background_quick_bar_test.dart` only propagates a live store flip for the
/// FIRST widget test in a file, so a live-flip assertion smuggled in as one
/// more case there would silently never rebuild.
Widget _scope(Widget child) => InheritedProvider<StoreLocator>.value(
      value: StoreLocator(),
      startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
        final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
        return sub.cancel;
      },
      lazy: false,
      child: child,
    );

Widget _harness() => _scope(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(child: BackgroundQuickBar(axis: Axis.horizontal)),
        ),
      ),
    );

Finder get _bar => find.byKey(const ValueKey('bg_quick_bar'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ch = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);

  tearDown(() => StoreLocator().delete(BackgroundPlaybackStore));

  testWidgets('the LEGACY half of the gate re-resolves on a live flip',
      (tester) async {
    final app = useAppStore();
    app.set(app.state.copyWith(
      useMetadataSettings: true,
      useLegacyStoragePersistence: false,
    ));
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    bg.set(bg.state.copyWith(enabled: true, quickBarEnabled: true));

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    expect(_bar, findsOneWidget,
        reason: 'precondition: the bar is mounted while the gate is open');

    // Exactly what `toggleUseLegacyStoragePersistence()` does: flip ONE field.
    app.set(app.state.copyWith(useLegacyStoragePersistence: true));
    await tester.pumpAndSettle();
    expect(_bar, findsNothing,
        reason: 'a bare gate read would keep the 副音 bar live here');

    // …and back, proving the subscription is two-way rather than one-shot.
    app.set(app.state.copyWith(useLegacyStoragePersistence: false));
    await tester.pumpAndSettle();
    expect(_bar, findsOneWidget);
  });
}
