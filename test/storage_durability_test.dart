import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/store/storage_state.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/db/storage_persistence.dart';
import 'package:iris/store/kv/secure_kv.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/app_instance.dart';

import 'helpers/sqlite3_loader.dart';

/// DB persistence whose READ fails — the exact condition that used to wipe
/// `storages_table`: the store fell back to its default (empty) state and any
/// later save replaced the whole table with that empty list.
class _LoadThrowingDbPersistence extends DbStoragePersistence {
  _LoadThrowingDbPersistence()
      : super(
          storageRepo: DbModule.storageRepo,
          favoritesRepo: DbModule.favoritesRepo,
          navRepo: DbModule.navRepo,
        );

  @override
  Future<StorageState?> load() async => throw StateError('db unavailable');
}

/// Inert legacy backend (never used by these cases).
class _StubPersistence implements StoragePersistence {
  @override
  Future<StorageState?> load() async => null;

  @override
  Future<void> save(StorageState state) async {}
}

DbStoragePersistence _realDbPersistence() => DbStoragePersistence(
      storageRepo: DbModule.storageRepo,
      favoritesRepo: DbModule.favoritesRepo,
      navRepo: DbModule.navRepo,
    );

Future<void> _seedWebdavRow(String id) {
  return DbModule.storageDao.insert(
    StoragesTableCompanion.insert(
      id: id,
      type: StorageType.webdav.index,
      name: id,
      basePath: '["/"]',
      host: const Value('192.168.1.4'),
      resolvedHost: const Value('192.168.1.4'),
      resolvedHosts: const Value('["192.168.1.4"]'),
      port: const Value('8090'),
      username: const Value('u'),
      password: const Value('p'),
      https: const Value(false),
    ),
  );
}

