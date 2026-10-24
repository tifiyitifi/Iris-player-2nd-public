import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:iris/store/kv/kv_keys.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:flutter_zustand/flutter_zustand.dart' as zustand;
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/storages/storage_scope_key.dart';
import 'package:iris/models/store/storage_state.dart';
import 'package:iris/store/db/storage_persistence.dart';
import 'package:iris/store/persistent_store.dart';
import 'package:iris/utils/app_instance.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyStore);

Map<String, dynamic> _stripConnectionStatus(
    Map<String, dynamic> json) {
  final result = Map<String, dynamic>.from(json);
  result.remove('storageConnectionStatus');
  return result;
}

/// Most-recent-first union of WebDAV resolved hosts, capped at 5.
List<String> _mergeResolvedHosts(List<String> incoming, List<String> current) {
  final merged = <String>[];
  for (final host in [...incoming, ...current]) {
    if (host.isEmpty || merged.contains(host)) continue;
    merged.add(host);
    if (merged.length >= 5) break;
  }
  return merged;
}

  // not use now.
class StorageStore extends PersistentStore<StorageState> {
  StorageStore() : super(StorageState());

  /// Shared-config store: an extra window's shutdown snapshot may predate a
  /// change another window made (see [PersistentStore.persistOnDispose]).
  @override
  bool get persistOnDispose => AppInstance.isPrimary;

  Storage? findById(String id) => state.storages.firstWhereOrNull((storage) => storage.id == id);

  bool isConnected(String id) => state.storageConnectionStatus[id] ?? true;

  void markDisconnected(String id) {
    set(state.copyWith(
      storageConnectionStatus: {
        ...state.storageConnectionStatus,
        id: false,
      },
    ));
  }

  void markConnected(String id) {
    final updated = Map<String, bool>.from(state.storageConnectionStatus);
    updated.remove(id);
    set(state.copyWith(storageConnectionStatus: updated));
  }

  Future<void> addStorage(Storage storage) async {
    set(state.copyWith(storages: [...state.storages, storage]));
    await save(state);
  }

  Future<void> updateStorage(int index, Storage storage) async {
    if (index < 0 || index >= state.storages.length) {
      return;
    }

    set(state.copyWith(
        storages: [...state.storages]
          ..removeAt(index)
          ..insert(index, storage)));
    await save(state);
  }

  Future<void> removeStorage(Storage storage) async {
    set(state.copyWith(storages: [...state.storages]..remove(storage)));
    await save(state);
  }

  Future<void> addFavorite(Favorite favorite) async {
    set(state.copyWith(favorites: [...state.favorites, favorite]));
    await save(state);
  }

  Future<void> removeFavorite(Favorite favorite) async {
    set(state.copyWith(favorites: [...state.favorites]..remove(favorite)));
    await save(state);
  }

  Future<void> updateCurrentStorage(Storage? storage) async {
    set(state.copyWith(currentStorage: storage));
    await save(state);
  }

  Future<void> updateCurrentPath(List<String> path) async {
    set(state.copyWith(currentPath: path));
    await save(state);
  }

  @override
  Future<StorageState?> load() async {
    areaKeyLog.i('Loading StorageState');
    try {
      final storage = getKvStore();

      String? storageState = await storage.read(key: 'storage_state');
      if (storageState != null) {
        return StorageState.fromJson(
            _stripConnectionStatus(json.decode(storageState)));
      }
    } catch (e) {
      areaKeyLog.e('Error loading StorageState: $e');
    }
    return null;
  }

  @override
  Future<void> save(StorageState state) async {
    try {
      final storage = getKvStore();

      await storage.write(
          key: 'storage_state',
          value: json.encode(
              _stripConnectionStatus(state.toJson())));
    } catch (e) {
      areaKeyLog.e('Error saving StorageState: $e');
    }
  }

  Future<void> importFromJson(
    Map<String, dynamic> json, {
    required bool override,
  }) async {
    final imported =
        StorageState.fromJson(_stripConnectionStatus(json));

    final merged = state.copyWith(
      storages: override
          ? imported.storages
          : [...state.storages, ...imported.storages],
      favorites: override
          ? imported.favorites
          : [...state.favorites, ...imported.favorites],
    );

    set(merged);
    await save(merged);
  }

