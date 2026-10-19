import 'dart:async';
import 'dart:convert';

import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_zustand/flutter_zustand.dart' as zustand;
import 'package:logging/logging.dart' as logging;
import 'package:iris/features/media_library/model/db/adapters/media_library.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_query.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_result.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart'
    show SourcesQuerySource;
import 'package:iris/features/media_library/model/db/repositories/media_library_repository_facade.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_library_repository.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_library_source.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/services/media_node_sync_service.dart';
import 'package:iris/features/media_library/services/system_library_open_check.dart';
import 'package:iris/features/media_library/view/content/model/lib_content_item.dart';
import 'package:iris/features/media_library/view/content/model/media_lib_content_mode.dart';
import 'package:iris/features/media_library/view/content/store/media_lib_content_runtime_state.dart';
import 'package:iris/features/media_library/view/content/store/media_lib_content_state.dart';
import 'package:iris/features/media_library/view/tab/store/libs/enum/load_state.dart';
import 'package:iris/features/meta_settings/engine/browse_scope_snapshot.dart'
    show currentBrowseScopeMediaTypes, currentPlayableScopeMediaTypes;
import 'package:iris/features/scenario_playback/actions/media_revision_actions.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart'
    show clampPageSize;
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/persistent_store.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyStore);

class MediaLibContentStore extends PersistentStore<MediaLibContentState> {
  final MediaNodeRepository nodeRepository;
  final MediaLibrarySourcesRepository sourcesRepository;
  final MediaLibraryFacade facade;

  MediaLibContentStore({
    required this.nodeRepository,
    required this.sourcesRepository,
    required this.facade,
  }) : super(const MediaLibContentState());

  static const _storageKey = 'media_lib_content_state';

  final KvStore _storage = getKvStore();

  int _refreshVersion = 0;

  MediaLibContentRuntimeState _runtime = const MediaLibContentRuntimeState();
  MediaLibContentRuntimeState get runtime => _runtime;

  /// Test seam: emits the current state so a widget test can assert that a
  /// no-op emission is not forwarded to the page. Never call from app code.
  @visibleForTesting
  void debugEmitNoop() => set(state);

  /// Test seam: installs a runtime snapshot without running a query. Never
  /// call from app code.
  @visibleForTesting
  void debugSetRuntime(MediaLibContentRuntimeState runtime) {
    _runtime = runtime;
    set(state);
  }

  // --- PERSISTENCE OVERRIDES ---

  @override
  Future<MediaLibContentState?> load() async {
    try {
      final raw = await _storage.read(key: _storageKey);
      if (raw != null) {
        final jsonMap = json.decode(raw) as Map<String, dynamic>;
        // A page is materialized in memory, so a size persisted by an older
        // build (the prompt used to allow 100000) must be clamped ON READ —
        // otherwise an upgrade fetches a hundred thousand rows and freezes.
        final loaded = MediaLibContentState.fromJson(jsonMap);
        set(loaded.copyWith(pageSize: clampPageSize(loaded.pageSize)));
      }
      return state;
    } catch (e) {
      areaKeyLog.e('Content store load error: $e');
      return state;
    }
  }

  @override
  Future<void> save(MediaLibContentState state) async {
    try {
      await _storage.write(
        key: _storageKey,
        value: json.encode(state.toJson()),
      );
    } catch (e) {
      areaKeyLog.e('Content store save error: $e');
    }
  }

  Future<void> _update(
    MediaLibContentState Function(MediaLibContentState current) updater,
  ) async {
    // Bug A fix: the store is created lazily on the first lib-tile tap, which
    // mutates before PersistentStore._init() has applied the persisted state.
    // Without waiting here, the first `save` would overwrite persisted fields
    // (viewMode, allDirsHideEmpty, pageSize, ...) with their defaults.
    await initialized;
    final next = updater(state);
    set(next);
    unawaited(save(next));
  }

  // --- CORE INTERFACES ---

