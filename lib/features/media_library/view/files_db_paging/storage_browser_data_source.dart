import 'dart:async';
import 'dart:io' show Platform;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart' hide Chip;
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/features/background_playback/background_playback_gate.dart';
import 'package:iris/features/background_playback/view/bg_source_rule_editor.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart';
import 'package:iris/features/media_library/model/media_lib/media_library_source.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/play_queue/models/play_queue_source.dart';
import 'package:iris/features/media_library/play_queue/play_queue_append_feedback.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/media_library/scan/service/recursive_scan_service.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/features/media_library/scan/view/scan_options_dialog.dart';
import 'package:iris/features/media_library/services/add_sources_to_library.dart';
import 'package:iris/features/media_library/services/media_node_sync_service.dart';
import 'package:iris/features/media_library/services/show_add_to_library_dialog.dart';
import 'package:iris/features/webdav_discovery/services/webdav_connect_coordinator.dart';
import 'package:iris/features/meta_settings/engine/browse_scope_snapshot.dart'
    show currentBrowseMediaScope;
import 'package:iris/features/playback_tools/services/open_with_service.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/paginated_browser/utils/breadcrumbs.dart';
import 'package:iris/features/scenario_playback/actions/media_revision_actions.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_actions.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/commands/vm_actions.dart';
import 'package:iris/features/virtual_media/vm_gate.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/enums/storage_list_error.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/storages/webdav.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/storage_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/files_sort.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/utils/request_storage_permission.dart';
import 'package:iris/widgets/adaptive/keyboard_form_shell.dart';
import 'package:iris/widgets/dialogs/show_append_queue_dialog.dart';
import 'package:iris/widgets/popups/storages/db/files_widget/file_subtitle.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyDb);

class StorageBrowserDataSource extends PaginatedBrowserDataSource<FileItem> {
  final Storage storage;

  List<FileItem> _allItems = [];
  List<FileItem> _sortedItems = [];
  int _currentPage = 0;
  bool _isLoading = false;
  bool _isError = false;
  StorageListErrorKind? _errorKind;
  String? _errorDetail;
  String? _searchQuery;

  /// Durable playback progress (media_nodes columns) for the files of the
  /// current directory, keyed by [FileItem.getID]. Used as the fallback when
  /// HistoryStore is empty (e.g. after clearing history) so progress stays
  /// visible. Value = (playbackPositionMs, durationMs).
  final Map<String, (int?, int?)> _durableProgress = {};

  /// Last seen persisted page size (reactivity filter for the app store).
  late int _lastPageSize;
  StreamSubscription<AppState>? _appSub;

  /// Last seen current path (reactivity filter for the storage store).
  late List<String> _lastPath;
  StreamSubscription<StorageState>? _storageSub;

