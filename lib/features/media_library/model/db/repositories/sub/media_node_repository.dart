import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_query.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_result.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/progress_write_guard.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/search/model/search_context.dart';
import 'package:iris/features/media_library/search/model/search_exclude_rule.dart';
import 'package:iris/models/db/app_database.dart' show MediaNodesTableData;
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

class MediaNodeRepository {
  final MediaNodesDao _nodesDao;

  MediaNodeRepository(this._nodesDao);

  /// 1. Path Tree View (Directory Browsing)
  /// Gets the seamless contents of a specific directory or source root.
  ///
  /// [mediaTypes] narrows FILE rows to the given types; when the listing is
  /// directory-only it instead scopes VISIBILITY (see DAO dirScopeVisible).
  /// Null keeps the unscoped legacy behavior.
  ///
  /// [hideEmptyDirs] hides directory rows without a playable descendant
  /// (pathTree "only dirs with media"); file rows are unaffected. Only adds
  /// filtering to the unscoped path — scoped queries already hide
  /// out-of-scope directories.
  Future<MediaNodePageResult> getDirectoryChildren({
    required String storageId,
    String? parentPath,
    required int page,
    int pageSize = 100,
    MediaSortField sortField = MediaSortField.name,
    SortDirection sortDirection = SortDirection.asc,
    bool folderFirst = false,
    List<MediaType>? mediaTypes,
    bool hideEmptyDirs = false,
  }) {
    final query = MediaNodePageQuery(
      page: page,
      pageSize: pageSize,
      storageId: storageId,
      parentPath: parentPath,
      sortField: sortField,
      sortDirection: sortDirection,
      folderFirst: folderFirst,
      mediaTypes: mediaTypes,
      hideEmptyDirs: hideEmptyDirs,
    );
    return _nodesDao.getPagedNodes(query);
  }

  /// 2. All Media View
  /// Fetches only files (no directories), optionally filtered by video/audio.
  /// [mediaTypes] further narrows the file rows (browse-scope projection).
  Future<MediaNodePageResult> getAllMedia({
    required int page,
    int pageSize = 100,
    MediaType? mediaType,
    List<MediaType>? mediaTypes,
    MediaSortField sortField = MediaSortField.modifiedAt,
    SortDirection sortDirection = SortDirection.desc,
    bool folderFirst = false,
  }) {
    final query = MediaNodePageQuery(
      page: page,
      pageSize: pageSize,
      nodeKind: MediaNodeKind.file,
      mediaType: mediaType,
      mediaTypes: mediaTypes,
      sortField: sortField,
      sortDirection: sortDirection,
      folderFirst: folderFirst,
    );
    return _nodesDao.getPagedNodes(query);
  }

  /// 3. All Directories View
  /// Same as All Media, but strictly filters for directories.
  Future<MediaNodePageResult> getAllDirectories({
    required int page,
    int pageSize = 100,
    MediaSortField sortField = MediaSortField.name,
    SortDirection sortDirection = SortDirection.asc,
    bool folderFirst = false,
  }) {
    final query = MediaNodePageQuery(
      page: page,
      pageSize: pageSize,
      nodeKind: MediaNodeKind.directory,
      sortField: sortField,
      sortDirection: sortDirection,
      folderFirst: folderFirst,
    );
    return _nodesDao.getPagedNodes(query);
  }

  /// 4. Search Results List
  /// Global search across all indexed nodes based on text query.
  Future<MediaNodePageResult> searchNodes({
    required String searchQuery,
    required int page,
    int pageSize = 50,
    MediaNodeKind? nodeKind,
  }) {
    final query = MediaNodePageQuery(
      page: page,
      pageSize: pageSize,
      searchQuery: searchQuery,
      nodeKind: nodeKind, // Can optionally restrict search to files or dirs
      // Usually search results are best sorted by name or match relevance
      sortField: MediaSortField.name,
      sortDirection: SortDirection.asc,
    );
    return _nodesDao.getPagedNodes(query);
  }

  /// Fetches a single file/dir node by its exact storage location.
  ///
  /// Canonical lookup with a legacy raw fallback (canonical first, then the
  /// caller's raw form) so rows stored with a leading slash before the DB
  /// normalization landed remain reachable.
  Future<MediaNode?> getNodeByPath({
    required String storageId,
    required List<String> path,
  }) async {
    // final row = await _nodesDao.getByPath(storageId, path.join('/'));  // legacy
    final row = await _nodesDao.getByPathCanonical(
        storageId, path.join('/')); // unified
    return row == null ? null : MediaNodeDriftAdapter.fromDb(row);
  }

