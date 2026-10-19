import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/screen_lock/store/use_screen_lock_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/circle_slider_layout.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/control_bar_controls.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/desktop_control_layout.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/tablet_control_layout.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/screen_lock_button.dart';
import 'package:iris/utils/platform.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

Widget _providerScope(Widget child) => InheritedProvider<StoreLocator>.value(
      value: StoreLocator(),
      startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
        final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
        return sub.cancel;
      },
      lazy: false,
      child: child,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  // ScreenLockButton reads the lock store only, but the harness keeps a live
  // (in-memory) DB so the store locator behaves like the app's.
  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  tearDown(() {
    StoreLocator().delete(ScreenLockStore);
    debugIsMobilePlatformOverride = null;
    debugIsDesktopOverride = null;
  });

  FileItem media(ContentType type) => FileItem(
        name: type == ContentType.video ? 'a.mp4' : 'a.mp3',
        uri: 'file:///a',
        type: type,
      );

  ControlBarControls controls(FileItem? file) => ControlBarControls(
        showControl: () {},
        showControlForHover: (cb) async {
          await cb;
        },
        color: null,
        overlayColor: null,
        file: file,
        circleScale: 0.5,
      );

  group('lock entry visibility', () {
    test('phone + video -> shown', () {
      debugIsMobilePlatformOverride = true;
      expect(controls(media(ContentType.video)).showScreenLock, isTrue);
    });

    test('desktop -> hidden (no touch guard to arm)', () {
      debugIsMobilePlatformOverride = false;
      debugIsDesktopOverride = true;
      expect(controls(media(ContentType.video)).showScreenLock, isFalse);
    });

    test('phone + audio -> hidden (no full-screen video surface)', () {
      debugIsMobilePlatformOverride = true;
      expect(controls(media(ContentType.audio)).showScreenLock, isFalse);
    });
  });

  group('tablet and wide bars carry the lock (tablet video was lockless)', () {
    Future<void> pump(WidgetTester tester, Widget layout) async {
      await tester.pumpWidget(_providerScope(
        Provider<MediaPlayer>.value(
          value: MediaPlayer(
            isInitializing: false,
            isPlaying: false,
            externalSubtitles: const [],
            position: Duration.zero,
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
          ),
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: layout),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('tablet + video -> the tablet bar carries the lock toggle',
        (tester) async {
      debugIsMobilePlatformOverride = true;
      await pump(
        tester,
        TabletControlLayout(controls: controls(media(ContentType.video))),
      );
      expect(find.byType(ScreenLockButton), findsOneWidget,
          reason: 'tablet video is the primary lock scenario and had no entry');
    });

    testWidgets('tablet + audio -> no lock toggle on the tablet bar',
        (tester) async {
      debugIsMobilePlatformOverride = true;
      await pump(
        tester,
        TabletControlLayout(controls: controls(media(ContentType.audio))),
      );
      expect(find.byType(ScreenLockButton), findsNothing);
    });

    testWidgets('a >=1024 wide tablet keeps the lock on the desktop bar',
        (tester) async {
      // A tablet at desktop width resolves to DesktopControlLayout, so the
      // guard has to be offered there too or the wide tablet is lockless again.
      debugIsMobilePlatformOverride = true;
      await pump(
        tester,
        DesktopControlLayout(controls: controls(media(ContentType.video))),
      );
      expect(find.byType(ScreenLockButton), findsOneWidget);
    });

    testWidgets('the desktop app never arms the guard', (tester) async {
      debugIsMobilePlatformOverride = false;
      debugIsDesktopOverride = true;
      await pump(
        tester,
        DesktopControlLayout(controls: controls(media(ContentType.video))),
      );
      expect(find.byType(ScreenLockButton), findsNothing);
    });
  });

  group('side panel entry (phone landscape one-handed type)', () {
    MediaPlayer player() => MediaPlayer(
          isInitializing: false,
          isPlaying: false,
          externalSubtitles: const [],
          position: Duration.zero,
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

    Future<void> pumpSidePanel(WidgetTester tester, FileItem file) async {
      await tester.pumpWidget(_providerScope(
        Provider<MediaPlayer>.value(
          value: player(),
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CircleSliderLayout(
                width: 800,
                panelPercent: 30,
                controls: controls(file),
                scrubberBuilder: (double? _, double? __) =>
                    const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('phone + video -> the side panel carries the lock toggle',
        (tester) async {
      debugIsMobilePlatformOverride = true;
      await pumpSidePanel(tester, media(ContentType.video));

      expect(find.byType(ScreenLockButton), findsOneWidget,
          reason: 'the side type must offer the guard like the linear bar');
    });

    testWidgets('phone + audio -> no lock toggle on the side panel',
        (tester) async {
      debugIsMobilePlatformOverride = true;
      await pumpSidePanel(tester, media(ContentType.audio));

      expect(find.byType(ScreenLockButton), findsNothing);
    });
  });

  group('on-bar lock button', () {
    testWidgets('tapping it arms the lock, tapping again releases it',
        (tester) async {
      debugIsMobilePlatformOverride = true;
      expect(useScreenLockStore().state.locked, isFalse);

      await tester.pumpWidget(_providerScope(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ScreenLockButton(showControl: () {}),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.lock_outline_rounded));
      await tester.pumpAndSettle();
      expect(useScreenLockStore().state.locked, isTrue);

      await tester.tap(find.byIcon(Icons.lock_open_rounded));
      await tester.pumpAndSettle();
      expect(useScreenLockStore().state.locked, isFalse);
    });
  });
}
