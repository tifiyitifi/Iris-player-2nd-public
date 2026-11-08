import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/widgets/popups/storages/db/storages_utils/storage_utils.dart';

/// Regression guard for "the same drive shows up as two storage entries".
///
/// An entry created before the volume-keyed id formula keeps its legacy id (and
/// with it the node tree, library source, scenarios, tags and playback state).
/// Adding that same root again — a manual "add folder", a drop, or a fresh
/// enumeration — must REUSE the persisted entry instead of appending a second
/// one under the new id.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => null);

  late AppDatabase db;

  const volume = 'vol:e9471df0-d25d-4a57-89d5-e282dd089114';
  const rootBase = ['E:'];

  /// The pre-volume-id entry: legacy id, same volume + base.
  LocalStorage legacyEntry({String id = 'legacy-e'}) => LocalStorage(
        id: id,
        type: StorageType.internal,
        name: 'Extreme SSD (E:)',
        basePath: rootBase,
        volumeId: volume,
      );

  /// What today's `makeLocalStorage` produces for that same root.
  LocalStorage enumeratedEntry({List<String> basePath = rootBase}) =>
      makeLocalStorage(
        type: StorageType.internal,
        name: 'Extreme SSD (E:)',
        basePath: basePath,
        volumeId: volume,
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

  test('re-adding the same volume+root reuses the existing entry', () async {
    final store = useStorageStore();
    final existing = legacyEntry();
    await store.addStorage(existing);

    final again = enumeratedEntry();
    // The two formulas disagree, which is exactly what used to create the twin.
    expect(again.id, isNot(existing.id));

    final result = await store.addStorage(again);

    expect(result.id, existing.id);
    expect(
      store.state.storages
          .whereType<LocalStorage>()
          .where((s) => s.volumeId == volume),
      hasLength(1),
    );
    // The row must keep the ORIGINAL id: the library / scenario / tag rows are
    // keyed on it.
    expect(store.findById(existing.id), isNotNull);
    expect(store.findById(again.id), isNull);
  });

  test('the same volume at a different root stays a separate entry', () async {
    final store = useStorageStore();
    await store.addStorage(legacyEntry());
    await store.addStorage(enumeratedEntry(basePath: const ['E:', 'movies']));

    expect(
      store.state.storages
          .whereType<LocalStorage>()
          .where((s) => s.volumeId == volume),
      hasLength(2),
    );
  });

  test('the same root on a different volume stays a separate entry', () async {
    final store = useStorageStore();
    await store.addStorage(legacyEntry());
    await store.addStorage(makeLocalStorage(
      type: StorageType.internal,
      name: 'Other disk (E:)',
      basePath: rootBase,
      volumeId: 'vol:other',
    ));

    expect(
      store.state.storages
          .whereType<LocalStorage>()
          .where((s) => s.basePath.join('/') == 'E:'),
      hasLength(2),
    );
  });

  test('a candidate without a volume id is appended, not matched', () async {
    final store = useStorageStore();
    await store.addStorage(legacyEntry());

    final noVolume = makeLocalStorage(
      type: StorageType.internal,
      name: 'Extreme SSD (E:)',
      basePath: rootBase,
    );
    final result = await store.addStorage(noVolume);

    expect(result.id, noVolume.id);
    expect(
      store.state.storages
          .whereType<LocalStorage>()
          .where((s) => s.basePath.join('/') == 'E:'),
      hasLength(2),
    );
  });
}