  /// Bulk fetch nodes by primary-key id (derived queue-index read path).
  /// Returns them keyed by numeric id; missing ids are simply absent.
  Future<Map<int, MediaNode>> nodesByIds(Iterable<int> ids) =>
      _nodesDao.nodesByIds(ids);

  /// Resolves existing FILE nodes for canonical media keys (`storageId:path`,
  /// the same shape as `canonicalKey` / tag members).
  ///
  /// Vanished or directory rows are simply absent from the result — callers
  /// (background candidate sources, …) must silently skip missing files, so
  /// nothing here throws for a deleted/moved media. Lookups run per storage,
  /// bounded by [concurrency], each an indexed canonical-path probe.
  Future<List<MediaNode>> nodesByMediaKeys(
    Set<String> keys, {
    int concurrency = 16,
  }) async {
    if (keys.isEmpty) return const [];
    final byStorage = <String, List<String>>{};
    for (final key in keys) {
      final idx = key.indexOf(':');
      if (idx <= 0) continue;
      byStorage
          .putIfAbsent(key.substring(0, idx), () => [])
          .add(canonicalDbPath(key.substring(idx + 1)));
    }
    final batches = await Future.wait([
      for (final entry in byStorage.entries)
        _nodesInStorage(entry.key, entry.value, concurrency),
    ]);
    return [
      for (final batch in batches) ...batch,
    ];
  }

  /// Resolves existing FILE nodes by their persisted SAF document [uri].
  ///
  /// A SAF single-picked file has an EMPTY path, so the document uri is the
  /// only identity that can round-trip it (see [MediaNode.occurrencePath]).
  /// Vanished rows are simply absent.
  Future<List<MediaNode>> nodesByUris(Set<String> uris) async {
    if (uris.isEmpty) return const [];
    final rows = await _nodesDao.getByUris(uris);
    return rows
        .map(MediaNodeDriftAdapter.fromDb)
        .where((n) => n.maybeMap(file: (_) => true, orElse: () => false))
        .toList(growable: false);
  }

  /// Resolves existing FILE nodes for canonical media keys, ALSO matching SAF
  /// single-picked rows through their persisted document `uri`.
  ///
  /// [nodesByMediaKeys] addresses rows via the DB `path` column, but a SAF
  /// single-picked file stores an EMPTY path and carries its identity in `uri`
  /// ([MediaNode.occurrencePath] returns the document uri for it). A path-keyed
  /// lookup can therefore never see it. [alsoByUris] carries those document
  /// uris (from the live files) and is resolved through [nodesByUris]; the
  /// union is returned, de-duplicated by node identity. Vanished rows stay
  /// absent — callers silently skip them, exactly as before.
  Future<List<MediaNode>> nodesByMediaKeysOrUris(
    Set<String> keys, {
    Iterable<String> alsoByUris = const [],
    int concurrency = 16,
  }) async {
    final pathNodes = await nodesByMediaKeys(keys, concurrency: concurrency);
    final uris = <String>{for (final u in alsoByUris) if (u.isNotEmpty) u};
    if (uris.isEmpty) return pathNodes;
    final uriNodes = await nodesByUris(uris);
    if (uriNodes.isEmpty) return pathNodes;
    final seen = <String>{for (final n in pathNodes) n.id};
    return <MediaNode>[
      ...pathNodes,
      for (final n in uriNodes)
        if (seen.add(n.id)) n,
    ];
  }

