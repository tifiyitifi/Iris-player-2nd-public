import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';

import 'helpers/sqlite3_loader.dart';

/// Persistence contract for the split corner-hide rows.
///
/// `slider.cornerHideMode` (desktop) and `slider.phoneCornerHideMode` (phone)
/// must never overwrite one another, and an install that predates the split
/// must keep hiding the way it did. The fallback is therefore read-only: it
/// seeds the new phone row from the old shared one, and the next phone write
/// stores its own value.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    useAppStore();
    await useAppStore().initialized;
  });

  AppState base() => const AppState(useMetadataSettings: true);

  tearDown(() async {
    useAppStore().set(const AppState());
    await MetaSettingsModule.repo.clearValues();
  });

  group('rehydration', () {
    test('a pre-split row seeds BOTH platforms (upgrade path)', () async {
      // What an install that set the direction before the split wrote.
      final state = await useAppStore().applySliderRows(base(), prefetched: {
        'cornerHideMode': 'diagonal',
      });
      expect(state.sidePanelCornerHideMode, SidePanelCornerHideMode.diagonal);
      expect(state.mobileSidePanelCornerHideMode,
          SidePanelCornerHideMode.diagonal,
          reason: 'the phone must not silently start hiding the old way');
    });

    test('the phone row wins over the shared one', () async {
      final state = await useAppStore().applySliderRows(base(), prefetched: {
        'cornerHideMode': 'vertical',
        'phoneCornerHideMode': 'horizontal',
      });
      expect(state.sidePanelCornerHideMode, SidePanelCornerHideMode.vertical);
      expect(state.mobileSidePanelCornerHideMode,
          SidePanelCornerHideMode.horizontal);
    });

    test('a corrupt row degrades to the default on both platforms', () async {
      final state = await useAppStore().applySliderRows(base(), prefetched: {
        'cornerHideMode': 'sideways',
        'phoneCornerHideMode': 'sideways',
      });
      expect(state.sidePanelCornerHideMode, SidePanelCornerHideMode.vertical);
      expect(state.mobileSidePanelCornerHideMode,
          SidePanelCornerHideMode.vertical);
    });

    test('no rows at all leaves both at the vertical default', () async {
      final state = await useAppStore().applySliderRows(base(), prefetched: {});
      expect(state.sidePanelCornerHideMode, SidePanelCornerHideMode.vertical);
      expect(state.mobileSidePanelCornerHideMode,
          SidePanelCornerHideMode.vertical);
    });
  });

  group('writes', () {
    test('each setter touches only its own row', () async {
      final store = useAppStore();
      await store.setMetadataGate(true);

      await store.updateMobileSidePanelCornerHideMode(
          SidePanelCornerHideMode.horizontal);
      final afterPhone = await MetaSettingsModule.repo.loadRawValues();
      expect(afterPhone['slider.phoneCornerHideMode'], 'horizontal');
      expect(afterPhone.containsKey('slider.cornerHideMode'), isFalse,
          reason: 'a phone write must not create or touch the desktop row');

      await store.updateSidePanelCornerHideMode(
          SidePanelCornerHideMode.diagonal);
      final afterDesktop = await MetaSettingsModule.repo.loadRawValues();
      expect(afterDesktop['slider.cornerHideMode'], 'diagonal');
      expect(afterDesktop['slider.phoneCornerHideMode'], 'horizontal',
          reason: 'a desktop write must not clobber the phone choice');
    });

    test('a phone write round-trips through rehydration', () async {
      final store = useAppStore();
      await store.setMetadataGate(true);
      await store.updateMobileSidePanelCornerHideMode(
          SidePanelCornerHideMode.diagonal);

      final state = await store.applySliderRows(base());
      expect(state.mobileSidePanelCornerHideMode,
          SidePanelCornerHideMode.diagonal);
      expect(state.sidePanelCornerHideMode, SidePanelCornerHideMode.vertical,
          reason: 'the desktop row was never written, so it keeps its default');
    });
  });
}