void main() {
  ensureSqlite3Loaded();

  // DbModule's statics are initialized once per process.
  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  // Clean slate between cases (the seeded ids are the only rows we create).
  setUp(() async {
    await DbModule.storageDao.deleteById('s1');
    await DbModule.storageDao.deleteById('s2');
    await DbModule.favoritesRepo.replaceAllFavorites(const []);
  });

  test('a failed load must not let a save wipe the storage table', () async {
    await _seedWebdavRow('s1');
    await _seedWebdavRow('s2');
    expect(await DbModule.storageDao.getAll(), hasLength(2));

    final store = UnifiedStorageStore(
      legacyPersistence: _StubPersistence(),
      dbPersistence: _LoadThrowingDbPersistence(),
    );
    await store.initialized;

    expect(store.loadOk, isFalse);
    expect(store.loaded, isTrue, reason: 'UI readiness still resolves');
    expect(store.state.storages, isEmpty);

    // Ordinary actions that persist would previously have replaced the whole
    // table with the never-loaded (empty) state.
    await store.updateCurrentPath(['/']);
    await store.updateCurrentStorage(null);

    final rows = await DbModule.storageDao.getAll();
    expect(rows, hasLength(2), reason: 'saved storages must survive');
    expect(rows.map((r) => r.id), containsAll(<String>['s1', 's2']));
  });

  test('a successful load still persists a user-initiated removal', () async {
    await _seedWebdavRow('s1');

    final store = UnifiedStorageStore(
      legacyPersistence: _StubPersistence(),
      dbPersistence: _realDbPersistence(),
    );
    await store.initialized;

    expect(store.loadOk, isTrue);
    expect(store.state.storages, hasLength(1));

    await store.removeStorage(store.state.storages.single);

    expect(await DbModule.storageDao.getAll(), isEmpty,
        reason: 'an authoritative empty list must remain persistable');
  });

  test('a folder tap does not replace another window\'s fresh storage', () async {
    await _seedWebdavRow('s1');

    // Window B loads while only s1 exists.
    final secondWindow = UnifiedStorageStore(
      legacyPersistence: _StubPersistence(),
      dbPersistence: _realDbPersistence(),
    );
    await secondWindow.initialized;
    expect(secondWindow.state.storages.map((s) => s.id), ['s1']);

    // Window A adds s2 after B's snapshot was taken.
    await _seedWebdavRow('s2');

    // B browses: navigation has its own row, so the storage table must stay
    // untouched (a full-replace save would have deleted s2).
    await secondWindow.updateCurrentPath(['Movies']);

    final rows = await DbModule.storageDao.getAll();
    expect(rows.map((r) => r.id), containsAll(<String>['s1', 's2']));
    final nav = await DbModule.navRepo.getNavigation();
    expect(nav?.currentPath, ['Movies']);
  });

  test('editing an entry keeps a sibling window\'s storage and favorite',
      () async {
    await _seedWebdavRow('s1');

    // Window B loads while only s1 exists.
    final secondWindow = UnifiedStorageStore(
      legacyPersistence: _StubPersistence(),
      dbPersistence: _realDbPersistence(),
    );
    await secondWindow.initialized;

    // Window A adds s2 and a favorite after B's snapshot was taken.
    await _seedWebdavRow('s2');
    await DbModule.favoritesRepo
        .addFavorite(Favorite(storageId: 's2', path: const ['Movies']));

    final renamed =
        secondWindow.state.storages.single.copyWith(name: 'renamed');
    await secondWindow.updateStorage(0, renamed);

    final rows = await DbModule.storageDao.getAll();
    expect(rows.map((r) => r.id), containsAll(<String>['s1', 's2']),
        reason: 'a full-replace save would have deleted s2');
    expect(rows.firstWhere((r) => r.id == 's1').name, 'renamed',
        reason: 'the edit itself must still land');
    expect(
      (await DbModule.favoritesRepo.getFavorites()).map((f) => f.storageId),
      contains('s2'),
      reason: 'editing a storage must not restore a stale favorite list',
    );
  });

  test('adding a favorite keeps a sibling window\'s new storage', () async {
    await _seedWebdavRow('s1');

    final secondWindow = UnifiedStorageStore(
      legacyPersistence: _StubPersistence(),
      dbPersistence: _realDbPersistence(),
    );
    await secondWindow.initialized;

    // Window A adds s2 after B's snapshot.
    await _seedWebdavRow('s2');

    await secondWindow
        .addFavorite(Favorite(storageId: 's1', path: const ['Mine']));

    final rows = await DbModule.storageDao.getAll();
    expect(rows.map((r) => r.id), containsAll(<String>['s1', 's2']),
        reason: 'adding a favorite must not replace the storage table');
    expect(
      (await DbModule.favoritesRepo.getFavorites()).map((f) => f.path),
      contains(equals(const ['Mine'])),
    );
  });

  test('the browse location is per window', () async {
    await _seedWebdavRow('s1');
    setKvStoreForTest(MemoryKvStore());
    AppInstance.debugSetSlot(1);
    addTearDown(() {
      resetKvStoreForTest();
      AppInstance.debugReset();
    });

    final primary = UnifiedStorageStore(
      legacyPersistence: _StubPersistence(),
      dbPersistence: _realDbPersistence(),
    );
    await primary.initialized;
    await primary.updateCurrentPath(['Primary']);

    AppInstance.debugSetSlot(2);
    final second = UnifiedStorageStore(
      legacyPersistence: _StubPersistence(),
      dbPersistence: _realDbPersistence(),
    );
    await second.initialized;
    expect(second.state.currentPath, ['Primary'],
        reason: 'a new window seeds from the shared location once');
    await second.updateCurrentPath(['Second']);

    expect((await DbModule.navRepo.getNavigation())?.currentPath, ['Primary'],
        reason: 'the shared nav row still belongs to the primary window');

    // The extra window restores its own location...
    final secondAgain = UnifiedStorageStore(
      legacyPersistence: _StubPersistence(),
      dbPersistence: _realDbPersistence(),
    );
    await secondAgain.initialized;
    expect(secondAgain.state.currentPath, ['Second']);

    // ...and the primary keeps its own.
    AppInstance.debugSetSlot(1);
    final primaryAgain = UnifiedStorageStore(
      legacyPersistence: _StubPersistence(),
      dbPersistence: _realDbPersistence(),
    );
    await primaryAgain.initialized;
    expect(primaryAgain.state.currentPath, ['Primary']);
  });

  test('a secondary window does not persist shared config on dispose',
      () async {
    await _seedWebdavRow('s1');
    AppInstance.debugSetSlot(2);
    addTearDown(AppInstance.debugReset);

    final store = UnifiedStorageStore(
      legacyPersistence: _StubPersistence(),
      dbPersistence: _realDbPersistence(),
    );
    await store.initialized;
    // Simulate the primary adding a storage while this window was open.
    await _seedWebdavRow('s2');

    await store.dispose();

    final rows = await DbModule.storageDao.getAll();
    expect(rows.map((r) => r.id), containsAll(<String>['s1', 's2']),
        reason: 'a stale shutdown snapshot must not replace the table');
  });

  test('the primary window still persists on dispose', () async {
    await _seedWebdavRow('s1');
    AppInstance.debugSetSlot(1);
    addTearDown(AppInstance.debugReset);

    final store = UnifiedStorageStore(
      legacyPersistence: _StubPersistence(),
      dbPersistence: _realDbPersistence(),
    );
    await store.initialized;
    await store.removeStorage(store.state.storages.single);

    await store.dispose();

    expect(await DbModule.storageDao.getAll(), isEmpty);
  });
}
