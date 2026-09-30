import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_queue_layout.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_queue_profile.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';

/// The queue layout is a persisted enum with two hard invariants:
///
/// 1. An existing install must keep the toolbar it already chose. The shipped
///    defaults are deliberately NOT V1 (landscape ships v3, the other two v2),
///    which is only safe because a default applies when nothing is stored: a
///    per-profile row wins, and the pre-split row is the fallback beneath it.
/// 2. The choice is remembered PER SCREEN SHAPE (desktop / phone landscape /
///    phone portrait), because a sideways phone has room for a different toolbar
///    than the same phone upright. A single shared value would mean rotating the
///    phone rearranges the toolbar the user just set up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    useAppStore();
    await useAppStore().initialized;
  });

  group('ScenarioQueueLayout', () {
    test('each shape ships the default that suits it', () {
      // A sideways phone has the width for the floating grid; upright and the
      // desktop dock are better served by the condensed row. V2 rather than V1
      // everywhere because a fresh install has no toolbar to protect.
      expect(const AppState().scenarioQueueLayoutLandscape,
          ScenarioQueueLayout.v3);
      expect(const AppState().scenarioQueueLayoutDesktop,
          ScenarioQueueLayout.v2);
      expect(const AppState().scenarioQueueLayoutPortrait,
          ScenarioQueueLayout.v2);
    });

    test('nextScenarioQueueLayout cycles all three and round-trips', () {
      expect(nextScenarioQueueLayout(ScenarioQueueLayout.v1),
          ScenarioQueueLayout.v2);
      expect(nextScenarioQueueLayout(ScenarioQueueLayout.v2),
          ScenarioQueueLayout.v3);
      expect(nextScenarioQueueLayout(ScenarioQueueLayout.v3),
          ScenarioQueueLayout.v1);
      for (final layout in ScenarioQueueLayout.values) {
        var walked = layout;
        for (var i = 0; i < ScenarioQueueLayout.values.length; i++) {
          walked = nextScenarioQueueLayout(walked);
        }
        expect(walked, layout, reason: 'the cycle must return to $layout');
      }
    });
  });

  group('ScenarioQueueProfile', () {
    test('desktop is one bucket: a resized window has no rotation', () {
      for (final runtime in ScreenOrientation.values) {
        for (final real in Orientation.values) {
          expect(
            resolveScenarioQueueProfile(
              mobile: false,
              runtimeOrientation: runtime,
              realOrientation: real,
            ),
            ScenarioQueueProfile.desktop,
          );
        }
      }
    });

    test('phones split by orientation, deferring to the runtime override', () {
      ScenarioQueueProfile resolve(ScreenOrientation runtime, Orientation real) =>
          resolveScenarioQueueProfile(
            mobile: true,
            runtimeOrientation: runtime,
            realOrientation: real,
          );

      expect(resolve(ScreenOrientation.landscape, Orientation.portrait),
          ScenarioQueueProfile.landscape,
          reason: 'the locked orientation wins over the real one');
      expect(resolve(ScreenOrientation.portrait, Orientation.landscape),
          ScenarioQueueProfile.portrait);
      // `device` defers to the real orientation.
      expect(resolve(ScreenOrientation.device, Orientation.landscape),
          ScenarioQueueProfile.landscape);
      expect(resolve(ScreenOrientation.device, Orientation.portrait),
          ScenarioQueueProfile.portrait);
    });
  });

  group('AppState scenario queue prefs', () {
    test('breadcrumb is hidden by default', () {
      expect(const AppState().scenarioQueueShowBreadcrumb, isFalse);
    });

    test('the V3 bar starts at the shared default in every profile', () {
      const state = AppState();
      expect(state.scenarioQueueBarOffsetFor(ScenarioQueueProfile.desktop),
          kScenarioQueueBarDefaultOffset);
      expect(state.scenarioQueueBarOffsetFor(ScenarioQueueProfile.portrait),
          kScenarioQueueBarDefaultOffset);
      expect(state.scenarioQueueBarOffsetFor(ScenarioQueueProfile.landscape),
          kScenarioQueueBarDefaultOffset);
    });

    test('profiles read and write independently', () {
      final state = const AppState()
          .withScenarioQueueLayout(ScenarioQueueProfile.portrait,
              ScenarioQueueLayout.v3)
          .withScenarioQueueBarOffset(
              ScenarioQueueProfile.portrait, const Offset(0.1, 0.2));

      expect(state.scenarioQueueLayoutFor(ScenarioQueueProfile.portrait),
          ScenarioQueueLayout.v3);
      expect(state.scenarioQueueBarOffsetFor(ScenarioQueueProfile.portrait),
          const Offset(0.1, 0.2));
      // The other two profiles must not have moved off their own defaults.
      expect(state.scenarioQueueLayoutFor(ScenarioQueueProfile.desktop),
          ScenarioQueueLayout.v2);
      expect(state.scenarioQueueLayoutFor(ScenarioQueueProfile.landscape),
          ScenarioQueueLayout.v3);
      expect(state.scenarioQueueBarOffsetFor(ScenarioQueueProfile.desktop),
          kScenarioQueueBarDefaultOffset);
      expect(state.scenarioQueueBarOffsetFor(ScenarioQueueProfile.landscape),
          kScenarioQueueBarDefaultOffset);
    });

    test('scenario queue prefs stay out of the legacy blob / snapshot', () {
      final json = const AppState().toJson();
      for (final key in const [
        'scenarioQueueLayoutDesktop',
        'scenarioQueueLayoutPortrait',
        'scenarioQueueLayoutLandscape',
        'scenarioQueueBarOffsetDesktop',
        'scenarioQueueBarOffsetPortrait',
        'scenarioQueueBarOffsetLandscape',
        'scenarioQueueShowBreadcrumb',
      ]) {
        expect(json.containsKey(key), isFalse, reason: '$key must not persist');
      }
    });
  });

  group('AppStore scenario queue prefs', () {
    tearDown(() async {
      final store = useAppStore();
      store.set(const AppState());
    });

    test('updateScenarioQueueLayout only touches the named profile', () async {
      final app = useAppStore();
      await app.updateScenarioQueueLayout(
          ScenarioQueueProfile.desktop, ScenarioQueueLayout.v3);
      expect(app.state.scenarioQueueLayoutFor(ScenarioQueueProfile.desktop),
          ScenarioQueueLayout.v3);
      expect(app.state.scenarioQueueLayoutFor(ScenarioQueueProfile.portrait),
          ScenarioQueueLayout.v2);
      expect(app.state.scenarioQueueLayoutFor(ScenarioQueueProfile.landscape),
          ScenarioQueueLayout.v3);
    });

    test('toggleScenarioQueueLayout cycles the named profile only', () async {
      final app = useAppStore();
      // Landscape ships on v3, so the first toggle walks it to v1.
      await app.toggleScenarioQueueLayout(ScenarioQueueProfile.landscape);
      expect(app.state.scenarioQueueLayoutFor(ScenarioQueueProfile.landscape),
          ScenarioQueueLayout.v1);
      await app.toggleScenarioQueueLayout(ScenarioQueueProfile.landscape);
      expect(app.state.scenarioQueueLayoutFor(ScenarioQueueProfile.landscape),
          ScenarioQueueLayout.v2);
      await app.toggleScenarioQueueLayout(ScenarioQueueProfile.landscape);
      expect(app.state.scenarioQueueLayoutFor(ScenarioQueueProfile.landscape),
          ScenarioQueueLayout.v3);
      expect(app.state.scenarioQueueLayoutFor(ScenarioQueueProfile.desktop),
          ScenarioQueueLayout.v2,
          reason: 'cycling one shape must not touch another');
    });

    test('updateScenarioQueueBarOffset clamps to the travel', () async {
      final app = useAppStore();
      await app.updateScenarioQueueBarOffset(
          ScenarioQueueProfile.portrait, const Offset(-3, 4));
      expect(app.state.scenarioQueueBarOffsetFor(ScenarioQueueProfile.portrait),
          const Offset(0, 1));
      expect(
          app.state.scenarioQueueBarOffsetFor(ScenarioQueueProfile.desktop),
          kScenarioQueueBarDefaultOffset);
    });

    test('updateScenarioQueueShowBreadcrumb writes the state', () async {
      final app = useAppStore();
      await app.updateScenarioQueueShowBreadcrumb(true);
      expect(app.state.scenarioQueueShowBreadcrumb, isTrue);
      await app.updateScenarioQueueShowBreadcrumb(false);
      expect(app.state.scenarioQueueShowBreadcrumb, isFalse);
    });
  });

  group('window.scenarioQueueLayout* AUX rows', () {
    AppState base() => const AppState(useMetadataSettings: true);

    tearDown(() async {
      useAppStore().set(const AppState());
    });

    test('the pre-split row seeds all three profiles (upgrade path)', () async {
      // What an install that already chose V2 wrote before the split.
      final state = await useAppStore().applyWindowRows(base(), prefetched: {
        'scenarioQueueLayout': 'v2',
      });
      expect(state.scenarioQueueLayoutFor(ScenarioQueueProfile.desktop),
          ScenarioQueueLayout.v2);
      expect(state.scenarioQueueLayoutFor(ScenarioQueueProfile.portrait),
          ScenarioQueueLayout.v2);
      expect(state.scenarioQueueLayoutFor(ScenarioQueueProfile.landscape),
          ScenarioQueueLayout.v2);
    });

    test('an existing V1 choice survives the new per-shape defaults', () async {
      // The defaults moved to V2/V2/V3, but they only apply when NOTHING is
      // stored. A user who deliberately picked V1 in the pre-split build has a
      // row saying so, and must not be silently moved onto V2/V3 by the upgrade.
      final state = await useAppStore().applyWindowRows(base(), prefetched: {
        'scenarioQueueLayout': 'v1',
      });
      for (final profile in ScenarioQueueProfile.values) {
        expect(state.scenarioQueueLayoutFor(profile), ScenarioQueueLayout.v1,
            reason: '$profile must keep the toolbar the user chose');
      }
    });

    test('a per-profile row wins over the pre-split seed', () async {
      final state = await useAppStore().applyWindowRows(base(), prefetched: {
        'scenarioQueueLayout': 'v2',
        'scenarioQueueLayoutPortrait': 'v3',
      });
      expect(state.scenarioQueueLayoutFor(ScenarioQueueProfile.portrait),
          ScenarioQueueLayout.v3);
      expect(state.scenarioQueueLayoutFor(ScenarioQueueProfile.desktop),
          ScenarioQueueLayout.v2);
    });

    test('no rows at all leaves every profile at its per-shape default',
        () async {
      // A fresh install: the per-profile row is absent AND there is no pre-split
      // seed, so the AppState defaults are what the user gets.
      final state = await useAppStore().applyWindowRows(base(), prefetched: {});
      expect(state.scenarioQueueLayoutFor(ScenarioQueueProfile.landscape),
          ScenarioQueueLayout.v3);
      expect(state.scenarioQueueLayoutFor(ScenarioQueueProfile.desktop),
          ScenarioQueueLayout.v2);
      expect(state.scenarioQueueLayoutFor(ScenarioQueueProfile.portrait),
          ScenarioQueueLayout.v2);
      for (final profile in ScenarioQueueProfile.values) {
        expect(state.scenarioQueueBarOffsetFor(profile),
            kScenarioQueueBarDefaultOffset);
      }
    });

    test('an unknown stored name degrades instead of throwing', () async {
      final state = await useAppStore().applyWindowRows(base(), prefetched: {
        'scenarioQueueLayout': 'v2',
        'scenarioQueueLayoutDesktop': 'v9',
        'scenarioQueueLayoutLandscape': 'grid',
      });
      // A name this build does not know must fall through to the seed, never
      // crash the boot and never half-apply.
      expect(state.scenarioQueueLayoutFor(ScenarioQueueProfile.desktop),
          ScenarioQueueLayout.v2);
      expect(state.scenarioQueueLayoutFor(ScenarioQueueProfile.landscape),
          ScenarioQueueLayout.v2);
      expect(state.scenarioQueueLayoutFor(ScenarioQueueProfile.portrait),
          ScenarioQueueLayout.v2);
    });

    test('bar offsets round-trip through the "x,y" row', () async {
      final store = useAppStore();
      await store.setMetadataGate(true);
      await store.updateScenarioQueueBarOffset(
          ScenarioQueueProfile.landscape, const Offset(0.25, 0.75));

      final raw = await MetaSettingsModule.repo.loadRawValues();
      expect(raw['window.scenarioQueueBarOffsetLandscape'], isNotNull);

      final state = await store.applyWindowRows(base());
      expect(state.scenarioQueueBarOffsetFor(ScenarioQueueProfile.landscape),
          const Offset(0.25, 0.75));
      expect(state.scenarioQueueBarOffsetFor(ScenarioQueueProfile.desktop),
          kScenarioQueueBarDefaultOffset);
    });

    test('a malformed offset row keeps the default placement', () async {
      final state = await useAppStore().applyWindowRows(base(), prefetched: {
        'scenarioQueueBarOffsetDesktop': 'not-a-fraction',
      });
      expect(state.scenarioQueueBarOffsetFor(ScenarioQueueProfile.desktop),
          kScenarioQueueBarDefaultOffset);
    });

    test('the store writes one row per profile, never the shared one', () async {
      final store = useAppStore();
      await store.setMetadataGate(true);
      await store.updateScenarioQueueLayout(
          ScenarioQueueProfile.portrait, ScenarioQueueLayout.v3);

      final raw = await MetaSettingsModule.repo.loadRawValues();
      expect(raw['window.scenarioQueueLayoutPortrait'], isNotNull);
      expect(raw.containsKey('window.scenarioQueueLayout'), isFalse,
          reason: 'the pre-split row is a read-only migration seed');
    });
  });

  group('window.*IsolationPct AUX rows', () {
    AppState base() => const AppState(useMetadataSettings: true);

    tearDown(() async {
      useAppStore().set(const AppState());
    });

    test('prefetched rows override the defaults', () async {
      final state = await useAppStore().applyWindowRows(base(), prefetched: {
        'sidePanelIsolationPct': '12.5',
        'linearBarIsolationPct': '40',
      });
      expect(state.sidePanelIsolationPct, 12.5);
      expect(state.linearBarIsolationPct, 40);
    });

    test('stored values are clamped to their hard bounds', () async {
      final state = await useAppStore().applyWindowRows(base(), prefetched: {
        'sidePanelIsolationPct': '999',
        'linearBarIsolationPct': '-5',
      });
      expect(state.sidePanelIsolationPct, 50);
      expect(state.linearBarIsolationPct, 0);
    });

    test('absent rows keep the AppState defaults', () async {
      final state = await useAppStore().applyWindowRows(base(), prefetched: {});
      expect(state.sidePanelIsolationPct, 5.0);
      expect(state.linearBarIsolationPct, 25.0);
    });

    test('the store updaters persist and clamp', () async {
      final store = useAppStore();
      await store.setMetadataGate(true);
      await store.updateSidePanelIsolationPct(80);
      await store.updateLinearBarIsolationPct(-1);
      expect(store.state.sidePanelIsolationPct, 50);
      expect(store.state.linearBarIsolationPct, 0);

      final raw = await MetaSettingsModule.repo.loadRawValues();
      expect(double.tryParse(raw['window.sidePanelIsolationPct'] ?? ''), 50);
      expect(double.tryParse(raw['window.linearBarIsolationPct'] ?? ''), 0);
    });
  });
}
