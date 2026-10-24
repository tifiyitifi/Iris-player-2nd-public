import 'package:drift/drift.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_query.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_result.dart';
import 'package:iris/features/media_library/model/db/tables/media_nodes_table.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/search/model/search_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_scope.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/db/storage_scope.dart';
import 'package:iris/utils/escape_like.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/utils/path_prefix_remap.dart';

part 'media_nodes_dao.g.dart';

/// A normalized source tuple accepted by [MediaNodesDao.getPagedNodesForSources]:
/// traversal semantics via [recursive] (directory prefix vs direct children) and
/// the scenario source row id for per-source exclude attachment (v5-D3).
typedef SourcesQuerySource = ({
  String storageId,
  String? path,
  MediaSourceKind kind,
  bool recursive,
  int? scenarioSourceId,
});

/// Probe-able / optional sort columns: rows without a value must sort AFTER rows
/// with one, regardless of direction (the scan-probe promise).
///
/// Shared by `getPagedNodes` and `getPagedNodesForSources` so the two query
/// paths cannot disagree about NULL placement.
bool _needsNullsLast(MediaSortField field) {
  switch (field) {
    case MediaSortField.durationMs:
    case MediaSortField.sizeInBytes:
    case MediaSortField.pixelCount:
    case MediaSortField.modifiedAt:
    case MediaSortField.createdAt:
      return true;
    default:
      return false;
  }
}

/// Leading `IS NULL` term (always ascending): 0 = has value, 1 = NULL, so NULLs
/// land last whichever way the sort column is ordered.
List<OrderingTerm Function(MediaNodesTable)> _nullsLastTerms(
  MediaSortField field,
  Expression<Object> Function(MediaNodesTable) sortColumn,
) =>
    _needsNullsLast(field)
        ? <OrderingTerm Function(MediaNodesTable)>[
            (t) => OrderingTerm(
                expression: sortColumn(t).isNull(), mode: OrderingMode.asc),
          ]
        : const <OrderingTerm Function(MediaNodesTable)>[];

/// Ascending tail that turns the sort column into a total order.
///
/// A sort column alone is not total (equal timestamps, sizes, durations, or a
/// NULL bucket), and SQLite may return ties in any order — which also makes
/// windowed paging unstable. `path` is unique per (data_scope_id, path) within a
/// single-storage query, so it closes the order. Kept ascending in both
/// directions, like the name tie-break.
List<OrderingTerm Function(MediaNodesTable)> _orderTailTerms(
  MediaSortField field,
) =>
    <OrderingTerm Function(MediaNodesTable)>[
      // Redundant when the sort column already IS normalized_name.
      if (field != MediaSortField.name)
        (t) =>
            OrderingTerm(expression: t.normalizedName, mode: OrderingMode.asc),
      (t) => OrderingTerm(expression: t.path, mode: OrderingMode.asc),
    ];

/// Root-level predicate for a storage's top level.
///
/// The canonical parent form of a storage-root child is NULL, but rows produced
/// before the scanner normalization fix (an absolute scan root relativized to
/// an EMPTY string) stored `''`. Both must match everywhere the root level is
/// queried, or root-scope playback reports "no playable content" for rows that
/// are plainly visible.
Expression<bool> _rootParent(MediaNodesTable t) =>
    t.parentPath.isNull() | t.parentPath.equals('');

/// The storage root's DIRECT CHILDREN.
///
/// Unlike [_rootParent], this excludes the storage-root container row itself
/// (`path == ''`, parent NULL): a node is never its own child. Matching it
/// as a child poisoned `allChildDirsScanned` (the root counted itself as an
/// unscanned child, so the root `scanDone` stamp could never land — the play
/// gate then reported "never fully scanned" right after a full scan) and
/// inflated every root aggregate and root listing.
Expression<bool> _rootChildren(MediaNodesTable t) =>
    (t.parentPath.isNull() | t.parentPath.equals('')) &
        t.path.equals('').not();

/// Parent predicate for an already-relativized [canonical] parent: an empty
/// parent is the storage root (see [_rootParent]); otherwise an exact match.
Expression<bool> _parentMatches(MediaNodesTable t, String canonical) =>
    canonical.isEmpty ? _rootChildren(t) : t.parentPath.equals(canonical);

@DriftAccessor(tables: [MediaNodesTable])
class MediaNodesDao extends DatabaseAccessor<AppDatabase> with _$MediaNodesDaoMixin {
  MediaNodesDao(super.db);

  // --- CRUD Operations ---

  Future<int> insertNode(MediaNode node) => into(mediaNodesTable).insert(node.toCompanion());

  /// Bulk fetch by primary key ids (derived-index read path). Returns the nodes
  /// keyed by their numeric id; missing ids are simply absent.
  Future<Map<int, MediaNode>> nodesByIds(Iterable<int> ids) async {
    final list = ids.toSet().toList(growable: false);
    if (list.isEmpty) return const {};
    final out = <int, MediaNode>{};
    const chunkSize = 500;
    for (var i = 0; i < list.length; i += chunkSize) {
      final chunk = list.sublist(
          i, i + chunkSize > list.length ? list.length : i + chunkSize);
      final rows = await (select(mediaNodesTable)
            ..where((t) => t.id.isIn(chunk)))
          .get();
      for (final row in rows) {
        out[row.id] = MediaNodeDriftAdapter.fromDb(row);
      }
    }
    return out;
  }

  /// Every node whose persisted document [uri] is one of [uris]. A SAF
  /// single-picked file carries no path, so the document uri is its only
  /// identity (see [MediaNode.occurrencePath]).
  Future<List<MediaNodesTableData>> getByUris(Iterable<String> uris) {
    final list = uris.toSet().toList(growable: false);
    if (list.isEmpty) return Future.value(const []);
    return (select(mediaNodesTable)..where((t) => t.uri.isIn(list))).get();
  }

  /// Upserts by `(storage_id, path)` and preserves the playback_* progress
  /// columns (rescan-preserving rule). [MediaNode.toCompanion] intentionally
  /// omits progress, so the conflict update never touches it.
  Future<void> upsertNode(MediaNode node) =>
      into(mediaNodesTable).insert(
        node.toCompanion(),
        onConflict: DoUpdate(
          (_) => node.toCompanion(),
          target: [mediaNodesTable.dataScopeId, mediaNodesTable.path],
        ),
      );

