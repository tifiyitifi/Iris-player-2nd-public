import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/meta_settings/bridge/state_bridge.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/store/use_app_store.dart';

import 'helpers/sqlite3_loader.dart';

/// Switching the side panel's horizontal anchor changes THREE state fields:
/// the anchor, the paired one-handed mode (which carries the hand the scrubber
/// mirrors by) and its legacy placement shadow.
///
/// The anchor is `@JsonKey`-excluded, so it only ever lives in the `slider.`
/// AUX row, while the mode is a plain persisted field (`app.phoneLandscapeUseMode`
/// under the metadata gate, the legacy blob otherwise). Writing only the anchor
/// row therefore left the hand behind: a hard restart kept the panel where the
/// user put it but reverted the ring mirroring and the hide-direction fallback.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });
  tearDownAll(() => db.close);

  setUp(() async {
    await MetaSettingsModule.repo.clearValues();
  });

  Future<AppState> restartProxy() async {
    final AppState? fromRows = StateBridge.materialize(
        await MetaSettingsModule.repo.loadRawValues());
    return AppStore().applySliderRows(fromRows ?? const AppState());
  }

  group('desktop anchor H', () {
    test('persists the paired handedness, not just the posH row', () async {
      final store = AppStore();
      await store.setMetadataGate(true);
      await store.updatePhoneLandscapeUseMode(PhoneLandscapeUseMode.rightSide);

      await store.updatePhoneSidePositionH(PhoneSidePositionH.left);

      final raw = await MetaSettingsModule.repo.loadRawValues();
      expect(raw['slider.posH'], 'left');
      expect(raw['app.phoneLandscapeUseMode'], '"leftSide"',
          reason: 'the hand must reach the snapshot rows, or a restart reverts it');

      final reloaded = await restartProxy();
      expect(reloaded.phoneSidePositionH, PhoneSidePositionH.left);
      expect(reloaded.phoneLandscapeUseMode, PhoneLandscapeUseMode.leftSide);
    });

    test('a centre anchor keeps the existing hand and persists it', () async {
      final store = AppStore();
      await store.setMetadataGate(true);
      await store.updatePhoneLandscapeUseMode(PhoneLandscapeUseMode.leftSide);

      await store.updatePhoneSidePositionH(PhoneSidePositionH.center);

      expect(store.state.phoneLandscapeUseMode, PhoneLandscapeUseMode.leftSide,
          reason: 'centre is purely positional and must not re-mirror the hand');
      final raw = await MetaSettingsModule.repo.loadRawValues();
      expect(raw['slider.posH'], 'center');
      expect(raw['app.phoneLandscapeUseMode'], '"leftSide"');
    });
  });

  group('phone anchor H', () {
    test('persists the paired handedness next to the phonePosH row', () async {
      final store = AppStore();
      await store.setMetadataGate(true);
      await store.updatePhoneLandscapeUseMode(PhoneLandscapeUseMode.rightSide);

      await store.updateMobileSidePositionH(PhoneSidePositionH.left);

      final raw = await MetaSettingsModule.repo.loadRawValues();
      expect(raw['slider.phonePosH'], 'left');
      expect(raw['app.phoneLandscapeUseMode'], '"leftSide"');
    });

    test('centre folds to right on the phone, and the hand follows it',
        () async {
      final store = AppStore();
      await store.setMetadataGate(true);
      await store.updatePhoneLandscapeUseMode(PhoneLandscapeUseMode.leftSide);

      await store.updateMobileSidePositionH(PhoneSidePositionH.center);

      expect(store.state.mobileSidePositionH, PhoneSidePositionH.right,
          reason: 'phones have no centre anchor');
      final raw = await MetaSettingsModule.repo.loadRawValues();
      expect(raw['slider.phonePosH'], 'right');
      expect(raw['app.phoneLandscapeUseMode'], '"rightSide"',
          reason: 'the folded anchor is a real right hand, not a centre move');
    });

    test('normal mode is not resurrected by an anchor move', () async {
      final store = AppStore();
      await store.setMetadataGate(true);

      await store.updateMobileSidePositionH(PhoneSidePositionH.left);

      final raw = await MetaSettingsModule.repo.loadRawValues();
      expect(raw['slider.phonePosH'], 'left');
      expect(raw['app.phoneLandscapeUseMode'], '"normal"',
          reason: 'a positional move must not switch the panel on');
    });
  });

  group('a deprecated mode that slipped in is folded on the next write', () {
    // `AppStore._normalizeLoaded` is the only reader that folds
    // leftHanded/rightHanded, and a settings import applies a snapshot straight
    // onto the state without it. A setter that wrote such a value back would
    // re-create the row the migration was meant to erase, and every side query
    // (`isLeftSide`, `isRightSide`) reads NO side off it — so the hand the
    // panel is operated with silently becomes the other one.
    Future<void> seedDeprecated(AppStore store) async {
      await store.setMetadataGate(true);
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      store.set(store.state.copyWith(
        // ignore: deprecated_member_use_from_same_package
        phoneLandscapeUseMode: PhoneLandscapeUseMode.leftHanded,
      ));
    }

    test('the use-mode setter folds what it is handed', () async {
      final store = AppStore();
      await store.setMetadataGate(true);

      // ignore: deprecated_member_use_from_same_package
      await store.updatePhoneLandscapeUseMode(PhoneLandscapeUseMode.leftHanded);

      expect(store.state.phoneLandscapeUseMode, PhoneLandscapeUseMode.leftSide);
      expect(store.state.phoneLandscapeSliderType,
          PhoneLandscapeSliderType.circleLeft);
      final raw = await MetaSettingsModule.repo.loadRawValues();
      expect(raw['app.phoneLandscapeUseMode'], '"leftSide"');
    });

    test('a centre anchor move persists the folded hand, not the dead one',
        () async {
      final store = AppStore();
      await seedDeprecated(store);

      await store.updatePhoneSidePositionH(PhoneSidePositionH.center);

      expect(store.state.phoneLandscapeUseMode, PhoneLandscapeUseMode.leftSide,
          reason: 'centre keeps the hand — but as a live one');
      expect(
        resolvePanelSideIsLeft(
          anchor: resolveSidePanelAlignment(store.state),
          mode: store.state.phoneLandscapeUseMode,
        ),
        isTrue,
        reason: 'a left hand must not resolve as the right one',
      );
      final raw = await MetaSettingsModule.repo.loadRawValues();
      expect(raw['app.phoneLandscapeUseMode'], '"leftSide"');
      expect((await restartProxy()).phoneLandscapeUseMode,
          PhoneLandscapeUseMode.leftSide);
    });
  });
}
