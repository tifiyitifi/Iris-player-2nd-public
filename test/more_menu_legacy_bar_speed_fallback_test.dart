import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/globals.dart' show moreMenuKeyNotifier;
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/more_menu_button.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:provider/provider.dart';
// Test-only StoreLocator host that does NOT dispose the global StoreLocator on
// unmount, so several cases can share one file.
import 'package:zustand/zustand.dart';

/// The More menu's 播放速度 row is a FALLBACK: it must exist exactly when the
/// live bar carries no RateButton of its own.
///
/// `MoreMenuButton` is the one consumer of the side-panel gate that BOTH bars
/// instantiate — `LegacyControlBar` builds its own at
/// `control_bar_widgets/legacy_control_bar.dart`. So the menu cannot read the
/// raw mount gate: `LegacyControlBar` never imports `CircleSliderLayout` or
/// `PhoneOneHandedScrubber`, and its linear branches are chosen by its OWN
/// `mobileBreakpoint` (640, the same value as `kMobileBreakpoint`) with
/// `rateButton` in the tablet and desktop ones. Reading the gate bare made a
/// one-handed mode under the legacy bar report a side panel, which both hid the
/// fallback everywhere and duplicated the bar's own row.
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

MediaPlayer _player() {
  return MediaPlayer(
    isInitializing: false,
    isPlaying: false,
    externalSubtitles: const [],
    position: Duration.zero,
    duration: const Duration(minutes: 1),
    buffer: Duration.zero,
    width: 0,
    height: 0,
    saveProgress: () async {},
    play: () async {},
    pause: () async {},
    backward: (_) async {},
    forward: (_) async {},
    stepBackward: () async {},
    stepForward: () async {},
    seek: (_) async {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  // MoreMenuButton builds `usePlaybackScenarioStore()`, whose onReady reaches
  // DbModule.scenarioRepo — without a live (in-memory) DB that late field is
  // uninitialized and the first case dies before any assertion runs.
  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  late AppState original;

  setUp(() {
    // BOTH seams: the panel's host gate reads `isDesktop`, so leaving it true
    // on this desktop runner would answer with the runner's platform.
    debugIsMobilePlatformOverride = true;
    debugIsDesktopOverride = false;
    original = useAppStore().state;
  });

  tearDown(() {
    useAppStore().set(original);
    debugIsMobilePlatformOverride = null;
    debugIsDesktopOverride = null;
  });

  void configure({
    PhoneLandscapeUseMode useMode = PhoneLandscapeUseMode.normal,
    bool gate = true,
    bool legacyControlBar = false,
  }) {
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: gate,
          useLegacyControlBar: legacyControlBar,
          phoneLandscapeUseMode: useMode,
          runtimeOrientation: ScreenOrientation.landscape,
        ));
  }

  Future<void> openMoreMenu(WidgetTester tester, Size surface) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(providerScope(
      Provider<MediaPlayer>.value(
        value: _player(),
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MoreMenuButton(
              showControl: () {},
              showControlForHover: (f) async => await f,
            ),
          ),
        ),
      ),
    ));
    // Deferred ARB loading resolves asynchronously.
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(moreMenuKeyNotifier.value!));
    await tester.pumpAndSettle();
  }

  testWidgets('the legacy bar is a linear layout, so a one-handed mode must '
      'not hide the speed fallback it already carries', (tester) async {
    configure(
      useMode: PhoneLandscapeUseMode.rightSide,
      legacyControlBar: true,
    );
    // >= LegacyControlBar's own mobileBreakpoint: the tablet branch renders
    // `rateButton` itself, so a second row would offer the same action twice.
    await openMoreMenu(tester, const Size(800, 360));

    expect(find.textContaining('播放速度'), findsNothing,
        reason: 'the legacy bar at 800 wide is its tablet branch, which has a '
            'RateButton of its own — the one-handed mode must not make the '
            'menu think it is looking at a side panel');
  });

  testWidgets('the legacy bar below its breakpoint still keeps the fallback',
      (tester) async {
    configure(
      useMode: PhoneLandscapeUseMode.rightSide,
      legacyControlBar: true,
    );
    // < 640: the legacy bar's mobile branch has no RateButton, so the More menu
    // is the only place the action lives.
    await openMoreMenu(tester, const Size(500, 360));

    expect(find.textContaining('播放速度'), findsOneWidget);
  });

  testWidgets('a one-handed mode on the real bar is still a side panel',
      (tester) async {
    // The veto must not take the feature with it: with the real bar the
    // sideway panel renders no RateButton at any width, so the fallback stays.
    configure(useMode: PhoneLandscapeUseMode.rightSide);
    await openMoreMenu(tester, const Size(800, 360));

    expect(find.textContaining('播放速度'), findsOneWidget);
  });
}
