import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/globals.dart'
    show controlBarIsolationHeightNotifier, controlPanelKeyNotifier;
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart' show PhoneLandscapeUseMode, PlayerBackend;
import 'package:iris/pages/player/overlays/controls_overlay.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

/// The picture-fullscreen playlist dock excludes the CONTROL BAR from its
/// right-edge summon strip by reading the box [controlPanelKeyNotifier]
/// publishes (`ControlsOverlay`). These tests lock the production wiring: the
/// key must hug the BAR — if it were wrapped around the full-screen
/// `Positioned.fill`/`Align` instead, the dock's whole summon strip would be
/// dead once the bar is up. They also lock the hidden-bar contract: the bar
/// slides off-screen, so its box can no longer contain the pointer and the
/// strip stays summonable.

const Size _window = Size(1280, 720);

MediaPlayer _player() => MediaPlayer(
      isInitializing: false,
      isPlaying: false,
      externalSubtitles: const [],
      position: const Duration(seconds: 12),
      duration: const Duration(hours: 1),
      buffer: Duration.zero,
      width: 16,
      height: 9,
      saveProgress: () async {},
      play: () async {},
      pause: () async {},
      backward: (_) async {},
      forward: (_) async {},
      stepBackward: () async {},
      stepForward: () async {},
      seek: (_) async {},
    );

Widget _shell(Widget body, BackgroundPlaybackEngine engine) =>
    InheritedProvider<StoreLocator>.value(
      value: StoreLocator(),
      startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
        final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
        return sub.cancel;
      },
      lazy: false,
      child: Provider<MediaPlayer>.value(
        value: _player(),
        child: ChangeNotifierProvider<BackgroundPlaybackEngine>.value(
          value: engine,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SizedBox(
                width: _window.width,
                height: _window.height,
                child: body,
              ),
            ),
          ),
        ),
      ),
    );

Widget _overlay(FileItem file) => ControlsOverlay(
      file: file,
      title: 'clip.mp4',
      showControl: () {},
      showControlForHover: (_) async {},
      hideControl: () {},
      showProgress: () {},
    );

const FileItem _video = FileItem(name: 'clip.mp4', uri: 'file:///clip.mp4');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);
  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  late BackgroundPlaybackEngine engine;
  setUp(() {
    engine = BackgroundPlaybackEngine(
      backend: PlayerBackend.mediaKit,
      attachNative: false,
    );
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: true,
          useLegacyStoragePersistence: false,
          phoneLandscapeUseMode: PhoneLandscapeUseMode.rightSide,
        ));
    // Bottom-anchored right edge — the anchor the dock's strip overlaps.
    usePlayerUiStore().updateIsShowControl(true);
  });
  tearDown(() => engine.dispose());

  testWidgets('the published box hugs the control bar, not the screen',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      tester.view.physicalSize = _window;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_shell(_overlay(_video), engine));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final GlobalKey? key = controlPanelKeyNotifier.value;
      expect(key, isNotNull, reason: 'the bar must publish its box');
      expect(find.byKey(key!), findsOneWidget);

      final Rect rect = tester.getRect(find.byKey(key));
      // Anchored to the right edge, like the panel it wraps.
      expect(rect.right, closeTo(_window.width, 1));
      expect(rect.bottom, closeTo(_window.height, 1));
      // The bar itself, nowhere near the full screen: the strip above it stays
      // summonable.
      expect(rect.width, lessThan(_window.width * 0.5));
      expect(rect.top, greaterThan(0));

      // Per-mount contract: unmounting retracts the box.
      await tester.pumpWidget(_shell(const SizedBox.shrink(), engine));
      await tester.pumpAndSettle();
      expect(controlPanelKeyNotifier.value, isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a hidden bar publishes an off-screen box', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      tester.view.physicalSize = _window;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // Video + controls hidden: the bar slides away, so it must stop covering
      // the dock's summon strip.
      usePlayerUiStore().updateIsShowControl(false);
      await tester.pumpWidget(_shell(_overlay(_video), engine));
      await tester.pumpAndSettle();

      final GlobalKey? key = controlPanelKeyNotifier.value;
      expect(key, isNotNull);
      final Rect rect = tester.getRect(find.byKey(key!));
      expect(rect.top, greaterThanOrEqualTo(_window.height),
          reason: 'a hidden bar is translated off-screen');
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the normal long-strip bar publishes its isolation zone',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      tester.view.physicalSize = _window;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // Not one-handed: the normal long-strip bottom bar (not a side panel).
      useAppStore().set(useAppStore().state.copyWith(
            phoneLandscapeUseMode: PhoneLandscapeUseMode.normal,
          ));

      await tester.pumpWidget(_shell(_overlay(_video), engine));
      await tester.pumpAndSettle();

      final GlobalKey? key = controlPanelKeyNotifier.value;
      expect(key, isNotNull);
      final Rect rect = tester.getRect(find.byKey(key!));
      // The bar hugs the bottom and is nowhere near the full screen — the box
      // must not be the whole `Positioned.fill`, or the measured zone would
      // swallow the entire summon strip.
      expect(rect.height, lessThan(_window.height * 0.5));

      // Isolation height = bar height + 25% of the area (the default setting).
      final double expected = rect.height + _window.height * 0.25;
      expect(
        controlBarIsolationHeightNotifier.value,
        closeTo(expected, 1.0),
        reason: 'the normal bar must publish barHeight + 25% of the area',
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