  Future<void> setLibrary(String libraryId) async {
    if (state.currentLibraryId == libraryId) return;

    await _update((current) => current.copyWith(
          currentLibraryId: libraryId,
          currentStorageId: null,
          currentSourceRootPath: null,
          currentParentPath: null,
          requestedPage: 0,
          // D13: switching libraries clears the AllDirs L2 selection.
          allDirsSelectedStorageId: null,
          allDirsSelectedPath: null,
          allDirsL1Page: null,
          autoSkippedSources: false,
        ));

    // Single-source system libs (sys_<storageId>) skip the sources page and
    // land directly in the source content; navigateInto refreshes by itself.
    final entered = await _maybeAutoEnterSingleSystemSource();
    if (!entered) await refresh();
  }

  /// Auto-enters the only source of a single-source system library so the
  /// click-through skips the (always length-1) sources page. Applies to
  /// pathTree only — allMedia/allDirs aggregate across sources and never
  /// show a sources page. Returns true when navigation happened.
  Future<bool> _maybeAutoEnterSingleSystemSource() async {
    if (state.viewMode != MediaLibContentMode.pathTree) return false;
    final libraryId = state.currentLibraryId;
    if (libraryId == null) return false;
    if (state.currentStorageId != null || state.currentParentPath != null) {
      return false;
    }
    final library = await facade.getLibraryById(libraryId);
    if (library == null || !library.isSystem) return false;
    if (library.id == SystemLibraryOpenCheckService.detachedLibId) return false;
    final sources = await sourcesRepository.getSources(libraryId);
    if (sources.length != 1) return false;
    await _update((current) => current.copyWith(autoSkippedSources: true));
    await navigateInto(SourceLibContentItem(sources.single));
    return true;
  }

  Future<void> setViewMode(MediaLibContentMode mode) async {
    if (state.viewMode == mode) return;
    await _update((current) => current.copyWith(
          viewMode: mode,
          requestedPage: 0,
          // D13: switching view mode clears the AllDirs L2 selection.
          allDirsSelectedStorageId: null,
          allDirsSelectedPath: null,
          allDirsL1Page: null,
        ));
    // Entering pathTree on a sources page also honors the single-source
    // system-lib skip (same rule as setLibrary).
    final entered = await _maybeAutoEnterSingleSystemSource();
    if (!entered) await refresh();
  }

  Future<void> goToPage(int targetPage) async {
    if (targetPage == state.requestedPage && _runtime.state != LoadState.initial) return;
    await _update((current) => current.copyWith(requestedPage: targetPage));
    await refresh();
  }

  Future<void> updatePageSize(int newSize) async {
    if (newSize == state.pageSize) return;
    await _update((current) => current.copyWith(
          pageSize: newSize,
          requestedPage: 0,
        ));
    await refresh();
  }

  Future<void> refresh() async {
    if (state.currentLibraryId == null) return;

    final executionVersion = ++_refreshVersion;

    _runtime = _runtime.copyWith(state: LoadState.loading, error: null);

    try {
      List<LibContentItem> resolvedItems = [];
      int totalItems = 0;
      int totalPages = 0;
      int currentPage = 0;

      switch (state.viewMode) {
        case MediaLibContentMode.pathTree:
          final result = await _loadPathTreeHierarchy();
          resolvedItems = result.$1;
          totalItems = result.$2;
          totalPages = result.$3;
          currentPage = result.$4;
          break;
        case MediaLibContentMode.allMedia:
          final result = await _loadAllMedia();
          resolvedItems = result.items.map((e) => NodeLibContentItem(e)).toList();
          totalItems = result.totalItems;
          totalPages = result.totalPages;
          // D10: align with pathTree (0-based currentPage).
          currentPage = result.currentPage - 1;
          break;
        case MediaLibContentMode.allDirs:
          final result = await _loadAllDirs();
          resolvedItems = result.items.map((e) => NodeLibContentItem(e)).toList();
          totalItems = result.totalItems;
          totalPages = result.totalPages;
          // D10: align with pathTree (0-based currentPage).
          currentPage = result.currentPage - 1;
          break;
      }

      // Browse-scope display override: when a narrowed scope is active,
      // directory aggregates (count/size/duration) are re-projected to the
      // in-scope subtree. Persisted aggregate columns stay untouched.
      final scopedTypes = _scopedMediaTypes();
      if (scopedTypes != null) {
        resolvedItems = await _applyScopedAggregates(resolvedItems, scopedTypes);
      }

      if (executionVersion != _refreshVersion) return;

      _runtime = _runtime.copyWith(
        state: LoadState.ready,
        items: resolvedItems,
        totalItems: totalItems,
        totalPages: totalPages,
        currentPage: currentPage,
        error: null,
      );
    } catch (e) {
      if (executionVersion != _refreshVersion) return;
      _runtime = _runtime.copyWith(state: LoadState.error, error: e);
      areaKeyLog.e('Content refresh error: $e');
    }

    set(state);
  }