  Future<List<MediaNode>> _nodesInStorage(
    String storageId,
    List<String> paths,
    int concurrency,
  ) async {
    final rows = <MediaNodesTableData>[];
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= paths.length) return;
        final row = await _nodesDao.getByPathCanonical(storageId, paths[index]);
        if (row != null) rows.add(row);
      }
    }

    final workers = List.generate(
      concurrency.clamp(1, 64),
      (_) => worker(),
    );
    await Future.wait(workers);
    return rows
        .map(MediaNodeDriftAdapter.fromDb)
        .where((n) => n.maybeMap(file: (_) => true, orElse: () => false))
        .toList(growable: false);
  }

  /// Per-file playback progress for the given canonical media keys
  /// (`storageId:path`). Missing/vanished files are absent from the result.
  ///
  /// Backs the virtual-media resume rule: a group's watched file is chosen by
  /// the newest `lastPlayedAt` across its segments.
  Future<
      Map<
          String,
          ({
            int? positionMs,
            bool completed,
            DateTime? lastPlayedAt,
          })>> progressForMediaKeys(
    Set<String> keys, {
    int concurrency = 16,
  }) async {
    if (keys.isEmpty) return const {};
    final nodes = await nodesByMediaKeys(keys, concurrency: concurrency);
    final out = <String,
        ({
      int? positionMs,
      bool completed,
      DateTime? lastPlayedAt,
    })>{};
    for (final node in nodes) {
      final file = node.maybeMap(file: (f) => f, orElse: () => null);
      if (file == null) continue;
      out[canonicalKey(file.storageId, file.path.join('/'))] = (
        positionMs: file.playbackPositionMs,
        completed: file.playbackCompleted,
        lastPlayedAt: file.lastPlayedAt,
      );
    }
    return out;
  }

  // --- Utility Methods ---

  Future<void> updateNode(MediaNode node) {
    return _nodesDao.upsertNode(node);
  }

  /// Upserts many file nodes in chunked batches (500/块).
  ///
  /// Used by the desktop drag-and-drop path, which indexes a whole dropped
  /// batch at once instead of one round trip per file. Chunked upsert keeps a
  /// single poisoned node from failing the rest: a chunk that throws falls back
  /// to per-node writes, mirroring [updateNode] semantics.
  Future<void> batchUpsertNodes(List<MediaNode> nodes) async {
    if (nodes.isEmpty) return;
    const chunkSize = 500;
    for (var i = 0; i < nodes.length; i += chunkSize) {
      final end = (i + chunkSize) > nodes.length ? nodes.length : i + chunkSize;
      final chunk = nodes.sublist(i, end);
      try {
        await _nodesDao.batchUpsert([for (final n in chunk) n.toCompanion()]);
      } catch (_) {
        // One bad row must not drop the whole batch; retry individually.
        for (final node in chunk) {
          try {
            await _nodesDao.upsertNode(node);
          } catch (_) {
            // Best-effort: a failed index still lets playback surface the
            // real open error later.
          }
        }
      }
    }
  }

  /// Writes the duration for a file node and recomputes ancestor aggregates.
  Future<void> updateFileDuration({
    required String storageId,
    required String path,
    required int durationMs,
  }) async {
    await _nodesDao.updateFileDuration(storageId, path, durationMs);
    await _nodesDao.recomputeDurationAncestors(storageId, path);
  }

  /// Writes deep-probe media info for a file node.
  ///
  /// When [durationMs] is provided, ancestor duration aggregates are
  /// repaired exactly like [updateFileDuration]; dimension fields are
  /// written as-is.
  ///
  /// Returns the number of rows written (`0` = no matching media_nodes row),
  /// so scan/harvest write-back can distinguish a real write from a no-op.
  Future<int> updateFileMediaInfo({
    required String storageId,
    required String path,
    int? durationMs,
    String? uri,
    int? width,
    int? height,
    int? pixelCount,
  }) async {
    final rows = await _nodesDao.updateFileMediaInfo(
      storageId: storageId,
      path: path,
      durationMs: durationMs,
      uri: uri,
      width: width,
      height: height,
      pixelCount: pixelCount,
    );
    if (durationMs != null) {
      await _nodesDao.recomputeDurationAncestors(storageId, path);
    }
    return rows;
  }

  /// Global per-file playback progress (uniform across all scenarios).
  ///
  /// Null parameters leave the corresponding column unchanged.
  /// [historyRestoreBudgetMs] null keeps the stored budget untouched.
  ///
  /// This is the SINGLE write funnel for playback progress: every caller
  /// (player hooks, VM controller, scenario stop, budget spend) goes through
  /// here. A [ProgressWriteIntent.live] write that looks like a pre-seek head
  /// sample over a large stored progress is dropped at the funnel so no
  /// caller can clobber the stored progress (the 第8次 log root cause);
  /// explicit intents ([explicitClear]/[targeted]/[userSeek]) land verbatim.
  /// [writeTag] names the call site in the attribution log.
  Future<void> updatePlaybackProgress({
    required String storageId,
    required String path,
    int? positionMs,
    bool? completed,
    DateTime? lastPlayedAt,
    int? playCount,
    int? historyRestoreBudgetMs,
    ProgressWriteIntent intent = ProgressWriteIntent.live,
    String? writeTag,
  }) async {
    // CLOSE_DEBUG_LOG: progress-lose attribution — every write logs
    // old→new with the caller tag so the next repro log is conclusive.
    const funnelDiag = AreaKeyLog(LogKeys.player);
    final canonical = canonicalDbPath(path);
    var row = await _nodesDao.getByPath(storageId, canonical);
    row ??=
        canonical == path ? null : await _nodesDao.getByPath(storageId, path);
    final tag = writeTag ?? 'unknown';
    if (row == null) {
      funnelDiag.w('progress-write [$tag] DROP (no row) $storageId:$path '
          'pos=$positionMs completed=$completed budget=$historyRestoreBudgetMs');
      return;
    }
    final node = MediaNodeDriftAdapter.fromDb(row);
    final existingPos =
        node.maybeMap(file: (f) => f.playbackPositionMs, orElse: () => null);
    final existingDur =
        node.maybeMap(file: (f) => f.durationMs, orElse: () => null);
    final blocked = shouldBlockFunnelWrite(
      existingPosMs: existingPos,
      incomingPosMs: positionMs,
      durationMs: existingDur,
      completed: completed,
      intent: intent,
    );
    funnelDiag.i('progress-write [$tag] '
        '${existingPos ?? "null"}->${positionMs ?? "keep"} '
        'completed=$completed budget=$historyRestoreBudgetMs '
        'intent=${intent.name}${blocked ? " BLOCKED" : ""} '
        '$storageId:$path');
    if (blocked) return;
    return _nodesDao.updatePlaybackProgress(
      storageId: storageId,
      path: path,
      positionMs: positionMs,
      completed: completed,
      lastPlayedAt: lastPlayedAt,
      playCount: playCount,
      historyRestoreBudgetMs: historyRestoreBudgetMs,
    );
  }

  /// Returns {MediaType: count} for all files under [parentPath] in [storageId].
  /// [mediaTypes] optionally narrows the counted rows (browse-scope projection).
  Future<Map<MediaType, int>> countMediaByType({
    required String storageId,
    String? parentPath,
    List<MediaType>? mediaTypes,
  }) {
    return _nodesDao.countByMediaTypeUnderPath(
      storageId,
      parentPath ?? '',
      mediaTypes: mediaTypes,
    );
  }

  /// Scoped per-directory aggregates for the browse-scope display override
  /// (see MediaNodesDao.aggregateByMediaTypes).
  Future<Map<String, ({int mediaCount, int sizeBytes, int durationMs})>>
      aggregateByMediaTypes({
    required String storageId,
    required List<String> paths,
    required List<MediaType> mediaTypes,
  }) {
    return _nodesDao.aggregateByMediaTypes(
      storageId: storageId,
      paths: paths,
      mediaTypes: mediaTypes,
    );
  }

  // --- D2a: aggregate recomputation (mirrors RecursiveScanService) ---

  /// Recomputes the aggregate columns of the directory node at [dirPath] from
  /// its direct children (same math as `RecursiveScanService._computeDirAggregates`).
  /// Media counts include only video/audio rows (unknown excluded), matching
  /// the empty-directory definition used by the allDirs hide-empty filter.
  /// A no-op when no directory node exists at [dirPath].
  Future<void> recomputeDirAggregates({
    required String storageId,
    required String dirPath,
  }) async {
    final children = await _nodesDao.getDirectChildren(storageId, dirPath);

    int directDirCount = 0;
    int directMediaCount = 0;
    int directItemCount = children.length;
    int totalDirCount = 0;
    int totalMediaCount = 0;
    int totalItemCount = children.length;
    int totalSizeInBytes = 0;
    int totalDurationMs = 0;

    for (final child in children) {
      if (child.nodeKind == MediaNodeKind.directory) {
        directDirCount++;
        totalDirCount += 1 + child.totalDirCount;
        totalMediaCount += child.totalMediaCount;
        totalItemCount += child.totalItemCount;
        totalSizeInBytes += child.totalSizeInBytes;
        totalDurationMs += child.totalDurationMs;
      } else {
        if (child.mediaType != null && child.mediaType != MediaType.unknown) {
          directMediaCount++;
          totalMediaCount++;
        }
        totalSizeInBytes += child.sizeInBytes ?? 0;
        totalDurationMs += child.durationMs ?? 0;
      }
    }

    await _nodesDao.updateAggregates(
      storageId: storageId,
      path: dirPath,
      directMediaCount: directMediaCount,
      directDirCount: directDirCount,
      directItemCount: directItemCount,
      totalMediaCount: totalMediaCount,
      totalDirCount: totalDirCount,
      totalItemCount: totalItemCount,
      totalSizeInBytes: totalSizeInBytes,
      totalDurationMs: totalDurationMs,
    );
  }

  /// Walks up from [startPath] recomputing aggregates for each existing
  /// ancestor directory until the storage root (parentPath == null) or a
  /// missing node is reached. Non-existent nodes are skipped — an UPDATE on
  /// them affects 0 rows — so partial trees converge as they are browsed.
  ///
  /// [startPath] may carry a leading slash (the files-paged browser paths on
  /// Android start with `/storage/...`); lookups go through
  /// [MediaNodesDao.getByPathCanonical] so they match the canonical rows.
  Future<void> recomputeDirAncestors({
    required String storageId,
    required String startPath,
  }) async {
    String? currentPath = canonicalDbPath(startPath);
    final visited = <String>{};
    while (currentPath != null && currentPath.isNotEmpty) {
      if (!visited.add(currentPath)) break;
      final node = await _nodesDao.getByPathCanonical(storageId, currentPath);
      if (node == null) break;
      await recomputeDirAggregates(
        storageId: storageId,
        dirPath: currentPath,
      );
      currentPath = node.parentPath;
    }
  }

  /// Ensures a directory node exists at [dirPath].
  ///
  /// The files-paged sync (`_syncDbWithFilesystem`) only creates a browsed
  /// directory's *children*; the browsed directory's own node exists only if
  /// its parent was previously browsed or it was scanned. Creating it here
  /// (when missing or kind-mismatched) guarantees the D2a aggregate recompute
  /// has a row to write to.
  Future<void> ensureDirNode({
    required String storageId,
    required String dirPath,
  }) async {
    final canonicalPath = canonicalDbPath(dirPath);
    if (canonicalPath.isEmpty) return;
    final existing =
        await _nodesDao.getByPathCanonical(storageId, canonicalPath);
    if (existing != null && existing.nodeKind == MediaNodeKind.directory) {
      return;
    }
    // pathConv keeps a SAF `content://` tree prefix as one segment (a raw
    // split would turn the scheme into bogus `content:`/authority rows).
    final segments = pathConv(canonicalPath);
    if (segments.isEmpty) return;
    await _nodesDao.batchUpsert([
      MediaNode.directory(
        id: '$storageId:$canonicalPath',
        storageId: storageId,
        path: segments,
        parentPath: segments.length == 1
            ? null
            : segments.sublist(0, segments.length - 1).join('/'),
        pathDepth: segments.length,
        name: segments.last,
      ).toCompanion(),
    ]);
  }

  /// Idempotent legacy-path repair for [storageId]: rewrites pre-canonicalization
  /// rows (stored `path`/`parentPath` with a leading slash, e.g. `//storage/...`)
  /// to their canonical form and dedupes rows that collide on the canonical
  /// path. This makes legacy rows visible to the canonical queries (pathTree /
  /// allDirs / L2) and removes duplicate directory tiles in allDirs L1.
  ///
  /// When a canonical row already exists for a legacy path, the legacy row is
  /// dropped; otherwise one survivor is rewritten to the canonical form.
  Future<void> repairLegacyPaths(String storageId) async {
    final rows = await _nodesDao.getLegacySlashRows(storageId);
    if (rows.isEmpty) return;

    final groups = <String, List<MediaNodesTableData>>{};
    for (final row in rows) {
      final canonical = canonicalDbPath(row.path);
      groups.putIfAbsent(canonical, () => []).add(row);
    }

    for (final group in groups.values) {
      final canonicalPath = canonicalDbPath(group.first.path);

      final existingCanonical =
          await _nodesDao.getByPath(storageId, canonicalPath);
      if (existingCanonical != null) {
        // Canonical row already present → drop every legacy duplicate.
        for (final row in group) {
          await _nodesDao.deleteNodeByRawPath(storageId, row.path);
        }
        continue;
      }

      // Otherwise keep one survivor (prefer the already-canonical row) and
      // rewrite it to the canonical form.
      MediaNodesTableData? keep;
      for (final row in group) {
        final rowIsCanonical = row.path == canonicalDbPath(row.path);
        final keepIsCanonical =
            keep != null && keep.path == canonicalDbPath(keep.path);
        if (keep == null || (rowIsCanonical && !keepIsCanonical)) {
          keep = row;
        }
      }
      if (keep == null) continue;

      for (final row in group) {
        if (row.id != keep.id) {
          await _nodesDao.deleteNodeByRawPath(storageId, row.path);
        }
      }

      if (keep.path != canonicalPath ||
          keep.parentPath != canonicalDbPathOrNull(keep.parentPath)) {
        await _nodesDao.updatePathAndParent(
          storageId,
          keep.path,
          canonicalPath,
          canonicalDbPathOrNull(keep.parentPath),
        );
      }
    }
  }

  /// Generic paginated query with full filtering support.
  Future<MediaNodePageResult> getPagedNodes(MediaNodePageQuery query) {
    return _nodesDao.getPagedNodes(query);
  }

  /// Paginated query scoped to a set of library sources (allMedia / allDirs).
  ///
  /// Each source contributes its own match rule (storage = full storage,
  /// directory = exact-or-prefix, file = exact path); sources are OR'ed and
  /// overlapping coverage never duplicates rows. See
  /// [MediaNodesDao.getPagedNodesForSources].
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
    bool hideEmptyDirs = false,
    required int page,
    int pageSize = 100,
  }) {
    return _nodesDao.getPagedNodesForSources(
      sources: sources,
      searchQuery: searchQuery,
      excludeRules: excludeRules,
      nodeKind: nodeKind,
      mediaTypes: mediaTypes,
      sortField: sortField,
      sortDirection: sortDirection,
      folderFirst: folderFirst,
      pathGroupFirst: pathGroupFirst,
      hideEmptyDirs: hideEmptyDirs,
      page: page,
      pageSize: pageSize,
    );
  }

  /// Media-search scoped query over [SearchSource]s (F-005/F-007, §5.2.1).
  ///
  /// Files-only by default (C1); always passes `pathGroupFirst: true` so the DB
  /// segment is globally grouped by parent directory (F-008), and forwards
  /// [excludeRules] so count and data queries both honor them (v5-D3).
  Future<MediaNodePageResult> searchNodesForSources({
    required List<SearchSource> sources,
    required String searchQuery,
    List<SearchExcludeRule>? excludeRules,
    MediaNodeKind nodeKind = MediaNodeKind.file,
    List<MediaType>? mediaTypes,
    MediaSortField sortField = MediaSortField.name,
    SortDirection sortDirection = SortDirection.asc,
    bool folderFirst = false,
    required int page,
    int pageSize = 100,
  }) {
    return _nodesDao.getPagedNodesForSources(
      sources: [
        for (final s in sources)
          (
            storageId: s.storageId,
            path: s.path,
            kind: s.kind,
            recursive: s.recursive,
            scenarioSourceId: s.scenarioSourceId,
          ),
      ],
      searchQuery: searchQuery,
      excludeRules: excludeRules,
      nodeKind: nodeKind,
      mediaTypes: mediaTypes,
      sortField: sortField,
      sortDirection: sortDirection,
      folderFirst: folderFirst,
      pathGroupFirst: true,
      page: page,
      pageSize: pageSize,
    );
  }

  /// Existence probe of explicit-item paths (F-007 / v4-D2).
  Future<Set<String>> getExistingFilePaths({
    required String storageId,
    required List<String> paths,
  }) {
    return _nodesDao.getExistingFilePaths(storageId: storageId, paths: paths);
  }

  /// Scanned real media FILES (video/audio) under [path] (recursive, inclusive
  /// of the exact path itself) for [storageId]. Used by background-playback
  /// path/pathAndTag candidate rules; vanished rows are silently absent.
  Future<List<MediaNode>> mediaFilesUnderPath({
    required String storageId,
    required String path,
    int limit = 400,
  }) async {
    final rows = await _nodesDao.mediaRowsUnderPrefix(
      storageId: storageId,
      pathPrefix: path,
      limit: limit,
    );
    final out = <MediaNode>[];
    for (final row in rows) {
      final node = MediaNodeDriftAdapter.fromDb(row);
      final fileNode = node.maybeMap(file: (f) => f, orElse: () => null);
      if (fileNode == null) continue;
      if (fileNode.mediaType != MediaType.video &&
          fileNode.mediaType != MediaType.audio) {
        continue;
      }
      out.add(node);
      if (out.length >= limit) break;
    }
    return out;
  }
}

