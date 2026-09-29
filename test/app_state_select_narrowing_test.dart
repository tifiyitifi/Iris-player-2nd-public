import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/features/meta_settings/engine/osd_resolver.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/pages/player/control_bar/control_bar.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/circle_slider_layout.dart';
import 'package:iris/pages/player/overlays/controls_overlay.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/dialogs/show_slider_type_dialog.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

/// WHY: a whole-state `useAppStore().select(context, (s) => s)` on a Freezed
/// [AppState] is NOT a no-op read. `Store.set` emits unconditionally,
/// `StoreScope` marks every dependent on each emit, and the selector's
/// `!=` check is Freezed's deep field compare — so ANY AppState mutation
/// re-ran the consuming widget. `ControlsOverlay` sits over the whole video
/// and [AppStore.updateTransientRate] rewrites `transientRate` on EVERY
/// speed-gesture pan update, which dragged the title bar and the whole
/// control bar along once per frame for a field neither of them renders.
///
/// These tests lock the narrow shape from both ends: the `*From` helpers must
/// agree with the AppState overloads (no behaviour drift), and the widgets
/// must actually stop rebuilding on a write they do not read — with a POSITIVE
/// control, because a "did not rebuild" assertion is worthless on its own.
///
/// DELIVERY NOTE (probe-verified, supersedes the older "the select()->rebuild
/// chain never delivers under testWidgets" comments in the gesture/frame-tools
/// tests): a plain `set()` + `pump()`/`pumpAndSettle()` does NOT deliver —
/// `Store.set` -> `StoreLocator._onChange` -> `_controller.add` are async hops
/// FakeAsync never flushes. Mutating inside `tester.runAsync()` escapes that
/// zone and a single following `pump()` DOES rebuild. So [_mutate] is mandatory
/// here; dropping it would make every assertion below vacuously pass.

