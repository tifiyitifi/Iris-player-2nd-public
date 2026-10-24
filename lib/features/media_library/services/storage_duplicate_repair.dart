import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/scenario_playback/actions/media_revision_actions.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// One storage entry that should absorb the others.
class StorageDuplicateGroup {
  const StorageDuplicateGroup({
    required this.survivor,
    required this.losers,
  });

  final LocalStorage survivor;
  final List<LocalStorage> losers;
}

/// What a merge actually did (surfaced to the user + logged).
class StorageMergeStats {
  const StorageMergeStats({
    this.movedNodes = 0,
    this.mergedNodes = 0,
    this.droppedPhantoms = 0,
    this.repointedRefs = 0,
    this.ghostRowsMarked = 0,
  });

  final int movedNodes;
  final int mergedNodes;
  final int droppedPhantoms;
  final int repointedRefs;
  final int ghostRowsMarked;

  StorageMergeStats operator +(StorageMergeStats other) => StorageMergeStats(
        movedNodes: movedNodes + other.movedNodes,
        mergedNodes: mergedNodes + other.mergedNodes,
        droppedPhantoms: droppedPhantoms + other.droppedPhantoms,
        repointedRefs: repointedRefs + other.repointedRefs,
        ghostRowsMarked: ghostRowsMarked + other.ghostRowsMarked,
      );

  String get summary =>
      'moved=$movedNodes merged=$mergedNodes phantoms=$droppedPhantoms '
      'refs=$repointedRefs ghosts=$ghostRowsMarked';
}

/// Detects **exact duplicate** local storage entries.
///
/// Two entries are duplicates only when they name the SAME path root: same
/// stable volume id AND identical base path. Sharing a volume with a different
/// base (e.g. `E:` vs `E:/movies`) is legitimate — node paths are stored
/// storage-relative, so folding those would re-interpret every stored path.
///
/// [libraryStorageIds] / [nodeCounts] / [referenceCounts] are rank hints; the
/// survivor is the entry that owns the library, then the most rows, then the
/// most references, and only then the earlier entry in user order. The choice
/// is made ONCE per merge — after it there is a single entry left.
List<StorageDuplicateGroup> planDuplicateStorageGroups(
  List<Storage> storages, {
  Set<String> libraryStorageIds = const <String>{},
  Map<String, int> nodeCounts = const <String, int>{},
  Map<String, int> referenceCounts = const <String, int>{},
}) {
  final byKey = <String, List<({int index, LocalStorage storage})>>{};
  for (var i = 0; i < storages.length; i++) {
    final storage = storages[i];
    if (storage is! LocalStorage) continue;
    final volumeId = storage.volumeId;
    if (volumeId == null || volumeId.isEmpty) continue;
    final base = _canonicalBase(storage.basePath);
    if (base.isEmpty) continue;
    final key = _groupKey(volumeId, storage.basePath);
    (byKey[key] ??= <({int index, LocalStorage storage})>[])
        .add((index: i, storage: storage));
  }

  final groups = <StorageDuplicateGroup>[];
  for (final entries in byKey.values) {
    if (entries.length < 2) continue;
    final ranked = [...entries]..sort((a, b) {
        final byLibrary = _rank(libraryStorageIds.contains(b.storage.id))
            .compareTo(_rank(libraryStorageIds.contains(a.storage.id)));
        if (byLibrary != 0) return byLibrary;
        final byNodes = (nodeCounts[b.storage.id] ?? 0)
            .compareTo(nodeCounts[a.storage.id] ?? 0);
        if (byNodes != 0) return byNodes;
        final byRefs = (referenceCounts[b.storage.id] ?? 0)
            .compareTo(referenceCounts[a.storage.id] ?? 0);
        if (byRefs != 0) return byRefs;
        return a.index.compareTo(b.index);
      });
    final survivor = ranked.first.storage;
    final losers = <LocalStorage>[
      for (final entry in ranked.skip(1)) entry.storage,
    ];
    groups.add(StorageDuplicateGroup(survivor: survivor, losers: losers));
  }
  return groups;
}

int _rank(bool value) => value ? 1 : 0;

String _canonicalBase(List<String> base) =>
    canonicalDbPath(normalizePathText(base.join('/')));

