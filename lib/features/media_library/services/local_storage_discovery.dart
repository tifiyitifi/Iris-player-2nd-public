import 'package:flutter/foundation.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/widgets/popups/storages/db/storages_utils/storage_utils.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Enumerates the local disks and persists them (`persistScannedStorages`),
/// independent of which storagedb surface happens to be mounted.
///
/// WHY this is a service and not widget state: the discovery used to live only
/// inside the Storage TAB's list widget ([StoragesDbList]). `StoragesDb`
/// bypasses that list whenever a storage is restored from the previous session
/// (`currentStorage != null`) or a sub-interface is open (`libContent` /
/// `scenario` / `search`), so the discovery never executed and the storagedb
/// could end up with no local storage at all. Called from the popup ROOT, this
/// covers every surface.
///
/// Deliberately takes NO `BuildContext`: `useEffect` callbacks run inside
/// flutter_hooks' `initHook`, where any inherited-widget lookup asserts in
/// debug, so the caller resolves [LocalStorageLabels] in build and passes them
/// down.
///
/// Idempotent: concurrent callers join the in-flight run, and a later call
/// re-reads the persisted set, so an already-known disk is reconciled (moved /
/// renamed) instead of re-added.
abstract final class LocalStorageDiscovery {
  /// Test seam: replaces the platform enumeration. Production never writes it.
  static Future<List<LocalStorage>> Function()? debugEnumerator;

  static Future<void>? _inFlight;

  /// The running discovery, if any. Test seam.
  @visibleForTesting
  static Future<void>? get inFlight => _inFlight;

  /// Runs the discovery once; see the class docs.
  ///
  /// [labels] is only needed for the default enumeration (localized storage
  /// names); [store], [enumerate] and [resolveVolumeId] are injectable seams.
  /// Tests inject [enumerate] and omit [labels].
  static Future<void> ensure({
    LocalStorageLabels? labels,
    UnifiedStorageStore? store,
    Future<List<LocalStorage>> Function()? enumerate,
    Future<String?> Function(String rootPath)? resolveVolumeId,
  }) {
    final running = _inFlight;
    if (running != null) {
      _log.i('LocalStorageDiscovery: joined the in-flight run');
      return running;
    }

    _log.i('LocalStorageDiscovery: invoked '
        '(labels=${labels != null} enumerate=${enumerate != null} '
        'debugEnumerator=${debugEnumerator != null})');

    final resolvedEnumerate = enumerate ??
        debugEnumerator ??
        (() {
          assert(
            labels != null,
            'LocalStorageDiscovery.ensure needs `labels` (or an injected '
            'enumerator) to enumerate the local disks',
          );
          return scanLocalStorages(labels!);
        });

    final future = _ownership(
      store ?? useStorageStore(),
      resolvedEnumerate,
      resolveVolumeId,
    );
    _inFlight = future;
    return future;
  }

  /// Sole-owner wrapper.
  ///
  /// Clears [_inFlight] in a `finally`, i.e. BEFORE the returned future
  /// completes, so a caller arriving after a run finished starts a fresh run
  /// instead of joining a settled future (joining one would silently make it a
  /// no-op — which is how a single failed run used to swallow the only trigger
  /// its caller had).
  static Future<void> _ownership(
    UnifiedStorageStore store,
    Future<List<LocalStorage>> Function() enumerate,
    Future<String?> Function(String rootPath)? resolveVolumeId,
  ) async {
    try {
      if (!await _run(store, enumerate, resolveVolumeId)) {
        // One retry: the popup can mount before the store/DB is ready, and the
        // caller's effect may never fire again (unchanged hook keys).
        await _run(store, enumerate, resolveVolumeId);
      }
    } finally {
      _inFlight = null;
    }
  }

  /// Returns whether the disks were enumerated AND persisted.
  static Future<bool> _run(
    UnifiedStorageStore store,
    Future<List<LocalStorage>> Function() enumerate,
    Future<String?> Function(String rootPath)? resolveVolumeId,
  ) async {
    try {
      final scanned = await enumerate();
      _log.i('LocalStorageDiscovery: enumerated ${scanned.length} disk(s) '
          '[${scanned.map((s) => '${s.type}/${s.basePath.join('/')}').join(', ')}]');

      // Match against the DB AND the live store: a legacy-mode run keeps its
      // entries in secure storage (the DB is empty), and matching only against
      // the DB would then re-add every disk as a duplicate.
      final existing = <String, LocalStorage>{
        for (final s in await DbModule.storageRepo.getStorages())
          if (s is LocalStorage) s.id: s,
        for (final s in store.state.storages)
          if (s is LocalStorage) s.id: s,
      }.values.toList();

      final merged = await persistScannedStorages(
        scannedStorages: scanned,
        dbStorages: existing,
        store: store,
        resolveVolumeId: resolveVolumeId,
      );
      // Observable proof the discovery reached the store: this is the line that
      // was missing while the run silently died in the hook init phase.
      _log.i(
        'LocalStorageDiscovery: scanned=${scanned.length} known=${existing.length} '
        'persisted=${merged.whereType<LocalStorage>().length}',
      );
      return true;
    } catch (e, s) {
      // Never let a discovery failure take the popup down; it is a background
      // convenience, and the Storage tab still shows whatever is persisted.
      _log.e('LocalStorageDiscovery failed: $e\n$s');
      return false;
    }
  }
}
