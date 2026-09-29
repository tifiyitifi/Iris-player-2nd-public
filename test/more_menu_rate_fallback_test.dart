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
// Test-only StoreLocator host (see pubspec dev_dependencies comment).
import 'package:zustand/zustand.dart';

/// StoreScope-equivalent that does NOT dispose the global StoreLocator on
/// unmount (mirrors more_menu_frame_tools_test.providerScope).
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

/// The More menu's 播放速度 row is a FALLBACK: it must exist exactly when the
/// live control-bar layout carries no dedicated RateButton.
///
/// Layouts without a RateButton (see control_bar.dart):
///   - CircleSliderLayout — side type (`useOneHandedScrubber`) AND the plain
///     phone-landscape circle slider (`useCircleSlider`), at ANY width;
///   - MobileControlLayout — width < kMobileBreakpoint (640).
/// Every wider linear bar (Tablet/Desktop) renders `controls.rate` itself, so
/// duplicating the row there would offer the same action twice.
///
/// Regression history: the row used to be gated on `width < 600`, which hid it
/// for the whole sideway panel (landscape phones are >= 600 wide) AND left a
/// 600–640 hole where MobileControlLayout was active but the row stayed hidden.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  // MoreMenuButton builds `usePlaybackScenarioStore()`, whose onReady reaches
  // DbModule.scenarioRepo — without a live (in-memory) DB that late field is
  // uninitialized and the first test dies before any assertion runs.
  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  late AppState original;

  setUp(() {
    debugIsMobilePlatformOverride = true;
    original = useAppStore().state;
  });

  tearDown(() {
    useAppStore().set(original);
    debugIsMobilePlatformOverride = null;
  });

  void setSurface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  void configure({
    PhoneLandscapeUseMode useMode = PhoneLandscapeUseMode.normal,
    PhoneLandscapeSliderType sliderType = PhoneLandscapeSliderType.normal,
    bool gate = true,
  }) {
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: gate,
          phoneLandscapeUseMode: useMode,
          phoneLandscapeSliderType: sliderType,
          runtimeOrientation: ScreenOrientation.device,
        ));
  }

  Future<void> openMoreMenu(WidgetTester tester, Size surface) async {
    setSurface(tester, surface);
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

  testWidgets('portrait narrow bar keeps the speed fallback row', (tester) async {
    const surface = Size(400, 800);
    configure();
    await openMoreMenu(tester, surface);

    expect(find.textContaining('播放速度'), findsOneWidget);
  });

  testWidgets('sideway panel in landscape exposes the speed row', (tester) async {
    const surface = Size(1024, 600);
    configure(
      useMode: PhoneLandscapeUseMode.rightSide,
      sliderType: PhoneLandscapeSliderType.circleRight,
    );
    await openMoreMenu(tester, surface);

    // CircleSliderLayout renders no RateButton, so the More menu must carry it
    // even though the window is far past the old 600px cutoff.
    expect(find.textContaining('播放速度'), findsOneWidget);
  });

  testWidgets('plain circle slider in phone landscape exposes the speed row',
      (tester) async {
    const surface = Size(1024, 600);
    // GATE OFF: with the meta gate on, the use mode is the placement authority
    // and `useLegacyCircleSliderPanel` mounts nothing, so a stored circleRight
    // beside a `normal` mode is a leftover pair, not a panel.
    configure(
      useMode: PhoneLandscapeUseMode.normal,
      sliderType: PhoneLandscapeSliderType.circleRight,
      gate: false,
    );
    await openMoreMenu(tester, surface);

    expect(find.textContaining('播放速度'), findsOneWidget);
  });

  testWidgets('gate ON: a stale circle type beside a normal mode mounts no '
      'panel, so a wide linear bar keeps its own speed button', (tester) async {
    const surface = Size(1400, 800);
    // The bar/anchor disagreement this pins: the menu used to read the leftover
    // `circleRight` as "a circle panel is on screen" and suppress the fallback
    // row, while the bar — gated on the same bit the anchor resolver is — is a
    // linear layout that renders `controls.rate` itself. Nothing was left to
    // offer the action, and the panel the menu was dodging did not exist.
    configure(
      useMode: PhoneLandscapeUseMode.normal,
      sliderType: PhoneLandscapeSliderType.circleRight,
    );
    await openMoreMenu(tester, surface);

    expect(find.textContaining('播放速度'), findsNothing,
        reason: 'no circle panel is mounted, so the wide linear bar owns the '
            'speed button and the fallback row would duplicate it');
  });

  testWidgets('600-640 width (mobile layout) exposes the speed row',
      (tester) async {
    const surface = Size(620, 800);
    configure();
    await openMoreMenu(tester, surface);

    // MobileControlLayout has no RateButton; the old 600px gate skipped 600-640.
    expect(find.textContaining('播放速度'), findsOneWidget);
  });

  testWidgets('wide linear bar does NOT duplicate the speed row', (tester) async {
    const surface = Size(1400, 800);
    configure();
    await openMoreMenu(tester, surface);

    // Tablet/Desktop layouts render `controls.rate` themselves.
    expect(find.textContaining('播放速度'), findsNothing);
  });
}