String _groupKey(String volumeId, List<String> base) {
  final canonical = _canonicalBase(base);
  final folded = StoragePathCodec.baseRidesCaseInsensitiveFs(base)
      ? canonical.toLowerCase()
      : canonical;
  return '$volumeId|$folded';
}

/// Detects duplicates against the live store + DB.
Future<List<StorageDuplicateGroup>> detectDuplicateStorageGroups() async {
  final store = useStorageStore();
  // The startup flow runs before the first frame consumes the store; awaiting
  // `initialized` guarantees a real (not default-empty) list.
  await store.initialized;
  final storages = store.state.storages;
  final local = storages.whereType<LocalStorage>().toList(growable: false);
  if (local.length < 2) return const <StorageDuplicateGroup>[];

  final dao = DbModule.mediaNodesDao;
  final libraryStorageIds = <String>{};
  final nodeCounts = <String, int>{};
  final referenceCounts = <String, int>{};
  final db = dao.db;

  for (final storage in local) {
    final scope = storage.dataScopeId ?? storage.id;
    try {
      nodeCounts[storage.id] = (await dao.rowsInScope(scope)).length;
    } catch (_) {}
    try {
      final rows = await DbModule.mediaLibSourcesDao.getByStorageId(storage.id);
      if (rows.isNotEmpty) libraryStorageIds.add(storage.id);
    } catch (_) {}
    try {
      referenceCounts[storage.id] = await _countReferences(db, storage.id);
    } catch (_) {}
  }

  return planDuplicateStorageGroups(
    storages,
    libraryStorageIds: libraryStorageIds,
    nodeCounts: nodeCounts,
    referenceCounts: referenceCounts,
  );
}

Future<int> _countReferences(AppDatabase db, String storageId) async {
  var total = 0;
  for (final (table, column) in _referenceColumns) {
    final rows = await db.customSelect(
      'SELECT COUNT(*) AS c FROM $table WHERE $column = ?',
      variables: <Variable<Object>>[Variable<String>(storageId)],
    ).getSingle();
    total += rows.read<int>('c');
  }
  return total;
}

/// `(table, storage-id column)` pairs every stored reference lives in.
///
/// A schema-coverage test asserts this list covers every `*storage_id*` column
/// in the database, so a future table cannot silently keep pointing at the
/// merged-away entry.
const List<(String, String)> _referenceColumns = <(String, String)>[
  ('media_lib_sources', 'storage_id'),
  ('scenario_sources', 'storage_id'),
  ('scenario_explicit_items', 'storage_id'),
  ('scenario_excludes', 'storage_id'),
  ('video_tag_members', 'storage_id'),
  ('favorites_table', 'storage_id'),
  ('navigation_table', 'current_storage_id'),
  ('bg_mappings_table', 'storage_id'),
  ('bg_mapping_segments_table', 'bg_storage_id'),
];

@visibleForTesting
List<(String, String)> get storageReferenceColumns => _referenceColumns;

