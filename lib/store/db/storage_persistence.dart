import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:iris/models/db/repositories/favorites_db_repository.dart';
import 'package:iris/models/db/repositories/navigation_db_repository.dart';
import 'package:iris/models/db/repositories/storage_db_repository.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/store/storage_state.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/utils/logger.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyStore);

abstract class StoragePersistence {
  Future<StorageState?> load();
  Future<void> save(StorageState state);
}

/// Optional narrow write for backends where a full [StoragePersistence.save]
/// would replace unrelated data.
///
/// The DB backend writes a FULL replace (storages + favorites + navigation), so
/// a folder tap in a second window would restore that window's stale storage
/// list over changes made in the first one. Navigation has its own row, so it
/// gets its own narrow write; blob backends keep the full save (the whole state
/// is one value there).
abstract interface class StorageNavigationPersistence
    implements StoragePersistence {
  Future<void> saveNavigation(StorageState state);
}

/// Optional narrow writes for backends where a full [StoragePersistence.save]
/// would replace unrelated data (storages + favorites + navigation).
///
/// Each storage/favorite mutation owns specific row(s); writing only those keeps
/// a second IRIS window from restoring its stale lists over changes the first
/// one made. Blob backends keep the full save (their whole state is one value).
///
/// MULTI-WINDOW LIMIT: the narrow writers only exist on the DB backend
/// ([DbStoragePersistence]). A blob backend stores the WHOLE [StorageState] as
/// one value, so every mutation there falls back to a full [save] — two windows
/// editing storages / favorites / navigation concurrently are LAST-WRITE-WINS,
/// and the later snapshot silently drops the other window's row edits. Portable
/// mode does not change that: `FileJsonKv` merges per top-level KEY and
/// `storage_state` IS one key. Fixing it properly needs a read-modify-write
/// primitive keyed on one value across processes, which `KvStore` does not
/// expose (a plain lock around `write` cannot merge rows), so it is documented
/// instead — the legacy backend is a compatibility mode, the DB backend is the
/// default.
abstract interface class StorageEntryPersistence
    implements StoragePersistence {
  /// Inserts or updates one storage row (upsert: never assume the caller holds
  /// a brand-new id).
  Future<void> saveStorage(Storage storage);

  /// Removes one storage row.
  Future<void> deleteStorage(String id);

  /// Upserts/deletes individual favorite rows. A path change is a KEY change,
  /// so a remap arrives as one upsert plus one delete.
  Future<void> saveFavoriteChanges({
    List<Favorite> upserts = const [],
    List<Favorite> deletes = const [],
  });
}

class SecureStoragePersistence implements StoragePersistence {
  @override
  Future<StorageState?> load() async {
    try {
      final storage = getKvStore();
      final raw = await storage.read(key: 'storage_state');
      if (raw == null) return null;
      return StorageState.fromJson(json.decode(raw));
    } catch (e) {
      areaKeyLog.e('SecureStorage load error: $e');
      return null;
    }
  }

  @override
  Future<void> save(StorageState state) async {
    try {
      final storage = getKvStore();
      await storage.write(
        key: 'storage_state',
        value: json.encode(state.toJson()),
      );
    } catch (e) {
      areaKeyLog.e('SecureStorage save error: $e');
    }
  }
}

class DbStoragePersistence
    implements StorageNavigationPersistence, StorageEntryPersistence {
  final StorageDbRepository storageRepo;
  final FavoritesDbRepository favoritesRepo;
  final NavigationDbRepository navRepo;

  DbStoragePersistence({
    required this.storageRepo,
    required this.favoritesRepo,
    required this.navRepo,
  });

  @override
  Future<StorageState?> load() async {
    final storages = await storageRepo.getStorages();
    final favorites = await favoritesRepo.getFavorites();
    final nav = await navRepo.getNavigation();

    final currentStorage = nav?.currentStorageId == null
        ? null
        : storages.firstWhereOrNull((s) => s.id == nav!.currentStorageId);

    return StorageState(
      storages: storages,
      favorites: favorites,
      currentStorage: currentStorage,
      currentPath: nav?.currentPath ?? const [],
    );
  }

  @override
  Future<void> save(StorageState state) async {
    if (state.storages.isEmpty) {
      // Tripwire. The store gates saves on a successful load, so an empty list
      // here means "the user really has no storages left" — but this write is a
      // FULL REPLACE, so anything else reaching here (a partial/never-loaded
      // state) would silently drop every saved storage.
      final existing = await storageRepo.getStorages();
      if (existing.isNotEmpty) {
        areaKeyLog.w(
          'DbStoragePersistence.save: clearing ${existing.length} saved '
          'storage(s) with an empty in-memory list (legit only when the last '
          'one was removed)',
        );
      }
    }
    await storageRepo.replaceAllStorages(state.storages);
    await favoritesRepo.replaceAllFavorites(state.favorites);
    await navRepo.saveNavigation(
      currentStorageId: state.currentStorage?.id,
      currentPath: state.currentPath,
    );
    areaKeyLog.i("DbStoragePersistence SAVE: ${state.currentStorage?.id} ${state.currentPath}");
  }

  @override
  Future<void> saveNavigation(StorageState state) => navRepo.saveNavigation(
        currentStorageId: state.currentStorage?.id,
        currentPath: state.currentPath,
      );

  @override
  Future<void> saveStorage(Storage storage) =>
      storageRepo.updateInsertStorage(storage);

  @override
  Future<void> deleteStorage(String id) => storageRepo.removeStorage(id);

  @override
  Future<void> saveFavoriteChanges({
    List<Favorite> upserts = const [],
    List<Favorite> deletes = const [],
  }) async {
    // Upsert first: a remapped favorite keeps a usable row at the new key even
    // if the process dies before the stale old-key row is removed.
    for (final f in upserts) {
      await favoritesRepo.addFavorite(f);
    }
    for (final f in deletes) {
      await favoritesRepo.removeFavorite(f);
    }
  }
}