  Map<String, dynamic> exportToJson() {
    return _stripConnectionStatus(state.toJson());
  }
}

//StorageStore useStorageStore() => create(() => StorageStore());

// unified store factory

class UnifiedStorageStore extends PersistentStore<StorageState> {
  final StoragePersistence legacyPersistence;
  final StoragePersistence dbPersistence;

  late StoragePersistence _activePersistence;
  bool _backendSelected = false;

  /// True once the FIRST load attempt finished — success OR failure. This is
  /// the UI readiness signal (the browser shows its spinner until then).
  bool _loaded = false;
  bool get loaded => _loaded;

  UnifiedStorageStore({
    required this.legacyPersistence,
    required this.dbPersistence,
    bool useLegacy = false,
  }) : super(StorageState());

  StoragePersistence get activePersistence => _activePersistence;

  /// Shared-config store: an extra window's shutdown snapshot may predate a
  /// storage/favorite/navigation change another window made.
  @override
  bool get persistOnDispose => AppInstance.isPrimary;

  @override
  Future<StorageState?> load() async {
    // Determine active persistence at first load
    if (!_backendSelected) {
      _activePersistence = dbPersistence; // default backend, can be switched later
      _backendSelected = true;
    }
    final readPersistence = _activePersistence;

    try {
      final rawState = await readPersistence.load();
      // A backend switch may have landed while this read was in flight
      // (e.g. AppStore.onReady racing the startup load). The switch already
      // published its own backend's state; applying this stale snapshot now
      // would display one backend's data while writing to the other.
      if (!identical(_activePersistence, readPersistence)) return null;
      // Reached only when the read did not throw, so the snapshot is
      // authoritative — even when it is empty, which is exactly what lets a
      // user-initiated "removed my last storage" persist. (The base store's
      // `loadOk` turns writes on under the same condition.)
      if (rawState == null) return null;
      final normalized = rawState.copyWith(storageConnectionStatus: const {});
      return _applySessionNavigation(normalized);
    } finally {
      _loaded = true;
    }
  }

  @override
  Future<void> save(StorageState state) async {
    // Writes are a FULL REPLACE in the DB backend (delete-all + insert), so
    // persisting the default empty state of a store whose load never succeeded
    // would wipe every saved storage/favorite. `loadOk` is false forever in
    // that case, and this is the gate that matters.
    if (!loadOk) {
      areaKeyLog.w('skip save: storage store never loaded successfully');
      return;
    }
    await _activePersistence.save(
      state.copyWith(storageConnectionStatus: const {}),
    );
  }

  /// Switches the persistence backend.
  ///
  /// The new backend is read BEFORE becoming active: if that read throws, the
  /// current state, the active backend and the write gate all stay untouched,
  /// so a failed switch can never be followed by a write into the new backend.
  Future<void> switchBackend(bool useLegacy) async {
    final newPersistence = useLegacy ? legacyPersistence : dbPersistence;

    if (_backendSelected && identical(newPersistence, _activePersistence)) {
      return;
    }

    final StorageState? loaded;
    try {
      loaded = await newPersistence.load();
    } catch (e) {
      areaKeyLog.e(
        'switchBackend(useLegacy: $useLegacy) load failed; '
        'keeping the current backend: $e',
      );
      return;
    }

    _activePersistence = newPersistence;
    _backendSelected = true;
    if (loaded != null) {
      final normalized = loaded.copyWith(storageConnectionStatus: const {});
      // Overlay THIS window's browse location exactly like [load] does: the
      // freshly loaded snapshot carries the SHARED nav row, so without this a
      // backend switch (startup `applyConfiguredBackends`, the legacy toggle, an
      // import) would drop an extra window's session navigation back onto the
      // primary's location.
      set(await _applySessionNavigation(normalized));
    }
  }

  /// Whether currently using legacy persistence
  bool get isUsingLegacy => identical(_activePersistence, legacyPersistence);

