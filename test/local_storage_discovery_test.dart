import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/services/local_storage_discovery.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/widgets/popups/storages/db/storages_utils/storage_utils.dart';

/// The storagedb's local-disk discovery must run from the POPUP ROOT, so a
/// restored `currentStorage` (which sends `StoragesDb` straight to the file
/// page) can no longer starve it: the discovery used to live only in the
/// Storage tab's list widget, so the local storage row was never generated.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => null);

  late AppDatabase db;

  LocalStorage scanned(String volumeId) => makeLocalStorage(
        type: StorageType.internal,
        name: 'Local storage',
        basePath: const ['/storage/emulated/0'],
        volumeId: volumeId,
      );

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });

  tearDownAll(() async {
    await db.close();
  });

  setUp(() async {
    final store = useStorageStore();
    await store.initialized;
    for (final s in [...store.state.storages]) {
      await store.removeStorage(s);
    }
  });

  test('a discovered disk is persisted through the store', () async {
    final store = useStorageStore();
    final disk = scanned('vol:emulated');

    await LocalStorageDiscovery.ensure(
      store: store,
      enumerate: () async => [disk],
      resolveVolumeId: (_) async => 'vol:emulated',
    );

    expect(store.findById(disk.id), isNotNull);

    final persisted = await DbModule.storageRepo.getStorages();
    expect(persisted.whereType<LocalStorage>().map((s) => s.id), contains(disk.id));
  });

  test('a second run does not duplicate an already-known disk', () async {
    final store = useStorageStore();
    final disk = scanned('vol:emulated');

    Future<void> run() => LocalStorageDiscovery.ensure(
          store: store,
          enumerate: () async => [disk],
          resolveVolumeId: (_) async => 'vol:emulated',
        );

    await run();
    await run();

    expect(
      store.state.storages.whereType<LocalStorage>().where((s) => s.id == disk.id),
      hasLength(1),
    );
  });

  test('concurrent callers join the same in-flight run', () async {
    final store = useStorageStore();
    final disk = scanned('vol:emulated');

    final a = LocalStorageDiscovery.ensure(
      store: store,
      enumerate: () async => [disk],
      resolveVolumeId: (_) async => 'vol:emulated',
    );
    final b = LocalStorageDiscovery.ensure(
      store: store,
      enumerate: () async => [scanned('vol:other')],
      resolveVolumeId: (_) async => 'vol:other',
    );

    expect(identical(a, b), isTrue);
    await a;
  });

  test('an enumeration failure never escapes', () async {
    final store = useStorageStore();
    var calls = 0;

    await LocalStorageDiscovery.ensure(
      store: store,
      enumerate: () async {
        calls++;
        throw StateError('platform channel missing');
      },
    );

    // The single retry is the point: a failed run must not consume the caller's
    // only trigger (the caller's effect may never fire again).
    expect(calls, 2);
    expect(LocalStorageDiscovery.inFlight, isNull);
  });

  test('a failed run does not swallow the next run', () async {
    final store = useStorageStore();
    final disk = scanned('vol:emulated');
    var calls = 0;

    await LocalStorageDiscovery.ensure(
      store: store,
      enumerate: () async {
        calls++;
        if (calls == 1) throw StateError('store not ready');
        return [disk];
      },
      resolveVolumeId: (_) async => 'vol:emulated',
    );

    expect(calls, 2);
    expect(store.findById(disk.id), isNotNull);
    expect(LocalStorageDiscovery.inFlight, isNull);
  });

  test('a finished run does not latch: a later call discovers a new disk',
      () async {
    final store = useStorageStore();
    final second = scanned('vol:b');

    Future<void> run(LocalStorage disk) => LocalStorageDiscovery.ensure(
          store: store,
          enumerate: () async => [disk],
          resolveVolumeId: (_) async => 'vol:a',
        );

    await run(scanned('vol:a'));
    await run(second);

    expect(store.findById(second.id), isNotNull);
  });
}