/// Merges [group]: every loser's rows/references move to the survivor, duplicate
/// node rows collapse into the survivor's (keeping the richer progress/probe
/// data), and the loser entries are removed.
///
/// All DB work for one loser runs in a single transaction, so an interrupted
/// merge re-runs cleanly (the loser is still listed and the moved rows no longer
/// match it).
Future<StorageMergeStats> mergeDuplicateStorageGroup(
  StorageDuplicateGroup group, {
  bool sweepMissingFiles = true,
  void Function(String phase)? onPhase,
  Future<void> Function(Storage storage)? removeEntry,
  bool notifyRevisions = true,
}) async {
  final dao = DbModule.mediaNodesDao;
  final db = dao.db;
  var stats = const StorageMergeStats();
  // Reference paths (tag memberships, library sources, favorites, …) are
  // compared the way the filesystem compares them: NTFS/UNC folds case, POSIX
  // and SAF stay exact. Detection already groups on this rule, so the merge must
  // not keep two case-variant spellings of one file as separate references.
  final foldCase =
      StoragePathCodec.baseRidesCaseInsensitiveFs(group.survivor.basePath);

  for (final loser in group.losers) {
    if (!_sameBase(group.survivor, loser)) {
      _log.w('storage merge: base mismatch ${loser.id}; skipped');
      continue;
    }
    onPhase?.call(loser.name);
    final loserScope = loser.dataScopeId ?? loser.id;
    final survivorScope = group.survivor.dataScopeId ?? group.survivor.id;

    await db.transaction(() async {
      stats += await _mergeNodes(
        dao: dao,
        base: group.survivor.basePath,
        survivorId: group.survivor.id,
        survivorScope: survivorScope,
        loserScope: loserScope,
      );
      // Scan bookkeeping is rebuilt on the next scan; never merge it, or the
      // union of two half-scanned trees would claim completeness.
      await db.customUpdate(
        'DELETE FROM scan_states WHERE data_scope_id = ?',
        variables: <Variable<Object>>[Variable<String>(loserScope)],
      );
      await db.customUpdate(
        'DELETE FROM scan_queue WHERE data_scope_id = ?',
        variables: <Variable<Object>>[Variable<String>(loserScope)],
      );
      // Collapse rows that would violate a UNIQUE(storage_id, path)-family
      // constraint once the two scopes become one (the survivor's row wins).
      await _dedupeReferences(db, loser.id, group.survivor.id,
          foldCase: foldCase);
      for (final (table, column) in _referenceColumns) {
        await db.customUpdate(
          'UPDATE $table SET $column = ? WHERE $column = ?',
          variables: <Variable<Object>>[
            Variable<String>(group.survivor.id),
            Variable<String>(loser.id),
          ],
        );
      }
      await _repointLibrary(db, loser.id, group.survivor.id,
          foldCase: foldCase);
      await _repointScenarioStates(db, loser.id, group.survivor.id);
    });

    // Store removal is idempotent and lives outside the transaction (the store
    // persists its own rows). The rows are already moved, so the entry is empty.
    try {
      final store = useStorageStore();
      await (removeEntry ?? store.removeStorage)(loser);
      // The removed entry may have been the current navigation target: land on
      // the survivor (same base path) instead of a dangling pointer.
      if (store.state.currentStorage?.id == loser.id) {
        await store.updateCurrentStorage(group.survivor);
      }
    } catch (e) {
      _log.w('storage merge: removing entry ${loser.id} failed: $e');
    }
    _log.i('storage merge: ${loser.id} -> ${group.survivor.id} '
        '[${stats.summary}]');
  }

  if (sweepMissingFiles) {
    stats += await sweepMissingFilesForStorage(
      group.survivor,
      onPhase: onPhase,
    );
  }

  if (notifyRevisions) {
    await MediaRevisionActions.mediaNodesChanged(<String>[group.survivor.id]);
  }
  return stats;
}

bool _sameBase(Storage a, Storage b) =>
    StoragePathCodec.sameBasePath(a.basePath, b.basePath);

Future<StorageMergeStats> _mergeNodes({
  required MediaNodesDao dao,
  required List<String> base,
  required String survivorId,
  required String survivorScope,
  required String loserScope,
}) async {
  var moved = 0;
  var merged = 0;
  var phantoms = 0;

  final survivorRows = await dao.rowsInScope(survivorScope);
  final byKey = <String, MediaNodesTableData>{
    for (final row in survivorRows)
      StoragePathCodec.relativeKeyForBase(base, row.path): row,
  };

  for (final row in await dao.rowsInScope(loserScope)) {
    final normalized = StoragePathCodec.relativizeForBase(base, row.path);
    // Pre-fix scans left absolute/above-base phantom rows; collapsing them into
    // the survivor would resurrect the exact ghosts the repair exists to clear.
    // Judged on the STORED form: relativizing first maps the row to '' and the
    // phantom predicates can no longer recognize it.
    final stored = canonicalDbPath(row.path);
    if (StoragePathCodec.isAboveBase(survivorId, stored) ||
        StoragePathCodec.isStaleAbsoluteBase(survivorId, stored)) {
      await dao.deleteNodeById(row.id);
      phantoms++;
      continue;
    }

    final key = StoragePathCodec.relativeKeyForBase(base, normalized);
    final existing = byKey[key];
    if (existing != null) {
      await (dao.update(dao.mediaNodesTable)
            ..where((t) => t.id.equals(existing.id)))
          .write(_mergedCompanion(existing, row));
      await dao.deleteNodeById(row.id);
      merged++;
      continue;
    }

    await (dao.update(dao.mediaNodesTable)..where((t) => t.id.equals(row.id)))
        .write(MediaNodesTableCompanion(
      storageId: Value(survivorId),
      dataScopeId: Value(survivorScope),
      path: Value(normalized),
      parentPath: Value(_parentOf(normalized).isEmpty
          ? null
          : _parentOf(normalized)),
      pathDepth: Value(_depthOf(normalized)),
      name: Value(_leafOf(normalized, row.name)),
    ));
    // Track the moved row: a legacy absolute + a relative spelling of the SAME
    // path can both exist in the loser scope, and the second one must merge
    // into this row instead of colliding with `UNIQUE(data_scope_id, path)`.
    byKey[key] = row;
    moved++;
  }
  return StorageMergeStats(
    movedNodes: moved,
    mergedNodes: merged,
    droppedPhantoms: phantoms,
  );
}