  /// Whether a storage is connected (runtime only, default true).
  bool isConnected(String id) => state.storageConnectionStatus[id] ?? true;

  /// Mark a storage as disconnected (runtime only, not persisted).
  void markDisconnected(String id) {
    set(state.copyWith(
      storageConnectionStatus: {
        ...state.storageConnectionStatus,
        id: false,
      },
    ));
  }

  /// Mark a storage as connected (remove runtime disconnected flag).
  void markConnected(String id) {
    final updated = Map<String, bool>.from(state.storageConnectionStatus);
    updated.remove(id);
    set(state.copyWith(storageConnectionStatus: updated));
  }

  // ---- Same API as StorageStore ----

  Storage? findById(String id) => state.storages.firstWhereOrNull((s) => s.id == id);

  /// Resolves the entry that supplies endpoint/credentials for a node row whose
  /// stored `storage_id` is [nodeStorageId]. A shared-scope node keeps its
  /// scope's id, which may be deleted while the node survives; prefer
  /// [viewingId] when it shares the node's scope (freshest resolved host), then
  /// that entry, then any surviving scope member. See [resolveStorageForNode].
  Storage? resolveStorageForNodeId(String nodeStorageId, {String? viewingId}) =>
      resolveStorageForNode(
        storages: state.storages,
        viewingId: viewingId,
        nodeStorageId: nodeStorageId,
      );

  Future<void> addStorage(Storage storage) async {
    set(state.copyWith(storages: [...state.storages, storage]));
    await _persistStorageAdd(storage);
  }

  Future<void> updateStorage(int index, Storage storage) async {
    if (index < 0 || index >= state.storages.length) return;
    final previous = state.storages[index];
    final newList = [...state.storages]
      ..removeAt(index)
      ..insert(index, storage);

    // Keep the persisted "current storage" pointer in sync with an edit (e.g. a
    // drive-letter move) instead of leaving it on the stale base path.
    final current = state.currentStorage;
    final nextCurrent =
        (current != null && current.id == storage.id) ? storage : current;

    // If the edit moved this entry out of its old data scope and no other entry
    // still maps to that scope, its node/scan rows become unreachable (the
    // entry itself no longer resolves there, and deletion deliberately keeps
    // last-owner rows). Drop them instead of leaving a permanent stray set.
    final oldScope = previous.dataScopeId ?? previous.id;
    final newScope = storage.dataScopeId ?? storage.id;
    final oldScopeStillUsed = newScope == oldScope ||
        newList.any((s) => (s.dataScopeId ?? s.id) == oldScope);

    set(state.copyWith(storages: newList, currentStorage: nextCurrent));
    await _persistStorageUpsert([storage]);
    // Defensive: an edit that also changed the id must not leave the old row
    // behind (the snapshot used to replace the whole table and hide this).
    if (previous.id != storage.id) {
      await _persistStorageDelete(previous.id);
    }

    if (!oldScopeStillUsed) {
      await _purgeScope(oldScope);
    }
  }

  /// Physically removes every node/scan row of a canonical [scopeId] that no
  /// entry maps to anymore.
  Future<void> _purgeScope(String scopeId) async {
    try {
      await DbModule.mediaNodesDao.deleteByScopeId(scopeId);
      await DbModule.scanQueueDao.clearByScopeId(scopeId);
      await DbModule.scanStatesDao.deleteByScopeId(scopeId);
    } catch (e) {
      areaKeyLog.w('purge unreachable scope $scopeId failed: $e');
    }
  }