// ── Part A: the narrow helpers are the same function ─────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    // Drain the store's real-async `load()` HERE, outside any FakeAsync zone.
    // Started inside the first `testWidgets` body it would still be in flight
    // when that test ends, and every LATER widget test in this file came up
    // with an empty tree (no exception, nothing pumped). Same guard as
    // gesture_overlay_mode_reactive_test.
    useAppStore();
    await useAppStore().initialized;
  });
  tearDown(() => debugIsMobilePlatformOverride = null);

  group('narrow helpers match the AppState overloads', () {
    // Not gated on the phone-mode matrix below: the OSD resolver reads neither
    // the gate rows nor the use mode, so it gets its own full matrix instead of
    // six redundant copies.
    test('resolveOsdShouldShowFrom', () {
      for (final bool enabled in <bool>[false, true]) {
        for (final OsdVisibilityMode mode in OsdVisibilityMode.values) {
          for (final bool isShowControl in <bool>[false, true]) {
            for (final bool metaGate in <bool>[false, true]) {
              final AppState s = AppState(
                useMetadataSettings: metaGate,
                osdEnabled: enabled,
                osdVisibilityMode: mode,
              );
              expect(
                resolveOsdShouldShowFrom(
                  osdEnabled: enabled,
                  visibilityMode: mode,
                  metadataEnabled: metaGate && MetaSettingsModule.ready,
                  isShowControl: isShowControl,
                ),
                resolveOsdShouldShow(
                  s,
                  metaGate && MetaSettingsModule.ready,
                  isShowControl: isShowControl,
                ),
                reason: 'enabled=$enabled mode=$mode control=$isShowControl '
                    'gate=$metaGate',
              );
            }
          }
        }
      }
    });

    for (final bool gate in <bool>[false, true]) {
      for (final PhoneLandscapeUseMode mode
          in kLivePhoneLandscapeUseModes) {
        test('desktopHoverRevealsTitleFrom (gate=$gate, $mode)', () {
          for (final bool title in <bool>[false, true]) {
            for (final bool bar in <bool>[false, true]) {
              final AppState s = AppState(
                useMetadataSettings: gate,
                desktopHoverShowTitle: title,
                desktopHoverShowControlBar: bar,
              );
              expect(
                desktopHoverRevealsTitleFrom(
                  useMetadataSettings: gate,
                  desktopHoverShowTitle: title,
                  desktopHoverShowControlBar: bar,
                ),
                desktopHoverRevealsTitle(s),
                reason: 'gate=$gate title=$title bar=$bar',
              );
            }
          }
        });

        test('resolveSidePanelAlignmentFrom (gate=$gate, $mode)', () {
          for (final PhoneSidePositionH mobileH in PhoneSidePositionH.values) {
            for (final PhoneSidePositionH h in PhoneSidePositionH.values) {
              for (final PhoneSidePositionV v in PhoneSidePositionV.values) {
                final AppState s = AppState(
                  useMetadataSettings: gate,
                  phoneLandscapeUseMode: mode,
                  mobileSidePositionH: mobileH,
                  phoneSidePositionH: h,
                  phoneSidePositionV: v,
                );
                expect(
                  resolveSidePanelAlignmentFrom(
                    mode: mode,
                    useMetadataSettings: gate,
                    mobileSidePositionH: mobileH,
                    phoneSidePositionH: h,
                    phoneSidePositionV: v,
                  ),
                  resolveSidePanelAlignment(s),
                  reason: 'gate=$gate mobileH=$mobileH h=$h v=$v',
                );
              }
            }
          }
        });

        test('resolveControlPanelAnchorFrom (gate=$gate, $mode)', () {
          for (final PhoneSidePositionH h in PhoneSidePositionH.values) {
            for (final PhoneSidePositionV v in PhoneSidePositionV.values) {
              for (final bool mobile in <bool>[false, true]) {
                for (final bool landscape in <bool>[false, true]) {
                  // Deliberately also feed a LEGACY circle type under the gate:
                  // that pair is gate-suppressed, and the narrow form must
                  // suppress it exactly like the AppState overload does.
                  for (final PhoneLandscapeSliderType type
                      in PhoneLandscapeSliderType.values) {
                    debugIsMobilePlatformOverride = mobile;
                    final AppState s = AppState(
                      useMetadataSettings: gate,
                      phoneLandscapeUseMode: mode,
                      mobileSidePositionH: PhoneSidePositionH.left,
                      phoneSidePositionH: h,
                      phoneSidePositionV: v,
                      phoneLandscapeSliderType: type,
                    );
                    expect(
                      resolveControlPanelAnchorFrom(
                        mode: mode,
                        useMetadataSettings: gate,
                        mobileSidePositionH: PhoneSidePositionH.left,
                        phoneSidePositionH: h,
                        phoneSidePositionV: v,
                        sliderType: type,
                        isLandscape: landscape,
                        width: 800,
                      ),
                      resolveControlPanelAnchor(
                        s,
                        isLandscape: landscape,
                        width: 800,
                      ),
                      reason: 'gate=$gate h=$h v=$v mobile=$mobile '
                          'landscape=$landscape type=$type',
                    );
                  }
                }
              }
            }
          }
        });
      }
    }
  });

  // ── Part B/C: the widgets actually stop rebuilding ─────────────────────────

  group('overlay subscription is field-scoped', () {
    late BackgroundPlaybackEngine engine;
    setUp(() {
      engine = BackgroundPlaybackEngine(
        backend: PlayerBackend.mediaKit,
        attachNative: false,
      );
      useAppStore().set(const AppState(
        useMetadataSettings: true,
        useLegacyStoragePersistence: false,
        phoneLandscapeUseMode: PhoneLandscapeUseMode.rightSide,
      ));
      usePlayerUiStore().updateIsShowControl(true);
    });
    tearDown(() => engine.dispose());

    testWidgets(
        'an unrelated AppState write leaves the overlay alone, a read one '
        'rebuilds it', (tester) async {
      int builds = 0;
      ControlsOverlay.debugOnOverlayBuild = () => builds++;
      addTearDown(() => ControlsOverlay.debugOnOverlayBuild = null);

      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_playerShell(
        ControlsOverlay(
          file: const FileItem(name: 'clip.mp4', uri: 'file:///clip.mp4'),
          title: 'clip.mp4',
          showControl: () {},
          showControlForHover: (_) async {},
          hideControl: () {},
          showProgress: () {},
        ),
        engine,
      ));
      await tester.pumpAndSettle();
      // The mount is NOT a single build any more, and deliberately so: the bar
      // publishes its real layout zone after the first frame (it is only
      // knowable once the layout settled) and the overlay subscribes to it, so
      // a second build follows the first frame. What this test owns is the
      // DELTA each AppState write causes, so the baseline is taken here rather
      // than hard-coded to 1.
      final int afterMount = builds;
      expect(afterMount, greaterThan(0), reason: 'precondition: it mounted');

      // POSITIVE CONTROL FIRST: a field the overlay DOES read. If this does
      // not move the counter the harness is blind and the next assertion
      // proves nothing, so fail loudly instead of green.
      await _mutate(tester, () => useAppStore().set(
            useAppStore().state
                .copyWith(phoneLandscapeUseMode: PhoneLandscapeUseMode.leftSide),
          ));
      expect(builds, afterMount + 1,
          reason: 'the use mode steers the anchor — the overlay must rebuild');

      // The real regression: `transientRate` is written on every speed-gesture
      // pan update and rendered by NOTHING in the overlay.
      await _mutate(tester,
          () => useAppStore().set(useAppStore().state.copyWith(transientRate: 1.5)));
      expect(builds, afterMount + 1,
          reason: 'a write the overlay never reads must not rebuild it');

      await _unmount(tester);
    });

    testWidgets(
        'the dialog center-action rows ignore an unrelated AppState write',
        (tester) async {
      int builds = 0;
      debugOnCenterActionBuild = () => builds++;
      addTearDown(() => debugOnCenterActionBuild = null);

      await tester.pumpWidget(_dialogShell());
      await tester.pumpAndSettle();
      useAppStore().set(const AppState(
        phoneLandscapeUseMode: PhoneLandscapeUseMode.rightSide,
        phoneOneHandedScrubberKind: PhoneSideScrubberKind.dial,
      ));
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(builds, 1, reason: 'one build for the mount');

      await _mutate(tester, () => useAppStore().set(useAppStore().state
          .copyWith(centerZoneInwardAction: CircleSliderCenterAction.none)));
      expect(builds, 2,
          reason: 'a dropdown value it renders — the rows must rebuild');

      await _mutate(tester,
          () => useAppStore().set(useAppStore().state.copyWith(transientRate: 1.5)));
      expect(builds, 2,
          reason: 'a write the dialog never reads must not rebuild it');

      await _unmount(tester);
    });
  });

  // The panel is the expensive one: it re-runs a LayoutBuilder, a
  // CustomMultiChildLayout and the whole button wrap, and it sits UNDER the
  // control bar — whose own subscription 050dd4a4 already narrowed. A child's
  // `context.select` registers its own dependency, so that fix could not have
  // reached it.
  group('side panel subscription is field-scoped', () {
    late BackgroundPlaybackEngine engine;
    setUp(() {
      engine = BackgroundPlaybackEngine(
        backend: PlayerBackend.mediaKit,
        attachNative: false,
      );
      // A phone in landscape with the LEGACY circle panel: the only
      // CircleSliderLayout that mounts with the meta gate off (the gate retires
      // the legacy placement, see useLegacyCircleSliderPanel).
      debugIsMobilePlatformOverride = true;
      useAppStore().set(const AppState(
        useMetadataSettings: false,
        useLegacyStoragePersistence: false,
        phoneLandscapeUseMode: PhoneLandscapeUseMode.normal,
        phoneLandscapeSliderType: PhoneLandscapeSliderType.circleRight,
      ));
    });
    tearDown(() => engine.dispose());

    testWidgets(
        'the side panel ignores an unrelated AppState write, a geometry one '
        'rebuilds it', (tester) async {
      int builds = 0;
      CircleSliderLayout.debugOnPanelBuild = () => builds++;
      addTearDown(() => CircleSliderLayout.debugOnPanelBuild = null);

      // Landscape phone: wide enough for the panel, short enough to be a phone.
      tester.view.physicalSize = const Size(800, 360);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_playerShell(
        const ControlBar(
          showControl: _noop,
          showControlForHover: _noopFuture,
        ),
        engine,
        surface: const Size(800, 360),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(CircleSliderLayout), findsOneWidget,
          reason: 'precondition: the legacy circle panel is mounted');

      // A baseline, not a literal: the panel re-measures its button bar in a
      // post-frame callback, so the settled count is mount + measurement.
      final int baseline = builds;

      // POSITIVE CONTROL FIRST — a field the panel renders. If this does not
      // move the counter the harness is blind and the next assertion proves
      // nothing.
      await _mutate(
          tester, () => useAppStore().set(useAppStore().state.copyWith(sidewayBarPos: 0.4)));
      expect(builds, baseline + 1,
          reason: 'the button block position steers the delegate — the panel '
              'must rebuild');

      // The regression: `transientRate` is rewritten on every speed-gesture
      // stop and rendered by NOTHING in the panel.
      await _mutate(tester,
          () => useAppStore().set(useAppStore().state.copyWith(transientRate: 1.5)));
      expect(builds, baseline + 1,
          reason: 'a write the panel never reads must not rebuild it');

      await _unmount(tester);
    });
  });
}