  Future<void> deleteNode(String storageId, String path) {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(path));
    return (delete(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) &
                  t.path.equals(canonical)))
        .go();
  }

  /// Every scope id among [candidateScopes] that currently holds [rawPath].
  ///
  /// The candidate set is the storage's scope family; a row written through a
  /// sibling entry (same physical tree, independent scope) is still found.
  Future<Set<String>> scopesContainingPath({
    required String storageId,
    required Iterable<String> candidateScopes,
    required String rawPath,
  }) async {
    final scopes = candidateScopes.where((e) => e.isNotEmpty).toSet();
    final canonical = StoragePathCodec.relativizeRaw(storageId, rawPath);
    if (scopes.isEmpty || canonical.isEmpty) return const <String>{};
    final rows = await (selectOnly(mediaNodesTable, distinct: true)
          ..addColumns([mediaNodesTable.dataScopeId])
          ..where(mediaNodesTable.dataScopeId.isIn(scopes) &
              mediaNodesTable.path.equals(canonical)))
        .get();
    return <String>{
      for (final row in rows)
        if (row.read(mediaNodesTable.dataScopeId) case final scope?) scope,
    };
  }

  /// Identity-safe delete of [rawPath] across [scopeIds].
  ///
  /// Physical delete / scan-repair callers must use this instead of
  /// [deleteNode]: a node row may live under a scope id that is NOT the storage
  /// entry the caller holds (a re-added drive with a NULL `data_scope_id`, or a
  /// linked sibling), and a scope-only WHERE silently deleted 0 rows while the
  /// file disappeared from disk. Returns the number of removed rows.
  Future<int> deleteNodeAcrossScopes({
    required String storageId,
    required Iterable<String> scopeIds,
    required String rawPath,
  }) {
    final scopes = scopeIds.where((e) => e.isNotEmpty).toSet();
    final canonical = StoragePathCodec.relativizeRaw(storageId, rawPath);
    if (scopes.isEmpty || canonical.isEmpty) return Future<int>.value(0);
    return (delete(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.isIn(scopes) & t.path.equals(canonical)))
        .go();
  }

  /// Marks [rawPath] absent in every scope of [scopeIds] (does NOT delete rows).
  ///
  /// The fallback when a physical delete removed the file but no node row
  /// matched: the library must stop offering a file that no longer exists, and
  /// a later rescan can still reconcile the row. Returns the affected rows.
  Future<int> markNodeAbsentAcrossScopes({
    required String storageId,
    required Iterable<String> scopeIds,
    required String rawPath,
  }) {
    final scopes = scopeIds.where((e) => e.isNotEmpty).toSet();
    final canonical = StoragePathCodec.relativizeRaw(storageId, rawPath);
    if (scopes.isEmpty || canonical.isEmpty) return Future<int>.value(0);
    return (update(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.isIn(scopes) & t.path.equals(canonical)))
        .write(const MediaNodesTableCompanion(isPresent: Value(false)));
  }

  /// Every row of one canonical scope (used by the duplicate-entry merge).
  Future<List<MediaNodesTableData>> rowsInScope(String scopeId) =>
      (select(mediaNodesTable)
            ..where((t) => t.dataScopeId.equals(scopeId)))
          .get();

  /// Deletes a node row by primary key.
  Future<int> deleteNodeById(int id) =>
      (delete(mediaNodesTable)..where((t) => t.id.equals(id))).go();

  /// Moves one row to another canonical scope/owner (duplicate-entry merge).
  Future<int> moveNodeToScope({
    required int id,
    required String storageId,
    required String dataScopeId,
  }) =>
      (update(mediaNodesTable)..where((t) => t.id.equals(id))).write(
        MediaNodesTableCompanion(
          storageId: Value(storageId),
          dataScopeId: Value(dataScopeId),
        ),
      );

  // --- Batch Operations (for recursive scan) ---

  Future<void> batchUpsert(List<MediaNodesTableCompanion> entries) async {
    if (entries.isEmpty) return;
    const chunkSize = 500;
    for (var i = 0; i < entries.length; i += chunkSize) {
      final chunk = entries.sublist(
        i,
        i + chunkSize > entries.length ? entries.length : i + chunkSize,
      );
      await batch((b) {
        for (final entry in chunk) {
          b.insert(
            mediaNodesTable,
            entry,
            onConflict: DoUpdate(
              (_) => entry,
              target: [mediaNodesTable.dataScopeId, mediaNodesTable.path],
            ),
          );
        }
      });
    }
  }

  /// Deletes multiple nodes by exact path match within a storage.
  ///
  /// Chunks the `IN` list to stay under SQLite's `SQLITE_MAX_VARIABLE_NUMBER`
  /// (999) — large scans would otherwise throw "too many SQL variables".
  Future<void> batchDeleteByPaths(
      String storageId, List<String> paths) async {
    if (paths.isEmpty) return;
    final canonical = paths
        .map((p) => StoragePathCodec.relativize(storageId, canonicalDbPath(p)))
        .toList();
    const chunkSize = 900;
    for (var i = 0; i < canonical.length; i += chunkSize) {
      final chunk = canonical.sublist(
        i,
        i + chunkSize > canonical.length ? canonical.length : i + chunkSize,
      );
      await (delete(mediaNodesTable)
            ..where((t) =>
                t.dataScopeId.equals(StorageScope.of(storageId)) & t.path.isIn(chunk)))
          .go();
    }
  }

  /// Batch sets isPresent for a list of paths.
  ///
  /// Chunked for the same SQLite variable limit as [batchDeleteByPaths].
  Future<void> batchSetIsPresent(
      String storageId, List<String> paths, bool present) async {
    if (paths.isEmpty) return;
    final canonical = paths
        .map((p) => StoragePathCodec.relativize(storageId, canonicalDbPath(p)))
        .toList();
    const chunkSize = 900;
    for (var i = 0; i < canonical.length; i += chunkSize) {
      final chunk = canonical.sublist(
        i,
        i + chunkSize > canonical.length ? canonical.length : i + chunkSize,
      );
      await (update(mediaNodesTable)
            ..where((t) =>
                t.dataScopeId.equals(StorageScope.of(storageId)) & t.path.isIn(chunk)))
          .write(MediaNodesTableCompanion(
        isPresent: Value(present),
      ));
    }
  }

  /// Deletes all nodes whose path starts with [pathPrefix] under [storageId].
  /// If [pathPrefix] is empty, deletes all root-level children (parentPath NULL
  /// or its legacy empty form).
  Future<void> deleteByPathPrefix(String storageId, String pathPrefix) async {
    if (pathPrefix.isEmpty) {
      await (delete(mediaNodesTable)
            ..where((t) =>
                t.dataScopeId.equals(StorageScope.of(storageId)) & _rootParent(t)))
          .go();
    } else {
      final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(pathPrefix));
      final escaped = escapeLike(canonical);
      await (delete(mediaNodesTable)
            ..where((t) =>
                t.dataScopeId.equals(StorageScope.of(storageId)) &
                (t.path.like('$escaped/%', escapeChar: r'\') |
                    t.path.equals(canonical))))
          .go();
    }
  }

  /// Deletes the single row stored under the exact [storedPath] (NO path
  /// conversion is applied).
  ///
  /// For stale absolute-form rows (see
  /// [StoragePathCodec.isStaleAbsoluteBase]): their relativized form is `''`,
  /// so [deleteNode] / [deleteByPathPrefix] would target the real root
  /// container instead of the phantom.
  Future<void> deleteByExactStoredPath(
      String storageId, String storedPath) async {
    await (delete(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) &
              t.path.equals(storedPath)))
        .go();
  }

  /// Deletes phantom above-base ancestor rows for [storageId] (see
  /// [StoragePathCodec.isAboveBase]) plus their subtrees, as well as the
  /// stale absolute-form root self node (see
  /// [StoragePathCodec.isStaleAbsoluteBase]).
  ///
  /// Pre-fix scans built directory nodes from absolute segments, leaking the
  /// base and everything above it (`F:`, `F:/dl`) into the DB. The topmost
  /// phantom carries a NULL parent, so `allChildDirsScanned` counts it as an
  /// unscanned root child and the root `scanDone` stamp can never land — the
  /// play gate then reports "never fully scanned" right after a full scan.
  /// Runs best-effort at scan entry; relative rows can never match the
  /// prefix, so legitimate content is untouched. Returns the number of
  /// phantom subtrees removed.
  Future<int> deleteAboveBaseAncestors(String storageId) async {
    var deleted = 0;
    // Phantom depth is bounded by the base depth; re-query after each pass
    // so a dangling mid-chain row (whose phantom parent is already gone)
    // surfaces at the root level on the next pass.
    for (var pass = 0; pass < 8; pass++) {
      final roots = await getRootLevelNodes(storageId);
      var found = false;
      for (final row in roots) {
        if (row.nodeKind != MediaNodeKind.directory || row.path.isEmpty) {
          continue;
        }
        final canon = canonicalDbPath(row.path);
        if (StoragePathCodec.isAboveBase(storageId, canon)) {
          await deleteByPathPrefix(storageId, row.path);
          deleted++;
          found = true;
          continue;
        }
        // Absolute-form root self node from pre-fix scans (e.g. stored `F:`
        // with base `F:`): it relativizes to `''`, so it must go by exact
        // stored-path match — a prefix delete would wipe the real root
        // container instead.
        if (StoragePathCodec.isStaleAbsoluteBase(storageId, canon)) {
          await deleteByExactStoredPath(storageId, row.path);
          deleted++;
          found = true;
        }
      }
      if (!found) break;
    }
    return deleted;
  }

  /// Deletes all nodes for an entire storage.
  Future<void> deleteByStorage(String storageId) async {
    await (delete(mediaNodesTable)
          ..where((t) => t.dataScopeId.equals(StorageScope.of(storageId))))
        .go();
  }

  /// Deletes every node row of one **canonical scope** (no storage-id
  /// translation). Used when the last entry of a scope is unlinked/removed, so
  /// its rows cannot be reached through any entry anymore.
  Future<void> deleteByScopeId(String scopeId) async {
    await (delete(mediaNodesTable)
          ..where((t) => t.dataScopeId.equals(scopeId)))
        .go();
  }

  /// Re-points every node of a data scope to [newStorageId] (a surviving owner
  /// entry). Used when the current canonical owner is removed: queries stay
  /// scope-keyed, but `node.storageId` must name a live entry so playback can
  /// resolve credentials/URLs.
  Future<void> reassignStorageIdForScope({
    required String scopeId,
    required String newStorageId,
  }) async {
    await (update(mediaNodesTable)
          ..where((t) => t.dataScopeId.equals(scopeId)))
        .write(MediaNodesTableCompanion(storageId: Value(newStorageId)));
  }

  /// Rewrites the leading [oldBase] of every `path`/`parent_path` under
  /// [storageId] to [newBase] in one pass (drive-letter reassignment).
  ///
  /// Only the path prefix changes — probe data, aggregates and playback
  /// progress ride along on the same row, so a re-mounted disk is not
  /// re-scanned. Returns the number of rows affected.
  Future<int> remapPathPrefix({
    required String storageId,
    required String oldBase,
    required String newBase,
  }) {
    final query = buildPathPrefixRemap(
      table: 'media_nodes',
      keyColumn: 'data_scope_id',
      keyValue: StorageScope.of(storageId),
      oldBase: oldBase,
      newBase: newBase,
      hasParentPath: true,
    );
    return customUpdate(
      query.sql,
      variables: query.variables,
      updates: {mediaNodesTable},
    );
  }

  /// Moves ONE node row to [newPath] (same storage), rewriting its name and
  /// normalized name. Used for a case-only rename on a case-insensitive
  /// filesystem: the row keeps its id, probe data and playback progress instead
  /// of being deleted and re-inserted. Returns the number of rows affected.
  Future<int> renameNodePath({
    required String storageId,
    required String oldPath,
    required String newPath,
    required String name,
  }) {
    return (update(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) &
              t.path.equals(oldPath)))
        .write(MediaNodesTableCompanion(
      path: Value(newPath),
      name: Value(name),
      normalizedName: Value(name.toLowerCase()),
    ));
  }

  /// Rewrites the ABSOLUTE local subtitle URIs stored in `subtitles_json` that
  /// live under [oldBase].
  ///
  /// The video path is storage-relative and gets rebuilt at open time, but an
  /// external subtitle is an absolute snapshot captured at scan time. Without
  /// this, a drive-letter remap (E: → F:) left every subtitle pointing at the
  /// old drive while its video played from the new one. Returns the number of
  /// rows written.
  Future<int> remapSubtitleUris({
    required String storageId,
    required String oldBase,
    required String newBase,
  }) async {
    if (oldBase.isEmpty || newBase.isEmpty || oldBase == newBase) return 0;
    final rows = await customSelect(
      'SELECT id, subtitles_json FROM media_nodes '
      'WHERE data_scope_id = ? AND subtitles_json IS NOT NULL '
      "AND subtitles_json <> '[]'",
      variables: [Variable.withString(StorageScope.of(storageId))],
    ).get();
    var changed = 0;
    for (final row in rows) {
      try {
        final raw = row.read<String>('subtitles_json');
        final next = remapSubtitleJsonUris(
          raw,
          oldBase: oldBase,
          newBase: newBase,
        );
        if (next == null) continue;
        await customStatement(
          'UPDATE media_nodes SET subtitles_json = ? WHERE id = ?',
          [next, row.read<int>('id')],
        );
        changed++;
      } catch (e) {
        // One row's bad payload must not abort the shared remap transaction
        // (see remapSubtitleJsonUris). Skip it and keep going.
        AreaKeyLog(LogKeys.legacyDb)
            .w('remapSubtitleUris: skipped row ${row.read<int>('id')}: $e');
      }
    }
    return changed;
  }

  /// Marks a directory node as scan-done with current timestamp.
  Future<void> markScanDone(String storageId, String path) async {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(path));
    await (update(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) &
                  t.path.equals(canonical)))
        .write(MediaNodesTableCompanion(
          isScanDone: const Value(true),
          lastScanAt: Value(DateTime.now()),
        ));
  }

  /// Marks a directory as being recursively scanned (`scanState='scanning'`).
  /// Legacy `isScanDone` is left untouched (a scanning dir is not done).
  Future<void> markDirScanning(String storageId, String path) async {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(path));
    await (update(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) &
                  t.path.equals(canonical)))
        .write(MediaNodesTableCompanion(
          scanState: const Value('scanning'),
        ));
  }

  /// Marks a directory as FULLY recursively scanned (bottom-up): enum
  /// `scanDone` + legacy `isScanDone=true` + `lastScanAt=now` in one write so
  /// the scan-resume path (`allChildDirsScanned`) keeps working unchanged.
  Future<void> markDirScanDone(String storageId, String path) async {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(path));
    await (update(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) &
                  t.path.equals(canonical)))
        .write(MediaNodesTableCompanion(
          scanState: const Value('scanDone'),
          isScanDone: const Value(true),
          lastScanAt: Value(DateTime.now()),
        ));
  }

  /// Marks a directory's scan as failed (`scanState='error'`).
  Future<void> markDirScanError(String storageId, String path) async {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(path));
    await (update(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) &
                  t.path.equals(canonical)))
        .write(MediaNodesTableCompanion(
          scanState: const Value('error'),
        ));
  }

  /// Scan status of one directory node: `(state, lastScanAt)`. A missing row
  /// (never scanned, or not even listed) reports `('notScan', null)`.
  Future<({String state, DateTime? lastScanAt})?> dirScanStatus(
      String storageId, String path) async {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(path));
    final row = await (select(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) &
                  t.path.equals(canonical)))
        .getSingleOrNull();
    if (row == null) return (state: 'notScan', lastScanAt: null);
    return (state: row.scanState, lastScanAt: row.lastScanAt);
  }

  /// Checks whether all immediate child directories of [parentPath]
  /// have isScanDone = true.
  Future<bool> allChildDirsScanned(
      String storageId, String parentPath) async {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(parentPath));
    final unscanned = await (select(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) &
              _parentMatches(t, canonical) &
              t.nodeKind.equals(MediaNodeKind.directory.name) &
              t.isScanDone.equals(false)))
        .get();
    return unscanned.isEmpty;
  }

  /// Returns all direct child directories of [parentPath].
  Future<List<MediaNodesTableData>> getChildDirs(
      String storageId, String parentPath) async {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(parentPath));
    return (select(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) &
              _parentMatches(t, canonical) &
              t.nodeKind.equals(MediaNodeKind.directory.name)))
        .get();
  }

  /// Returns all direct children (dirs + files) of [parentPath].
  Future<List<MediaNodesTableData>> getDirectChildren(
      String storageId, String parentPath) async {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(parentPath));
    return (select(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) &
              _parentMatches(t, canonical)))
        .get();
  }

  /// Returns a single node by storage + path.
  ///
  /// The path is canonicalized on the lookup side (like every other path-keyed
  /// accessor), so callers may pass either the rooted or canonical form.
  /// [getByPathRaw] is the exact-path variant for the legacy leading-slash
  /// fallback.
  Future<MediaNodesTableData?> getByPath(
      String storageId, String path) {
    return getByPathRaw(
        storageId, StoragePathCodec.relativize(storageId, canonicalDbPath(path)));
  }

  /// Exact-path lookup with NO canonicalization (legacy fallback / repair).
  Future<MediaNodesTableData?> getByPathRaw(
      String storageId, String path) async {
    return (select(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) & t.path.equals(path))
          ..limit(1))
        .getSingleOrNull();
  }

  /// Canonical-form single-node lookup with a legacy raw fallback: tries the
  /// canonical path first, then the caller's raw form (compat for rows stored
  /// with a leading slash before the DB normalization landed).
  Future<MediaNodesTableData?> getByPathCanonical(
      String storageId, String path) async {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(path));
    final row = await getByPath(storageId, canonical);
    if (row != null) return row;
    // A SAF document uri now keeps its `content://` scheme (`safSegmentsOf`),
    // while rows written before that fix sit under the COLLAPSED key
    // (`content:/…` — the form v23 repaired). Address both so an existing single
    // pick is never orphaned by a query built from the live uri.
    final collapsed = collapsedSafSchemePath(canonical);
    if (collapsed != null) {
      final legacy = await getByPath(storageId, collapsed);
      if (legacy != null) return legacy;
    }
    if (canonical == path) return row;
    return getByPathRaw(storageId, path);
  }

  /// Returns the storage-root CONTAINER row (`path == ''`), or null when the
  /// storage has never been scanned.
  ///
  /// Deliberately NOT `_rootParent`: a NULL parent also matches every genuine
  /// root-level child (a top-level dir/file and the pre-fix above-base phantom
  /// alike), so `_rootParent` + `limit(1)` would return whichever row SQLite
  /// happens to hit first — the container is not guaranteed. Keying on the
  /// exact empty path is the container-only read that [_rootChildren] encodes
  /// for [getRootLevelNodes].
  Future<MediaNodesTableData?> getRootNode(String storageId) =>
      getByPath(storageId, '');

  /// Legacy repair: returns rows whose stored `path` starts with `/` (or `//`)
  /// — pre-canonicalization rows that canonical queries cannot see.
  Future<List<MediaNodesTableData>> getLegacySlashRows(
      String storageId) async {
    return (select(mediaNodesTable)
          ..where((t) => t.dataScopeId.equals(StorageScope.of(storageId)) & t.path.like('/%')))
        .get();
  }

  /// Exact-path delete (no canonicalization) — used by the legacy repair to
  /// remove a specific legacy row without touching the canonical row.
  Future<void> deleteNodeByRawPath(String storageId, String rawPath) {
    final canonical = StoragePathCodec.relativize(storageId, rawPath);
    return (delete(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) & t.path.equals(canonical)))
        .go();
  }

  /// Rewrites a legacy row's stored `path`/`parentPath` to their canonical
  /// forms (exact-path match, no canonicalization on the lookup side).
  Future<void> updatePathAndParent(
    String storageId,
    String rawPath,
    String newPath,
    String? newParentPath,
  ) {
    final raw = StoragePathCodec.relativize(storageId, rawPath);
    final next = StoragePathCodec.relativize(storageId, newPath);
    final nextParent = newParentPath == null
        ? null
        : StoragePathCodec.relativize(storageId, newParentPath);
    return (update(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) & t.path.equals(raw)))
        .write(MediaNodesTableCompanion(
      path: Value(next),
      parentPath: Value(nextParent),
    ));
  }

  /// Returns all top-level nodes (parentPath IS NULL or legacy empty) for a
  /// storage. Used to compute aggregates for root sources that span the entire
  /// storage. The storage-root container row itself (`path == ''`) is not
  /// its own child and is excluded (see [_rootChildren]).
  Future<List<MediaNodesTableData>> getRootLevelNodes(
      String storageId) async {
    return (select(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) & _rootChildren(t)))
        .get();
  }

  /// Updates aggregate counts on a directory node.
  Future<void> updateAggregates({
    required String storageId,
    required String path,
    required int directMediaCount,
    required int directDirCount,
    required int directItemCount,
    required int totalMediaCount,
    required int totalDirCount,
    required int totalItemCount,
    required int totalSizeInBytes,
    required int totalDurationMs,
  }) async {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(path));
    await (update(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) &
                  t.path.equals(canonical)))
        .write(MediaNodesTableCompanion(
          directMediaCount: Value(directMediaCount),
          directDirCount: Value(directDirCount),
          directItemCount: Value(directItemCount),
          totalMediaCount: Value(totalMediaCount),
          totalDirCount: Value(totalDirCount),
          totalItemCount: Value(totalItemCount),
          totalSizeInBytes: Value(totalSizeInBytes),
          totalDurationMs: Value(totalDurationMs),
        ));
  }

  /// Returns {MediaType: count} for all files under [pathPrefix] in [storageId].
  /// If [pathPrefix] is empty, counts root-level files only. [mediaTypes]
  /// optionally narrows the counted rows (browse-scope projection).
  Future<Map<MediaType, int>> countByMediaTypeUnderPath(
    String storageId,
    String pathPrefix, {
    List<MediaType>? mediaTypes,
  }) async {
    final countExp = mediaNodesTable.id.count();
    final mediaTypeCol = mediaNodesTable.mediaType;

    Expression<bool> pathCondition;
    if (pathPrefix.isEmpty) {
      pathCondition = _rootParent(mediaNodesTable);
    } else {
      final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(pathPrefix));
      final escaped = escapeLike(canonical);
      pathCondition = mediaNodesTable.path.like('$escaped/%', escapeChar: r'\') |
          mediaNodesTable.path.equals(canonical);
    }

    Expression<bool> predicate = mediaNodesTable.dataScopeId.equals(StorageScope.of(storageId)) &
        mediaNodesTable.nodeKind.equals(MediaNodeKind.file.name) &
        pathCondition;
    if (mediaTypes != null && mediaTypes.isNotEmpty) {
      predicate &=
          mediaNodesTable.mediaType.isIn(mediaTypes.map((e) => e.name));
    }

    final query = selectOnly(mediaNodesTable)
      ..addColumns([mediaTypeCol, countExp])
      ..where(predicate)
      ..groupBy([mediaTypeCol]);

    final rows = await query.get();
    final result = <MediaType, int>{};
    for (final row in rows) {
      final typeStr = row.read(mediaTypeCol);
      final count = row.read(countExp) ?? 0;
      if (typeStr != null) {
        final type = MediaType.values.firstWhere(
          (e) => e.name == typeStr,
          orElse: () => MediaType.unknown,
        );
        result[type] = count;
      }
    }
    return result;
  }

  /// Scoped per-directory aggregates for the browse-media-scope DISPLAY
  /// override: {canonical path → (mediaCount, sizeBytes, durationMs)} of
  /// in-scope FILE nodes anywhere under each path. The persisted aggregate
  /// columns are never touched — this is a read-only projection.
  ///
  /// One grouped query per path; page-sized path lists keep this cheap.
  Future<Map<String, ({int mediaCount, int sizeBytes, int durationMs})>>
      aggregateByMediaTypes({
    required String storageId,
    required List<String> paths,
    required List<MediaType> mediaTypes,
  }) async {
    final result =
        <String, ({int mediaCount, int sizeBytes, int durationMs})>{};
    if (mediaTypes.isEmpty) return result;

    final countExp = mediaNodesTable.id.count();
    final sizeExp = mediaNodesTable.sizeInBytes.sum();
    final durExp = mediaNodesTable.durationMs.sum();

    for (final rawPath in paths) {
      if (rawPath.isEmpty) continue;
      final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(rawPath));
      final escaped = escapeLike(canonical);
      final query = selectOnly(mediaNodesTable)
        ..addColumns([countExp, sizeExp, durExp])
        ..where(mediaNodesTable.dataScopeId.equals(StorageScope.of(storageId)) &
            mediaNodesTable.nodeKind.equals(MediaNodeKind.file.name) &
            mediaNodesTable.mediaType.isIn(
                mediaTypes.map((e) => e.name).toList()) &
            mediaNodesTable.path.like('$escaped/%', escapeChar: r'\'));
      final row = await query.getSingle();
      result[canonical] = (
        mediaCount: row.read(countExp) ?? 0,
        sizeBytes: row.read<int>(sizeExp) ?? 0,
        durationMs: row.read<int>(durExp) ?? 0,
      );
    }
    return result;
  }

  /// Updates only the durationMs field on a file node.
  ///
  /// Canonical lookup with a legacy raw fallback so rows stored with a leading
  /// slash still receive the write (compat until they are re-synced).
  Future<void> updateFileDuration(
      String storageId, String path, int durationMs) async {
    final storedPath = await _resolveStoredPath(storageId, path);
    if (storedPath == null) return;
    await (update(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) & t.path.equals(storedPath)))
        .write(MediaNodesTableCompanion(
      durationMs: Value(durationMs),
    ));
  }

  /// Writes deep-probe media info onto a file node.
  ///
  /// Only explicitly provided fields are written; every other column is
  /// preserved. Null parameters leave the corresponding column unchanged.
  /// Canonical lookup with a legacy raw fallback (see [updateFileDuration]).
  ///
  /// Returns the number of rows actually updated: `0` when the file has no
  /// media_nodes row (or the lookup resolved to nothing), so callers can tell
  /// a real write from a silent no-op (`[vm-scan] write-back failed`).
  Future<int> updateFileMediaInfo({
    required String storageId,
    required String path,
    int? durationMs,
    String? uri,
    int? width,
    int? height,
    int? pixelCount,
  }) async {
    final storedPath = await _resolveStoredPath(storageId, path);
    if (storedPath == null) return 0;
    return (update(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) & t.path.equals(storedPath)))
        .write(MediaNodesTableCompanion(
      durationMs:
          durationMs == null ? const Value.absent() : Value(durationMs),
      uri: uri == null ? const Value.absent() : Value(uri),
      width: width == null ? const Value.absent() : Value(width),
      height: height == null ? const Value.absent() : Value(height),
      pixelCount:
          pixelCount == null ? const Value.absent() : Value(pixelCount),
    ));
  }

  /// File rows under a SAF storage whose persisted `uri` is still missing.
  ///
  /// One-time legacy backfill (schema v23 added the column): rows created
  /// before SAF support carried no document URI and are repaired lazily at
  /// startup by re-resolving each file through the SAF provider.
  Future<List<({String path, String name})>> listSafFilesMissingUri(
    String storageId,
    String treePrefix, {
    int limit = 500,
  }) async {
    final rows = await customSelect(
      "SELECT path, name FROM media_nodes "
      "WHERE data_scope_id = ? AND node_kind = 'file' "
      // The SAF tree id is percent-encoded and may contain `_`; escape the
      // prefix so `%`/`_` are literals, exactly like every other LIKE here.
      "AND path LIKE ? ESCAPE '\\' AND uri IS NULL LIMIT ?",
      variables: [
        Variable.withString(StorageScope.of(storageId)),
        Variable.withString('${escapeLike(treePrefix)}/%'),
        Variable.withInt(limit),
      ],
      readsFrom: {mediaNodesTable},
    ).get();
    return [
      for (final r in rows)
        (path: r.read<String>('path'), name: r.read<String>('name')),
    ];
  }

  /// Persists a backfilled SAF document [uri] for one media_nodes row
  /// (exact canonical path match; no ancestor recompute needed).
  Future<void> setNodeUri(String storageId, String path, String uri) async {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(path));
    await customUpdate(
      'UPDATE media_nodes SET uri = ? '
      'WHERE data_scope_id = ? AND path = ?',
      variables: [
        Variable.withString(uri),
        Variable.withString(StorageScope.of(storageId)),
        Variable.withString(canonical),
      ],
      updates: {mediaNodesTable},
    );
  }

  /// Global per-file playback progress (uniform across all scenarios).
  ///
  /// Only the playback_* columns are touched — media fields are preserved.
  /// Null parameters leave the corresponding column unchanged.
  /// Canonical lookup with a legacy raw fallback (see [updateFileDuration]).
  ///
  /// [historyRestoreBudgetMs] null keeps the stored budget untouched.
  Future<void> updatePlaybackProgress({
    required String storageId,
    required String path,
    int? positionMs,
    bool? completed,
    DateTime? lastPlayedAt,
    int? playCount,
    int? historyRestoreBudgetMs,
  }) async {
    final storedPath = await _resolveStoredPath(storageId, path);
    if (storedPath == null) return;
    await (update(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) & t.path.equals(storedPath)))
        .write(MediaNodesTableCompanion(
      playbackPositionMs: positionMs == null ? const Value.absent() : Value(positionMs),
      playbackCompleted: completed == null ? const Value.absent() : Value(completed),
      lastPlayedAt: lastPlayedAt == null ? const Value.absent() : Value(lastPlayedAt),
      playCount: playCount == null ? const Value.absent() : Value(playCount),
      historyRestoreBudget:
          historyRestoreBudgetMs == null ? const Value.absent() : Value(historyRestoreBudgetMs),
    ));
  }

  /// Resolves the exact stored `path` of a row for [path]: returns the
  /// canonical form when a canonical row exists, else the COLLAPSED SAF scheme
  /// form of a pre-v23 row (`content://a/b` → `content:/a/b`, the shape
  /// MigrationV23 left behind), else the caller's raw form when a legacy
  /// (leading-slash) row exists, else null.
  ///
  /// A null return means the write is silently dropped by the caller — log
  /// it so a path-shape mismatch between producers and the DB is visible
  /// instead of vanishing (e.g. VM duration write-back with no effect).
  Future<String?> _resolveStoredPath(String storageId, String path) async {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(path));
    final canonicalRow = await getByPath(storageId, canonical);
    if (canonicalRow != null) return canonical;
    // A SAF document uri keeps its `content://` scheme, while rows written
    // before that fix sit under the COLLAPSED key: address both, exactly like
    // [getByPathCanonical], so a duration/dims write-back onto a pre-fix single
    // pick is not dropped as "no row".
    final collapsed = collapsedSafSchemePath(canonical);
    if (collapsed != null) {
      final collapsedRow = await getByPath(storageId, collapsed);
      if (collapsedRow != null) return collapsed;
    }
    if (canonical == path) {
      AreaKeyLog(LogKeys.legacyDb)
          .w('resolveStoredPath miss: no row for $storageId:$path');
      return null;
    }
    final legacyRow = await getByPathRaw(storageId, path);
    if (legacyRow != null) return path;
    AreaKeyLog(LogKeys.legacyDb)
        .w('resolveStoredPath miss: no row for $storageId:$path');
    return null;
  }

  /// Recomputes totalDurationMs for [dirPath] by summing its direct children.
  Future<void> recomputeDurationAggregate(
      String storageId, String dirPath) async {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(dirPath));
    final children = await getDirectChildren(storageId, canonical);
    int totalDurationMs = 0;
    for (final child in children) {
      if (child.nodeKind == MediaNodeKind.directory) {
        totalDurationMs += child.totalDurationMs;
      } else {
        totalDurationMs += child.durationMs ?? 0;
      }
    }
    await (update(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) &
                  t.path.equals(canonical)))
        .write(MediaNodesTableCompanion(
      totalDurationMs: Value(totalDurationMs),
    ));
  }

  /// Walks up the directory tree from [startPath] and recomputes
  /// totalDurationMs at each ancestor level.
  Future<void> recomputeDurationAncestors(
      String storageId, String startPath) async {
    String? currentPath = startPath;
    while (currentPath != null && currentPath.isNotEmpty) {
      await recomputeDurationAggregate(storageId, currentPath);
      final lastSlash = currentPath.lastIndexOf('/');
      currentPath = lastSlash > 0 ? currentPath.substring(0, lastSlash) : null;
    }
  }

  // --- Complex Paginated Queries ---

  /// Executes a dynamic paginated query.
  /// Hides the SQL complexity from the Repository.
  Future<MediaNodePageResult> getPagedNodes(MediaNodePageQuery query) async {
    return transaction(() async {
      // Normalize the parent path so callers with different slash conventions
      // (rooted `/storage/...`, canonical `storage/...`) match the same rows.
      // An EMPTY relativized parent is the storage ROOT: collapse it to null so
      // it takes the root branch below instead of a recursive-prefix match on
      // an empty prefix (which matched nothing — the "root folder shows files
      // but resolves to no playable content" bug).
      final rawParent =
          query.parentPath == null
              ? null
              : StoragePathCodec.relativize(
                  query.storageId ?? '', canonicalDbPath(query.parentPath!));
      final parentPath =
          (rawParent == null || rawParent.isEmpty) ? null : rawParent;

      // 1. Build the dynamic WHERE expression
      Expression<bool> buildWhereClause(MediaNodesTable t) {
        Expression<bool> predicate = const Constant(true);

        if (query.storageId != null) {
          predicate &= t.dataScopeId.equals(StorageScope.of(query.storageId!));
        }
        if (parentPath != null) {
          if (query.recursive) {
            final escaped = escapeLike(parentPath);
            predicate &=
                t.path.like('$escaped/%', escapeChar: r'\') |
                t.path.equals(parentPath);
          } else {
            predicate &= t.parentPath.equals(parentPath);
          }
        } else if (query.storageId != null) {
          if (query.matchAllInStorage) {
            // Entire-storage query: match every node of the storage.
            predicate &= t.path.isNotNull();
          } else {
            // Directory browsing at storage root: only show root-level nodes
            // (the `''` container row itself is not its own child).
            predicate &= _rootChildren(t);
          }
        }
        if (query.nodeKind != null) {
          predicate &= t.nodeKind.equals(query.nodeKind!.name); // Assuming Enum maps to String
        }
        if (query.mediaType != null) {
          predicate &= t.mediaType.equals(query.mediaType!.name);
        }
        // Browse-scope visibility: a row-level mediaType IN filter would drop
        // every directory row (their mediaType is null), so directories are
        // scoped through a playable-descendant EXISTS instead (mirrors
        // getPagedNodesForSources). Mixed listings (nodeKind == null) apply
        // each predicate only to its own row kind.
        if (query.mediaTypes != null && query.mediaTypes!.isNotEmpty) {
          final types = query.mediaTypes!;
          final filesInScope =
              t.mediaType.isIn(types.map((e) => e.name).toList());
          final dirInScope = _hasPlayableDescendant(t, types: types);
          switch (query.nodeKind) {
            case MediaNodeKind.directory:
              predicate &= dirInScope;
            case MediaNodeKind.file:
              predicate &= filesInScope;
            case null:
              predicate &= (t.nodeKind.equals(MediaNodeKind.directory.name) &
                      dirInScope) |
                  (t.nodeKind.equals(MediaNodeKind.file.name) & filesInScope);
          }
        } else if (query.hideEmptyDirs) {
          // Unscoped pathTree "only dirs with media": files pass through,
          // directories need a playable descendant (default video+audio).
          final nonEmptyDir = _hasPlayableDescendant(t);
          switch (query.nodeKind) {
            case MediaNodeKind.directory:
              predicate &= nonEmptyDir;
            case MediaNodeKind.file:
              break;
            case null:
              predicate &= (t.nodeKind.equals(MediaNodeKind.file.name) |
                  (t.nodeKind.equals(MediaNodeKind.directory.name) &
                      nonEmptyDir));
          }
        }
        if (query.searchQuery != null && query.searchQuery!.isNotEmpty) {
          predicate &= buildSearchPredicate(t, query.searchQuery!);
        }

        return predicate;
      }

      // 2. Map the Sort Enum to Drift Columns
      Expression<Object> sortColumn(MediaNodesTable t) {
        switch (query.sortField) {
          case MediaSortField.name:
            return t.normalizedName;
          case MediaSortField.path:
            return t.path;
          case MediaSortField.modifiedAt:
            return t.modifiedAt;
          case MediaSortField.createdAt:
            return t.createdAt;
          case MediaSortField.sizeInBytes:
            return t.sizeInBytes;
          case MediaSortField.durationMs:
            return t.durationMs;
          case MediaSortField.pixelCount:
            return t.pixelCount;
          case MediaSortField.totalSizeInBytes:
            return t.totalSizeInBytes;
          case MediaSortField.totalDurationMs:
            return t.totalDurationMs;
          default:
            return t.normalizedName;
        }
      }

      List<OrderingTerm Function(MediaNodesTable)> buildOrderClauses() {
        final mode = query.sortDirection == SortDirection.asc
            ? OrderingMode.asc
            : OrderingMode.desc;

        final nullsLastTerms = _nullsLastTerms(query.sortField, sortColumn);
        final tailTerms = _orderTailTerms(query.sortField);

        // 同目录连续 (pathGroupFirst): group same-parent files into contiguous
        // blocks — ORDER BY (parentPath, sortField, name, path). Direction
        // applies to both parentPath and sortField; the tail stays ascending.
        if (query.pathGroupFirst) {
          return [
            (t) => OrderingTerm(expression: t.parentPath, mode: mode),
            ...nullsLastTerms,
            (t) => OrderingTerm(expression: sortColumn(t), mode: mode),
            ...tailTerms,
          ];
        }

        return [
          ...nullsLastTerms,
          (t) => OrderingTerm(expression: sortColumn(t), mode: mode),
          ...tailTerms,
        ];
      }

      OrderingTerm buildFolderFirstClause(MediaNodesTable t) {
        return OrderingTerm(expression: t.nodeKind, mode: OrderingMode.asc);
      }

      // 3. Count Total Items (Required for totalPages math).
      //
      // Window fetches that already know the source total pass
      // `countTotal: false` and skip the full filtered COUNT entirely; the
      // result then reports -1 for totalItems/totalPages (unknown).
      final int totalItems;
      if (query.countTotal) {
        final countExp = mediaNodesTable.id.count();
        final countQuery = selectOnly(mediaNodesTable)
          ..addColumns([countExp])
          ..where(buildWhereClause(mediaNodesTable));

        final countRow = await countQuery.getSingle();
        totalItems = countRow.read(countExp) ?? 0;
      } else {
        totalItems = -1;
      }

      // 4. Fetch Paginated Data
      final dataQuery = select(mediaNodesTable)
        ..where((t) => buildWhereClause(t))
        ..orderBy([
          if (query.folderFirst) (t) => buildFolderFirstClause(t),
          ...buildOrderClauses(),
        ])
        ..limit(query.pageSize, offset: query.offset);

      final rows = await dataQuery.get();
      final items = rows.map(MediaNodeDriftAdapter.fromDb).toList();

      // 5. Calculate Result Metrics (-1 stays unknown when count was skipped).
      final int totalPages;
      if (totalItems < 0) {
        totalPages = -1;
      } else {
        final pages = (totalItems / query.pageSize).ceil();
        totalPages = pages == 0 ? 1 : pages;
      }

      return MediaNodePageResult(
        items: items,
        totalItems: totalItems,
        totalPages: totalPages,
        currentPage: query.page,
        pageSize: query.pageSize,
      );
    });
  }

  /// A source-scoped paginated query (allMedia / allDirs / media search).
  ///
  /// Unlike [getPagedNodes], which is scoped to one storage/parent path, this
  /// matches every node covered by the given [sources] set. Each source
  /// (`SourcesQuerySource`):
  ///   - `storage` (path == null)  → entire storage
  ///   - `directory` + recursive   → exact path OR any prefix descendant
  ///     (includes the source root directory itself)
  ///   - `directory` + non-recursive → direct children (`parentPath = path`;
  ///     storage root path `''` → `parentPath IS NULL`, v5-D5)
  ///   - `file` (path != null) → exact path (single file)
  /// [recursive] is traversal semantics only; the `pathGroupFirst` sort is
  /// decoupled (v4-D7).
  ///
  /// Sources are OR'ed together; SQL WHERE OR yields each row at most once, so
  /// overlapping sources never produce duplicate rows.
  ///
  /// [searchQuery] (optional) further narrows with the shared token predicate
  /// (F-006); [excludeRules] (optional) attach NOT predicates per source
  /// branch (v5-D3): scenario-scoped rules apply to every branch, source-scoped
  /// rules only to the branch whose `(storageId, scenarioSourceId)` matches the
  /// rule — synthetic current-dir tuples (scenarioSourceId null) never carry
  /// source-scoped rules.
  Future<MediaNodePageResult> getPagedNodesForSources({
    required List<SourcesQuerySource> sources,
    String? searchQuery,
    List<SearchExcludeRule>? excludeRules,
    MediaNodeKind? nodeKind,
    List<MediaType>? mediaTypes,
    MediaSortField sortField = MediaSortField.name,
    SortDirection sortDirection = SortDirection.asc,
    bool folderFirst = false,
    bool pathGroupFirst = false,

    /// D2: when true (and [nodeKind] is [MediaNodeKind.directory]) only
    /// directories that contain at least one playable (video/audio) file at or
    /// below their path are returned. Implemented as a correlated EXISTS — it
    /// does not depend on the stored `totalMediaCount` aggregates being
    /// maintained, so it is correct even before any scan/browse has computed
    /// them. Defaults to false, leaving existing callers unchanged.
    bool hideEmptyDirs = false,
    required int page,
    int pageSize = 100,
  }) async {
    if (sources.isEmpty) {
      return MediaNodePageResult(
        items: const [],
        totalItems: 0,
        totalPages: 1,
        currentPage: page,
        pageSize: pageSize,
      );
    }

    return transaction(() async {
      Expression<bool> buildWhereClause(MediaNodesTable t) {
        // OR-group across sources.
        Expression<bool> sourceExpr = const Constant(false);
        for (final source in sources) {
          Expression<bool> expr =
              t.dataScopeId.equals(StorageScope.of(source.storageId));
          final path = source.path == null
              ? null
              : StoragePathCodec.relativize(
                  source.storageId, canonicalDbPath(source.path!));
          if (path == null || path.isEmpty) {
            // Storage root.
            if (source.kind == MediaSourceKind.directory &&
                !source.recursive) {
              // v5-D5: currentDirDirect at the storage root → direct children.
              expr &= _rootChildren(t);
            } else {
              // Full storage (recursive or storage-kind source).
              expr &= t.path.isNotNull();
            }
          } else if (source.kind == MediaSourceKind.directory) {
            if (source.recursive) {
              // Exact OR prefix (includes the source root dir itself).
              final escaped = escapeLike(path);
              expr &=
                  (t.path.equals(path) | t.path.like('$escaped/%', escapeChar: r'\'));
            } else {
              // Non-recursive directory → direct children only (C3).
              expr &= t.parentPath.equals(path);
            }
          } else {
            // file source → exact path (single file).
            expr &= t.path.equals(path);
          }
          // v5-D3: per-source exclude rules (NOT-ANDed into the branch).
          for (final rule in excludeRules ?? const <SearchExcludeRule>[]) {
            final applies = rule.scope == ExcludeScope.scenario ||
                (source.scenarioSourceId != null &&
                    rule.storageId == source.storageId &&
                    source.scenarioSourceId == rule.sourceId);
            if (applies) {
              expr &= excludeNotPredicate(t, rule);
            }
          }
          sourceExpr |= expr;
        }

        Expression<bool> predicate = sourceExpr;
        if (searchQuery != null && searchQuery.isNotEmpty) {
          predicate &= buildSearchPredicate(t, searchQuery);
        }
        if (nodeKind != null) {
          predicate &= t.nodeKind.equals(nodeKind.name);
        }
        // Browse-scope visibility for DIRECTORIES: a row-level mediaType IN
        // filter would drop every dir row (their mediaType is null), so the
        // scope is expressed as a scoped playable-descendant EXISTS instead.
        final bool dirScopeVisible = nodeKind == MediaNodeKind.directory &&
            mediaTypes != null &&
            mediaTypes.isNotEmpty;
        if (mediaTypes != null && mediaTypes.isNotEmpty && !dirScopeVisible) {
          predicate &=
              t.mediaType.isIn(mediaTypes.map((e) => e.name).toList());
        }
        if (dirScopeVisible) {
          predicate &= _hasPlayableDescendant(t, types: mediaTypes!);
        } else if (hideEmptyDirs && nodeKind == MediaNodeKind.directory) {
          predicate &= _hasPlayableDescendant(t);
        }
        return predicate;
      }

      // Sort column mapping (mirrors getPagedNodes).
      Expression<Object> sortColumn(MediaNodesTable t) {
        switch (sortField) {
          case MediaSortField.name:
            return t.normalizedName;
          case MediaSortField.path:
            return t.path;
          case MediaSortField.modifiedAt:
            return t.modifiedAt;
          case MediaSortField.createdAt:
            return t.createdAt;
          case MediaSortField.sizeInBytes:
            return t.sizeInBytes;
          case MediaSortField.durationMs:
            return t.durationMs;
          case MediaSortField.totalSizeInBytes:
            return t.totalSizeInBytes;
          case MediaSortField.totalDurationMs:
            return t.totalDurationMs;
          default:
            return t.normalizedName;
        }
      }

      List<OrderingTerm Function(MediaNodesTable)> buildOrderClauses() {
        final mode = sortDirection == SortDirection.asc
            ? OrderingMode.asc
            : OrderingMode.desc;

        // Mirrors getPagedNodes: NULLs last, plus a deterministic name/path tail
        // so equal keys (and NULL buckets) keep a stable, page-safe order.
        final nullsLastTerms = _nullsLastTerms(sortField, sortColumn);
        final tailTerms = _orderTailTerms(sortField);

        if (pathGroupFirst) {
          return [
            (t) => OrderingTerm(expression: t.parentPath, mode: mode),
            ...nullsLastTerms,
            (t) => OrderingTerm(expression: sortColumn(t), mode: mode),
            ...tailTerms,
          ];
        }

        return [
          ...nullsLastTerms,
          (t) => OrderingTerm(expression: sortColumn(t), mode: mode),
          ...tailTerms,
        ];
      }

      final countExp = mediaNodesTable.id.count();
      final countQuery = selectOnly(mediaNodesTable)
        ..addColumns([countExp])
        ..where(buildWhereClause(mediaNodesTable));
      final countRow = await countQuery.getSingle();
      final totalItems = countRow.read(countExp) ?? 0;

      final dataQuery = select(mediaNodesTable)
        ..where((t) => buildWhereClause(t))
        ..orderBy([
          if (folderFirst)
            (t) => OrderingTerm(
                expression: t.nodeKind, mode: OrderingMode.asc),
          ...buildOrderClauses(),
        ])
        ..limit(pageSize, offset: (page - 1) * pageSize);

      final rows = await dataQuery.get();
      final items = rows.map(MediaNodeDriftAdapter.fromDb).toList();

      final totalPages = (totalItems / pageSize).ceil();

      return MediaNodePageResult(
        items: items,
        totalItems: totalItems,
        totalPages: totalPages == 0 ? 1 : totalPages,
        currentPage: page,
        pageSize: pageSize,
      );
    });
  }

  /// D2: correlated `EXISTS` — a directory row is non-empty when a playable
  /// (video/audio) file node lives at or below its path (recursive).
  ///
  /// The inner subquery selects from a self-alias (`f`) so its columns are
  /// unambiguous against the outer `media_nodes` reference; the outer [outer]
  /// column expressions are written table-qualified by drift because the
  /// subquery sets the multi-table context.
  ///
  /// [types] narrows which descendant media types count as "playable". The
  /// default keeps the legacy video+audio semantics (aggregate parity);
  /// browse-scope queries pass their narrowed list so directories whose
  /// subtree only holds out-of-scope files become invisible.
  Expression<bool> _hasPlayableDescendant(
    MediaNodesTable outer, {
    List<MediaType> types = const [MediaType.video, MediaType.audio],
  }) {
    final f = alias(mediaNodesTable, 'f');
    final sub = selectOnly(f)
      ..addColumns([const Constant<int>(1)])
      ..where(
        f.nodeKind.equals(MediaNodeKind.file.name) &
        f.mediaType.isIn(types.map((e) => e.name).toList()) &
        (f.path.equalsExp(outer.path) |
            f.path.likeExp(outer.path + const Constant('/%'))),
      );
    return existsQuery(sub);
  }

  // --- Search helpers (media search feature, F-005/F-006/F-007) ---

  /// Shared token predicate: every whitespace-split token must match
  /// `normalizedName` as a case-insensitive substring; `%`/`_` are treated as
  /// literals via `ESCAPE '\'` (F-006). An empty/whitespace-only query yields
  /// `Constant(true)` (callers already skip empty queries, but this keeps the
  /// helper total).
  Expression<bool> buildSearchPredicate(MediaNodesTable t, String raw) {
    final tokens = tokenizeQuery(raw);
    if (tokens.isEmpty) return const Constant(true);
    Expression<bool> like(String tok) => t.normalizedName.like(
          '%${escapeLike(tok.toLowerCase())}%',
          escapeChar: r'\',
        );
    return tokens.skip(1).fold(like(tokens.first), (p, tok) => p & like(tok));
  }

  /// NOT predicate of one exclude rule on one source branch (v5-D3, §5.1.3):
  /// the branch keeps a row only when it does not match the rule.
  ///
  /// - media rule → `path != r`
  /// - directory recursive → `NOT (path = r OR path LIKE 'r/%')` (whole subtree)
  /// - directory non-recursive → `NOT (parentPath = r)` (direct children;
  ///   `r == ''` → `NOT (parentPath IS NULL)`)
  Expression<bool> excludeNotPredicate(
      MediaNodesTable t, SearchExcludeRule rule) {
    final canonical = StoragePathCodec.relativize(rule.storageId, canonicalDbPath(rule.path));
    if (rule.kind == ExcludeRuleKind.media) {
      return t.path.equals(canonical).not();
    }
    // directory rule
    if (rule.recursive) {
      if (canonical.isEmpty) return const Constant(false);
      return (t.path.equals(canonical) |
              t.path.like('${escapeLike(canonical)}/%', escapeChar: r'\'))
          .not();
    }
    if (canonical.isEmpty) {
      return _rootParent(t).not();
    }
    return t.parentPath.equals(canonical).not();
  }

  /// Lightweight existence check of explicit items (F-007 / v4-D2): returns the
  /// canonical paths among [paths] that already have a `file` row in
  /// [storageId]. Used to decide whether an in-scope explicit item is covered
  /// by the DB segment (no synthesis) or must be synthesized.
  Future<Set<String>> getExistingFilePaths({
    required String storageId,
    required List<String> paths,
  }) async {
    if (paths.isEmpty) return const {};
    final canonical = paths
        .map((p) => StoragePathCodec.relativize(storageId, canonicalDbPath(p)))
        .toList();
    const chunkSize = 900;
    final out = <String>{};
    for (var i = 0; i < canonical.length; i += chunkSize) {
      final chunk = canonical.sublist(
        i,
        i + chunkSize > canonical.length ? canonical.length : i + chunkSize,
      );
      final query = select(mediaNodesTable)
        ..where((t) =>
            t.dataScopeId.equals(StorageScope.of(storageId)) &
            t.nodeKind.equals(MediaNodeKind.file.name) &
            t.path.isIn(chunk));
      final rows = await query.get();
      out.addAll(rows.map(
          (r) => StoragePathCodec.absolutize(storageId, canonicalDbPath(r.path))));
    }
    return out;
  }

  /// FILE rows under [pathPrefix] in [storageId] — recursive (all
  /// descendants) and inclusive of the exact path itself. Used by 副音
  /// path/pathAndTag candidate rules. No media-type narrowing here; callers
  /// map rows and filter (video/audio) themselves.
  Future<List<MediaNodesTableData>> mediaRowsUnderPrefix({
    required String storageId,
    required String pathPrefix,
    int limit = 400,
  }) async {
    final canonical = StoragePathCodec.relativize(storageId, canonicalDbPath(pathPrefix));
    final escaped = escapeLike(canonical);
    return (select(mediaNodesTable)
          ..where((t) =>
              t.dataScopeId.equals(StorageScope.of(storageId)) &
              t.nodeKind.equals(MediaNodeKind.file.name) &
              (t.path.equals(canonical) |
                  t.path.like('$escaped/%', escapeChar: r'\')))
          ..limit(limit))
        .get();
  }
}

/*
@DriftAccessor(tables: [MediaNodesTable])
class MediaNodesDao extends DatabaseAccessor<AppDatabase> with _$MediaNodesDaoMixin {
  MediaNodesDao(super.db);

  Future<void> upsert(MediaNodesTableCompanion entry) {
    return into(mediaNodesTable).insertOnConflictUpdate(entry);
  }

  Future<void> batchUpsert(List<MediaNodesTableCompanion> entries) async {
    await batch((b) {
      b.insertAllOnConflictUpdate(mediaNodesTable, entries);
    });
  }

  /// Get single node by storage + path
  Future<MediaNodesTableData?> getByPath({
    required String storageId,
    required String path,
  }) {
    return (select(mediaNodesTable)
          ..where(
            (t) => t.dataScopeId.equals(StorageScope.of(storageId)) & t.path.equals(path),
          ))
        .getSingleOrNull();
  }

  /// Delete all nodes from one storage
  Future<void> deleteByStorage(String storageId) {
    return (delete(mediaNodesTable)..where((t) => t.dataScopeId.equals(StorageScope.of(storageId)))).go();
  }

  /// Directory listing (tree view)
  Future<List<MediaNodesTableData>> listByParent({
    required String storageId,
    required String? parentPath,
    int limit = 100,
    int offset = 0,
    MediaSortField sort = MediaSortField.name,
    SortDirection order = SortDirection.asc,
  }) {
    final query = select(mediaNodesTable);

    query.where((t) {
      final storageExpr = t.dataScopeId.equals(StorageScope.of(storageId));

      final parentExpr =
          (parentPath == null || parentPath.isEmpty)
              ? _rootChildren(t)
              : t.parentPath.equals(parentPath);

      return storageExpr & parentExpr;
    });

    _applySort(query, sort, order);

    query.limit(limit, offset: offset);

    return query.get();
  }

  /// All media (for library page)
  Future<List<MediaNodesTableData>> listAllMedia({
    int limit = 100,
    int offset = 0,
    MediaSortField sort = MediaSortField.name,
    SortDirection order = SortDirection.asc,
  }) {
    final query = select(mediaNodesTable)..where((t) => t.isDir.equals(false));

    _applySort(query, sort, order);

    query.limit(limit, offset: offset);

    return query.get();
  }

  /// All directories
  Future<List<MediaNodesTableData>> listAllDirs({
    int limit = 100,
    int offset = 0,
  }) {
    final query = select(mediaNodesTable)
      ..where((t) => t.isDir.equals(true))
      ..limit(limit, offset: offset);

    return query.get();
  }

  /// Search (name-based)
  Future<List<MediaNodesTableData>> searchByName({
    required String keyword,
    int limit = 100,
    int offset = 0,
  }) {
    final query = select(mediaNodesTable)
      ..where((t) => t.name.like('%$keyword%'))
      ..limit(limit, offset: offset);

    return query.get();
  }

  /// Sync helpers
  Future<void> markAllNotExists(String storageId, String parentPath) {
    return (update(mediaNodesTable)
          ..where((t) => t.dataScopeId.equals(StorageScope.of(storageId)) & t.parentPath.equals(parentPath)))
        .write(MediaNodesTableCompanion(
      exists: const Value(false),
    ));
  }

  Future<void> deleteNotExists(String storageId) {
    return (delete(mediaNodesTable)
          ..where((t) => t.dataScopeId.equals(StorageScope.of(storageId)) & t.exists.equals(false)))
        .go();
  }

  /// Internal sort helper
  void _applySort(
    SimpleSelectStatement<$MediaNodesTableTable, MediaNodesTableData> query,
    MediaSortField sort,
    SortDirection order,
  ) {
    final ordering = order == SortDirection.asc ? OrderingMode.asc : OrderingMode.desc;

    switch (sort) {
      case MediaSortField.name:
        query.orderBy([(t) => OrderingTerm(expression: t.name, mode: ordering)]);
        break;
      case MediaSortField.size:
        query.orderBy([(t) => OrderingTerm(expression: t.size, mode: ordering)]);
        break;
      case MediaSortField.modified:
        query.orderBy([(t) => OrderingTerm(expression: t.modifiedAt, mode: ordering)]);
        break;
    }
  }
}
*/
