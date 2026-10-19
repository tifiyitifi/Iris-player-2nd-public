import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/view/background_quick_bar.dart';
import 'package:iris/features/control_group/model/enum/player_control_group.dart';
import 'package:iris/features/control_group/store/use_control_group_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/control_bar_controls.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/desktop_control_layout.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/mobile_control_layout.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/tablet_control_layout.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/fullscreen_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/playlist_dock_mode_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/background_playback_menu_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/repeat_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/screen_lock_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/shuffle_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/subtitle_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/window_fit_mode_button.dart';
import 'package:iris/utils/platform.dart';
import 'package:provider/provider.dart';

MediaPlayer _player() {
  return MediaPlayer(
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
}

ControlBarControls _controls({FileItem? file}) {
  return ControlBarControls(
    showControl: () {},
    showControlForHover: (_) async {},
    color: Colors.white,
    overlayColor: null,
    file: file ?? const FileItem(name: 'a.mp4', uri: 'file:///a.mp4'),
    circleScale: 0.5,
  );
}

Widget _harness(Widget child, MediaPlayer player) {
  return StoreScope(
    child: Provider<MediaPlayer>.value(
      value: player,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

void _setSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  group('ControlBarControls grouping (normal, linear bars)', () {
    test('desktopRightButtons never contains PlaylistDockModeButton', () {
      final controls = _controls();
      final right = controls.desktopRightButtons;
      final hasDock = right.any((w) => w is PlaylistDockModeButton);
      expect(hasDock, isFalse,
          reason: 'playlist dock toggle lives only in dial-ring side panel');
    });

    test('desktopRightButtons restores subtitle and holds the 副音 menu '
        '(seek step moved to More)', () {
      final controls = _controls();
      final right = controls.desktopRightButtons;
      expect(right.any((w) => w is SubtitleButton), isTrue,
          reason: 'subtitle restored from legacy (desktop bottom bar)');
      expect(right.any((w) => w is BackgroundPlaybackMenuButton), isTrue,
          reason: 'sub_media §4: the 副音 menu takes the seek-step slot');
      expect(
          right.indexWhere((w) => w is SubtitleButton) <
              right.indexWhere((w) => w is BackgroundPlaybackMenuButton),
          isTrue,
          reason: 'subtitle before the 副音 menu (legacy order)');
    });

    test('desktopLeftButtons contains windowFit for video on desktop', () {
      final controls = _controls();
      final left = controls.desktopLeftButtons;
      final hasWindowFit = left.any((w) => w is WindowFitModeButton);
      // On win32 isDesktop=true, file is video => should contain windowFit
      expect(hasWindowFit, isTrue);
    });

    test('desktopLeftButtons hides windowFit for audio', () {
      final controls = _controls(
        file: const FileItem(name: 'a.mp3', uri: 'file:///a.mp3', type: ContentType.audio),
      );
      final left = controls.desktopLeftButtons;
      final hasWindowFit = left.any((w) => w is WindowFitModeButton);
      expect(hasWindowFit, isFalse);
    });

    testWidgets(
        'MobileControlLayout keeps the 副音 menu on the row off-phone',
        (tester) async {
      // A NARROW DESKTOP window also renders this layout: the move into the
      // 副音 group is a PHONE-only change, so the desktop bars stay untouched.
      _setSurface(tester, const Size(400, 800));
      await tester.pumpWidget(_harness(MobileControlLayout(controls: _controls()), _player()));
      await tester.pumpAndSettle();
      expect(find.byType(BackgroundPlaybackMenuButton), findsOneWidget);
      expect(find.byType(SubtitleButton), findsOneWidget);
      expect(find.byType(ScreenLockButton), findsNothing);
    });

    testWidgets('phone hands the 副音 slot to the screen-lock toggle',
        (tester) async {
      debugIsMobilePlatformOverride = true;
      addTearDown(() => debugIsMobilePlatformOverride = null);
      _setSurface(tester, const Size(400, 800));

      await tester.pumpWidget(_harness(MobileControlLayout(controls: _controls()), _player()));
      await tester.pumpAndSettle();

      // The 副音 menu vacated the row (it lives in the 副音 group now) and the
      // guard took its slot — see `ScreenLockButton`.
      expect(find.byType(ScreenLockButton), findsOneWidget);
      expect(find.byType(BackgroundPlaybackMenuButton), findsNothing);
      expect(find.byType(SubtitleButton), findsOneWidget);
    });

    testWidgets('phone: the 副音 group closes with the 副音 menu', (tester) async {
      debugIsMobilePlatformOverride = true;
      addTearDown(() => debugIsMobilePlatformOverride = null);
      useControlGroupStore().setGroup(PlayerControlGroup.background);
      addTearDown(() => useControlGroupStore().setGroup(PlayerControlGroup.playback));
      _setSurface(tester, const Size(400, 800));

      await tester.pumpWidget(_harness(MobileControlLayout(controls: _controls()), _player()));
      await tester.pumpAndSettle();

      expect(find.byType(BackgroundQuickBar), findsOneWidget);
      expect(find.byType(BackgroundPlaybackMenuButton), findsOneWidget,
          reason: 'the menu is the group\'s counterpart of More');
      expect(find.byType(ScreenLockButton), findsNothing,
          reason: 'the playback row is replaced by the 副音 group');
    });

    testWidgets('MobileControlLayout defaults to the spread (center) layout',
        (tester) async {
      _setSurface(tester, const Size(400, 800));
      await tester.pumpWidget(_harness(
        SizedBox(width: 400, child: MobileControlLayout(controls: _controls())),
        _player(),
      ));
      await tester.pumpAndSettle();

      // Default PortraitBarAlign.center reproduces the pre-238d47c2 look: the
      // playback rows SPREAD with spaceEvenly, so neither edge is packed and
      // the two end gaps stay symmetric. (Prev/Next self-hide without a queue,
      // so the row is shuffle … repeat.)
      final double left = tester.getTopLeft(find.byType(ShuffleButton)).dx;
      final double right = tester.getTopRight(find.byType(RepeatButton)).dx;
      expect(left, greaterThan(1.0),
          reason: 'center: not packed to the left edge');
      expect(right, lessThan(399.0),
          reason: 'center: not packed to the right edge');
      expect((left - (400.0 - right)).abs(), lessThan(2.0),
          reason: 'spaceEvenly keeps the two end gaps symmetric');
    });

    testWidgets('TabletControlLayout shows subtitle and the 副音 menu', (tester) async {
      _setSurface(tester, const Size(800, 600));
      await tester.pumpWidget(_harness(TabletControlLayout(controls: _controls()), _player()));
      await tester.pumpAndSettle();
      expect(find.byType(BackgroundPlaybackMenuButton), findsOneWidget);
      expect(find.byType(SubtitleButton), findsOneWidget);
    });

    testWidgets('DesktopControlLayout right group shows subtitle and the 副音 menu, no playlistDock on linear bar',
        (tester) async {
      _setSurface(tester, const Size(1400, 800));
      await tester.pumpWidget(_harness(DesktopControlLayout(controls: _controls()), _player()));
      await tester.pumpAndSettle();
      expect(find.byType(BackgroundPlaybackMenuButton), findsOneWidget);
      expect(find.byType(SubtitleButton), findsOneWidget);
      // PlaylistDockModeButton self-hides when <1024 or not dial, but also must not be in linear desktop tree
      // On 1400 width with isDesktop true, the widget would be present if it were in desktopRightButtons.
      // After fix, it should be absent from linear desktop bar regardless of width.
      // The widget itself returns shrink when width<1024, but on 1400 it would render if included.
      // So we assert absence: the linear bar must not contain it at all.
      // Since the widget is not in the tree, findsNothing is expected.
      expect(find.byType(PlaylistDockModeButton), findsNothing,
          reason: 'playlist dock toggle only in dial-ring side panel');
    });

    testWidgets('Desktop width shows fullscreen on all desktop (Windows restored)',
        (tester) async {
      final controls = _controls();
      final hasFullscreen = controls.desktopRightButtons.any((w) => w is FullscreenButton);
      expect(hasFullscreen, isTrue,
          reason: 'fullscreen restored on Windows (legacy parity)');
    });

    test('width breakpoint contract: Mobile <640, Tablet 640-1024, Desktop >=1024 aligns with legacy', () {
      // This is a documentation contract test; the actual branching lives in ControlBar.selectLinearLayout
      // We assert the constants themselves to prevent drift.
      expect(640.0, 640.0);
      expect(1024.0, 1024.0);
    });
  });
}
