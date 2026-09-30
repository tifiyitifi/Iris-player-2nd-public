import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/control_group/model/control_group_state.dart';
import 'package:iris/features/control_group/model/enum/player_control_group.dart';
import 'package:iris/features/control_group/store/use_control_group_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/pages/player/control_bar/control_bar.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/control_bar_controls.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/desktop_control_layout.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/mobile_control_layout.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/resolve_control_bar_overflow.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/tablet_control_layout.dart';
import 'package:iris/features/windows/desktop_control_bar/view/desktop_stacked_control_layout.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/more_menu_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/play_pause_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/shuffle_button.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/storage_button.dart';
import 'package:iris/features/background_playback/view/background_quick_bar.dart';
import 'package:iris/store/kv/kv_keys.dart';
import 'package:iris/store/kv/secure_kv.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

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

ControlBarControls _controls({Set<ControlBarSlot> collapsed = const {}}) {
  return ControlBarControls(
    showControl: () {},
    showControlForHover: (_) async {},
    color: Colors.white,
    overlayColor: null,
    file: const FileItem(name: 'a.mp4', uri: 'file:///a.mp4'),
    circleScale: 0.5,
    collapsed: collapsed,
  );
}

Widget _providerScope(Widget child) => InheritedProvider<StoreLocator>.value(
      value: StoreLocator(),
      startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
        final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
        return sub.cancel;
      },
      lazy: false,
      child: child,
    );