  StorageBrowserDataSource(this.storage) {
    _lastPageSize = useAppStore().state.storageBrowserPageSize;
    _appSub = useAppStore().stream.listen((state) {
      if (state.storageBrowserPageSize != _lastPageSize) {
        _lastPageSize = state.storageBrowserPageSize;
        notifyListeners();
      }
    });
    _lastPath = useStorageStore().state.currentPath;
    _storageSub = useStorageStore().stream.listen((state) {
      if (!const ListEquality<String>().equals(state.currentPath, _lastPath)) {
        _lastPath = state.currentPath;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _appSub?.cancel();
    _storageSub?.cancel();
    super.dispose();
  }

  // ── helpers ──

  @override
  bool get supportsSearch => false;

  SortBy get _sortBy => useAppStore().state.sortBy;
  SortOrder get _sortOrder => useAppStore().state.sortOrder;
  bool get _folderFirst => useAppStore().state.folderFirst;

  List<String> get _basePath => storage.basePath;
  List<String> get _currentPath => useStorageStore().state.currentPath;

  /// True when the context-driven playback system owns the play flow.
  bool get _useScenarioMode {
    final app = useAppStore().state;
    return !app.useLegacyStoragePersistence && app.useScenarioDrivenPlayback;
  }

  /// Storage-relative folder path of the current browse position and the
  /// storage-relative path of [file].
  ///
  /// The folder path is kept in its raw (browser) form — it is used as the
  /// scenario source whose `parent_path` must match the DB. The item path is
  /// canonicalized to the resolver's occurrence rendering so the persisted
  /// `currentPlaybackOccurrence` matches what the queue resolves.
  (String, String) _storageRelativePaths(FileItem file) {
    // The RAW (possibly slashed) form is kept only for the occurrence/playback
    // key rendering. The folder handed to the scenario layer must be CANONICAL
    // (`''` = storage root, `anime` below it) to match `media_nodes.parent_path`
    // / `path`; passing the raw WebDAV root `'/'` made every scope lookup miss.
    final rawFolderPath = _currentPath.join('/');
    final rawItemPath =
        rawFolderPath.isEmpty ? file.name : '$rawFolderPath/${file.name}';
    return (canonicalDbPath(rawFolderPath), canonicalOccurrencePath(rawItemPath));
  }

  /// Returns true when playback actually started, false when nothing played
  /// (empty dir, or a failure already surfaced by the action's error dialog).
  /// The caller uses the result to decide whether the popup may close.
  Future<bool> _playFromCurrentDir(BuildContext context, FileItem tapped) async {
    final playable = _sortedItems.where((f) => f.isPlayable).toList();
    if (playable.isEmpty) return false;

    if (_useScenarioMode) {
      final (folderPath, itemPath) = _storageRelativePaths(tapped);
      // v15-D6: surface failures via the uniform copyable error dialog.
      return ScenarioPlaybackActions.runPlayAction(
        context,
        () => ScenarioPlaybackActions.playFolderScopeInDefaultScenario(
          storageId: storage.id,
          folderPath: folderPath,
          tapped: tapped,
          itemPath: itemPath,
          sortField: ScenarioPlaybackActions.scenarioSortFieldFrom(_sortBy),
          sortDirection:
              ScenarioPlaybackActions.scenarioSortDirectionFrom(_sortOrder),
        ),
      );
    }

    final queue = playable
        .asMap()
        .entries
        .map((e) => PlayQueueItem(file: e.value, index: e.key))
        .toList();
    final idx = playable.indexOf(tapped);

    await useAppStore().updateAutoPlay(true);
    await useAppStore().updateShuffle(false);
    await usePlayQueueStore().setSource(
      PlayQueueSource.explicit(items: queue),
      initialPos: idx,
    );
    return true;
  }

  List<FileItem> get _filtered {
    final cached = _filteredCache;
    if (cached != null &&
        identical(cached.$1, _sortedItems) &&
        cached.$2 == _searchQuery) {
      return cached.$3;
    }
    _filterComputeCount++;
    var items = _sortedItems;
    if (_searchQuery != null && _searchQuery!.isNotEmpty) {
      final q = _searchQuery!.toLowerCase();
      items = items.where((f) => f.name.toLowerCase().contains(q)).toList();
    }
    _filteredCache = (_sortedItems, _searchQuery, items);
    return items;
  }

  /// Memoized [_filtered]: `items`/`totalItems`/`totalPages` are read many
  /// times per build, and with a search active each read would otherwise
  /// re-run the O(N) substring filter and allocate a fresh list. Keyed by the
  /// sorted source list identity plus the query, so every mutation path
  /// (`_applySort`, search set/clear) invalidates it automatically.
  (List<FileItem>, String?, List<FileItem>)? _filteredCache;

  int _filterComputeCount = 0;

  /// Test seam: how many times the filter/search pass actually ran.
  @visibleForTesting
  int get debugFilterComputeCount => _filterComputeCount;

  /// Test seam: installs a search query without a dialog.
  @visibleForTesting
  void setSearchQueryForTest(String? query) {
    _searchQuery = query;
    _currentPage = 0;
    notifyListeners();
  }

  void _applySort() {
    final scope = currentBrowseMediaScope();
    _sortedItems = filesSort(
      // isVisible drops non-playable files; the browse scope additionally
      // hides playable-but-out-of-scope ones (dirs stay scope-neutral).
      files: _allItems
          .where((f) => f.isVisible && f.matchesBrowseScope(scope))
          .toList(),
      sortBy: _sortBy,
      sortOrder: _sortOrder,
      folderFirst: _folderFirst,
    );
  }

  // ── public triggers ──

  Future<void> loadFromStorage() async {
    _isLoading = true;
    _isError = false;
    _errorKind = null;
    _errorDetail = null;
    _durableProgress.clear();
    notifyListeners();

    try {
      final path = _currentPath.isEmpty ? _basePath : _currentPath;
      var result = await storage.getFilesDetailed(path);

      // A wildcard entry whose CACHED host answers but serves an empty listing
      // is suspicious: the persisted cache may point at a different machine
      // (shared/anonymous credentials + a wide pattern) — which reads as an
      // empty folder. Re-resolve while ignoring the cache and retry once.
      // When no new host answers, the empty listing is treated as UNREACHABLE
      // (never as a proven-empty directory): the phone cannot know whether
      // the other end is powered off, so the DB snapshot must be kept and the
      // last resolved host must stay untouched.
      if (!result.hasError && result.items.isEmpty) {
        final wildcard = _wildcardWithCache();
        if (wildcard != null) {
          final retry = await _relistViaFreshResolution(wildcard, path);
          if (retry != null && retry.items.isNotEmpty) {
            result = retry;
          } else {
            result = FileListResult(
              const <FileItem>[],
              errorKind: StorageListErrorKind.unreachable,
              errorDetail:
                  'no candidate host answered; kept last resolved host ${wildcard.resolvedHosts.join(', ')} (pattern: ${wildcard.host})',
            );
          }
        }
      }

      _allItems = result.items;

      if (result.hasError) {
        // A failed listing must NOT be treated as an empty directory: the UI
        // has to explain the cause, and an empty list must never reach the DB
        // sync (which would purge this directory's rows).
        _isError = true;
        _errorKind = result.errorKind;
        _errorDetail = result.errorDetail;
        if (result.errorKind == StorageListErrorKind.permissionDenied) {
          markStoragePermissionDenied();
        }
        useStorageStore().markDisconnected(storage.id);
      } else {
        useStorageStore().markConnected(storage.id);
        _applySort();
        if (!useAppStore().state.useLegacyStoragePersistence) {
          await _syncDbWithFilesystem(path);
        }
      }
    } catch (e) {
      _isError = true;
      _errorKind = classifyLocalListError(e);
      _errorDetail = e.toString();
      if (_errorKind == StorageListErrorKind.permissionDenied) {
        markStoragePermissionDenied();
      }
      useStorageStore().markDisconnected(storage.id);
    }

    _isLoading = false;
    notifyListeners();
  }

  /// The current storage when it is an IPv4-wildcard WebDAV entry that already
  /// carries a (non-empty) resolved-host cache — the only case where an empty
  /// listing can mean "the cache points at the wrong machine".
  WebDAVStorage? _wildcardWithCache() {
    final s = storage;
    if (s is! WebDAVStorage) return null;
    if (!isIPv4WildcardHost(s.host)) return null;
    if (s.resolvedHosts.isEmpty) return null;
    return s;
  }

  /// Re-resolves [wildcard] with its whole cache excluded, then lists again
  /// through the freshly chosen host. Returns null when nothing new was found
  /// (or the retry itself failed), so the caller keeps its original result.
  Future<FileListResult?> _relistViaFreshResolution(
    WebDAVStorage wildcard,
    List<String> path,
  ) async {
    final stale = <String>{...wildcard.resolvedHosts};
    final host = await webdavConnectCoordinator()
        .reResolveExcluding(wildcard, excludeHosts: stale);
    if (host == null) return null;

    areaKeyLog.i(
      'webdav ${wildcard.id}: cached host(s) $stale listed nothing; '
      'retrying via $host',
    );

    // Re-read from the store so the retry uses the refreshed cache (the new
    // host is prepended by the coordinator's record step).
    final refreshed = useStorageStore().findById(wildcard.id);
    final target = refreshed is WebDAVStorage ? refreshed : wildcard;
    final retry = await target.getFilesDetailed(path);
    return retry.hasError ? null : retry;
  }

  /// Sync current directory between filesystem and media library DB.
  /// Only for non-legacy mode, after a successful filesystem read.
  ///
  /// Delegates the DB upsert / stale-delete / aggregate recompute to the shared
  /// [MediaNodeSyncService]; only the durable progress capture (files-paged UI)
  /// stays here.
  Future<void> _syncDbWithFilesystem(List<String> dirPath) async {
    try {
      final sync = await MediaNodeSyncService().syncDirectory(
        storage: storage,
        items: _allItems,
        dirPath: dirPath,
      );
      final dbRows = sync.preSyncChildren;

      // Capture durable progress from the media library (survives history
      // clears) for the current directory's playable files. Keyed canonically
      // so the read side (buildItemSubtitle) matches on every platform.
      for (final row in dbRows) {
        final file = row.maybeMap(file: (f) => f, orElse: () => null);
        if (file == null) continue;
        _durableProgress[canonicalProgressKey(file.storageId, file.path)] =
            (file.playbackPositionMs, file.durationMs);
      }

      // Only a sync that actually wrote rows may invalidate the scenario queue
      // index; a no-op re-browse must not force a rebuild.
      if (sync.changed) {
        await MediaRevisionActions.mediaNodesChanged([storage.id]);
      }
    } catch (e) {
      areaKeyLog.e('StorageBrowserDataSource DB sync error: $e');
    }
  }

  // ── PaginatedBrowserDataSource ──

  @override
  int get totalItems => _filtered.length;

  @override
  int get currentPage => _currentPage;

  @override
  int get totalPages =>
      _filtered.isEmpty ? 1 : (_filtered.length / pageSize).ceil();

  /// Persisted per-surface page size (source of truth: AppState, like rate).
  @override
  int get pageSize => useAppStore().state.storageBrowserPageSize;

  @override
  bool get isLoading => _isLoading;

  @override
  bool get isError => _isError;

  @override
  StorageListErrorKind? get listErrorKind => _errorKind;

  @override
  String? get listErrorDetail => _errorDetail;

  @override
  List<FileItem> get items {
    final start = _currentPage * pageSize;
    final end = (start + pageSize).clamp(0, _filtered.length);
    if (start >= _filtered.length) return [];
    return _filtered.sublist(start, end);
  }

  @override
  String getItemId(FileItem item) => item.getID();

  // ── Breadcrumbs ──

  @override
  List<String>? get currentBreadcrumbs => sealedPathBreadcrumbs(
        sealedName: storage.name,
        path: _currentPath,
        basePath: _basePath,
      );

  @override
  bool get isRightToLeftBreadcrumbs => false;

  @override
  Future<void> navigateToCrumb(int index) async {
    if (index == 0) {
      handleNavigationHome();
      return;
    }
    // index 0 = sealed storage root; deeper crumbs add one segment each past
    // the (possibly multi-segment) base.
    final target = sealedCrumbTarget(
      baseLength: _basePath.length,
      crumbIndex: index,
    ).clamp(_basePath.length, _currentPath.length);
    final newPath = _currentPath.sublist(0, target);
    useStorageStore().updateCurrentPath(newPath);
    _currentPage = 0;
    await loadFromStorage();
  }

  @override
  Future<bool> handleNavigationBack() async {
    if (_currentPath.length > _basePath.length) {
      final newPath = _currentPath.sublist(0, _currentPath.length - 1);
      useStorageStore().updateCurrentPath(newPath);
      _currentPage = 0;
      await loadFromStorage();
      return true;
    }
    return false;
  }

  @override
  Future<void> handleNavigationHome() async {
    useStorageStore().updateCurrentPath(List<String>.from(_basePath));
    _currentPage = 0;
    _searchQuery = null;
    await loadFromStorage();
  }

  // ── Paging / Sort ──

  @override
  Future<void> fetchPage(int targetPage, int currentSize) async {
    _currentPage = targetPage;
    notifyListeners();
  }

  @override
  Future<void> changePageSize(int newSize) async {
    if (newSize < 1) return;
    newSize = clampPageSize(newSize);
    await useAppStore().updateStorageBrowserPageSize(newSize);
    _currentPage = 0;
    notifyListeners();
  }

  @override
  Future<void> changeSort(SortOption sortOption) async {
    // sortOption.value is expected to be a MapEntry<SortBy, SortOrder>
    if (sortOption.value is MapEntry<SortBy, SortOrder>) {
      final entry = sortOption.value as MapEntry<SortBy, SortOrder>;
      await useAppStore().updateSortBy(entry.key);
      await useAppStore().updateSortOrder(entry.value);
    }
    _applySort();
    _currentPage = 0;
    notifyListeners();
  }

  Future<void> refresh() async {
    _searchQuery = null;
    await loadFromStorage();
  }

  @override
  Future<void> retryLoad() => loadFromStorage();

  // ── Search ──

  @override
  Future<void> openSearchDialog(
    BuildContext context,
    VoidCallback onSearchInitiated,
  ) async {
    final t = getLocalizations(context);
    final result = await showKeyboardTextPrompt(
      context: context,
      title: t.lib_search,
      hint: t.lib_file_name_hint,
      confirmLabel: t.lib_search,
      cancelLabel: t.cancel,
    );
    if (result != null && result.isNotEmpty) {
      _searchQuery = result;
      _currentPage = 0;
      onSearchInitiated();
      notifyListeners();
    }
  }

  void clearSearch() {
    _searchQuery = null;
    _currentPage = 0;
    notifyListeners();
  }

  // ── Tap ──

  @override
  bool handleItemTap(BuildContext context, FileItem item) {
    if (item.isDir) {
      _openDirectory(item.name);
      return true;
    }
    if (item.isPlayable) {
      // The play flow can raise its first-use notice / error dialogs on this
      // route, so the popup must only close once playback actually started.
      _playAndMaybeClose(context, item);
      return true;
    }
    return false;
  }

  void _openDirectory(String name) {
    useStorageStore().updateCurrentPath([..._currentPath, name]);
    _currentPage = 0;
    _searchQuery = null;
    loadFromStorage();
  }

  // ── Tile presentation ──

  @override
  Widget? buildItemLeading(BuildContext context, FileItem item) {
    if (item.isDir) {
      return const Icon(Icons.folder_rounded);
    }
    switch (item.type) {
      case ContentType.video:
        return const Icon(Icons.movie_rounded);
      case ContentType.audio:
        return const Icon(Icons.audiotrack_rounded);
      case ContentType.image:
        return const Icon(Icons.image_rounded);
      case ContentType.other:
        return const Icon(Icons.file_copy_rounded);
    }
  }

  @override
  String? buildItemTitle(FileItem item) => item.name;

  @override
  Widget? buildItemSubtitle(BuildContext context, FileItem item) {
    // final durable = _durableProgress[item.getID()];  // legacy: uri key
    final durable = _durableProgress[canonicalProgressKey(item.storageId,
        item.path,
        uri: item.uri)]; // unified
    return FileSubtitle(
      file: item,
      durablePositionMs: durable?.$1,
      durableDurationMs: durable?.$2,
    );
  }

  @override
  Widget? buildTileContent(BuildContext context, FileItem item) => null;

  @override
  Widget buildTileInfoDialog(BuildContext context, FileItem item) {
    final t = getLocalizations(context);
    return AlertDialog(
      title: Text(item.name),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow(t.lib_info_type,
                item.isDir ? t.lib_info_directory : item.type.name),
            _infoRow(t.lib_info_path, item.path.join('/')),
            if (!item.isDir) ...[
              _infoRow(t.lib_info_size, _formatSize(item.size)),
              if (item.lastModified != null)
                _infoRow(t.lib_info_modified, item.lastModified.toString()),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.close),
        ),
      ],
    );
  }

  // ── Sort menu ──

  @override
  Widget buildSortMenu(BuildContext context) {
    final t = getLocalizations(context);
    final currentSortBy = useAppStore().select(context, (s) => s.sortBy);
    final currentOrder = useAppStore().select(context, (s) => s.sortOrder);
    final folderFirst = useAppStore().select(context, (s) => s.folderFirst);

    return PopupMenuButton<String>(
      clipBehavior: Clip.hardEdge,
      constraints: const BoxConstraints(minWidth: 200),
      tooltip: t.lib_sort_tip,
      icon: const Icon(Icons.sort_rounded),
      itemBuilder: (_) => [
        _sortItem(
            context, t.lib_sort_name, SortBy.name, currentSortBy, currentOrder),
        _sortItem(
            context, t.lib_sort_size, SortBy.size, currentSortBy, currentOrder),
        _sortItem(context, t.lib_sort_modified, SortBy.lastModified,
            currentSortBy, currentOrder),
        PopupMenuItem(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(t.lib_folder_first),
              Checkbox(
                value: folderFirst,
                onChanged: (_) {
                  useAppStore().updateFolderFirst(!folderFirst);
                  _applySort();
                  _currentPage = 0;
                  notifyListeners();
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  PopupMenuItem<String> _sortItem(
    BuildContext context,
    String label,
    SortBy target,
    SortBy current,
    SortOrder order,
  ) {
    return PopupMenuItem(
      value: target.name,
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        title: Text(label),
        trailing: current == target
            ? Icon(order == SortOrder.asc
                ? Icons.arrow_upward
                : Icons.arrow_downward)
            : null,
      ),
      onTap: () {
        final newOrder = current == target && order == SortOrder.asc
            ? SortOrder.desc
            : SortOrder.asc;
        useAppStore().updateSortBy(target);
        useAppStore().updateSortOrder(newOrder);
        _applySort();
        _currentPage = 0;
        notifyListeners();
      },
    );
  }

  // ── Page actions ──

  void _toggleFavorite() {
    final store = useStorageStore();
    final favorites = store.state.favorites;
    final current = favorites.firstWhereOrNull(
      (f) => f.storageId == storage.id && f.path == _currentPath,
    );
    if (current != null) {
      store.removeFavorite(current);
    } else {
      store.addFavorite(
        Favorite(storageId: storage.id, path: _currentPath),
      );
    }
    notifyListeners();
  }

  @override
  List<PageAction> buildCustomPageActions(BuildContext context) {
    final isFavorite = useStorageStore().select(
      context,
      (s) => s.favorites
          .any((f) => f.storageId == storage.id && f.path == s.currentPath),
    );
    // Offline-grey: scan walks the live tree, so without a connection it can
    // only fail — disabled with no reaction. Refresh (retryLoad) stays
    // enabled as the recovery path; Favorite is a pure local-DB op.
    final online = useStorageStore().select(
      context,
      (s) => s.storageConnectionStatus[storage.id] ?? true,
    );
    return [
      PageAction(
        icon: Icon(
            isFavorite ? Icons.star_rounded : Icons.star_outline_rounded),
        label: isFavorite ? 'Unfavorite' : 'Favorite',
        onPressed: _toggleFavorite,
      ),
      PageAction(
        icon: const Icon(Icons.refresh),
        label: 'Refresh/Scan',
        subActions: [
          PageAction(
            icon: const Icon(Icons.refresh),
            label: 'Refresh current',
            onPressed: () => refresh(),
          ),
          PageAction(
            icon: const Icon(Icons.manage_search_rounded),
            label: 'Scan recursively',
            onPressed: online ? () => _startRecursiveScan(context) : null,
          ),
        ],
      ),
      if (_useScenarioMode)
        // Offline-grey: playing the folder queues live files — disabled
        // without a connection, same rule as the scan entry above.
        PageAction(
          icon: const Icon(Icons.play_arrow_rounded),
          label: 'Play current folder',
          onPressed: online
              ? () async {
                  await ScenarioPlaybackActions
                      .runPlayActionWithNoMediaConfirm(
                    context,
                    action: ({bool force = false}) =>
                        ScenarioPlaybackActions.playSelectionInDefaultScenario(
                      files: const [],
                      directories: [
                        (
                          storageId: storage.id,
                          path: _currentPath.join('/'),
                          recursive: true,
                        ),
                      ],
                      sortField:
                          ScenarioPlaybackActions.scenarioSortFieldFrom(_sortBy),
                      sortDirection: ScenarioPlaybackActions
                          .scenarioSortDirectionFrom(_sortOrder),
                      force: force,
                      gateContext: context,
                    ),
                  );
                }
              : null,
        ),
    ];
  }

  Future<void> _startRecursiveScan(BuildContext context,
      {String? rootPath}) async {
    // Scan options gate: null = cancelled by the user.
    final probeEnabled =
        await showScanOptionsDialog(context, storageType: storage.type);
    if (probeEnabled == null) return;
    if (!context.mounted) return;

    final scanStore = useRecursiveScanStore();
    rootPath ??= _currentPath.join('/');
    final service = RecursiveScanService(
      storage: storage,
      scanStore: scanStore,
      nodesDao: DbModule.mediaNodesDao,
      sourcesDao: DbModule.mediaLibSourcesDao,
      probeService:
          probeEnabled ? createMediaProbeService() : null,
    );
    await service.scanRecursively(rootPaths: [rootPath], context: context);
    // The scan mutated `media_nodes`: announce the storage so the derived queue
    // index / open queue view pick up the new content instead of serving a
    // stale generation.
    await MediaRevisionActions.mediaNodesChanged([storage.id]);
  }

  // ── Trailing actions ──

  /// F-003 (v5-D33/v6-D34): closes the storagedb popup after a successful
  /// Override play unless pinned. [navigator]/[stay] are captured BEFORE the
  /// play await so no BuildContext crosses the async gap.
  void _closePopupOnPlaySuccess(NavigatorState navigator, {required bool stay}) {
    if (navigator.mounted && !stay && navigator.canPop()) {
      navigator.pop();
    }
  }

  /// Tap-to-play: runs the play flow to completion — its first-use notice /
  /// error dialogs must resolve on this route first — and closes the popup only
  /// when playback actually started (unless the user pinned "stay on play").
  Future<void> _playAndMaybeClose(BuildContext context, FileItem item) async {
    // Capture the navigator + pin BEFORE the await so no BuildContext crosses
    // the async gap (the dialogs outlive this tile's context).
    final navigator = Navigator.of(context);
    final stay = usePlaybackScenarioStore().storagesDbStayOnPlay;
    final ok = await _playFromCurrentDir(context, item);
    if (ok) _closePopupOnPlaySuccess(navigator, stay: stay);
  }

  @override
  List<GenericItemAction<FileItem>> getItemTrailingActions(
    BuildContext context,
    FileItem item,
  ) {
    final t = getLocalizations(context);
    final sortField = ScenarioPlaybackActions.scenarioSortFieldFrom(_sortBy);
    final sortDirection =
        ScenarioPlaybackActions.scenarioSortDirectionFrom(_sortOrder);
    // Offline-grey: scan walks the live tree, so without a connection it can
    // only fail — disabled with no reaction (same rule as the page-level
    // Refresh/Scan entry in buildCustomPageActions). Read straight from the
    // store: the menu is built on demand when opened, so no select
    // subscription is needed.
    final online =
        useStorageStore().state.storageConnectionStatus[storage.id] ?? true;
    return [
      if (item.isPlayable) ...[
        GenericItemAction(
          label: t.lib_override_queue,
          icon: const Icon(Icons.playlist_play, size: 16),
          onPressed: (ctx, i) async {
            if (_useScenarioMode) {
              final (folderPath, itemPath) = _storageRelativePaths(item);
              final navigator = Navigator.of(ctx);
              final stay = usePlaybackScenarioStore().storagesDbStayOnPlay;
              // v15-D6/D15: playability failures surface as the No Media
              // confirm (force retry) instead of a plain error dialog.
              final result =
                  await ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
                ctx,
                action: ({bool force = false}) =>
                    ScenarioPlaybackActions.playFolderScopeInDefaultScenario(
                  storageId: storage.id,
                  folderPath: folderPath,
                  tapped: item,
                  itemPath: itemPath,
                  sortField: sortField,
                  sortDirection: sortDirection,
                  force: force,
                ),
              );
              if (result == NoMediaActionResult.success) {
                _closePopupOnPlaySuccess(navigator, stay: stay);
              }
              return;
            }
            final playable = _sortedItems.where((f) => f.isPlayable).toList();
            final queue = playable
                .asMap()
                .entries
                .map((e) => PlayQueueItem(file: e.value, index: e.key))
                .toList();
            final idx = playable.indexOf(item);
            usePlayQueueStore().setSource(
              PlayQueueSource.explicit(items: queue),
              initialPos: idx,
            );
          },
        ),
        GenericItemAction(
          label: t.lib_append_queue,
          icon: const Icon(Icons.playlist_add, size: 16),
          onPressed: (ctx, i) async {
            if (_useScenarioMode) {
              // v14-D2: append with a before/after feedback dialog.
              if (!ctx.mounted) return;
              await ScenarioPlaybackActions.appendToDefaultScenarioWithFeedback(
                ctx,
                [item],
              );
              return;
            }
            final prepend = await showAppendQueueDialog(ctx);
            if (prepend != null) {
              if (!ctx.mounted) return;
              await appendToPlayQueueWithFeedback(
                ctx,
                files: [item],
                prepend: prepend,
              );
            }
          },
        ),
      ],
      // F-003 (GAP-1): directories gain Override/Append as recursive sources
      // (scenario branch only; legacy keeps the pre-existing actions).
      if (item.isDir && _useScenarioMode) ...[
        GenericItemAction(
          label: t.lib_override_queue,
          icon: const Icon(Icons.playlist_play, size: 16),
          onPressed: (ctx, i) async {
            final navigator = Navigator.of(ctx);
            final stay = usePlaybackScenarioStore().storagesDbStayOnPlay;
            final result =
                await ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
              ctx,
              action: ({bool force = false}) =>
                  ScenarioPlaybackActions.playSelectionInDefaultScenario(
                files: const [],
                directories: [
                  (
                    storageId: storage.id,
                    path: item.path.join('/'),
                    recursive: true,
                  ),
                ],
                sortField: sortField,
                sortDirection: sortDirection,
                force: force,
                gateContext: ctx,
              ),
            );
            if (result == NoMediaActionResult.success) {
              _closePopupOnPlaySuccess(navigator, stay: stay);
            }
          },
        ),
        GenericItemAction(
          label: t.lib_append_queue,
          icon: const Icon(Icons.playlist_add, size: 16),
          onPressed: (ctx, i) async {
            if (!ctx.mounted) return;
            await ScenarioPlaybackActions.appendToDefaultScenarioWithFeedback(
              ctx,
              const [],
              directories: [
                (
                  storageId: storage.id,
                  path: item.path.join('/'),
                  recursive: true,
                ),
              ],
            );
          },
        ),
      ],
      // Folders gain a per-directory recursive scan: same flow as the
      // page-level Refresh/Scan entry, but rooted at this folder instead of
      // the current browse path.
      if (item.isDir)
        GenericItemAction(
          label: t.files_scan_recursive,
          icon: const Icon(Icons.manage_search_rounded, size: 16),
          enabled: online,
          onPressed: (ctx, i) =>
              _startRecursiveScan(ctx, rootPath: i.path.join('/')),
        ),
      GenericItemAction(
        label: t.lib_add_to_library,
        icon: const Icon(Icons.library_add, size: 16),
        onPressed: (ctx, i) => _addToLibrary(ctx, [item]),
      ),
      // Folder quick-adds: turn this folder into a 副音 source rule / a
      // virtual-merge rule, prefilled with storage+folder defaults.
      if (item.isDir && BackgroundPlaybackGate.enabled)
        GenericItemAction(
          label: t.lib_add_as_bg_source,
          icon: const Icon(Icons.queue_music, size: 16),
          onPressed: (ctx, i) => openBgSourceRuleEditorForFolder(
            ctx,
            storageName: storage.name,
            folderName: i.name,
            folderPath: relativeToStoragePath(
              i.path.join('/'),
              [storage.basePath.join('/')],
            ),
          ),
        ),
      if (item.isDir && VirtualMediaGate.enabled)
        GenericItemAction(
          label: t.lib_add_as_vm_merge,
          icon: const Icon(Icons.merge_type, size: 16),
          onPressed: (ctx, i) => openVmRuleEditorForFolder(
            ctx,
            storageName: storage.name,
            folderName: i.name,
            folderPath: relativeToStoragePath(
              i.path.join('/'),
              [storage.basePath.join('/')],
            ),
          ),
        ),
      // Open-with: Android device-local playable files only (policy §5 —
      // remote storages stay browse-only; desktop uses the player instead).
      if (isOpenWithActionVisible(
        onAndroid: Platform.isAndroid,
        storageType: item.storageType,
        playable: item.isPlayable,
        uri: item.uri,
      ))
        GenericItemAction(
          label: t.lib_open_with,
          icon: const Icon(Icons.open_in_new_rounded, size: 16),
          onPressed: (ctx, i) => openMediaFileExternally(i.uri),
        ),
      GenericItemAction(
        label: t.lib_info_action,
        icon: const Icon(Icons.info_outline, size: 16),
        onPressed: (ctx, i) {
          showDialog(context: ctx, builder: (_) => buildTileInfoDialog(ctx, i));
        },
      ),
    ];
  }

  // ── Selection actions ──

  @override
  List<CustomSelectionAction<FileItem>> buildCustomSelectionActions(
    BuildContext context,
  ) {
    final t = getLocalizations(context);
    return [
      CustomSelectionAction<FileItem>(
        icon: const Icon(Icons.info_outline),
        label: t.lib_info_action,
        onPressed: (ctx, selected) async {
          int totalDirs = 0;
          int totalFiles = 0;
          int totalSize = 0;
          for (final item in selected) {
            if (item.isDir) {
              totalDirs++;
            } else {
              totalFiles++;
              totalSize += item.size;
            }
          }
          await showDialog(
            context: ctx,
            builder: (dialogCtx) {
              final t = getLocalizations(dialogCtx);
              return AlertDialog(
                title: Text(t.lib_selection_info),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _infoRow(t.lib_info_section_selected,
                        t.lib_info_selected_count(selected.length)),
                    _infoRow(t.lib_info_directories, '$totalDirs'),
                    _infoRow(t.lib_info_files, '$totalFiles'),
                    _infoRow(t.lib_info_total_size, _formatSize(totalSize)),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx),
                    child: Text(t.close),
                  ),
                ],
              );
            },
          );
          return false;
        },
      ),
      CustomSelectionAction<FileItem>(
        icon: const Icon(Icons.playlist_play),
        label: t.lib_override_queue,
        onPressed: (ctx, selected) async {
          final playable = selected.where((i) => i.isPlayable).toList();
          if (_useScenarioMode) {
            // F-005 (v2-D2/GAP-5): dirs become recursive sources and are NOT
            // dropped; the guard becomes "both empty" (No Media confirm, v6-D36).
            final dirs = selected
                .where((i) => i.isDir)
                .map((d) => (
                      storageId: storage.id,
                      path: d.path.join('/'),
                      recursive: true,
                    ))
                .toList();
            await ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
              ctx,
              action: ({bool force = false}) =>
                  ScenarioPlaybackActions.playSelectionInDefaultScenario(
                files: playable,
                directories: dirs,
                sortField:
                    ScenarioPlaybackActions.scenarioSortFieldFrom(_sortBy),
                sortDirection:
                    ScenarioPlaybackActions.scenarioSortDirectionFrom(_sortOrder),
                force: force,
                gateContext: ctx,
              ),
            );
            return true;
          }
          if (playable.isEmpty) return false;
          final queue = playable
              .asMap()
              .entries
              .map((e) => PlayQueueItem(file: e.value, index: e.key))
              .toList();
          usePlayQueueStore().setSource(
            PlayQueueSource.explicit(items: queue),
            initialPos: 0,
          );
          return true;
        },
      ),
      CustomSelectionAction<FileItem>(
        icon: const Icon(Icons.playlist_add),
        label: t.lib_append_queue,
        onPressed: (ctx, selected) async {
          final playable = selected.where((i) => i.isPlayable).toList();
          if (_useScenarioMode) {
            // F-005 (GAP-2/v2-D3): dirs append as recursive sources instead of
            // being silently dropped; both-empty → No Media confirm → force
            // append.
            final dirs = selected
                .where((i) => i.isDir)
                .map((d) => (
                      storageId: storage.id,
                      path: d.path.join('/'),
                      recursive: true,
                    ))
                .toList();
            if (playable.isEmpty && dirs.isEmpty) {
              await ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
                ctx,
                append: true,
                action: ({bool force = false}) async {
                  if (!force) {
                    throw PlaybackUnavailableException(
                        getLocalizations(ctx).lib_not_in_database);
                  }
                  if (!ctx.mounted) return;
                  await ScenarioPlaybackActions
                      .appendToDefaultScenarioWithFeedback(ctx, const []);
                },
              );
              return true;
            }
            // v14-D2: append with a before/after feedback dialog.
            if (!ctx.mounted) return true;
            await ScenarioPlaybackActions.appendToDefaultScenarioWithFeedback(
              ctx,
              playable,
              directories: dirs,
            );
            return true;
          }
          if (playable.isEmpty) return false;
          final prepend = await showAppendQueueDialog(ctx);
          if (prepend != null) {
            if (!ctx.mounted) return true;
            await appendToPlayQueueWithFeedback(
              ctx,
              files: playable,
              prepend: prepend,
            );
          }
          return true;
        },
      ),
      CustomSelectionAction<FileItem>(
        icon: const Icon(Icons.library_add),
        label: t.lib_add_to_library,
        onPressed: (ctx, selected) async {
          await _addToLibrary(ctx, selected.toList());
          return false;
        },
      ),
    ];
  }

  // ── Add to Library ──

  Future<void> _addToLibrary(BuildContext context, List<FileItem> items) async {
    final targetId = await showAddToLibraryDialog(context);
    if (targetId == null) return;

    final now = DateTime.now();
    final ts = _formatTimestamp(now);

    final sources = items.map((item) {
      final displayName = '${item.name}_$ts';
      return MediaLibrarySource(
        id: 0,
        libraryId: targetId,
        storageId: item.storageId.isNotEmpty ? item.storageId : storage.id,
        path: item.path,
        name: displayName,
        pathDepth: item.path.length,
        kind: item.isDir ? MediaSourceKind.directory : MediaSourceKind.file,
      );
    }).toList();

    final added = await addSourcesToLibrary(
      targetLibraryId: targetId,
      sources: sources,
    );

    if (context.mounted) {
      await showDialog(
        context: context,
        builder: (_) {
          final t = getLocalizations(context);
          return AlertDialog(
            content: Text(t.lib_added_sources(added)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t.ok),
              ),
            ],
          );
        },
      );
    }
  }

  // ── Helpers ──

  static String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    final i = (bytes / 1024).floor().clamp(0, suffixes.length - 1);
    if (i == 0) return '$bytes B';
    const divisor = [
      1,
      1024,
      1024 * 1024,
      1024 * 1024 * 1024,
      1024 * 1024 * 1024 * 1024
    ];
    return '${(bytes / divisor[i]).toStringAsFixed(2)} ${suffixes[i]}';
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');

  static String _formatTimestamp(DateTime dt) {
    return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} '
        '${_pad(dt.hour)}:${_pad(dt.minute)}:${_pad(dt.second)}';
  }

  static Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w500)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