  // --- PATH TREE LOADING ---

  /// Single funnel for every query this store builds: resolves the current
  /// browse-media-scope into SQL-facing mediaTypes (null = unscoped). Gate
  /// OFF degrades to all, so legacy-mode runs stay unfiltered.
  List<MediaType>? _scopedMediaTypes() => currentBrowseScopeMediaTypes();

  /// Re-projects directory aggregates to the in-scope subtree so subtitles
  /// and info dialogs show scoped counts while the DB keeps the real ones.
  Future<List<LibContentItem>> _applyScopedAggregates(
    List<LibContentItem> items,
    List<MediaType> types,
  ) async {
    final pathsByStorage = <String, List<String>>{};
    for (final item in items) {
      if (item is NodeLibContentItem && item.node.isDir) {
        final dir = item.node as MediaDirectory;
        pathsByStorage
            .putIfAbsent(dir.storageId, () => [])
            .add(dir.path.join('/'));
      }
    }
    if (pathsByStorage.isEmpty) return items;

    final overrides = <String,
        Map<String, ({int mediaCount, int sizeBytes, int durationMs})>>{};
    for (final entry in pathsByStorage.entries) {
      overrides[entry.key] = await nodeRepository.aggregateByMediaTypes(
        storageId: entry.key,
        paths: entry.value,
        mediaTypes: types,
      );
    }

    return [
      for (final item in items)
        if (item is NodeLibContentItem && item.node is MediaDirectory)
          () {
            final dir = item.node as MediaDirectory;
            final agg = overrides[dir.storageId]
                ?[canonicalDbPath(dir.path.join('/'))];
            if (agg == null) return item;
            return NodeLibContentItem(dir.copyWith(
              totalMediaCount: agg.mediaCount,
              totalSizeInBytes: agg.sizeBytes,
              totalDurationMs: agg.durationMs,
            ));
          }()
        else
          item
    ];
  }

  Future<(List<LibContentItem>, int, int, int)> _loadPathTreeHierarchy() async {
    if (state.currentStorageId == null && state.currentParentPath == null) {
      final sources = await sourcesRepository.getSources(state.currentLibraryId!);
      final items = sources.map((e) => SourceLibContentItem(e)).toList();
      return (items, items.length, 1, 0);
    }

    final result = await nodeRepository.getDirectoryChildren(
      storageId: state.currentStorageId!,
      parentPath: state.currentParentPath,
      page: state.requestedPage + 1,
      pageSize: state.pageSize,
      sortField: state.sortField,
      sortDirection: state.sortDirection,
      folderFirst: state.folderFirst,
      mediaTypes: _scopedMediaTypes(),
      hideEmptyDirs: state.pathTreeHideEmpty,
    );

    final items = result.items.map((e) => NodeLibContentItem(e)).toList();
    return (items, result.totalItems, result.totalPages, result.currentPage - 1);
  }

  // --- ALL MEDIA LOADING ---

  Future<MediaNodePageResult> _loadAllMedia() {
    final libraryId = state.currentLibraryId;
    if (libraryId == null) {
      return Future.value(_emptyPage());
    }

    return _loadBySources(
      libraryId: libraryId,
      nodeKind: MediaNodeKind.file,
      // Playable baseline (excludes unknown rows) narrowed by the scope.
      mediaTypes: currentPlayableScopeMediaTypes(),
      pathGroupFirst: false,
      includeFileSources: true,
      hideEmptyDirs: false,
    );
  }

  // --- ALL DIRS LOADING ---