void _noop() {}

Future<void> _noopFuture(Future<void> f) async => await f;

/// Escapes the FakeAsync zone so the zustand change stream actually delivers
/// (see the delivery note above), then lets the marked-dirty elements build.
///
/// Completes on a REAL change event rather than a guessed delay: a fixed
/// `Future.delayed` would both waste wall time and leave a live timer behind
/// for the next test, and "the write landed" must be a fact here or every
/// assertion below is measuring nothing.
Future<void> _mutate(WidgetTester tester, void Function() write) async {
  await tester.runAsync(() async {
    final Completer<void> delivered = Completer<void>();
    final StreamSubscription<dynamic> sub =
        StoreLocator().changes.listen((_) {
      if (!delivered.isCompleted) delivered.complete();
    });
    write();
    await delivered.future;
    await sub.cancel();
  });
  await tester.pump();
}

/// Unmounts the tree and drains the overlay's 200ms slide animations, so the
/// next test starts from a clean binding instead of a half-finished frame.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

/// StoreScope-equivalent that does NOT dispose the global [StoreLocator] on
/// unmount (the real `StoreScope` does, which breaks every later test).
Widget _storeScope(Widget child) => InheritedProvider<StoreLocator>.value(
      value: StoreLocator(),
      startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
        final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
        return sub.cancel;
      },
      lazy: false,
      child: child,
    );

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

Widget _playerShell(
  Widget body,
  BackgroundPlaybackEngine engine, {
  Size surface = const Size(1280, 720),
}) =>
    _storeScope(
      Provider<MediaPlayer>.value(
        value: _player(),
        child: ChangeNotifierProvider<BackgroundPlaybackEngine>.value(
          value: engine,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SizedBox(
                width: surface.width,
                height: surface.height,
                child: body,
              ),
            ),
          ),
        ),
      ),
    );

Widget _dialogShell() => _storeScope(
      MaterialApp(
        // SAME locale as [_playerShell] on purpose. The ARB delegates load
        // DEFERRED, and FakeAsync cannot advance a fresh locale's load: a
        // second widget test asking for a locale the file had not loaded yet
        // came up with a completely EMPTY tree — `MaterialApp` renders a blank
        // `Localizations` box, no exception, nothing to find. The first test
        // primes the cache; every later test must reuse its locale.
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => showSliderTypeDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
