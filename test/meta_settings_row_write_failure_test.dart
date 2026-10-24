import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/meta_settings/model/db/dao/settings_dao.dart';
import 'package:iris/features/meta_settings/model/db/repositories/settings_db_repository.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';

import 'helpers/sqlite3_loader.dart';

/// A metadata mirror write that FAILED must not advance the diff baseline.
///
/// The baseline is a "these rows are stored" claim. When the DB rejected the
/// write and the baseline still moved, the failed fields disappeared from the
/// next diff — the mirror silently lost them and never wrote them again.
class _ThrowingRepo extends SettingsDbRepository {
  _ThrowingRepo(super.dao);

  @override
  Future<void> upsertRawValues(
    List<SettingValuesTableCompanion> entries,
  ) async {
    throw StateError('mirror write failed');
  }

  @override
  Future<void> replaceAllRawEntries(
    List<SettingValuesTableCompanion> entries,
  ) async {
    throw StateError('mirror reseed failed');
  }
}

/// A repo whose FIRST upsert stalls until the test releases it.
///
/// Used to prove that two overlapping writes are serialized: the newer
/// snapshot must be the one that lands last.
class _StallingRepo extends SettingsDbRepository {
  _StallingRepo(super.dao);

  final Completer<void> release = Completer<void>();
  int upserts = 0;

  @override
  Future<void> upsertRawValues(
    List<SettingValuesTableCompanion> entries,
  ) async {
    upserts++;
    if (upserts == 1) await release.future;
    await super.upsertRawValues(entries);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;
  late SettingsDbRepository realRepo;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
    realRepo = MetaSettingsModule.repo;
    final app = useAppStore();
    await app.initialized;
  });

  setUp(() async {
    MetaSettingsModule.repo = realRepo;
    await realRepo.clearValues();
    useAppStore().debugResetRowsBaseline();
  });

  tearDown(() async {
    MetaSettingsModule.repo = realRepo;
  });

  tearDownAll(() async {
    await db.close();
  });

  test('the module reports a failed mirror write instead of swallowing it',
      () async {
    MetaSettingsModule.repo = _ThrowingRepo(SettingsDao(db));

    expect(
      await MetaSettingsModule.persistChangedRows({'app.seekStepSeconds': '7'}),
      isFalse,
      reason: 'the caller must be able to tell that nothing was stored',
    );
    expect(await MetaSettingsModule.persistState(useAppStore().state), isFalse);
  });

  test('a failed write keeps the baseline, so the next write re-sends it',
      () async {
    final app = useAppStore();
    // Metadata mode, blob writes off: only the rows mirror is exercised.
    app.set(app.state.copyWith(
      useMetadataSettings: true,
      syncLegacyBlob: false,
    ));
    app.debugResetRowsBaseline();
    await app.persistSnapshot(app.state);

    // The mirror write fails: field A never reached the DB.
    MetaSettingsModule.repo = _ThrowingRepo(SettingsDao(db));
    app.set(app.state.copyWith(transientRate: 1.25));
    await app.persistSnapshot(app.state);

    // The next write succeeds and touches ANOTHER field.
    MetaSettingsModule.repo = realRepo;
    app.set(app.state.copyWith(seekStepSeconds: 7));
    await app.persistSnapshot(app.state);

    final rows = await realRepo.loadRawValues();
    expect(rows['app.seekStepSeconds'], '7');
    expect(
      rows['app.transientRate'],
      '1.25',
      reason: 'the field whose write failed must be retried by the next diff',
    );
  });

  test('overlapping mirror writes are serialized: the newest one lands last',
      () async {
    final app = useAppStore();
    app.set(app.state.copyWith(
      useMetadataSettings: true,
      syncLegacyBlob: false,
    ));
    app.debugResetRowsBaseline();
    await app.persistSnapshot(app.state);

    final stalling = _StallingRepo(SettingsDao(db));
    MetaSettingsModule.repo = stalling;

    // The first write stalls inside the DB call; the second one must wait for
    // it instead of racing past it and being overwritten.
    final first = app.persistSnapshot(app.state.copyWith(seekStepSeconds: 5));
    await Future<void>.delayed(Duration.zero);
    final second = app.persistSnapshot(app.state.copyWith(seekStepSeconds: 7));
    await Future<void>.delayed(Duration.zero);
    stalling.release.complete();
    await Future.wait([first, second]);

    final rows = await realRepo.loadRawValues();
    expect(rows['app.seekStepSeconds'], '7',
        reason: 'the newest snapshot must be the one stored');
  });
}