  /// Records newly resolved WebDAV host(s) for the scope that [id] belongs to,
  /// keeping a short most-recent-first history (cap 5). Recent hosts are tried
  /// before any scan, so a DHCP shuffle is usually recovered without
  /// discovery.
  ///
  /// Two entries linked into one data scope (shared library) share this cache:
  /// whichever entry resolves a host pushes it to every member, so the whole
  /// group follows the machine — wildcards AND fixed-IP entries (a fixed entry
  /// prefers the shared host and still falls back to its configured `host`).
  ///
  /// No-op when [id] is unknown, is not a WebDAV entry, or the merged order is
  /// unchanged.
  Future<void> updateWebdavResolvedHosts(String id, List<String> hosts) async {
    final index = state.storages.indexWhere((s) => s.id == id);
    if (index < 0) return;
    final current = state.storages[index];
    if (current is! WebDAVStorage) return;
    // A locked entry (undecryptable password) keeps its type so it stays
    // editable, but its row must not be rewritten: broadcasting a new host
    // would clear the lock and clobber the stored cipher.
    if (DbModule.storageRepo.isLockedId(id)) return;

    final scopeId = current.dataScopeId ?? current.id;
    final newList = [...state.storages];
    final changedEntries = <Storage>[];
    var changed = false;
    for (var i = 0; i < newList.length; i++) {
      final member = newList[i];
      if (member is! WebDAVStorage) continue;
      if (DbModule.storageRepo.isLockedId(member.id)) continue;
      if ((member.dataScopeId ?? member.id) != scopeId) continue;
      final merged = _mergeResolvedHosts(hosts, member.resolvedHosts);
      if (const ListEquality<String>().equals(merged, member.resolvedHosts)) {
        continue;
      }
      newList[i] = member.copyWith(resolvedHosts: merged);
      changedEntries.add(newList[i]);
      changed = true;
    }
    if (!changed) return;

    set(state.copyWith(storages: newList));
    await _persistStorageUpsert(changedEntries);
  }

  Future<void> removeStorage(Storage storage) async {
    // Nodes are scope-owned: if a linked sibling survives, re-point the shared
    // rows to it BEFORE dropping this entry, so playback resolves a live owner.
    final scope = storage.dataScopeId ?? storage.id;
    final survivor = state.storages.firstWhereOrNull(
      (s) => s.id != storage.id && (s.dataScopeId ?? s.id) == scope,
    );

    set(state.copyWith(storages: [...state.storages]..remove(storage)));
    await _persistStorageDelete(storage.id);

    if (survivor != null) {
      try {
        await DbModule.mediaNodesDao.reassignStorageIdForScope(
          scopeId: scope,
          newStorageId: survivor.id,
        );
        await DbModule.scanQueueDao.reassignStorageIdForScope(
          scopeId: scope,
          newStorageId: survivor.id,
        );
        await DbModule.scanStatesDao.reassignStorageIdForScope(
          scopeId: scope,
          newStorageId: survivor.id,
        );
      } catch (e) {
        areaKeyLog.w('reassign scope $scope to ${survivor.id} failed: $e');
      }
    }
  }

  Future<void> addFavorite(Favorite favorite) async {
    set(state.copyWith(favorites: [...state.favorites, favorite]));
    await _persistFavoriteChanges(upserts: [favorite]);
  }

  Future<void> removeFavorite(Favorite favorite) async {
    set(state.copyWith(favorites: [...state.favorites]..remove(favorite)));
    await _persistFavoriteChanges(deletes: [favorite]);
  }

  /// Moves every favorite whose path sits under a storage's [oldBase] to
  /// [newBase] (drive-letter reassignment). No-op and no save when nothing
  /// matched.
  Future<void> remapFavorites({
    required String storageId,
    required String oldBase,
    required String newBase,
  }) async {
    final oldSegs = pathConv(oldBase);
    final newSegs = pathConv(newBase);
    if (oldSegs.isEmpty) return;
    var changed = false;
    final next = <Favorite>[];
    // A remapped favorite changes KEY (path), so the write is an upsert at the
    // new key plus a delete of the old one — never a list replace.
    final movedFrom = <Favorite>[];
    final movedTo = <Favorite>[];
    for (final f in state.favorites) {
      if (f.storageId != storageId) {
        next.add(f);
        continue;
      }
      final remapped = remapLeadingSegments(f.path, oldSegs, newSegs);
      if (remapped == null) {
        next.add(f);
        continue;
      }
      changed = true;
      final moved = f.copyWith(path: remapped);
      movedFrom.add(f);
      movedTo.add(moved);
      next.add(moved);
    }
    if (!changed) return;
    set(state.copyWith(favorites: next));
    await _persistFavoriteChanges(upserts: movedTo, deletes: movedFrom);
  }

