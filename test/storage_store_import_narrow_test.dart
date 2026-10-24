import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/store/storage_state.dart';
import 'package:iris/store/db/storage_persistence.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/app_instance.dart';

/// Two windows share the storage/favorite rows. A MERGE import (append) used to
/// go through the whole-state `save`, i.e. a full replace with this window's
/// snapshot — so an entry another window added after this snapshot was loaded
/// vanished, and this window's browse location overwrote the shared nav row.
///
/// The append path must therefore write ONLY the imported rows. An OVERRIDE
/// import is an explicit "these are my storages/favorites now" and keeps the
/// documented full replace.
class _RecordingEntryPersistence implements StorageEntryPersistence {
  _RecordingEntryPersistence(this.initial);

  final StorageState? initial;

  int fullSaves = 0;
  final List<Storage> upserted = <Storage>[];
  final List<String> deleted = <String>[];
  final List<Favorite> favoriteUpserts = <Favorite>[];
  final List<Favorite> favoriteDeletes = <Favorite>[];

  @override
  Future<StorageState?> load() async => initial;

  @override
  Future<void> save(StorageState state) async => fullSaves++;

  @override
  Future<void> saveStorage(Storage storage) async => upserted.add(storage);

  @override
  Future<void> deleteStorage(String id) async => deleted.add(id);

  @override
  Future<void> saveFavoriteChanges({
    List<Favorite> upserts = const [],
    List<Favorite> deletes = const [],
  }) async {
    favoriteUpserts.addAll(upserts);
    favoriteDeletes.addAll(deletes);
  }
}

WebDAVStorage _webdav(String id) => WebDAVStorage(
      id: id,
      name: id,
      host: '$id.local',
      basePath: const ['/'],
      port: '5005',
      username: 'alice',
      password: 'p',
      https: false,
    );

/// The on-disk shape of an export section: `json.encode` runs each union's
/// `toJson()`, so the decoded round-trip is what the importer actually sees.
Map<String, dynamic> _payload(StorageState state) =>
    jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(AppInstance.debugReset);

  test('an APPEND import writes only the imported rows', () async {
    final local = _webdav('local');
    final incoming = _webdav('incoming');
    final persistence = _RecordingEntryPersistence(
      StorageState(
        storages: [local],
        currentStorage: local,
        currentPath: const ['local', 'dir'],
      ),
    );
    final store = UnifiedStorageStore(
      legacyPersistence: persistence,
      dbPersistence: persistence,
    );
    await store.initialized;
    expect(store.state.storages.map((s) => s.id), ['local']);

    await store.importFromJson(
      _payload(StorageState(
        storages: [incoming],
        favorites: [Favorite(storageId: 'incoming', path: const ['fav'])],
      )),
      override: false,
    );

    expect(
      persistence.fullSaves,
      0,
      reason: 'an append import must not replace the whole list',
    );
    expect(persistence.upserted.map((s) => s.id), ['incoming']);
    expect(persistence.deleted, isEmpty);
    expect(
      persistence.favoriteUpserts.map((f) => f.storageId),
      ['incoming'],
      reason: 'only the imported favorite is written',
    );
    // The in-memory list still shows the merged result.
    expect(store.state.storages.map((s) => s.id), ['local', 'incoming']);
    await store.dispose();
  });

  test('an OVERRIDE import keeps the documented full replace', () async {
    final local = _webdav('local');
    final incoming = _webdav('incoming');
    final persistence = _RecordingEntryPersistence(
      StorageState(storages: [local], currentStorage: local),
    );
    final store = UnifiedStorageStore(
      legacyPersistence: persistence,
      dbPersistence: persistence,
    );
    await store.initialized;

    await store.importFromJson(
      _payload(StorageState(storages: [incoming])),
      override: true,
    );

    expect(persistence.fullSaves, 1);
    expect(persistence.upserted, isEmpty);
    expect(store.state.storages.map((s) => s.id), ['incoming']);
    await store.dispose();
  });
}
