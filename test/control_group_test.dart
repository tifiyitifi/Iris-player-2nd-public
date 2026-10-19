import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/control_group/domain/center_zone.dart';
import 'package:iris/features/control_group/model/enum/player_control_group.dart';
import 'package:iris/features/control_group/store/use_control_group_store.dart';
import 'package:iris/features/control_group/view/control_group_floating_button.dart';
import 'package:iris/globals.dart' show sidewayQuickColumnAttachedNotifier;
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/kv/kv_keys.dart';
import 'package:iris/store/kv/secure_kv.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
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

Widget _harness(Widget child) => _providerScope(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Stack(children: [child])),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ch = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);

  tearDown(() {
    StoreLocator().delete(ControlGroupStore);
    StoreLocator().delete(PlayerUiStore);
    StoreLocator().delete(UnifiedPlayQueueStore);
  });

  group('group order', () {
    test('cycles in declaration order and wraps', () {
      expect(nextPlayerControlGroup(PlayerControlGroup.playback),
          PlayerControlGroup.background);
      expect(nextPlayerControlGroup(PlayerControlGroup.background),
          PlayerControlGroup.playback);
    });
  });

  group('center zone classification', () {
    const Offset center = Offset(50, 50);

    test('more-vertical pointers map to top/bottom', () {
      expect(
        centerZoneForOffset(const Offset(50, 10),
            center, inwardOnLeft: true),
        CenterZone.top,
      );
      expect(
        centerZoneForOffset(const Offset(50, 90),
            center, inwardOnLeft: true),
        CenterZone.bottom,
      );
    });

    test('horizontal pointers honor inwardOnLeft', () {
      // Panel on the right → screen centre is to the LEFT.
      expect(
        centerZoneForOffset(const Offset(10, 50),
            center, inwardOnLeft: true),
        CenterZone.inward,
      );
      expect(
        centerZoneForOffset(const Offset(90, 50),
            center, inwardOnLeft: true),
        CenterZone.outward,
      );
      // Panel on the left → centre is to the RIGHT.
      expect(
        centerZoneForOffset(const Offset(90, 50),
            center, inwardOnLeft: false),
        CenterZone.inward,
      );
      expect(
        centerZoneForOffset(const Offset(10, 50),
            center, inwardOnLeft: false),
        CenterZone.outward,
      );
    });
  });

  group('center zone resolver', () {
    test('phone uses the four configured actions', () {
      const AppState state = AppState();
      expect(resolveCenterZoneAction(state, CenterZone.inward,
          isMobileOverride: true), CircleSliderCenterAction.switchControlGroup);
      expect(resolveCenterZoneAction(state, CenterZone.top,
          isMobileOverride: true), CircleSliderCenterAction.toggleControls);
    });

    test('desktop keeps legacy all-toggleControls until phone mode', () {
      const AppState state = AppState();
      for (final zone in CenterZone.values) {
        expect(resolveCenterZoneAction(state, zone, isMobileOverride: false),
            CircleSliderCenterAction.toggleControls);
      }
    });

    test('desktop phone mode honors the configured actions', () {
      const AppState state =
          AppState(desktopCenterZonePhoneMode: true);
      expect(resolveCenterZoneAction(state, CenterZone.inward,
          isMobileOverride: false), CircleSliderCenterAction.switchControlGroup);
    });
  });

  group('control group store', () {
    test('cycleGroup advances and persists the group', () async {
      final store = useControlGroupStore();
      await store.initialized;
      expect(store.state.group, PlayerControlGroup.playback);

      await store.cycleGroup();
      expect(store.state.group, PlayerControlGroup.background);

      await store.cycleGroup();
      expect(store.state.group, PlayerControlGroup.playback);
    });

    test('floating position fractions clamp into 0..1', () async {
      final store = useControlGroupStore();
      await store.initialized;
      await store.setFloatingButtonFraction(1.4, -0.2);
      expect(store.state.floatingX, 1.0);
      expect(store.state.floatingY, 0.0);
    });
  });

  group('legacy floating toggle upgrade', () {
    /// Seeds a pre-orientation-split KV blob under the control-group key.
    void seedLegacy(Map<String, dynamic> json) {
      final kv = MemoryKvStore();
      kv.values[KvKeys.controlGroupState] = jsonEncode(json);
      setKvStoreForTest(kv);
      addTearDown(resetKvStoreForTest);
    }

    test('an ON legacy toggle upgrades into PORTRAIT only', () async {
      seedLegacy({'floatingButtonEnabled': true, 'floatingX': 0.3});

      final store = useControlGroupStore();
      await store.initialized;

      expect(store.state.floatingButtonPortrait, isTrue);
      expect(store.state.floatingButtonLandscape, isFalse,
          reason: 'the legacy value carries no landscape meaning, and '
              'landscape deliberately ships OFF');
      expect(store.state.floatingX, 0.3, reason: 'unrelated fields survive');
    });

    test('an OFF legacy toggle stays OFF in portrait', () async {
      seedLegacy({'floatingButtonEnabled': false});

      final store = useControlGroupStore();
      await store.initialized;

      expect(store.state.floatingButtonPortrait, isFalse);
      expect(store.state.floatingButtonLandscape, isFalse);
    });

    test('JSON already carrying the new keys is left untouched', () async {
      seedLegacy({
        'floatingButtonEnabled': true,
        'floatingButtonPortrait': false,
        'floatingButtonLandscape': true,
      });

      final store = useControlGroupStore();
      await store.initialized;

      expect(store.state.floatingButtonPortrait, isFalse);
      expect(store.state.floatingButtonLandscape, isTrue);
    });
  });

  group('floating button default', () {
    test('ships portrait ON, landscape OFF and desktop ON', () async {
      final store = useControlGroupStore();
      await store.initialized;

      expect(store.state.floatingButtonPortrait, isTrue);
      expect(store.state.floatingButtonLandscape, isFalse);
      expect(store.state.floatingButtonDesktop, isTrue);
    });

    test('the two orientation flags are independent', () async {
      final store = useControlGroupStore();
      await store.initialized;

      expect(store.isFloatingButtonVisible(isLandscape: false), isTrue);
      expect(store.isFloatingButtonVisible(isLandscape: true), isFalse);

      await store.setFloatingButtonVisible(isLandscape: true, visible: true);
      await store.setFloatingButtonVisible(isLandscape: false, visible: false);

      expect(store.isFloatingButtonVisible(isLandscape: true), isTrue);
      expect(store.isFloatingButtonVisible(isLandscape: false), isFalse);
      expect(store.state.floatingButtonLandscape, isTrue);
      expect(store.state.floatingButtonPortrait, isFalse);
    });
  });

  group('floating button', () {
    setUp(() => debugIsMobilePlatformOverride = true);
    tearDown(() => debugIsMobilePlatformOverride = null);

    void usePortrait(WidgetTester tester) {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    void useLandscape(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('tap cycles the bottom control group (portrait default on)',
        (tester) async {
      usePortrait(tester);
      final store = useControlGroupStore();
      await store.initialized;
      store.set(store.state.copyWith(
        group: PlayerControlGroup.playback,
        floatingButtonPortrait: true,
        floatingButtonLandscape: false,
      ));

      await tester.pumpWidget(_harness(const ControlGroupFloatingButton()));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('control_group_floating_button')),
          findsOneWidget);

      await tester.tap(find.byKey(
          const ValueKey<String>('control_group_floating_button')));
      await tester.pumpAndSettle();

      expect(store.state.group, PlayerControlGroup.background);
    });

    testWidgets('hidden in landscape when only portrait is enabled',
        (tester) async {
      useLandscape(tester);
      final store = useControlGroupStore();
      await store.initialized;
      store.set(store.state.copyWith(
        floatingButtonPortrait: true,
        floatingButtonLandscape: false,
      ));

      await tester.pumpWidget(_harness(const ControlGroupFloatingButton()));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('control_group_floating_button')),
          findsNothing);
    });

    testWidgets('shown in landscape when the landscape flag is enabled',
        (tester) async {
      useLandscape(tester);
      final store = useControlGroupStore();
      await store.initialized;
      store.set(store.state.copyWith(
        floatingButtonPortrait: false,
        floatingButtonLandscape: true,
      ));

      await tester.pumpWidget(_harness(const ControlGroupFloatingButton()));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('control_group_floating_button')),
          findsOneWidget);
    });

    testWidgets('drag tracks the finger across same-frame pan updates',
        (tester) async {
      useLandscape(tester);

      final store = useControlGroupStore();
      await store.initialized;
      store.set(store.state.copyWith(
        floatingButtonLandscape: true,
        floatingX: 0.5,
        floatingY: 0.5,
      ));

      await tester.pumpWidget(_harness(const ControlGroupFloatingButton()));
      await tester.pumpAndSettle();

      final Finder button =
          find.byKey(const ValueKey<String>('control_group_floating_button'));
      final double availW = tester.getSize(find.byType(Stack).first).width - 46;

      final TestGesture gesture =
          await tester.startGesture(tester.getCenter(button));
      // The FIRST move only clears the pan slop, which `DragStartBehavior.start`
      // absorbs (no onPanUpdate), so it must not count toward the total.
      await gesture.moveBy(const Offset(60, 0));
      // Two more moves land in the SAME frame — no pump in between. A handler
      // that accumulates onto the fraction CAPTURED AT BUILD TIME applies only
      // the last delta and the button falls behind the finger.
      await gesture.moveBy(const Offset(30, 0));
      await gesture.moveBy(const Offset(30, 0));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(store.state.floatingX, greaterThan(0.5 + 50 / availW));
    });
  });

  group('floating button (desktop)', () {
    testWidgets('desktop uses its own flag, not the phone orientations',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final store = useControlGroupStore();
      await store.initialized;

      // Phone flags off, desktop flag ON → shown: desktop ignores orientation.
      store.set(store.state.copyWith(
        floatingButtonPortrait: false,
        floatingButtonLandscape: false,
        floatingButtonDesktop: true,
      ));
      await tester.pumpWidget(_harness(const ControlGroupFloatingButton()));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('control_group_floating_button')),
        findsOneWidget,
      );

      // Desktop flag OFF → hidden even with the phone portrait flag ON.
      store.set(store.state.copyWith(
        floatingButtonDesktop: false,
        floatingButtonPortrait: true,
      ));
      await tester.pumpWidget(_harness(const ControlGroupFloatingButton()));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('control_group_floating_button')),
        findsNothing,
      );
    });

    testWidgets('stands down while the side panel carries the 副音 column',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => sidewayQuickColumnAttachedNotifier.value = false);

      final store = useControlGroupStore();
      await store.initialized;
      store.set(store.state.copyWith(
        floatingButtonPortrait: false,
        floatingButtonLandscape: false,
        floatingButtonDesktop: true,
      ));

      await tester.pumpWidget(_harness(const ControlGroupFloatingButton()));
      await tester.pumpAndSettle();
      final Finder button =
          find.byKey(const ValueKey<String>('control_group_floating_button'));
      expect(button, findsOneWidget,
          reason: 'precondition: the desktop flag alone shows the switch');

      // The side-type panel attached its own 副音 quick column (published by
      // `CircleSliderLayout`): the same controls are already on screen, so the
      // switch button stands down instead of sitting on top of the strip.
      sidewayQuickColumnAttachedNotifier.value = true;
      await tester.pumpAndSettle();
      expect(button, findsNothing);

      // Column gone (switch off, group 2 active, a narrow budget) → the switch
      // is the only way to the 副音 group again.
      sidewayQuickColumnAttachedNotifier.value = false;
      await tester.pumpAndSettle();
      expect(button, findsOneWidget);
    });
  });

  group('floating button rides the control panel', () {
    setUp(() => debugIsMobilePlatformOverride = true);
    tearDown(() => debugIsMobilePlatformOverride = null);

    Future<void> seed(ContentType type) => usePlayQueueStore().update(
          playQueue: [
            PlayQueueItem(
              file: FileItem(
                name: type == ContentType.video ? 'a.mp4' : 'a.mp3',
                uri: 'file:///a',
                type: type,
              ),
              index: 0,
            ),
          ],
          index: 0,
        );

    Future<Finder> pumpButton(WidgetTester tester) async {
      final store = useControlGroupStore();
      await store.initialized;
      store.set(store.state.copyWith(
        floatingButtonLandscape: true,
        group: PlayerControlGroup.playback,
      ));
      await tester.pumpWidget(_harness(const ControlGroupFloatingButton()));
      await tester.pumpAndSettle();
      return find.byKey(const ValueKey<String>('control_group_floating_button'));
    }

    testWidgets('a video: hidden and inert while the bar is hidden',
        (tester) async {
      await seed(ContentType.video);
      final Finder button = await pumpButton(tester);

      // Bar down (auto-hide) → the switch fades out on the bar's own schedule...
      usePlayerUiStore().updateIsShowControl(false);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AnimatedOpacity>(find.descendant(
              of: button,
              matching: find.byType(AnimatedOpacity),
            ))
            .opacity,
        0.0,
      );

      // ...and refuses pointers, so a tap on its old spot cannot switch groups.
      await tester.tapAt(tester.getCenter(button));
      await tester.pumpAndSettle();
      expect(useControlGroupStore().state.group, PlayerControlGroup.playback);

      // Bar up → the switch is live again.
      usePlayerUiStore().updateIsShowControl(true);
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(button));
      await tester.pumpAndSettle();
      expect(useControlGroupStore().state.group, PlayerControlGroup.background);
    });

    testWidgets('audio pins the bar, so the switch stays live', (tester) async {
      await seed(ContentType.audio);
      usePlayerUiStore().updateIsShowControl(false);
      final Finder button = await pumpButton(tester);

      await tester.tapAt(tester.getCenter(button));
      await tester.pumpAndSettle();

      expect(useControlGroupStore().state.group, PlayerControlGroup.background);
    });
  });
}