Widget _harness(Widget child) {
  return _providerScope(
    Provider<MediaPlayer>.value(
      value: _player(),
      child: MaterialApp(
        locale: const Locale('en'),
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

  // The Zustand store is a process-wide singleton, so drop it between tests or
  // a seeded KV state would never be re-read.
  tearDown(() => StoreLocator().delete(ControlGroupStore));

  // Seed the control-group state through the KV backend BEFORE pumping, so the
  // store loads into the desired group without touching it outside the
  // StoreScope (which conflicts with the scope's lifecycle).
  void seedControlGroup({
    required PlayerControlGroup group,
    required bool floatingDesktop,
  }) {
    final kv = MemoryKvStore();
    kv.values[KvKeys.controlGroupState] = jsonEncode(
      const ControlGroupState()
          .copyWith(group: group, floatingButtonDesktop: floatingDesktop)
          .toJson(),
    );
    setKvStoreForTest(kv);
    addTearDown(resetKvStoreForTest);
  }

  group('ControlBarControls collapsed filtering', () {
    test('collapsed slots leave their button groups', () {
      final controls = _controls(
        collapsed: {ControlBarSlot.shuffle, ControlBarSlot.storage},
      );
      expect(controls.desktopLeftButtons.any((w) => w is ShuffleButton), isFalse);
      expect(controls.desktopRightButtons.any((w) => w is StorageButton), isFalse);
    });

    test('core slots are never removed by the policy', () {
      // Resolve at an extreme width: every optional slot collapses, yet the
      // core transport stays on the bar.
      final collapsed = resolveControlBarOverflow(
        availableWidth: 200,
        present: <ControlBarSlot>{
          ControlBarSlot.playPause,
          ControlBarSlot.shuffle,
          ControlBarSlot.storage,
          ControlBarSlot.rate,
        },
        volumeWidth: 48,
      );
      final controls = _controls(collapsed: collapsed);
      expect(
        controls.desktopLeftButtons.any((w) => w is PlayPauseButton),
        isTrue,
      );
    });
  });

  group('ControlBar layout follows the AVAILABLE width', () {
    // A fresh install now defaults to the right-side one-handed panel, so
    // ControlBar would mount the side panel instead of the responsive bar
    // these cases exercise. Pin the normal (non-sideway) mode.
    setUp(() {
      useAppStore().set(const AppState(
        phoneLandscapeUseMode: PhoneLandscapeUseMode.normal,
      ));
    });

    testWidgets('a narrow box inside a wide window degrades to tablet',
        (tester) async {
      // Window is wide (would previously select the desktop single line), but
      // the bar box is narrow — the docked-playlist regression.
      _setSurface(tester, const Size(1400, 800));
      await tester.pumpWidget(_harness(SizedBox(
        width: 700,
        height: 400,
        child: ControlBar(
          showControl: () {},
          showControlForHover: (_) async {},
        ),
      )));
      await tester.pumpAndSettle();

      expect(find.byType(TabletControlLayout), findsOneWidget);
      expect(find.byType(DesktopControlLayout), findsNothing);
    });

    testWidgets('a wide box keeps a desktop layout', (tester) async {
      _setSurface(tester, const Size(1400, 800));
      await tester.pumpWidget(_harness(SizedBox(
        width: 1300,
        height: 400,
        child: ControlBar(
          showControl: () {},
          showControlForHover: (_) async {},
        ),
      )));
      await tester.pumpAndSettle();

      // The exact desktop layout depends on the stored single/stacked choice,
      // but it must be one of the desktop arrangements — never tablet/mobile.
      expect(find.byType(TabletControlLayout), findsNothing);
      expect(find.byType(MobileControlLayout), findsNothing);
      final bool hasDesktop =
          find.byType(DesktopControlLayout).evaluate().isNotEmpty ||
              find.byType(DesktopStackedControlLayout).evaluate().isNotEmpty;
      expect(hasDesktop, isTrue);
    });
  });

  group('Desktop normal bar honors the control group', () {
    testWidgets('group 2 with the desktop switch enabled shows the 副音 bar',
        (tester) async {
      _setSurface(tester, const Size(1400, 800));
      seedControlGroup(
        group: PlayerControlGroup.background,
        floatingDesktop: true,
      );

      await tester.pumpWidget(_harness(SizedBox(
        width: 1300,
        height: 200,
        child: DesktopControlLayout(controls: _controls()),
      )));
      await tester.pumpAndSettle();

      expect(find.byType(BackgroundQuickBar), findsOneWidget);
      expect(find.byType(PlayPauseButton), findsNothing);
    });

    testWidgets('without the desktop switch the bar keeps the playback group',
        (tester) async {
      _setSurface(tester, const Size(1400, 800));
      seedControlGroup(
        group: PlayerControlGroup.background,
        floatingDesktop: false,
      );

      await tester.pumpWidget(_harness(SizedBox(
        width: 1300,
        height: 200,
        child: DesktopControlLayout(controls: _controls()),
      )));
      await tester.pumpAndSettle();

      expect(find.byType(PlayPauseButton), findsOneWidget);
    });

    testWidgets('switch mode shows ONE group: no standalone 副音 row',
        (tester) async {
      _setSurface(tester, const Size(1400, 800));
      seedControlGroup(
        group: PlayerControlGroup.playback,
        floatingDesktop: true,
      );

      await tester.pumpWidget(_harness(SizedBox(
        width: 1300,
        height: 200,
        child: DesktopControlLayout(controls: _controls()),
      )));
      await tester.pumpAndSettle();

      expect(find.byType(PlayPauseButton), findsOneWidget);
      // Group-switch mode suppresses the standalone 副音 quick row entirely.
      expect(find.byType(BackgroundQuickBar), findsNothing);
    });

    testWidgets('legacy mode still shows the standalone 副音 row',
        (tester) async {
      _setSurface(tester, const Size(1400, 800));
      seedControlGroup(
        group: PlayerControlGroup.playback,
        floatingDesktop: false,
      );

      await tester.pumpWidget(_harness(SizedBox(
        width: 1300,
        height: 200,
        child: DesktopControlLayout(controls: _controls()),
      )));
      await tester.pumpAndSettle();

      expect(find.byType(PlayPauseButton), findsOneWidget);
      expect(find.byType(BackgroundQuickBar), findsOneWidget);
    });
  });

  group('More menu receives collapsed controls', () {
    testWidgets('a collapsed shuffle becomes a More entry', (tester) async {
      _setSurface(tester, const Size(1400, 800));
      await tester.pumpWidget(_harness(MoreMenuButton(
        showControl: () {},
        showControlForHover: (_) async {},
        collapsed: const {ControlBarSlot.shuffle},
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();

      expect(find.textContaining('Shuffle'), findsWidgets);
    });
  });
}
