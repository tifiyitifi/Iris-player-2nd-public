import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/store/storage_state.dart';
import 'package:iris/store/db/storage_persistence.dart';
import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/app_instance.dart';

/// The browse LOCATION is per-window state (see `_persistNavigation`): the
/// primary writes the shared navigation row, an extra window its own
/// session-scoped value.
///
/// A backend switch reloads the whole state from the new backend, which carries
/// that SHARED row. Without re-overlaying the session value the extra window is
/// silently moved to the primary's folder — the switch happens at startup
/// (`applyConfiguredBackends`), on the legacy toggle and after an import, so
/// this is not a rare path.
class _MemoryKv implements KvStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }

  @override
  Future<bool> containsKey({required String key}) async =>
      values.containsKey(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
}

class _FixedPersistence implements StoragePersistence {
  _FixedPersistence(this.stateToReturn);

  final StorageState? stateToReturn;

  @override
  Future<StorageState?> load() async => stateToReturn;

  @override
  Future<void> save(StorageState state) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final nas = WebDAVStorage(
    id: 'nas',
    name: 'nas',
    host: 'nas.local',
    basePath: const ['/'],
    port: '5005',
    username: 'alice',
    password: 'p',
    https: false,
  );

  setUp(() {
    AppInstance.debugSetSlot(2);
    setKvStoreForTest(_MemoryKv());
  });

  tearDown(() {
    resetKvStoreForTest();
    AppInstance.debugReset();
  });

  test('switchBackend keeps the extra window session browse location',
      () async {
    // This window's own location (slot 2 → `s2.` prefix).
    await getKvStore().write(
      key: 's2.storage_nav_state',
      value: jsonEncode({
        'storageId': 'nas',
        'path': ['session', 'dir'],
      }),
    );

    final shared = StorageState(
      storages: [nas],
      currentStorage: nas,
      currentPath: const ['primary', 'dir'],
    );
    final store = UnifiedStorageStore(
      legacyPersistence: _FixedPersistence(shared),
      dbPersistence: _FixedPersistence(shared),
    );
    await store.initialized;
    expect(
      store.state.currentPath,
      const ['session', 'dir'],
      reason: 'the initial load overlays the session location',
    );

    await store.switchBackend(true);

    expect(store.isUsingLegacy, isTrue);
    expect(
      store.state.currentPath,
      const ['session', 'dir'],
      reason: 'a backend switch must not drop the session browse location',
    );
    expect(store.state.currentStorage?.id, 'nas');
    await store.dispose();
  });
}