  Future<MediaNodePageResult> _loadAllDirs() async {
    final libraryId = state.currentLibraryId;
    if (libraryId == null) {
      return Future.value(_emptyPage());
    }

    final selectedStorageId = state.allDirsSelectedStorageId;
    final selectedPath = state.allDirsSelectedPath;

    // L2: media files of the selected directory (recursive per switch).
    if (selectedStorageId != null && selectedPath != null) {
      // D14: if the selected directory vanished, fall back to L1 automatically.
      final dirExists = await _directoryExists(
        storageId: selectedStorageId,
        path: selectedPath,
      );
      if (!dirExists) {
        areaKeyLog.w('[L2] D14 fallback to L1: not navigable '
            'storage=$selectedStorageId path=$selectedPath');
        await clearAllDirsSelection();
        return _loadBySources(
          libraryId: libraryId,
          nodeKind: MediaNodeKind.directory,
          mediaTypes: _scopedMediaTypes(),
          pathGroupFirst: true,
          includeFileSources: false,
        );
      }

      final l2 = await _loadL2Files(
        storageId: selectedStorageId,
        parentPath: selectedPath,
      );

      // D4: L2 root-cause diagnostics. dirExists/totalItems are logged at
      // WARNING so they are visible in debug builds without any log flag; the
      // (expensive) direct-children breakdown is gated behind the
      // log.legacy.store channel and distinguishes a "mediaType-filtered rows"
      // problem (unknown rows shown by pathTree but excluded by the L2
      // video/audio filter) from the by-design "only subdirectories" case.
      areaKeyLog.w('[L2] storage=$selectedStorageId path=$selectedPath '
          'dirExists=$dirExists totalItems=${l2.totalItems}');
      if (_l2DiagnosticsEnabled) {
        final children = await nodeRepository.getDirectoryChildren(
          storageId: selectedStorageId,
          parentPath: selectedPath,
          page: 1,
          pageSize: 10000,
        );
        var dirs = 0, files = 0, videoAudio = 0, unknown = 0;
        for (final child in children.items) {
          if (child.isDir) {
            dirs++;
          } else {
            files++;
            final mt = (child as MediaFile).mediaType;
            if (mt == MediaType.video || mt == MediaType.audio) {
              videoAudio++;
            } else {
              unknown++;
            }
          }
        }
        areaKeyLog.i('[L2] storage=$selectedStorageId path=$selectedPath '
            'children(dirs=$dirs files=$files '
            'videoAudio=$videoAudio unknown=$unknown)');
      }
      return l2;
    }

    return _loadBySources(
      libraryId: libraryId,
      nodeKind: MediaNodeKind.directory,
      mediaTypes: _scopedMediaTypes(),
      pathGroupFirst: true,
      includeFileSources: false,
      hideEmptyDirs: state.allDirsHideEmpty,
    );
  }

  /// Whether the directory at [path] in [storageId] is still navigable.
  ///
  /// D5: same-source probe as pathTree navigation — a directory is navigable
  /// when ANY row lives at or below [path] (its own row or descendants), not
  /// only when an exact directory row exists. This removes the D14
  /// false-negative risk from stale rows / missing directory nodes that made
  /// allDirs L1 → L2 silently fall back to L1.
  Future<bool> _directoryExists({
    required String storageId,
    required String path,
  }) async {
    final probe = MediaNodePageQuery(
      page: 1,
      pageSize: 1,
      storageId: storageId,
      parentPath: path.isEmpty ? null : path,
      recursive: true,
    );
    final result = await nodeRepository.getPagedNodes(probe);
    return result.totalItems > 0;
  }

  /// Whether the [areaKeyLog] channel is emitting INFO records, used to gate
  /// the (possibly expensive) D4 L2 diagnostics so they never run in paths
  /// where the channel is closed.
  bool get _l2DiagnosticsEnabled =>
      logging.Logger(areaKeyLog.key).isLoggable(logging.Level.INFO);

  Future<MediaNodePageResult> _loadL2Files({
    required String storageId,
    required String parentPath,
  }) {
    final recursive = state.allDirsRecursive;
    final query = MediaNodePageQuery(
      page: state.requestedPage + 1,
      pageSize: state.pageSize,
      storageId: storageId,
      parentPath: parentPath.isEmpty ? null : parentPath,
      recursive: recursive,
      nodeKind: MediaNodeKind.file,
      // Playable baseline (excludes unknown rows) narrowed by the scope.
      mediaTypes: currentPlayableScopeMediaTypes(),
      sortField: state.sortField,
      sortDirection: state.sortDirection,
      folderFirst: state.folderFirst,
    );
    return nodeRepository.getPagedNodes(query);
  }