String _parentOf(String relative) {
  if (relative.isEmpty) return '';
  final i = relative.lastIndexOf('/');
  return i <= 0 ? '' : relative.substring(0, i);
}

int _depthOf(String relative) {
  if (relative.isEmpty) return 0;
  // The scan writes `segments.length` (pathDepth 2 for `yb/c.mp4`), so the
  // repair must count the leaf too — counting separators alone left every moved
  // row one level shallower than a scanned one.
  return '/'.allMatches(relative).length + 1;
}

String _leafOf(String relative, String fallback) {
  if (relative.isEmpty) return fallback;
  final i = relative.lastIndexOf('/');
  return i < 0 ? relative : relative.substring(i + 1);
}

/// Column-wise merge of two rows that describe the SAME file.
///
/// Progress takes the value that is actually set; probe fields keep whichever
/// side has a value (never overwrite data with NULL); presence is the OR (a row
/// is only a ghost when BOTH agree it is missing).
MediaNodesTableCompanion _mergedCompanion(
  MediaNodesTableData target,
  MediaNodesTableData source,
) {
  // Progress travels with the row that was actually played LAST (a rescan of
  // the same drive in a second entry must not roll the resume point back).
  final progress = _laterPlayed(target, source) ? source : target;
  final other = identical(progress, source) ? target : source;

  // Position and completion describe ONE playthrough and must travel TOGETHER.
  // OR-ing `completed` marked a file the later row had only half-watched as
  // finished, so the next open skipped the resume and restarted from the head.
  // Only rows with no play information at all (legacy flags without a
  // timestamp/position) keep the union.
  final resumeDescribesPlaythrough =
      progress.lastPlayedAt != null || progress.playbackPositionMs != null;
  final playbackCompleted = resumeDescribesPlaythrough
      ? progress.playbackCompleted
      : (progress.playbackCompleted || other.playbackCompleted);

  int? pickInt(int? a, int? b) => a ?? b;
  String? pickText(String? a, String? b) => (a == null || a.isEmpty) ? b : a;
  DateTime? later(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null || !b.isAfter(a)) return a;
    return b;
  }

  return MediaNodesTableCompanion(
    playbackPositionMs:
        Value(pickInt(progress.playbackPositionMs, other.playbackPositionMs)),
    playbackCompleted: Value(playbackCompleted),
    lastPlayedAt: Value(later(target.lastPlayedAt, source.lastPlayedAt)),
    playCount: Value(_max(target.playCount, source.playCount)),
    historyRestoreBudget: Value(
        pickInt(progress.historyRestoreBudget, other.historyRestoreBudget)),
    durationMs: Value(pickInt(target.durationMs, source.durationMs)),
    width: Value(pickInt(target.width, source.width)),
    height: Value(pickInt(target.height, source.height)),
    pixelCount: Value(pickInt(target.pixelCount, source.pixelCount)),
    sizeInBytes: Value(pickInt(target.sizeInBytes, source.sizeInBytes)),
    uri: Value(pickText(target.uri, source.uri)),
    subtitlesJson: Value(pickText(target.subtitlesJson, source.subtitlesJson)),
    modifiedAt: Value(later(target.modifiedAt, source.modifiedAt)),
    createdAt: Value(target.createdAt ?? source.createdAt),
    isPresent: Value(target.isPresent || source.isPresent),
    lastSeenAt: Value(later(target.lastSeenAt, source.lastSeenAt)),
    directMediaCount:
        Value(_max(target.directMediaCount, source.directMediaCount)),
    directDirCount: Value(_max(target.directDirCount, source.directDirCount)),
    directItemCount: Value(_max(target.directItemCount, source.directItemCount)),
    totalMediaCount: Value(_max(target.totalMediaCount, source.totalMediaCount)),
    totalDirCount: Value(_max(target.totalDirCount, source.totalDirCount)),
    totalItemCount: Value(_max(target.totalItemCount, source.totalItemCount)),
    totalSizeInBytes:
        Value(_max(target.totalSizeInBytes, source.totalSizeInBytes)),
    totalDurationMs:
        Value(_max(target.totalDurationMs, source.totalDurationMs)),
  );
}