/*

class MediaNodeRepository {
  final MediaNodesDao _nodesDao;

  MediaNodeRepository(this._nodesDao);

  // --- Directory Tree Navigation ---

  /// Lists nodes within a specific directory.
  ///
  /// handles the transformation of parent paths
  Future<List<MediaNode>> listNodesInDirectory({
    required String storageId,
    required List<String>? parentPath,
    required List<MediaLibrarySource> sources,
    int limit = 100,
    int offset = 0,
    MediaSortField sort = MediaSortField.name,
    SortDirection order = SortDirection.asc,
  }) async {
    final rows = await _nodesDao.listByParent(
      storageId: storageId,
      parentPath: parentPath?.join('/'),
      limit: limit,
      offset: offset,
      sort: sort,
      order: order,
    );

    return _filterAndMap(rows, sources);
  }

  // --- Global Discovery ---

  /// Retrieves all media (audio/video) across the library,
  /// applying source path filtering.
  Future<List<MediaNode>> listMediaInLibrary({
    required List<MediaLibrarySource> sources,
    MediaType? mediaType,
    int limit = 100,
    int offset = 0,
    MediaSortField sort = MediaSortField.name,
    SortDirection order = SortDirection.asc,
  }) async {
    final rows = await _nodesDao.listAllMedia(
      limit: limit,
      offset: offset,
      sort: sort,
      order: order,
    );

    return _filterAndMap(rows, sources, mediaTypeFilter: mediaType);
  }

  /// Retrieves all directories associated with the provided sources.
  Future<List<MediaNode>> listDirectoriesInLibrary({
    required List<MediaLibrarySource> sources,
    int limit = 100,
    int offset = 0,
  }) async {
    final rows = await _nodesDao.listAllDirs(
      limit: limit,
      offset: offset,
    );

    return _filterAndMap(rows, sources);
  }

  // --- Search & Lookup ---

  /// Performs a keyword search across nodes, restricted by library sources.
  Future<List<MediaNode>> search({
    required List<MediaLibrarySource> sources,
    required String keyword,
    MediaType? mediaType,
    int limit = 100,
    int offset = 0,
  }) async {
    final rows = await _nodesDao.searchByName(
      keyword: keyword,
      limit: limit,
      offset: offset,
    );

    return _filterAndMap(rows, sources, mediaTypeFilter: mediaType);
  }

  /// Fetches a single node by its specific storage location.
  Future<MediaNode?> getNodeByPath({
    required String storageId,
    required List<String> path,
  }) async {
    final row = await _nodesDao.getByPath(
      storageId: storageId,
      path: path.join('/'),
    );

    return row != null ? MediaNodeDriftAdapter.fromDb(row) : null;
  }

  // --- Internal Logic (Information Hiding) ---

  /// Core logic for filtering database rows against MediaLibrarySources.
  ///
  /// By keeping this logic here, we prevent 'leakage' where the UI or Facade
  /// would otherwise have to manually check path prefixes.
  List<MediaNode> _filterAndMap(
    List<MediaNodesTableData> rows,
    List<MediaLibrarySource> sources, {
    MediaType? mediaTypeFilter,
  }) {
    return rows
        .where((row) {
          // 1. Path Match check
          final isWithinSources = sources.any((source) {
            if (source.storageId != row.storageId) return false;
            if (source.path == null) return true; // Full storage source

            final sourcePathString = source.path!.join('/');
            return row.path.startsWith(sourcePathString);
          });

          if (!isWithinSources) return false;

          // 2. Media Type check
          if (mediaTypeFilter != null) {
            if (row.mediaType == null) return false;
            return row.mediaType == mediaTypeFilter.index;
          }

          return true;
        })
        .map(MediaNodeDriftAdapter.fromDb)
        .toList();
  }

  /// Deletes nodes associated with a specific storage (Cleanup).
  Future<void> deleteByStorage(String storageId) {
    return _nodesDao.deleteByStorage(storageId);
  }
}
*/
