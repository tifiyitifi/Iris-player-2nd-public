import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/meta_settings/bridge/state_bridge.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/kv/secure_kv.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/app_instance.dart';
import 'package:iris/widgets/popup.dart' show PopupDirection;

import 'helpers/sqlite3_loader.dart';

/// A shared settings blob is a WHOLE-SNAPSHOT value: an extra window's copy can
/// predate a change another window made, so writing it back would revert that
/// change. Only the authoritative window may rewrite it; the metadata rows path
/// is a per-field diff and stays safe.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await MetaSettingsModule.init(db);
    AppInstance.debugReset();
    resetKvStoreForTest();
  });

  tearDown(() async {
    AppInstance.debugReset();
    resetKvStoreForTest();
    await db.close();
  });

  test('an extra window mutation does not rewrite the settings blob', () async {
    final kv = MemoryKvStore();
    setKvStoreForTest(kv);
    AppInstance.debugSetSlot(2);

    final store = AppStore();
    await store.initialized;
    expect(store.loadOk, isTrue);

    await store.updateDefaultPopupDirection(PopupDirection.left);

    expect(kv.values.containsKey('app_state'), isFalse,
        reason: 'a stale snapshot must never overwrite the shared blob');
  });

  test('the primary window still writes the settings blob', () async {
    final kv = MemoryKvStore();
    setKvStoreForTest(kv);
    AppInstance.debugSetSlot(1);

    final store = AppStore();
    await store.initialized;

    await store.updateDefaultPopupDirection(PopupDirection.left);

    expect(kv.values['app_state'], isNotNull);
  });

  test('a settings import writes the blob from any window', () async {
    final kv = MemoryKvStore();
    setKvStoreForTest(kv);
    AppInstance.debugSetSlot(2);

    final store = AppStore();
    await store.initialized;

    // An import is an explicit whole-settings replacement: it is exempt from
    // the per-window blob gate. (A real bundle arrives JSON-decoded, so round
    // the snapshot through JSON like the import boundary does.)
    final bundle =
        jsonDecode(jsonEncode(AppState().toJson())) as Map<String, dynamic>;
    await store.importFromJson(bundle);

    expect(kv.values['app_state'], isNotNull);
  });

  test('an extra window writes only the rows it changed', () async {
    // A full snapshot already mirrors this window's baseline.
    final seed = AppState();
    await MetaSettingsModule.repo.replaceAllRawEntries([
      for (final e in StateBridge.encodeRows(seed).entries)
        SettingValuesTableCompanion.insert(key: e.key, value: e.value),
    ]);
    final kv = MemoryKvStore();
    final seedBlob = jsonEncode(seed.toJson());
    await kv.write(key: 'app_state', value: seedBlob);
    setKvStoreForTest(kv);
    AppInstance.debugSetSlot(2);

    final store = AppStore();
    await store.initialized;
    expect(store.loadOk, isTrue);

    // A sibling window changes a DIFFERENT setting while this window is open.
    final sibling = StateBridge.encodeRows(
      seed.copyWith(defaultPopupDirection: PopupDirection.right),
    )['app.defaultPopupDirection']!;
    await MetaSettingsModule.repo
        .saveRawValue('app.defaultPopupDirection', sibling);

    await store.updateThemeMode(ThemeMode.dark);

    final rows = await MetaSettingsModule.repo.loadRawValues();
    expect(rows['app.themeMode'], isNotNull,
        reason: 'this window\'s own change must still persist');
    expect(rows['app.defaultPopupDirection'], sibling,
        reason: 'the diff must not rewrite rows this window never changed');
    expect(kv.values['app_state'], seedBlob,
        reason: 'an extra window never rewrites the whole-snapshot blob');
  });

  test('an extra window keeps a metadata gate switch in memory', () async {
    // Gate ON: setting_values is authoritative and the blob is a rollback
    // mirror. An extra window's snapshot predates both a sibling's row write
    // and its blob write, so a gate transition from here must NOT replay
    // either whole-namespace write.
    final seed = AppState(useMetadataSettings: true);
    await MetaSettingsModule.repo.replaceAllRawEntries([
      for (final e in StateBridge.encodeRows(seed).entries)
        SettingValuesTableCompanion.insert(key: e.key, value: e.value),
    ]);
    final kv = MemoryKvStore();
    final seedBlob = jsonEncode(seed.toJson());
    await kv.write(key: 'app_state', value: seedBlob);
    setKvStoreForTest(kv);
    AppInstance.debugSetSlot(2);

    final store = AppStore();
    await store.initialized;
    expect(store.loadOk, isTrue);

    // A sibling window changed a setting while this window was open.
    final sibling = StateBridge.encodeRows(
      seed.copyWith(defaultPopupDirection: PopupDirection.right),
    )['app.defaultPopupDirection']!;
    await MetaSettingsModule.repo
        .saveRawValue('app.defaultPopupDirection', sibling);
    final blobBefore = kv.values['app_state'];
    final rowsBefore = _appRows(await MetaSettingsModule.repo.loadRawValues());

    await store.setMetadataGate(false);

    expect(store.state.useMetadataSettings, isFalse,
        reason: 'the switch still takes effect in THIS window');
    expect(kv.values['app_state'], blobBefore,
        reason: 'a stale snapshot must never rewrite the shared blob');
    expect(_appRows(await MetaSettingsModule.repo.loadRawValues()), rowsBefore,
        reason: 'clearAppValues() is a whole-namespace write an extra window '
            'must not replay');
    expect(rowsBefore['app.defaultPopupDirection'], sibling);
  });

  test('an extra window never reseeds the app rows on gate ON', () async {
    // Gate OFF: the blob is authoritative and the rows still exist (they are
    // preserved on purpose). Turning the gate ON from a stale extra window
    // used to REPLACE the whole `app.` namespace with that stale snapshot.
    final seed = AppState(useMetadataSettings: false);
    final siblingRows = StateBridge.encodeRows(
      seed.copyWith(defaultPopupDirection: PopupDirection.right),
    );
    await MetaSettingsModule.repo.replaceAllRawEntries([
      for (final e in siblingRows.entries)
        SettingValuesTableCompanion.insert(key: e.key, value: e.value),
    ]);
    final kv = MemoryKvStore();
    final seedBlob = jsonEncode(seed.toJson());
    await kv.write(key: 'app_state', value: seedBlob);
    setKvStoreForTest(kv);
    AppInstance.debugSetSlot(2);

    final store = AppStore();
    await store.initialized;
    expect(store.loadOk, isTrue);
    final blobBefore = kv.values['app_state'];
    final rowsBefore = _appRows(await MetaSettingsModule.repo.loadRawValues());

    await store.setMetadataGate(true);

    expect(store.state.useMetadataSettings, isTrue);
    expect(kv.values['app_state'], blobBefore,
        reason: 'a stale snapshot must never rewrite the shared blob');
    expect(_appRows(await MetaSettingsModule.repo.loadRawValues()), rowsBefore,
        reason: 'replaceAllRawEntries() is a whole-namespace write');
    expect(rowsBefore['app.defaultPopupDirection'],
        siblingRows['app.defaultPopupDirection']);
  });

  test('the primary window still persists a metadata gate switch', () async {
    final seed = AppState(useMetadataSettings: false);
    final kv = MemoryKvStore();
    await kv.write(key: 'app_state', value: jsonEncode(seed.toJson()));
    setKvStoreForTest(kv);
    AppInstance.debugSetSlot(1);

    final store = AppStore();
    await store.initialized;
    expect(store.loadOk, isTrue);

    await store.setMetadataGate(true);

    final written =
        jsonDecode(kv.values['app_state']!) as Map<String, dynamic>;
    expect(written['useMetadataSettings'], isTrue,
        reason: 'boot-time gate discovery reads the blob');
  });

  test('an unknown rows baseline never replaces a sibling window\'s rows',
      () async {
    // A row outside the `app.` namespace keeps the value table non-empty (so the
    // one-time blob import is skipped) while materialize() finds no `app.`
    // snapshot → load falls back to the blob with an UNKNOWN rows baseline.
    await MetaSettingsModule.repo.saveRawValue('scan.seed', '"x"');
    final kv = MemoryKvStore();
    final seeded = AppState();
    await kv.write(key: 'app_state', value: jsonEncode(seeded.toJson()));
    setKvStoreForTest(kv);
    AppInstance.debugSetSlot(2);

    final store = AppStore();
    await store.initialized;
    expect(store.loadOk, isTrue);

    // A sibling window changed a setting after this window's snapshot.
    final sibling = StateBridge.encodeRows(
      seeded.copyWith(defaultPopupDirection: PopupDirection.right),
    )['app.defaultPopupDirection']!;
    await MetaSettingsModule.repo
        .saveRawValue('app.defaultPopupDirection', sibling);

    await store.updateSeekStepSeconds(30);

    final rows = await MetaSettingsModule.repo.loadRawValues();
    expect(rows['app.defaultPopupDirection'], sibling,
        reason: 'a whole-snapshot reseed would clobber it');
  });
}

/// The `app.*` slice of the settings mirror — the namespace a gate transition
/// replaces wholesale (see `setMetadataGate`).
Map<String, String> _appRows(Map<String, String> rows) => {
      for (final e in rows.entries)
        if (e.key.startsWith('app.')) e.key: e.value,
    };