bool _laterPlayed(MediaNodesTableData a, MediaNodesTableData b) {
  final pa = a.lastPlayedAt;
  final pb = b.lastPlayedAt;
  if (pa == null) return pb != null;
  if (pb == null) return false;
  return pb.isAfter(pa);
}

int _max(int a, int b) => a > b ? a : b;

/// Deletes the loser's reference rows that the survivor already has.
///
/// Every one of these tables carries a `UNIQUE(...)` domain that includes
/// `storage_id`; repointing the loser's rows first would abort the transaction
/// on the first collision.
///
/// [foldCase] compares the path columns under the filesystem's own rules
/// (NTFS/UNC fold, POSIX/SAF exact). The UNIQUE indexes themselves are BINARY,
/// so without folding a case-variant spelling of the same file survives the
/// repoint as a second membership/source row.
Future<void> _dedupeReferences(
  AppDatabase db,
  String loserId,
  String survivorId, {
  required bool foldCase,
}) async {
  final rules = <String>[
    // table : the remaining UNIQUE key columns after storage_id
    'scenario_sources|scenario_id, path',
    'scenario_explicit_items|scenario_id, path',
    'video_tag_members|tag_id, path',
    'favorites_table|path',
    'bg_mappings_table|path',
    'media_lib_sources|library_id, path',
  ];
  for (final rule in rules) {
    final split = rule.split('|');
    final table = split[0];
    final keys = split[1]
        .split(',')
        .map((e) => e.trim())
        .map((col) => foldCase
            ? 't2.$col IS $table.$col COLLATE NOCASE'
            : 't2.$col IS $table.$col')
        .join(' AND ');
    await db.customUpdate(
      'DELETE FROM $table WHERE storage_id = ? AND EXISTS ('
      'SELECT 1 FROM $table t2 WHERE t2.storage_id = ? AND $keys)',
      variables: <Variable<Object>>[
        Variable<String>(loserId),
        Variable<String>(survivorId),
      ],
    );
  }
}