  Future<MediaNodePageResult> _loadBySources({
    required String libraryId,
    required MediaNodeKind? nodeKind,
    required List<MediaType>? mediaTypes,
    required bool pathGroupFirst,
    required bool includeFileSources,
    bool hideEmptyDirs = false,
  }) async {
    final sources = await sourcesRepository.getSources(libraryId);
    final sourceTuples = <SourcesQuerySource>[];

    for (final source in sources) {
      final kind = source.kind ?? _inferKind(source);
      if (kind == MediaSourceKind.file && !includeFileSources) continue;
      sourceTuples.add((
        storageId: source.storageId,
        path: source.path?.join('/'),
        kind: kind,
        // v4-D7: per-source traversal — lib directory sources are always
        // recursive; the pathGroupFirst SORT is passed separately below.
        recursive: true,
        scenarioSourceId: null,
      ));
    }

    return nodeRepository.getPagedNodesForSources(
      sources: sourceTuples,
      nodeKind: nodeKind,
      mediaTypes: mediaTypes,
      sortField: state.sortField,
      sortDirection: state.sortDirection,
      folderFirst: state.folderFirst,
      pathGroupFirst: pathGroupFirst,
      hideEmptyDirs: hideEmptyDirs,
      page: state.requestedPage + 1,
      pageSize: state.pageSize,
    );
  }

  MediaSourceKind _inferKind(MediaLibrarySource source) {
    if (source.path == null || source.path!.isEmpty) {
      return MediaSourceKind.storage;
    }
    return MediaSourceKind.directory;
  }

  MediaNodePageResult _emptyPage() {
    return MediaNodePageResult(
      items: const [],
      totalItems: 0,
      totalPages: 1,
      currentPage: 1,
      pageSize: state.pageSize,
    );
  }

  // --- ALL DIRS L2 NAVIGATION ---

  /// Enters the L2 view for [dir] inside AllDirs (D12). Preserves the L1 page
  /// so returning restores it (D15).
  Future<void> enterAllDirsDir({
    required String storageId,
    required String path,
    required int l1Page,
  }) async {
    await _update((current) => current.copyWith(
          allDirsSelectedStorageId: storageId,
          allDirsSelectedPath: path,
          allDirsL1Page: l1Page,
          requestedPage: 0,
        ));
    // Realtime filesystem → DB sync so L2 shows the directory's actual media
    // files (like files-paged) even when it was never browsed before.
    await _syncDirectoryFor(storageId, path);
    await refresh();
  }

  /// Exits L2 back to L1, restoring the preserved L1 page (D8/D15).
  Future<void> exitAllDirsDir() async {
    await _update((current) => current.copyWith(
          allDirsSelectedStorageId: null,
          allDirsSelectedPath: null,
          allDirsL1Page: null,
          requestedPage: current.allDirsL1Page ?? 0,
        ));
    await refresh();
  }

  /// D14: L2 directory vanished → fall back to L1.
  ///
  /// D5b: restores the preserved L1 page (consistent with [exitAllDirsDir])
  /// instead of resetting to page 0.
  Future<void> clearAllDirsSelection() async {
    await _update((current) => current.copyWith(
          allDirsSelectedStorageId: null,
          allDirsSelectedPath: null,
          allDirsL1Page: null,
          requestedPage: current.allDirsL1Page ?? 0,
        ));
  }

  /// Toggles the AllDirs L2 recursive switch (global, persisted).
  Future<void> updateAllDirsRecursive(bool value) async {
    if (state.allDirsRecursive == value) return;
    await _update((current) => current.copyWith(
          allDirsRecursive: value,
          requestedPage: 0,
        ));
    await refresh();
  }

  /// Toggles the AllDirs L1 "hide empty directories" filter (global, persisted).
  Future<void> updateAllDirsHideEmpty(bool value) async {
    if (state.allDirsHideEmpty == value) return;
    await _update((current) => current.copyWith(
          allDirsHideEmpty: value,
          requestedPage: 0,
        ));
    await refresh();
  }

  /// Toggles the pathTree "only show dirs with media" filter (global,
  /// persisted, default ON). Dirs only — file rows are never affected.
  Future<void> updatePathTreeHideEmpty(bool value) async {
    if (state.pathTreeHideEmpty == value) return;
    await _update((current) => current.copyWith(
          pathTreeHideEmpty: value,
          requestedPage: 0,
        ));
    await refresh();
  }

