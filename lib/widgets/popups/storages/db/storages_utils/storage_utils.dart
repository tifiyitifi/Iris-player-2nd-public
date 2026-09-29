import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:iris/features/media_library/services/path_prefix_remap_service.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/storages/storage_volume_reconciler.dart';
import 'package:iris/store/use_history_store.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Generates a stable, unique ID for a storage
/// based on type + basePath (or other unique properties)
///
/// For local disks the volatile drive letter is deliberately excluded: when a
/// stable [LocalStorage.volumeId] is known the id is keyed on it (plus any
/// sub-path below the volume root), so the same physical disk keeps the same id
/// — and therefore the same media-node scope — after a letter reassignment.
String generateStorageId(Storage storage) {
  String key;
  switch (storage.type) {
    case StorageType.webdav:
      final s = storage as WebDAVStorage;
      key = '${storage.type}:${s.name}:${s.host}:${s.port}:${s.basePath.join('/')}';
      break;
    case StorageType.ftp:
      final s = storage as FTPStorage;
      key = '${storage.type}:${s.name}:${s.host}:${s.port}:${s.username}:${s.basePath.join('/')}';
      break;
    default:
      final local = storage as LocalStorage;
      final volumeId = local.volumeId;
      if (volumeId != null && volumeId.isNotEmpty) {
        final rel = volumeRelativeBase(local.basePath);
        key = '${storage.type}:$volumeId${rel.isEmpty ? '' : ':$rel'}';
      } else {
        key = '${storage.type}:${storage.name}:${storage.basePath.join('/')}';
      }
  }
  return sha1.convert(utf8.encode(key)).toString();
}

/// Strips the volatile volume root from a base path, leaving only the
/// sub-directory below it (empty when [basePath] IS the volume root).
///
/// Used so a storage id can be keyed on a stable volume identity plus a stable
/// relative sub-path instead of a drive letter / mount point.
String volumeRelativeBase(List<String> basePath) {
  if (basePath.isEmpty) return '';
  final joined = basePath.join('/');
  final drive = RegExp(r'^[A-Za-z]:[/\\]?').firstMatch(joined);
  if (drive != null) {
    return joined.substring(drive.end).replaceAll(RegExp(r'^[/\\]+'), '');
  }
  final android = RegExp(r'^/?storage/[^/]+/?').firstMatch(joined);
  if (android != null) return joined.substring(android.end);
  return joined.replaceAll(RegExp(r'^/+'), '');
}

/// Factory method to reduce repeated boilerplate for LocalStorage creation
LocalStorage makeLocalStorage({
  required StorageType type,
  required String name,
  required List<String> basePath,
  String? volumeId,
}) {
  final storage = LocalStorage(
    type: type,
    name: name,
    basePath: basePath,
    volumeId: volumeId,
  );
  return storage.copyWith(id: generateStorageId(storage));
}

/// Merges the freshly enumerated local disks with the persisted entries for
/// display, so each disk appears EXACTLY once.
///
/// Prefers the persisted entry when both exist — it carries the user's rename,
/// its sub-path scope and its saved connection state — and only takes a disk
/// from [scanned] when [stored] does not represent it yet.
///
/// Deduplication MUST look at BOTH the id and the stable volume id: for a local
/// disk [generateStorageId] keys the id on the volume, and [makeLocalStorage]
/// assigns it, so an enumeration and its persisted entry normally share BOTH.
/// Matching on one side only cancels the pair out (the scanned entry dropped by
/// volume id AND the persisted one dropped by id), which renders the storagedb's
/// storage list blank.
List<Storage> mergeScannedAndStoredStorages({
  required List<LocalStorage> scanned,
  required List<Storage> stored,
}) {
  final storedIds = stored.map((s) => s.id).toSet();
  final storedVolumeIds = stored
      .whereType<LocalStorage>()
      .map((s) => s.volumeId)
      .whereType<String>()
      .toSet();

  final scannedOnly = scanned
      .where((l) =>
          !storedIds.contains(l.id) &&
          (l.volumeId == null || !storedVolumeIds.contains(l.volumeId)))
      .toList();

  return [
    ...scannedOnly,
    ...stored.where((s) => !scannedOnly.any((l) => l.id == s.id)),
  ];
}

/// Reconciles the enumerated local disks with the persisted entries, then
/// persists the result.
///
/// A disk that reappeared under a different drive letter is matched by its
/// stable volume identity (see [planStorageVolumeReconcile]); its entry keeps
/// its id/scope, its stored path prefix is rewritten to the new letter and its
/// media-node tree is preserved — no full rescan.
///
/// Returns the merged list (scanned entries first, then persisted entries not
/// represented by a scanned one). The caller (storages list) reads the store
/// reactively, so the return value is informational.
Future<List<LocalStorage>> persistScannedStorages({
  required List<LocalStorage> scannedStorages,
  required List<LocalStorage> dbStorages,
  required dynamic store,
  Future<String?> Function(String rootPath)? resolveVolumeId,
  Future<void> Function(String storageId, String oldBase, String newBase)?
      remapPaths,
}) async {
  final plan = await planStorageVolumeReconcile(
    scanned: scannedStorages,
    existing: dbStorages,
    resolveVolumeId: resolveVolumeId,
  );

  // The decisive "why is nothing in the list" signal: a plan with 0 moves and 0
  // adds means every scanned disk was matched to an entry that never reaches the
  // UI-visible store.
  _log.i('persistScannedStorages: scanned=${scannedStorages.length} '
      'existing=${dbStorages.length} moves=${plan.moves.length} '
      'adds=${plan.adds.length} '
      '[${plan.adds.map((s) => '${s.type}/${s.basePath.join('/')}').join(', ')}]');

  for (final move in plan.moves) {
    final remap = remapPaths ??
        (String id, String oldBase, String newBase) =>
            _defaultRemapPaths(store, id, oldBase, newBase);
    try {
      await remap(move.existing.id, move.oldBase, move.newBase);
    } catch (e) {
      _log.e('persistScannedStorages: remap ${move.existing.id} failed: $e');
    }
    final storages = (store.state.storages as List).cast<Storage>();
    final index = storages.indexWhere((s) => s.id == move.existing.id);
    if (index >= 0) {
      await store.updateStorage(index, move.updated);
    } else {
      await store.addStorage(move.updated);
    }
  }

  for (final add in plan.adds) {
    await store.addStorage(add);
  }

  return [
    ...scannedStorages,
    ...dbStorages.where(
        (s) => !scannedStorages.any((l) => l.id == s.id)),
  ];
}

/// Default side effects of moving a storage to a new base path: rewrite every
/// DB path prefix, then the store-owned favorites and the history keys.
Future<void> _defaultRemapPaths(
  dynamic store,
  String storageId,
  String oldBase,
  String newBase,
) async {
  await const PathPrefixRemapService()
      .remap(storageId: storageId, oldBase: oldBase, newBase: newBase);
  try {
    await store.remapFavorites(
      storageId: storageId,
      oldBase: oldBase,
      newBase: newBase,
    );
  } catch (e) {
    _log.w('remapFavorites failed for $storageId: $e');
  }
  try {
    await store.remapCurrentPath(
      storageId: storageId,
      oldBase: oldBase,
      newBase: newBase,
    );
  } catch (e) {
    _log.w('remapCurrentPath failed for $storageId: $e');
  }
  try {
    final history = useHistoryStore();
    await history.initialized;
    await history.remapStoragePath(
      storageId: storageId,
      oldBase: oldBase,
      newBase: newBase,
    );
  } catch (e) {
    _log.w('history remap skipped for $storageId: $e');
  }
}