  /// Moves the persisted browse location to a storage's new base path when that
  /// storage is the current one (drive-letter reassignment). No-op and no save
  /// when the location is not under [oldBase].
  Future<void> remapCurrentPath({
    required String storageId,
    required String oldBase,
    required String newBase,
  }) async {
    if (state.currentStorage?.id != storageId) return;
    final oldSegs = pathConv(oldBase);
    final newSegs = pathConv(newBase);
    if (oldSegs.isEmpty) return;
    final remapped = remapLeadingSegments(state.currentPath, oldSegs, newSegs);
    if (remapped == null) return;
    set(state.copyWith(currentPath: remapped));
    await _persistNavigation();
  }

  Future<void> updateCurrentStorage(Storage? storage) async {
    set(state.copyWith(currentStorage: storage));
    await _persistNavigation();
  }

  Future<void> updateCurrentPath(List<String> path) async {
    set(state.copyWith(currentPath: path));
    await _persistNavigation();
  }

  /// Browse-location writes must NOT go through [save] on the DB backend: that
  /// backend writes a FULL replace (storages + favorites + navigation), so
  /// opening a folder in a second window would restore its stale
  /// storage/favorite list over changes made in the first one. Only the nav row
  /// belongs to this mutation; blob backends keep the full save.
  ///
  /// Multi-window: the browse LOCATION is per-window state ("where am I
  /// browsing"), like the play queue. The shared nav row therefore belongs to
  /// the primary window; an extra window keeps its own in session-scoped KV and
  /// restores it on the next launch.
  Future<void> _persistNavigation() async {
    if (!loadOk) {
      areaKeyLog.w('skip nav save: storage store never loaded successfully');
      return;
    }
    if (!AppInstance.isPrimary) {
      await _persistSessionNavigation();
      return;
    }
    final snapshot = state.copyWith(storageConnectionStatus: const {});
    final persistence = _activePersistence;
    if (persistence is StorageNavigationPersistence) {
      await persistence.saveNavigation(snapshot);
    } else {
      await save(snapshot);
    }
  }

  /// Extra window's own browse location (see [_persistNavigation]).
  Future<void> _persistSessionNavigation() async {
    try {
      await getSessionKvStore().write(
        key: KvKeys.navigationState,
        value: json.encode({
          'storageId': state.currentStorage?.id,
          'path': state.currentPath,
        }),
      );
    } catch (e) {
      // Best-effort: a failed session write must never break browsing.
      areaKeyLog.w('session nav write failed: $e');
    }
  }

  /// Overlays this window's own browse location over the shared snapshot.
  ///
  /// Before the window has browsed anything, the shared row seeds it (a new
  /// window opens where the user already was); after its first navigation the
  /// session value wins and the two windows diverge.
  Future<StorageState> _applySessionNavigation(StorageState loaded) async {
    if (AppInstance.isPrimary) return loaded;
    try {
      final raw = await getSessionKvStore().read(key: KvKeys.navigationState);
      if (raw == null) return loaded;
      final map = json.decode(raw) as Map<String, dynamic>;
      final id = map['storageId'] as String?;
      final path = (map['path'] as List?)?.map((e) => '$e').toList();
      Storage? storage;
      if (id != null) {
        storage = loaded.storages.firstWhereOrNull((s) => s.id == id);
        // The entry was removed (or edited away by another window): keep the
        // shared snapshot rather than landing on a dangling pointer.
        if (storage == null) return loaded;
      }
      return loaded.copyWith(
        currentStorage: storage,
        currentPath: path ?? const [],
      );
    } catch (e) {
      areaKeyLog.w('session nav read failed: $e');
      return loaded;
    }
  }