  /// Whether unfiltered rows exist under the current pathTree position.
  ///
  /// Used by the empty state to distinguish "truly empty" from
  /// "filtered empty": same scope, same position, filter OFF, single-row
  /// probe. Only queried when the filtered listing is already empty, so the
  /// steady-state cost is zero.
  Future<bool> pathTreeHasUnfilteredRows() async {
    final storageId = state.currentStorageId;
    if (storageId == null) return false;
    final probe = await nodeRepository.getDirectoryChildren(
      storageId: storageId,
      parentPath: state.currentParentPath,
      page: 1,
      pageSize: 1,
      mediaTypes: _scopedMediaTypes(),
      hideEmptyDirs: false,
    );
    return probe.totalItems > 0;
  }

  /// Whether the current AllDirs view is inside L2.
  bool get isAllDirsL2 =>
      state.allDirsSelectedStorageId != null && state.allDirsSelectedPath != null;

  // --- NAVIGATION ---

  Future<void> navigateInto(LibContentItem item) async {
    if (!item.isDirectory) return;

    if (item is SourceLibContentItem) {
      final storage = useStorageStore().findById(item.source.storageId);
      final normalizedBase =
          (storage?.basePath.join('/') ?? '').replaceAll(RegExp(r'^/|/$'), '');
      final normalizedSource =
          (item.source.path?.join('/') ?? '').replaceAll(RegExp(r'^/|/$'), '');

      String rootPath;
      if (normalizedBase.isEmpty) {
        rootPath = normalizedSource;
      } else if (normalizedSource.isEmpty) {
        rootPath = normalizedBase;
      } else {
        rootPath = '$normalizedBase/$normalizedSource';
      }

      await _update((current) => current.copyWith(
            currentStorageId: item.source.storageId,
            currentSourceRootPath: rootPath,
            currentParentPath: rootPath,
            requestedPage: 0,
          ));
    } else if (item is NodeLibContentItem) {
      await _update((current) => current.copyWith(
            // Keep the entry the user opened; a node's canonical scope id may
            // be a linked sibling entry (shared library), which must not hijack
            // the browse context. Flat listings with no active entry fall back
            // to the node's own scope id.
            currentStorageId: current.currentStorageId ?? item.node.storageId,
            currentParentPath: item.node.path.join('/'),
            requestedPage: 0,
          ));
    }
    await _syncDirectoryFor(state.currentStorageId, state.currentParentPath);
    await refresh();
  }

  Future<bool> navigateUp() async {
    if (state.currentStorageId == null && state.currentParentPath == null) {
      return false;
    }

    final currentPath = state.currentParentPath;
    if (currentPath == null ||
        currentPath.isEmpty ||
        currentPath == state.currentSourceRootPath) {
      // Auto-skipped sources page: going up from the source root returns to
      // the lib list (caller closes the browser) instead of revealing the
      // skipped single-source page. Breadcrumb sealing is untouched — the
      // root itself stays clamped as before.
      if (state.autoSkippedSources) return false;
      await _update((current) => current.copyWith(
            currentStorageId: null,
            currentSourceRootPath: null,
            currentParentPath: null,
            requestedPage: 0,
          ));
    } else {
      final segments = currentPath.split('/');
      segments.removeLast();
      final parentPath = segments.join('/');

      await _update((current) => current.copyWith(
            currentParentPath: parentPath.isEmpty ? null : parentPath,
            requestedPage: 0,
          ));
    }
    await _syncDirectoryFor(state.currentStorageId, state.currentParentPath);
    await refresh();
    return true;
  }

  /// Directly set navigation context (used by breadcrumb navigation).
  /// Clamped to the sealed source root: breadcrumb targets must never escape
  /// above it (no `emulated / 0` leak); reaching the root stops there.
  Future<void> setNavigationContext({
    required String storageId,
    String? parentPath,
  }) async {
    final root = state.currentSourceRootPath;
    var clamped = parentPath;
    if (root != null && root.isNotEmpty) {
      if (clamped == null ||
          clamped.isEmpty ||
          (clamped != root && !clamped.startsWith('$root/'))) {
        clamped = root;
      }
    }
    await _update((current) => current.copyWith(
          currentStorageId: storageId,
          currentParentPath: clamped,
          requestedPage: 0,
        ));
    await _syncDirectoryFor(storageId, clamped);
    await refresh();
  }