Future<void> _repointLibrary(
  AppDatabase db,
  String loserId,
  String survivorId, {
  required bool foldCase,
}) async {
  final loserLibrary = 'sys_$loserId';
  final survivorLibrary = 'sys_$survivorId';
  final existing = await db.customSelect(
    'SELECT COUNT(*) AS c FROM media_libs WHERE id = ?',
    variables: <Variable<Object>>[Variable<String>(survivorLibrary)],
  ).getSingle();
  final survivorHasLibrary = existing.read<int>('c') > 0;

  if (!survivorHasLibrary) {
    // Adopt the loser's library: rename the library and re-home its sources.
    await db.customUpdate(
      'UPDATE media_libs SET id = ? WHERE id = ?',
      variables: <Variable<Object>>[
        Variable<String>(survivorLibrary),
        Variable<String>(loserLibrary),
      ],
    );
    await db.customUpdate(
      'UPDATE media_lib_sources SET library_id = ? WHERE library_id = ?',
      variables: <Variable<Object>>[
        Variable<String>(survivorLibrary),
        Variable<String>(loserLibrary),
      ],
    );
    return;
  }

  // Both sides have a library: keep the survivor's row but absorb the loser's
  // sources that the survivor does not already list, then drop the loser's
  // library container.
  //
  // The duplicate test is (storage_id, path), NOT path alone: after the
  // repoint above every loser source already names the SURVIVOR storage, and a
  // survivor source for the same path on a THIRD storage is a different,
  // legitimate source — deleting by path alone silently dropped it.
  final samePath = foldCase
      ? 's2.path IS media_lib_sources.path COLLATE NOCASE'
      : 's2.path IS media_lib_sources.path';
  await db.customUpdate(
    'DELETE FROM media_lib_sources WHERE library_id = ? AND EXISTS ('
    'SELECT 1 FROM media_lib_sources s2 WHERE s2.library_id = ? '
    'AND s2.storage_id IS media_lib_sources.storage_id AND $samePath)',
    variables: <Variable<Object>>[
      Variable<String>(loserLibrary),
      Variable<String>(survivorLibrary),
    ],
  );
  await db.customUpdate(
    'UPDATE media_lib_sources SET library_id = ? WHERE library_id = ?',
    variables: <Variable<Object>>[
      Variable<String>(survivorLibrary),
      Variable<String>(loserLibrary),
    ],
  );
  await db.customUpdate(
    'DELETE FROM media_libs WHERE id = ?',
    variables: <Variable<Object>>[Variable<String>(loserLibrary)],
  );
}

Future<void> _repointScenarioStates(
  AppDatabase db,
  String loserId,
  String survivorId,
) async {
  final from = '"storageId":"$loserId"';
  final to = '"storageId":"$survivorId"';
  await db.customUpdate(
    'UPDATE scenario_state SET current_playback_occurrence = '
    'REPLACE(current_playback_occurrence, ?, ?) '
    'WHERE current_playback_occurrence LIKE ?',
    variables: <Variable<Object>>[
      Variable<String>(from),
      Variable<String>(to),
      Variable<String>('%$from%'),
    ],
  );
}

/// Marks file rows absent when the file is gone from disk.
///
/// Recoverable by design (`is_present` only): the row — and its progress — stays
/// so a reconnected drive/rescan brings it back. Skips the whole sweep when the
/// storage root is not reachable, otherwise an offline drive would grey out the
/// entire library.
Future<StorageMergeStats> sweepMissingFilesForStorage(
  LocalStorage storage, {
  void Function(String phase)? onPhase,
}) async {
  final dao = DbModule.mediaNodesDao;
  final base = storage.basePath;
  final root = normalizePathText(base.join('/'));
  if (root.isEmpty) return const StorageMergeStats();
  // A bare drive ('E:') is drive-RELATIVE to the process cwd; the root form
  // ('E:/') is what `exists` must probe.
  final probe = RegExp(r'^[A-Za-z]:$').hasMatch(root) ? '$root/' : root;
  if (!Directory(probe).existsSync()) {
    _log.i('storage sweep skipped: $probe is offline');
    return const StorageMergeStats();
  }
  onPhase?.call(storage.name);

  final scope = storage.dataScopeId ?? storage.id;
  final rows = await dao.rowsInScope(scope);
  final files = <MediaNodesTableData>[
    for (final row in rows)
      if (row.nodeKind == MediaNodeKind.file && row.isPresent) row,
  ];
  final missing = <int>[];
  var checked = 0;
  for (final row in files) {
    final domain =
        StoragePathCodec.absolutize(storage.id, normalizePathText(row.path));
    try {
      if (!File(domain).existsSync()) missing.add(row.id);
    } catch (_) {
      // An unreadable path is not proof of absence.
    }
    checked++;
    if (checked % 200 == 0) {
      // Yield so the startup splash keeps painting on a large library.
      await Future<void>.delayed(Duration.zero);
    }
  }
  if (missing.isNotEmpty) {
    await (dao.update(dao.mediaNodesTable)
          ..where((t) => t.id.isIn(missing)))
        .write(const MediaNodesTableCompanion(isPresent: Value(false)));
  }
  _log.i('storage sweep: ${storage.id} checked=${files.length} '
      'missing=${missing.length}');
  return StorageMergeStats(ghostRowsMarked: missing.length);
}