  // ── Narrow entry writes ──
  //
  // Same reasoning as [_persistNavigation], one level down: on the DB backend
  // [save] replaces EVERY storage and favorite row with this window's snapshot.
  // A single add / edit / removal / favorite toggle therefore writes only the
  // row(s) it owns, so a second window cannot resurrect lists it never re-read.
  //
  // Blob backends keep the full save (their whole state is one value there) —
  // i.e. they stay LAST-WRITE-WINS: a concurrent edit in another window is
  // dropped when this snapshot lands. That is a known limitation of the legacy
  // backend (see `StorageEntryPersistence`), not something a lock can fix, and
  // it is why the DB backend is the default.

  Future<void> _persistStorageAdd(Storage storage) =>
      _persistStorageRows((p) => p.saveStorage(storage));

  Future<void> _persistStorageUpsert(Iterable<Storage> storages) async {
    final list = storages.toList(growable: false);
    if (list.isEmpty) return;
    await _persistStorageRows((p) async {
      for (final storage in list) {
        await p.saveStorage(storage);
      }
    });
  }

  Future<void> _persistStorageDelete(String id) =>
      _persistStorageRows((p) => p.deleteStorage(id));

  Future<void> _persistFavoriteChanges({
    List<Favorite> upserts = const [],
    List<Favorite> deletes = const [],
  }) {
    if (upserts.isEmpty && deletes.isEmpty) return Future<void>.value();
    return _persistStorageRows(
      (p) => p.saveFavoriteChanges(upserts: upserts, deletes: deletes),
    );
  }

  /// Runs [write] on the narrow backend, or falls back to a full [save] for blob
  /// backends. Gated on [loadOk] exactly like [save].
  Future<void> _persistStorageRows(
    Future<void> Function(StorageEntryPersistence p) write,
  ) async {
    if (!loadOk) {
      areaKeyLog.w('skip narrow storage save: store never loaded successfully');
      return;
    }
    final persistence = _activePersistence;
    if (persistence is StorageEntryPersistence) {
      await write(persistence);
    } else {
      await save(state);
    }
  }

  /// Import JSON, merge or override.
  ///
  /// APPEND is persisted as a NARROW upsert of the imported rows only. A whole
  /// [save] would replace every row with THIS window's snapshot, so an edit
  /// another window made after this snapshot was loaded would be dropped — the
  /// same reason a single add / edit / removal writes only its own row (see
  /// [_persistStorageRows]). It also keeps this window's browse location out of
  /// the shared navigation row.
  ///
  /// OVERRIDE is an explicit "make the file's storages/favorites my whole set",
  /// so it stays a full replace: rows absent from the import are deleted on
  /// purpose, and it is last-write-wins against a concurrent edit by design (a
  /// deliberate user action, like the settings-blob import).
  Future<void> importFromJson(
    Map<String, dynamic> json, {
    required bool override,
  }) async {
    final imported =
        StorageState.fromJson(_stripConnectionStatus(json));

    final mergedStorages = override
        ? imported.storages
        : [...state.storages, ...imported.storages];

    // A cross-device import may carry a dataScopeId that no longer maps to any
    // entry; repair dangling links before persisting so the import never
    // creates an unreachable shared library.
    final repairedStorages = repairImportedScopes(
      merged: mergedStorages,
      imported: imported.storages,
    );

    final merged = state.copyWith(
      storages: repairedStorages,
      favorites: override
          ? imported.favorites
          : [...state.favorites, ...imported.favorites],
    );

    set(merged);
    if (!override) {
      // Only the entries that came from the file, with their repaired scope
      // links ([repairedStorages] leaves local entries untouched).
      final importedIds = {for (final s in imported.storages) s.id};
      await _persistStorageUpsert(
        repairedStorages.where((s) => importedIds.contains(s.id)),
      );
      await _persistFavoriteChanges(upserts: imported.favorites);
      return;
    }
    await save(merged);
  }

  /// Export to JSON
  Map<String, dynamic> exportToJson() {
    return _stripConnectionStatus(state.toJson());
  }
}

UnifiedStorageStore useStorageStore() => zustand.create(() => UnifiedStorageStore(
      legacyPersistence: SecureStoragePersistence(),
      dbPersistence: DbStoragePersistence(
        storageRepo: DbModule.storageRepo,
        favoritesRepo: DbModule.favoritesRepo,
        navRepo: DbModule.navRepo,
      ),
    ));