  /// Realtime filesystem → DB sync for the current browse position, so the
  /// media lib content behaves like the files-paged browser (pathTree source
  /// tile open ≈ storagedb files paged). Gated to non-legacy mode; errors are
  /// logged and ignored so browsing never blocks on a failed sync.
  ///
  /// Offline is never proof of deletion: a failed listing only marks the
  /// storage disconnected and returns without touching `media_nodes`.
  Future<void> _syncDirectoryFor(String? storageId, String? parentPath) async {
    if (storageId == null || parentPath == null || parentPath.isEmpty) return;
    if (useAppStore().state.useLegacyStoragePersistence) return;
    final storage = useStorageStore().findById(storageId);
    if (storage == null) return;
    final segments =
        parentPath.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return;
    try {
      final result = await storage.getFilesDetailed(
        MediaNodeSyncService.absoluteDirPath(storage, segments),
      );
      if (result.hasError) {
        useStorageStore().markDisconnected(storageId);
        return;
      }
      useStorageStore().markConnected(storageId);
      final sync = await MediaNodeSyncService().syncDirectory(
        storage: storage,
        items: result.items,
        dirPath: segments,
      );
      // Only announce storages whose content actually changed, so a no-op
      // re-browse does not invalidate the derived scenario queue index.
      if (sync.changed) {
        await MediaRevisionActions.mediaNodesChanged([storageId]);
      }
    } catch (e) {
      areaKeyLog.w(
          '[content] sync dir failed storage=$storageId path=$parentPath: $e');
    }
  }

  // --- SORTING ---

  Future<void> updateSort({
    required MediaSortField field,
    required SortDirection direction,
  }) async {
    await _update((current) => current.copyWith(
          sortField: field,
          sortDirection: direction,
          requestedPage: 0,
        ));
    await refresh();
  }

  Future<void> updateFolderFirst(bool value) async {
    if (state.folderFirst == value) return;
    await _update((current) => current.copyWith(
          folderFirst: value,
          requestedPage: 0,
        ));
    await refresh();
  }

  Future<void> updateShowDeleteConfirmDialog(bool value) async {
    if (state.showDeleteConfirmDialog == value) return;
    await _update((current) => current.copyWith(
          showDeleteConfirmDialog: value,
        ));
  }

  // --- RECURSIVE MEDIA GATHERING (for play queue) ---

  Future<List<MediaFile>> gatherAllMediaFiles(List<LibContentItem> items) async {
    final result = <MediaFile>[];
    final dirsToProcess = <({String storageId, String? parentPath})>[];

    for (final item in items) {
      if (item is NodeLibContentItem && item.node.isFile) {
        result.add(item.node as MediaFile);
      } else if (item is NodeLibContentItem && item.node.isDir) {
        dirsToProcess.add((
          storageId: item.node.storageId,
          parentPath: item.node.path.join('/'),
        ));
      } else if (item is SourceLibContentItem) {
        dirsToProcess.add((
          storageId: item.source.storageId,
          parentPath: item.source.path?.join('/'),
        ));
      }
    }

    while (dirsToProcess.isNotEmpty) {
      final current = dirsToProcess.removeAt(0);

      final children = await nodeRepository.getDirectoryChildren(
        storageId: current.storageId,
        parentPath: current.parentPath,
        page: 1,
        pageSize: 10000,
      );

      for (final child in children.items) {
        if (child.isFile) {
          result.add(child as MediaFile);
        } else if (child.isDir) {
          dirsToProcess.add((
            storageId: child.storageId,
            parentPath: child.path.join('/'),
          ));
        }
      }
    }

    return result;
  }

  // --- MEDIA NODE BY ID ---

  MediaNode? findNodeById(String id) {
    for (final item in _runtime.items) {
      if (item.id == id && item is NodeLibContentItem) {
        return item.node;
      }
    }
    return null;
  }
}

MediaLibContentStore useMediaLibContentStore() {
  return zustand.create(
    () => MediaLibContentStore(
      nodeRepository: DbModule.nodeRepository,
      sourcesRepository: DbModule.sourcesRepository,
      facade: DbModule.mediaFacade,
    ),
  );
}
