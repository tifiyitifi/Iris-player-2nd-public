import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart';
import 'package:iris/features/media_library/search/model/search_context.dart';
import 'package:iris/features/media_library/search/model/search_scope.dart';
import 'package:iris/features/media_library/search/store/search_browser_store.dart';
import 'package:iris/features/media_library/model/media_lib/media_library_source.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/store/use_media_lib_browser_store.dart';
import 'package:iris/features/media_library/services/add_sources_to_library.dart';
import 'package:iris/features/media_library/services/source_delete_coverage.dart';
import 'package:iris/features/media_library/services/show_add_to_library_dialog.dart';
import 'package:iris/features/paginated_browser/utils/breadcrumbs.dart';
import 'package:iris/features/media_library/view/content/model/lib_content_item.dart';
import 'package:iris/features/media_library/view/content/model/media_lib_content_mode.dart';
import 'package:iris/features/media_library/view/content/store/media_lib_content_runtime_state.dart';
import 'package:iris/features/media_library/view/content/store/media_lib_content_state.dart';
import 'package:iris/features/media_library/view/content/store/use_media_lib_content_store.dart';
import 'package:iris/features/media_library/view/tab/store/libs/enum/load_state.dart';
import 'package:iris/features/media_library/play_queue/models/play_queue_source.dart';
import 'package:iris/features/media_library/play_queue/play_queue_append_feedback.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_actions.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/meta_settings/engine/browse_scope_snapshot.dart'
    show currentBrowseScopeMediaTypes;
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/commands/vm_actions.dart';
import 'package:iris/features/virtual_media/vm_gate.dart';
import 'package:iris/features/windows/explorer/menu/explorer_reveal_action.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_scope.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/adaptive/keyboard_form_shell.dart';
import 'package:iris/widgets/dialogs/show_append_queue_dialog.dart';
import 'package:iris/widgets/dialogs/show_copyable_error_dialog.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';

class LibContentDataSource extends PaginatedBrowserDataSource<LibContentItem> {
  final MediaLibContentStore _store;
  final VoidCallback? onBackToRoot;
  StreamSubscription<MediaLibContentState>? _sub;

  /// Snapshot of the last state forwarded to the page. Multiple store
  /// emissions per user action (persist-set + refresh-set, and refresh's
  /// loading→ready pair) are legitimate, but an emission whose page-visible
  /// snapshot is unchanged must not rebuild the whole list. A widget reads the
  /// getters directly on its first build, so the snapshot starts at the
  /// current state and only *changes* are forwarded.
  late _PageSnapshot _last = _PageSnapshot.of(this);

  LibContentDataSource(this._store, {this.onBackToRoot}) {
    _sub = _store.stream.listen((_) {
      final next = _PageSnapshot.of(this);
      if (next == _last) return;
      _last = next;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // --- PAGINATION STATE (delegated from store runtime) ---

  MediaLibContentRuntimeState get _rt => _store.runtime;

  /// True when the context-driven playback system owns the play flow.
  bool get _useScenarioMode {
    final app = useAppStore().state;
    return !app.useLegacyStoragePersistence && app.useScenarioDrivenPlayback;
  }

  @override
  int get totalItems => _rt.totalItems;

  @override
  int get currentPage => _rt.currentPage;

  @override
  int get totalPages => _rt.totalPages;

  @override
  int get pageSize => _store.state.pageSize;

  @override
  bool get isLoading => _rt.state == LoadState.loading;

  @override
  bool get isError => _rt.state == LoadState.error;

  @override
  List<LibContentItem> get items => _rt.items;

  @override
  String getItemId(LibContentItem item) => item.id;

  // --- BREADCRUMBS ---

  @override
  List<String>? get currentBreadcrumbs {
    if (_store.state.viewMode != MediaLibContentMode.pathTree) return null;
    if (_store.state.currentLibraryId == null) return null;

    final storageId = _store.state.currentStorageId;
    final storage = storageId == null ? null : _lookupStorage(storageId);
    return contentBreadcrumbs(
      storageName: storage?.name ?? storageId,
      parentPath: _store.state.currentParentPath,
      sourceRoot: _store.state.currentSourceRootPath,
    );
  }

  @override
  bool get isRightToLeftBreadcrumbs => false;

  // --- PAGING & NAVIGATION ---

  @override
  Future<void> fetchPage(int targetPage, int currentSize) async {
    await _store.goToPage(targetPage);
  }

  @override
  Future<void> changePageSize(int newSize) async {
    await _store.updatePageSize(clampPageSize(newSize));
  }

  @override
  Future<void> changeSort(SortOption sortOption) async {}

  /// Storage id behind [item], for the offline-grey policy.
  String? _storageIdOf(LibContentItem item) {
    if (item is NodeLibContentItem) return item.node.storageId;
    if (item is SourceLibContentItem) return item.source.storageId;
    return null;
  }

  /// Offline-grey, reactive: true when [storageId] is reachable (unknown ids
  /// count as reachable — only a proven failure greys). Read during build via
  /// `select` so rows and actions follow reconnects without a reload.
  bool _isStorageOnline(BuildContext context, String? storageId) {
    if (storageId == null) return true;
    return useStorageStore().select(
      context,
      (s) => s.storageConnectionStatus[storageId] ?? true,
    );
  }

  /// Offline-grey, one-shot (menus open fresh): same rule as
  /// [_isStorageOnline] without subscribing — popup builders re-read on
  /// every open.
  bool _isStorageOnlineSync(String? storageId) {
    if (storageId == null) return true;
    return useStorageStore().isConnected(storageId);
  }

  /// Offline-grey for a selection: play actions need live files for every
  /// selected item, so one disconnected storage disables the whole action.
  /// Pure-DB actions (info / add-as-source / delete snapshot) ignore this.
  bool _selectionHasOfflineStorage(Set<LibContentItem> selected) {
    final store = useStorageStore();
    return selected.any((i) {
      final id = _storageIdOf(i);
      return id != null && !store.isConnected(id);
    });
  }

  /// Files of a disconnected storage render greyed (dirs stay navigable so
  /// the last-known library snapshot remains browsable while offline).
  /// Called during build, so the reactive select keeps rows live.
  @override
  bool isItemUnavailable(BuildContext context, LibContentItem item) {
    if (item.isDirectory) return false;
    return !_isStorageOnline(context, _storageIdOf(item));
  }

  @override
  Future<bool> handleNavigationBack() async {
    // D1: AllDirs L2 → back to L1 (normal hierarchy rollback, page restored).
    if (_store.state.viewMode == MediaLibContentMode.allDirs &&
        _store.isAllDirsL2) {
      await _store.exitAllDirsDir();
      return true;
    }
    // D1: allDirs L1 / allMedia are peer-level views with no "back to" — Back
    // at their root returns false so the page falls through to onHomePage
    // (closeBrowser → libs list), instead of forcing setViewMode(pathTree).
    if (_store.state.viewMode != MediaLibContentMode.pathTree) {
      return false;
    }
    return await _store.navigateUp();
  }

  @override
  Future<void> handleNavigationHome() async {
    // Only reachable from navigateToCrumb(0) (pathTree breadcrumb first item):
    // currentBreadcrumbs is null outside pathTree, so no view-mode switch is
    // needed here.
    while (await _store.navigateUp()) {}
  }

  @override
  Future<void> navigateToCrumb(int index) async {
    final crumbs = currentBreadcrumbs;
    if (crumbs == null || index >= crumbs.length) return;

    if (index == 0) {
      await handleNavigationHome();
      return;
    }

    final storageId = _store.state.currentStorageId;
    if (storageId == null) return;

    final sourceRoot = _store.state.currentSourceRootPath ?? '';

    if (index == 1) {
      await _store.setNavigationContext(
        storageId: storageId,
        parentPath: sourceRoot.isEmpty ? null : sourceRoot,
      );
      return;
    }

    final subSegments = crumbs.sublist(2, index + 1);
    final subPath = subSegments.join('/');
    final fullPath = sourceRoot.isEmpty ? subPath : '$sourceRoot/$subPath';
    await _store.setNavigationContext(
      storageId: storageId,
      parentPath: fullPath,
    );
  }

  // --- SEARCH (media search feature, F-001) ---

  @override
  Future<void> openSearchDialog(
    BuildContext context,
    VoidCallback onSearchInitiated,
  ) async {
    // v5-D4: neutralize onSearchInitiated — the content page must NOT enter its
    // own search state (isSearchActive), otherwise returning from the search
    // page would leave the content page in a stale search banner and Back
    // would become cancelSearch instead of the position restore.
    await _openSearch(context);
  }

  Future<void> _openSearch(BuildContext context) async {
    final store = _store;
    final libraryId = store.state.currentLibraryId;
    if (libraryId == null) return;

    final sources = await store.sourcesRepository.getSources(libraryId);
    final searchSources = <SearchSource>[
      for (final s in sources)
        SearchSource(
          storageId: s.storageId,
          path: s.path?.join('/'),
          // v4-D7: lib directory sources are always recursive (traversal).
          kind: s.kind ?? (s.path == null || s.path!.isEmpty
              ? MediaSourceKind.storage
              : MediaSourceKind.directory),
          recursive: true,
        ),
    ];

    // §2.3: derive the entry context + location from the current view mode.
    final SearchEntryContext entry;
    String? storageId;
    String? parentPath;
    if (store.state.viewMode == MediaLibContentMode.allDirs &&
        store.isAllDirsL2) {
      entry = SearchEntryContext.libAllDirsL2;
      storageId = store.state.allDirsSelectedStorageId;
      parentPath = store.state.allDirsSelectedPath;
    } else if (store.state.viewMode == MediaLibContentMode.allDirs) {
      entry = SearchEntryContext.libAllDirsL1;
    } else if (store.state.viewMode == MediaLibContentMode.allMedia) {
      entry = SearchEntryContext.libAllMedia;
    } else if (store.state.currentStorageId == null &&
        store.state.currentParentPath == null) {
      entry = SearchEntryContext.libPathTreeRoot;
    } else {
      entry = SearchEntryContext.libPathTreeDir;
      storageId = store.state.currentStorageId;
      parentPath = store.state.currentParentPath;
    }

    final searchContext = SearchContext(
      entryContext: entry,
      storageId: storageId,
      parentPath: parentPath,
      scenarioId: null,
      sources: searchSources,
      explicitItems: const [],
    );

    useSearchBrowserStore().setMediaLibEntry(searchContext);
    useMediaLibBrowserStore().openSearch();
  }

  // --- TAP HANDLING ---

  @override
  bool handleItemTap(BuildContext context, LibContentItem item) {
    // Offline storage: library snapshots stay browsable (dirs navigate),
    // but greyed files never start playback — explain instead.
    if (!item.isDirectory) {
      final id = _storageIdOf(item);
      if (id != null && !useStorageStore().isConnected(id)) {
        final t = getLocalizations(context);
        showCopyableErrorDialog(context, message: t.storage_lost_play_blocked);
        return true;
      }
    }
    if (item.isDirectory) {
      // D12: AllDirs L1 → enter L2 (files of this directory).
      if (_store.state.viewMode == MediaLibContentMode.allDirs &&
          item is NodeLibContentItem) {
        final node = item.node as MediaDirectory;
        _store.enterAllDirsDir(
          storageId: node.storageId,
          path: node.path.join('/'),
          l1Page: _store.runtime.currentPage,
        );
        return true;
      }
      _store.navigateInto(item);
      return true;
    }
    // The play flow can raise its first-use notice / No Media confirm on this
    // route, so the popup must only close once playback actually started.
    _playAndMaybeClose(context, item);
    return true;
  }

  /// Runs [_playFromCurrentDir] to completion and closes the popup only when
  /// playback actually started (unless the user pinned "stay on play"). The
  /// navigator + pin are captured BEFORE the await so no BuildContext crosses
  /// the async gap.
  Future<void> _playAndMaybeClose(
      BuildContext context, LibContentItem item) async {
    final navigator = Navigator.of(context);
    final stay = usePlaybackScenarioStore().storagesDbStayOnPlay;
    final result = await _playFromCurrentDir(context, item);
    if (result == NoMediaActionResult.success) {
      if (navigator.mounted && !stay && navigator.canPop()) {
        navigator.pop();
      }
    }
  }

  /// Returns [NoMediaActionResult.success] only when playback actually started,
  /// so [_playAndMaybeClose] can leave the popup open on cancel / failure.
  Future<NoMediaActionResult> _playFromCurrentDir(
      BuildContext context, LibContentItem tapped) async {
    final allItems = _rt.items;
    final playable = allItems.where((i) => !i.isDirectory).where((i) {
      if (i is NodeLibContentItem) {
        final node = i.node;
        return node is MediaFile &&
            (node.mediaType == MediaType.video ||
                node.mediaType == MediaType.audio);
      }
      return false;
    }).toList();

    if (playable.isEmpty) return NoMediaActionResult.cancelled;

    final fileItems = playable.map((i) {
      final node = (i as NodeLibContentItem).node as MediaFile;
      return _mediaFileToFileItem(node);
    }).toList();

    final clickedIndex = playable.indexOf(tapped);
    if (clickedIndex < 0 || clickedIndex >= fileItems.length) {
      return NoMediaActionResult.cancelled;
    }

    if (_useScenarioMode) {
      return _playScenarioScope(context, tapped, fileItems[clickedIndex]);
    }

    // State ② (paged queue) and ③ (legacy): explicit queue of the current page.
    final queue = fileItems
        .asMap()
        .entries
        .map((e) => PlayQueueItem(file: e.value, index: e.key))
        .toList();

    await useAppStore().updateAutoPlay(true);
    await useAppStore().updateShuffle(false);
    await usePlayQueueStore().setSource(
      PlayQueueSource.explicit(items: queue),
      initialPos: clickedIndex,
    );
    return NoMediaActionResult.success;
  }

  /// Scenario-mode playback for the current view (D7/F132 state ①).
  ///
  /// - pathTree: folder scope of the tapped file's parent (existing behavior).
  /// - allDirs L2: folder scope of the selected directory, `recursive` per the
  ///   global AllDirs switch.
  /// - allMedia: system lib (single storage source) → whole-storage scope;
  ///   multi-source user lib → `playSelectionInDefaultScenario` with the
  ///   library's sources as folder sources + the tapped file positioned.
  ///
  /// Routes through the shared No Media 分流 helper (D15): an unplayable scope
  /// shows the No Media confirm instead of a plain error dialog. Returns the
  /// helper result so callers can react to success (popup close, D33).
  Future<NoMediaActionResult> _playScenarioScope(
      BuildContext context, LibContentItem tapped, FileItem tappedFile) async {
    final store = _store;
    final node = (tapped as NodeLibContentItem).node as MediaFile;

    // AllDirs L2 — folder scope of the selected directory.
    if (store.state.viewMode == MediaLibContentMode.allDirs &&
        store.isAllDirsL2) {
      return ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
          context,
          action: ({bool force = false}) =>
              ScenarioPlaybackActions.playFolderScopeInDefaultScenario(
        storageId: store.state.allDirsSelectedStorageId!,
        folderPath: store.state.allDirsSelectedPath ?? '',
        tapped: tappedFile,
        recursive: store.state.allDirsRecursive,
        sortField: ScenarioPlaybackActions.scenarioSortFieldFromMedia(
            store.state.sortField),
        sortDirection: store.state.sortDirection,
        force: force,
      ));
    }

    // AllMedia — library-sources scope.
    if (store.state.viewMode == MediaLibContentMode.allMedia) {
      final libraryId = store.state.currentLibraryId;
      if (libraryId == null) return NoMediaActionResult.cancelled;
      final sources = await store.sourcesRepository.getSources(libraryId);
      // The popup may have been dismissed while the DB read was in flight.
      if (!context.mounted) return NoMediaActionResult.cancelled;

      // Empty sources → play nothing (no error).
      if (sources.isEmpty) return NoMediaActionResult.cancelled;

      // Single storage-level source (e.g. system lib) → whole-storage scope.
      final singleStorage = sources.length == 1 &&
          (sources.single.path == null || sources.single.path!.isEmpty);
      if (singleStorage) {
        return ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
            context,
            action: ({bool force = false}) =>
                ScenarioPlaybackActions.playFolderScopeInDefaultScenario(
          storageId: sources.single.storageId,
          folderPath: '',
          tapped: tappedFile,
          recursive: true,
          sortField: ScenarioPlaybackActions.scenarioSortFieldFromMedia(
              store.state.sortField),
          sortDirection: store.state.sortDirection,
          force: force,
        ));
      }

      // Multi-source user lib → compose sources + position the tapped file.
      final directories = <ScenarioSourceSpec>[
        for (final source in sources)
          if (source.path == null || source.path!.isEmpty)
            (
              storageId: source.storageId,
              path: '',
              recursive: true,
              kind: ScenarioSourceKind.folder,
            )
          else
            (
              storageId: source.storageId,
              path: source.path!.join('/'),
              recursive: true,
              kind: ScenarioSourceKind.folder,
            ),
      ];
      return ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
          context,
          action: ({bool force = false}) =>
              ScenarioPlaybackActions.playSelectionInDefaultScenario(
        files: [tappedFile],
        directories: directories,
        sortField: ScenarioPlaybackActions.scenarioSortFieldFromMedia(
            store.state.sortField),
        sortDirection: store.state.sortDirection,
        force: force,
      ));
    }

    // pathTree — folder scope of the tapped file's parent (existing behavior).
    final parentSegments = node.path.length <= 1
        ? const <String>[]
        : node.path.sublist(0, node.path.length - 1);
    return ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
        context,
        action: ({bool force = false}) =>
            ScenarioPlaybackActions.playFolderScopeInDefaultScenario(
      storageId: node.storageId,
      folderPath: parentSegments.join('/'),
      tapped: tappedFile,
      sortField: ScenarioPlaybackActions.scenarioSortFieldFromMedia(
          store.state.sortField),
      sortDirection: store.state.sortDirection,
      force: force,
    ));
  }

  @override
  Widget buildTileInfoDialog(BuildContext context, LibContentItem item) {
    final t = getLocalizations(context);
    final rows = <Widget>[];

    if (item is SourceLibContentItem) {
      final s = item.source;
      final storageName = useStorageStore().findById(s.storageId)?.name;
      rows.addAll([
        _infoRow(t.lib_info_source_id, '${s.id}'),
        _infoRow(t.name, item.title),
        _infoRow(t.lib_info_type, t.lib_info_source),
        _infoRow(t.lib_info_storage_id, s.storageId),
        if (storageName != null && storageName.isNotEmpty)
          _infoRow(t.lib_info_storage_name, storageName),
        if (s.path != null && s.path!.isNotEmpty)
          _infoRow(t.lib_info_path, s.path!.join('/')),
        if (s.kind != null) _infoRow(t.lib_info_kind, '${s.kind}'),
        _infoRow(t.lib_info_total_media, '${s.totalMediaCount}'),
        _infoRow(t.lib_info_total_dirs, '${s.totalDirCount}'),
        _infoRow(t.lib_info_total_items, '${s.totalItemCount}'),
        _infoRow(t.lib_info_total_size,
            NodeLibContentItem.formatSize(s.totalSizeInBytes)),
        _infoRow(t.lib_info_total_duration,
            NodeLibContentItem.formatDurationHumanReadable(s.totalDurationMs)),
        _infoRow(t.lib_info_modified,
            NodeLibContentItem.formatDateTime(s.modifiedAt)),
        _infoRow(t.lib_info_created,
            NodeLibContentItem.formatDateTime(s.createdAt)),
      ]);
    } else if (item is NodeLibContentItem && item.node.isDir) {
      final dir = item.node as MediaDirectory;
      final storageName = useStorageStore().findById(dir.storageId)?.name;
      rows.addAll([
        _infoRow(t.lib_info_node_id, dir.id),
        _infoRow(t.name, item.title),
        _infoRow(t.lib_info_type, t.lib_info_directory),
        _infoRow(t.lib_info_path, dir.displayPath),
        _infoRow(t.lib_info_direct_children,
            t.lib_info_direct_children_value(
                dir.directMediaCount, dir.directDirCount, dir.directItemCount)),
        _infoRow(t.lib_info_recursive_totals,
            t.lib_info_recursive_totals_value(
                dir.totalMediaCount, dir.totalDirCount, dir.totalItemCount)),
        _infoRow(t.lib_info_total_size,
            NodeLibContentItem.formatSize(dir.totalSizeInBytes)),
        _infoRow(t.lib_info_total_duration,
            NodeLibContentItem.formatDurationHumanReadable(
                dir.totalDurationMs)),
        _infoRow(t.lib_info_modified,
            NodeLibContentItem.formatDateTime(dir.modifiedAt)),
        _infoRow(t.lib_info_created,
            NodeLibContentItem.formatDateTime(dir.createdAt)),
        _infoRow(t.lib_info_present, dir.isPresent ? t.lib_info_yes : t.lib_info_no),
        _infoRow(t.lib_info_last_seen,
            NodeLibContentItem.formatDateTime(dir.lastSeenAt)),
        _infoRow(t.lib_info_storage_id, dir.storageId),
        if (storageName != null && storageName.isNotEmpty)
          _infoRow(t.lib_info_storage_name, storageName),
        _infoRow(t.lib_info_depth, '${dir.pathDepth}'),
      ]);
    } else if (item is NodeLibContentItem && item.node.isFile) {
      final file = item.node as MediaFile;
      final storageName = useStorageStore().findById(file.storageId)?.name;
      rows.addAll([
        _infoRow(t.lib_info_node_id, file.id),
        _infoRow(t.name, item.title),
        _infoRow(t.lib_info_type, t.lib_info_file),
        _infoRow(t.lib_info_path, file.displayPath),
        _infoRow(t.lib_info_size,
            NodeLibContentItem.formatSize(file.sizeInBytes ?? 0)),
        _infoRow(t.lib_info_duration,
            NodeLibContentItem.formatDurationHumanReadable(
                file.durationMs ?? 0)),
        _infoRow(t.lib_info_modified,
            NodeLibContentItem.formatDateTime(file.modifiedAt)),
        _infoRow(t.lib_info_created,
            NodeLibContentItem.formatDateTime(file.createdAt)),
        _infoRow(t.lib_info_present, file.isPresent ? t.lib_info_yes : t.lib_info_no),
        _infoRow(t.lib_info_last_seen,
            NodeLibContentItem.formatDateTime(file.lastSeenAt)),
        _infoRow(t.lib_info_storage_id, file.storageId),
        if (storageName != null && storageName.isNotEmpty)
          _infoRow(t.lib_info_storage_name, storageName),
        _infoRow(t.lib_info_depth, '${file.pathDepth}'),
      ]);
    } else {
      rows.addAll([
        _infoRow(t.name, item.title),
        _infoRow(t.lib_info_type,
            item.isDirectory ? t.lib_info_directory : t.lib_info_file),
      ]);
    }

    return AlertDialog(
      title: Text(item.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  item is SourceLibContentItem
                      ? Icons.storage_rounded
                      : item.isDirectory
                          ? Icons.folder_rounded
                          : Icons.movie_rounded,
                  size: 24,
                  color: item is SourceLibContentItem
                      ? Theme.of(context).colorScheme.primary
                      : item.isDirectory
                          ? Colors.amber
                          : Colors.blue,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.title,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...rows,
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

  Widget _infoRow(String label, String value) {
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

  Widget _infoSectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
      ),
    );
  }

  // --- TILE CONTENT ---

  @override
  Widget? buildItemLeading(BuildContext context, LibContentItem item) {
    if (item is SourceLibContentItem) {
      return Icon(
        Icons.storage_rounded,
        size: 20,
        color: Theme.of(context).colorScheme.primary,
      );
    }
    return Icon(
      item.isDirectory ? Icons.folder_rounded : Icons.movie_rounded,
      size: 20,
      color: item.isDirectory ? Colors.amber : Colors.blue,
    );
  }

  @override
  String? buildItemTitle(LibContentItem item) => item.title;

  @override
  Widget? buildItemSubtitle(BuildContext context, LibContentItem item) {
    final subtitle = item.subtitle;
    if (subtitle.isEmpty) return null;
    return Text(
      subtitle,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
    );
  }

  @override
  Widget? buildTileContent(BuildContext context, LibContentItem item) => null;

  // --- SORT MENU ---

  @override
  Widget buildSortMenu(BuildContext context) {
    final t = getLocalizations(context);
    final currentField = _store.select(context, (s) => s.sortField);
    final currentDir = _store.select(context, (s) => s.sortDirection);
    final folderFirst = _store.select(context, (s) => s.folderFirst);
    final hideEmptyDirs = _store.select(context, (s) => s.allDirsHideEmpty);
    final onlyDirsWithMedia =
        _store.select(context, (s) => s.pathTreeHideEmpty);

    // D2/P6: the hide-empty toggle is meaningful only on the allDirs L1
    // directory list (L2 already shows files only); the pathTree twin lives
    // on its own row below.
    final showHideEmpty =
        _store.state.viewMode == MediaLibContentMode.allDirs &&
            !_store.isAllDirsL2;
    final showOnlyDirsWithMedia =
        _store.state.viewMode == MediaLibContentMode.pathTree;

    return PopupMenuButton(
      clipBehavior: Clip.hardEdge,
      constraints: const BoxConstraints(minWidth: 200),
      tooltip: t.lib_sort_tip,
      icon: const Icon(Icons.sort_rounded),
      itemBuilder: (_) => [
        _sortItem(context, t.lib_sort_name, MediaSortField.name, currentField,
            currentDir),
        _sortItem(context, t.lib_sort_size, MediaSortField.sizeInBytes,
            currentField, currentDir),
        _sortItem(context, t.lib_sort_duration, MediaSortField.durationMs,
            currentField, currentDir),
        // Resolution (probed width × height); unprobed files sort last.
        _sortItem(context, t.lib_sort_resolution, MediaSortField.pixelCount,
            currentField, currentDir),
        _sortItem(context, t.lib_sort_modified, MediaSortField.modifiedAt,
            currentField, currentDir),
        PopupMenuItem(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(t.lib_folder_first),
              Checkbox(
                value: folderFirst,
                onChanged: (_) {
                  _store.updateFolderFirst(!folderFirst);
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        ),
        if (showHideEmpty)
          PopupMenuItem(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(t.lib_hide_empty_dirs),
                Checkbox(
                  value: hideEmptyDirs,
                  onChanged: (_) {
                    _store.updateAllDirsHideEmpty(!hideEmptyDirs);
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
          ),
        if (showOnlyDirsWithMedia)
          PopupMenuItem(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(t.lib_only_dirs_with_media),
                Checkbox(
                  value: onlyDirsWithMedia,
                  onChanged: (_) {
                    _store.updatePathTreeHideEmpty(!onlyDirsWithMedia);
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  PopupMenuItem _sortItem(
    BuildContext context,
    String label,
    MediaSortField target,
    MediaSortField current,
    SortDirection order,
  ) {
    return PopupMenuItem(
      child: ListTile(
        mouseCursor: SystemMouseCursors.click,
        title: Text(label),
        trailing: current == target
            ? Icon(order == SortDirection.asc
                ? Icons.arrow_upward
                : Icons.arrow_downward)
            : null,
      ),
      onTap: () {
        final newDir = current == target && order == SortDirection.asc
            ? SortDirection.desc
            : SortDirection.asc;
        _store.updateSort(field: target, direction: newDir);
      },
    );
  }

  // --- CUSTOM PAGE ACTIONS (view mode switcher) ---

  @override
  List<PageAction> buildCustomPageActions(BuildContext context) {
    final t = getLocalizations(context);
    // D6: AllDirs L2 recursive switch — global toggle, visible only in L2.
    final allDirsL2 =
        _store.state.viewMode == MediaLibContentMode.allDirs &&
            _store.isAllDirsL2;
    final recursive = _store.state.allDirsRecursive;

    return [
      if (allDirsL2)
        PageAction(
          icon: Icon(
            recursive
                ? Icons.library_music_outlined
                : Icons.folder_outlined,
          ),
          label: recursive ? t.lib_recursive : t.lib_direct_only,
          onPressed: () =>
              _store.updateAllDirsRecursive(!recursive),
        ),
      PageAction(
        icon: const Icon(Icons.view_module_rounded),
        label: t.lib_view_mode,
        onPressed: () => _showViewModeDialog(context),
      ),
      if (_useScenarioMode && _store.state.currentStorageId != null)
        // Offline-grey: playing the folder resolves + queues live files, so
        // a disconnected storage disables the entry (standard disabled, no
        // reaction). View-mode / recursive switches render the local
        // snapshot and stay enabled.
        PageAction(
          icon: const Icon(Icons.play_arrow_rounded),
          label: t.lib_play_folder,
          onPressed: _isStorageOnline(context, _store.state.currentStorageId)
              ? () async {
                  await ScenarioPlaybackActions
                      .runPlayActionWithNoMediaConfirm(
                    context,
                    action: ({bool force = false}) =>
                        ScenarioPlaybackActions.playSelectionInDefaultScenario(
                      files: const [],
                      directories: [
                        (
                          storageId: _store.state.currentStorageId!,
                          path: _store.state.currentParentPath ?? '',
                          recursive: true,
                          kind: ScenarioSourceKind.folder,
                        ),
                      ],
                      sortField:
                          ScenarioPlaybackActions.scenarioSortFieldFromMedia(
                              _store.state.sortField),
                      sortDirection: _store.state.sortDirection,
                      force: force,
                      gateContext: context,
                    ),
                  );
                }
              : null,
        ),
    ];
  }

  void _showViewModeDialog(BuildContext context) {
    final currentMode = _store.state.viewMode;

    showDialog(
      context: context,
      builder: (dialogCtx) {
        final t = getLocalizations(dialogCtx);
        return AlertDialog(
          title: Text(t.lib_view_mode),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: MediaLibContentMode.values.map((mode) {
              return ListTile(
                leading: Icon(
                  mode == currentMode
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: mode == currentMode
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(_viewModeLabel(mode, t)),
                onTap: () {
                  Navigator.pop(dialogCtx);
                  _store.setViewMode(mode);
                },
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text(t.cancel),
            ),
          ],
        );
      },
    );
  }

  String _viewModeLabel(MediaLibContentMode mode, AppLocalizations t) {
    switch (mode) {
      case MediaLibContentMode.pathTree:
        return t.lib_mode_path_tree;
      case MediaLibContentMode.allMedia:
        return t.lib_mode_all_media;
      case MediaLibContentMode.allDirs:
        return t.lib_mode_all_dirs;
    }
  }

  // --- CUSTOM SELECTION ACTIONS ---

  @override
  List<CustomSelectionAction<LibContentItem>> buildCustomSelectionActions(
    BuildContext context,
  ) {
    // Offline-grey subscription: the bar only listens to the controller, so
    // subscribe here to rebuild play-action availability on (dis)connects.
    // (Info / add-as-source / delete below are pure local-DB ops and ignore
    // connectivity entirely.)
    useStorageStore().select(context, (s) => s.storageConnectionStatus);
    return [
      CustomSelectionAction<LibContentItem>(
        icon: const Icon(Icons.info_outline),
        label: getLocalizations(context).lib_info_action,
        onPressed: (ctx, selected) async {
          final items = selected.toList();

          // --- Direct counts ---
          final directDirs = items.where((i) => i.isDirectory).length;
          final directFiles = items.where((i) => !i.isDirectory).toList();
          final directMedia = directFiles.length;

          int directVideo = 0;
          int directAudio = 0;
          for (final item in directFiles) {
            if (item is NodeLibContentItem && item.node is MediaFile) {
              final mt = (item.node as MediaFile).mediaType;
              if (mt == MediaType.video) directVideo++;
              if (mt == MediaType.audio) directAudio++;
            }
          }

          // --- Recursive counts (from aggregate data) ---
          int recursiveDirs = 0;
          int recursiveMedia = 0;
          for (final item in items) {
            recursiveDirs += item.dirCount;
            recursiveMedia += item.mediaCount;
          }

          // --- Recursive video/audio (DB query for dirs/sources) ---
          int recursiveVideo = directVideo;
          int recursiveAudio = directAudio;
          for (final item in items) {
            String? storageId;
            String? parentPath;
            if (item is SourceLibContentItem) {
              storageId = item.source.storageId;
              parentPath = item.source.path?.join('/');
            } else if (item is NodeLibContentItem && item.node.isDir) {
              final dir = item.node as MediaDirectory;
              storageId = dir.storageId;
              parentPath = dir.path.join('/');
            }
            if (storageId != null) {
              try {
                // Scope-narrowed per-type counts (null under all/gate OFF).
                final counts = await DbModule.mediaNodeRepo.countMediaByType(
                  storageId: storageId,
                  parentPath: parentPath,
                  mediaTypes: currentBrowseScopeMediaTypes(),
                );
                for (final entry in counts.entries) {
                  if (entry.key == MediaType.video)
                    recursiveVideo += entry.value;
                  if (entry.key == MediaType.audio)
                    recursiveAudio += entry.value;
                }
              } catch (_) {}
            }
          }

          // --- Totals: size + played/unplayed duration ---
          int totalSize = 0;
          int playedDuration = 0;
          int unplayedItems = 0;
          for (final item in items) {
            if (item is SourceLibContentItem) {
              totalSize += item.source.totalSizeInBytes;
              if (item.source.totalDurationMs > 0) {
                playedDuration += item.source.totalDurationMs;
              } else {
                unplayedItems++;
              }
            } else if (item is NodeLibContentItem) {
              if (item.node.isDir) {
                final dir = item.node as MediaDirectory;
                totalSize += dir.totalSizeInBytes;
                if (dir.totalDurationMs > 0) {
                  playedDuration += dir.totalDurationMs;
                } else {
                  unplayedItems++;
                }
              } else {
                final file = item.node as MediaFile;
                totalSize += file.sizeInBytes ?? 0;
                if (file.durationMs != null && file.durationMs! > 0) {
                  playedDuration += file.durationMs!;
                } else {
                  unplayedItems++;
                }
              }
            }
          }

          final sizeStr = NodeLibContentItem.formatSize(totalSize);
          final playedDurationStr =
              NodeLibContentItem.formatDurationHumanReadable(playedDuration);

          // The popup may have been dismissed while counting.
          if (!ctx.mounted) return false;
          await showDialog(
            context: ctx,
            builder: (dialogCtx) {
              final t = getLocalizations(dialogCtx);
              return AlertDialog(
                title: Text(t.lib_selection_info),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            size: 24,
                            color: Theme.of(ctx).colorScheme.primary,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            t.lib_info_selected_count(items.length),
                            style:
                                const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _infoSectionLabel(t.lib_info_section_selected),
                      _infoRow(t.lib_info_directories, '$directDirs'),
                      _infoRow(t.lib_info_media_files, '$directMedia'),
                      _infoRow(t.lib_info_video, '$directVideo'),
                      _infoRow(t.lib_info_audio, '$directAudio'),
                      const SizedBox(height: 8),
                      _infoSectionLabel(t.lib_info_section_recursive),
                      _infoRow(t.lib_info_subdirs, '$recursiveDirs'),
                      _infoRow(t.lib_info_media_files, '$recursiveMedia'),
                      _infoRow(t.lib_info_video, '$recursiveVideo'),
                      _infoRow(t.lib_info_audio, '$recursiveAudio'),
                      const SizedBox(height: 8),
                      _infoRow(t.lib_info_total_size, sizeStr),
                      _infoRow(t.lib_info_played, playedDurationStr),
                      _infoRow(t.lib_info_unplayed, '$unplayedItems'),
                    ],
                  ),
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
      CustomSelectionAction<LibContentItem>(
        icon: const Icon(Icons.playlist_play),
        label: getLocalizations(context).lib_override_queue,
        // Offline-grey: queueing needs live files for every selected item —
        // one disconnected storage disables the action. Greyed rows stay
        // selectable so info / add-as-source / delete keep working on them.
        enabledFor: (selected) => !_selectionHasOfflineStorage(selected),
        onPressed: (ctx, selected) async {
          if (_useScenarioMode) {
            // F-006 (D26): the scenario branch does NOT use the old
            // `_gatherMediaFiles`-empty pre-block — empty/not-playable
            // selections surface via the No Media helper.
            final dirs = <ScenarioSourceSpec>[];
            final directFileItems = <FileItem>[];
            for (final sel in selected) {
              if (sel is SourceLibContentItem) {
                final source = sel.source;
                dirs.add((
                  storageId: source.storageId,
                  path: source.path?.join('/') ?? '',
                  recursive: true,
                  kind: ScenarioSourceKind.folder,
                ));
              } else if (sel is NodeLibContentItem) {
                if (sel.node.isDir) {
                  dirs.add((
                    storageId: sel.node.storageId,
                    path: sel.node.path.join('/'),
                    recursive: true,
                    kind: ScenarioSourceKind.folder,
                  ));
                } else {
                  directFileItems
                      .add(_mediaFileToFileItem(sel.node as MediaFile));
                }
              }
            }
            await ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
              ctx,
              action: ({bool force = false}) =>
                  ScenarioPlaybackActions.playSelectionInDefaultScenario(
                files: directFileItems,
                directories: dirs,
                sortField: ScenarioPlaybackActions.scenarioSortFieldFromMedia(
                    _store.state.sortField),
                sortDirection: _store.state.sortDirection,
                force: force,
                gateContext: ctx,
              ),
            );
            return true;
          }

          final files = await _gatherMediaFiles(selected.toList());
          // The popup may have been dismissed while gathering.
          if (!ctx.mounted) return false;
          if (files.isEmpty) {
            await showDialog(
              context: ctx,
              builder: (dialogCtx) {
                final t = getLocalizations(dialogCtx);
                return AlertDialog(
                  title: Text(t.lib_no_media),
                  content: Text(t.lib_no_media_selection),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogCtx),
                      child: Text(t.ok),
                    ),
                  ],
                );
              },
            );
            return false;
          }

          final fileItems = files.map((f) => _mediaFileToFileItem(f)).toList();
          final playQueue = fileItems
              .asMap()
              .entries
              .map((e) => PlayQueueItem(file: e.value, index: e.key))
              .toList();

          usePlayQueueStore().setSource(
            PlayQueueSource.explicit(items: playQueue),
            initialPos: 0,
          );
          return true;
        },
      ),
      CustomSelectionAction<LibContentItem>(
        icon: const Icon(Icons.playlist_add),
        label: getLocalizations(context).lib_append_queue,
        // Offline-grey: same rule as Override above.
        enabledFor: (selected) => !_selectionHasOfflineStorage(selected),
        onPressed: (ctx, selected) async {
          if (_useScenarioMode) {
            // F-006 (GAP-3/D26): dirs/sources append as recursive sources
            // (not flattened); both-empty → No Media confirm → 强制空追加.
            final dirs = <ScenarioSourceSpec>[];
            final directFileItems = <FileItem>[];
            for (final sel in selected) {
              if (sel is SourceLibContentItem) {
                final source = sel.source;
                dirs.add((
                  storageId: source.storageId,
                  path: source.path?.join('/') ?? '',
                  recursive: true,
                  kind: ScenarioSourceKind.folder,
                ));
              } else if (sel is NodeLibContentItem) {
                if (sel.node.isDir) {
                  dirs.add((
                    storageId: sel.node.storageId,
                    path: sel.node.path.join('/'),
                    recursive: true,
                    kind: ScenarioSourceKind.folder,
                  ));
                } else {
                  directFileItems
                      .add(_mediaFileToFileItem(sel.node as MediaFile));
                }
              }
            }
            if (directFileItems.isEmpty && dirs.isEmpty) {
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
              directFileItems,
              directories: dirs,
            );
            return true;
          }

          final files = await _gatherMediaFiles(selected.toList());
          // The popup may have been dismissed while gathering.
          if (!ctx.mounted) return false;
          if (files.isEmpty) {
            await showDialog(
              context: ctx,
              builder: (dialogCtx) {
                final t = getLocalizations(dialogCtx);
                return AlertDialog(
                  title: Text(t.lib_no_media),
                  content: Text(t.lib_no_media_selection),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogCtx),
                      child: Text(t.ok),
                    ),
                  ],
                );
              },
            );
            return false;
          }

          final fileItems = files.map((f) => _mediaFileToFileItem(f)).toList();

          final prepend = await showAppendQueueDialog(ctx);
          if (prepend != null) {
            if (!ctx.mounted) return true;
            await appendToPlayQueueWithFeedback(
              ctx,
              files: fileItems,
              prepend: prepend,
            );
          }
          return true;
        },
      ),
      CustomSelectionAction<LibContentItem>(
        icon: const Icon(Icons.library_add),
        label: getLocalizations(context).lib_add_as_source,
        onPressed: (ctx, selected) async {
          await _addAsSourceToLibrary(ctx, selected.toList());
          return false;
        },
      ),
      CustomSelectionAction<LibContentItem>(
        icon: const Icon(Icons.delete_outline),
        label: getLocalizations(context).lib_delete_action,
        onPressed: (ctx, selected) async {
          final confirmed = await _confirmDeleteIfNeeded(ctx);
          if (!confirmed) return false;

          await _handleDeleteSelection(selected.toList());
          await _store.refresh();
          return true;
        },
      ),
    ];
  }

  // --- DELETE LOGIC ---

  Future<bool> _confirmDeleteIfNeeded(BuildContext context) async {
    if (!_store.state.showDeleteConfirmDialog) return true;

    bool dontShowAgain = false;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        final t = getLocalizations(dialogCtx);
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: Text(t.lib_confirm_delete),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.lib_delete_body),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Checkbox(
                      value: dontShowAgain,
                      onChanged: (v) => setDialogState(() {
                        dontShowAgain = v ?? false;
                      }),
                    ),
                    Flexible(
                      child: Text(t.lib_dont_show_again),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, false),
                child: Text(t.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, true),
                child: Text(t.lib_delete_action,
                    style: const TextStyle(color: Colors.red)),
              ),
            ],
          ),
        );
      },
    );

    if (dontShowAgain) {
      await _store.updateShowDeleteConfirmDialog(false);
    }

    return result == true;
  }

  Future<void> _handleDeleteSelection(List<LibContentItem> items) async {
    final sourcesToDelete = <SourceLibContentItem>[];
    final nodesToDelete = <NodeLibContentItem>[];

    for (final item in items) {
      if (item is SourceLibContentItem) {
        sourcesToDelete.add(item);
      } else if (item is NodeLibContentItem) {
        nodesToDelete.add(item);
      }
    }

    for (final src in sourcesToDelete) {
      await _deleteSourceWithCoverageCheck(src.source);
    }

    final nodesDao = DbModule.mediaNodesDao;
    for (final nodeItem in nodesToDelete) {
      final node = nodeItem.node;
      final path = node.path.join('/');
      if (node.isDir) {
        try {
          await nodesDao.deleteByPathPrefix(node.storageId, path);
        } catch (_) {}
      } else {
        try {
          await nodesDao.deleteNode(node.storageId, path);
        } catch (_) {}
      }
    }
  }

  Future<void> _deleteSourceWithCoverageCheck(MediaLibrarySource source) async {
    final nodesDao = DbModule.mediaNodesDao;
    final sourcesDao = DbModule.mediaLibSourcesDao;

    // Sources are keyed by entry id, but nodes are shared by data scope: a
    // sibling entry linked into the same scope may still need these nodes, so
    // coverage must be judged across every entry sharing the scope.
    final scope = StorageScope.of(source.storageId);
    final scopedStorageIds = <String>{
      source.storageId,
      for (final storage in useStorageStore().state.storages)
        if (StorageScope.of(storage.id) == scope) storage.id,
    };
    final allSiblingSources = <MediaLibSourcesTableData>[];
    for (final storageId in scopedStorageIds) {
      allSiblingSources.addAll(await sourcesDao.getByStorageId(storageId));
    }
    final otherSources =
        allSiblingSources.where((s) => s.id != source.id).toList();

    final sourcePath = source.path?.join('/') ?? '';

    // Ancestor / equal / full-storage siblings fully cover the range and
    // descendant siblings need a subset, so nodes are only dropped when no
    // surviving source references the range (see resolveSourceDeleteNodeAction).
    final action = resolveSourceDeleteNodeAction(
      sourcePath: sourcePath,
      siblingPaths: otherSources.map((s) => s.path),
    );

    switch (action) {
      case SourceDeleteNodeAction.keep:
        break;
      case SourceDeleteNodeAction.deleteRange:
        await nodesDao.deleteByPathPrefix(source.storageId, sourcePath);
      case SourceDeleteNodeAction.deleteStorage:
        await nodesDao.deleteByStorage(source.storageId);
    }

    await sourcesDao.deleteSource(source.id);
  }

  // --- TRAILING ACTIONS ---

  /// F-004 (D25): scenario-branch Override for a single trailing item —
  /// file-kind sources/files reuse the click semantics; dirs and non-file
  /// sources override as recursive sources. Returns the helper result.
  Future<NoMediaActionResult> _trailingOverrideScenario(
      BuildContext ctx, LibContentItem item) async {
    final sortField =
        ScenarioPlaybackActions.scenarioSortFieldFromMedia(_store.state.sortField);
    final sortDirection = _store.state.sortDirection;

    if (item is SourceLibContentItem) {
      final source = item.source;
      if (source.kind == MediaSourceKind.file) {
        // D25: file-kind source → file semantics (click-like).
        return _playScenarioScopeFromSourceFile(ctx, source);
      }
      return ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
        ctx,
        action: ({bool force = false}) =>
            ScenarioPlaybackActions.playSelectionInDefaultScenario(
          files: const [],
          directories: [
            (
              storageId: source.storageId,
              path: source.path?.join('/') ?? '',
              recursive: true,
              kind: ScenarioSourceKind.folder,
            ),
          ],
          sortField: sortField,
          sortDirection: sortDirection,
          force: force,
          gateContext: ctx,
        ),
      );
    }

    if (item is NodeLibContentItem) {
      final node = item.node;
      if (node.isDir) {
        return ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
          ctx,
          action: ({bool force = false}) =>
              ScenarioPlaybackActions.playSelectionInDefaultScenario(
            files: const [],
            directories: [
              (
                storageId: node.storageId,
                path: node.path.join('/'),
                recursive: true,
                kind: ScenarioSourceKind.folder,
              ),
            ],
            sortField: sortField,
            sortDirection: sortDirection,
            force: force,
            gateContext: ctx,
          ),
        );
      }
      final fileItem = _mediaFileToFileItem(node as MediaFile);
      return _playScenarioScope(ctx, item, fileItem);
    }
    return NoMediaActionResult.cancelled;
  }

  /// F-004/D25: scenario-branch Append for a single trailing item — files /
  /// file-kind sources append as single explicit items; dirs / non-file
  /// sources append as recursive sources.
  Future<void> _trailingAppendScenario(BuildContext ctx, LibContentItem item) async {
    if (item is SourceLibContentItem) {
      final source = item.source;
      if (source.kind == MediaSourceKind.file) {
        final fileItem = await _fileItemForSource(ctx, source);
        if (!ctx.mounted) return;
        await ScenarioPlaybackActions.appendToDefaultScenarioWithFeedback(
          ctx,
          [fileItem],
        );
        return;
      }
      await ScenarioPlaybackActions.appendToDefaultScenarioWithFeedback(
        ctx,
        const [],
        directories: [
          (
            storageId: source.storageId,
            path: source.path?.join('/') ?? '',
            recursive: true,
            kind: ScenarioSourceKind.folder,
          ),
        ],
      );
      return;
    }
    if (item is NodeLibContentItem) {
      final node = item.node;
      if (node.isDir) {
        await ScenarioPlaybackActions.appendToDefaultScenarioWithFeedback(
          ctx,
          const [],
          directories: [
            (
              storageId: node.storageId,
              path: node.path.join('/'),
              recursive: true,
              kind: ScenarioSourceKind.folder,
            ),
          ],
        );
        return;
      }
      await ScenarioPlaybackActions.appendToDefaultScenarioWithFeedback(
        ctx,
        [_mediaFileToFileItem(node as MediaFile)],
      );
    }
  }

  /// Plays a file-kind [source] through the click semantics: the source file
  /// is resolved against `media_nodes`; when present it is played as a
  /// [NodeLibContentItem] via [_playScenarioScope]; when missing it falls back
  /// to a single-explicit override (No Media confirm when nothing plays).
  Future<NoMediaActionResult> _playScenarioScopeFromSourceFile(
      BuildContext ctx, MediaLibrarySource source) async {
    final segments =
        (source.path ?? const <String>[]).where((s) => s.isNotEmpty).toList();
    final node = await DbModule.mediaNodeRepo.getNodeByPath(
      storageId: source.storageId,
      path: segments,
    );
    if (!ctx.mounted) return NoMediaActionResult.cancelled;
    if (node != null && node.isFile) {
      final fileItem = _mediaFileToFileItem(node as MediaFile);
      return _playScenarioScope(ctx, NodeLibContentItem(node), fileItem);
    }
    return ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
      ctx,
      action: ({bool force = false}) =>
          ScenarioPlaybackActions.playSelectionInDefaultScenario(
        files: [
          FileItem(
            storageId: source.storageId,
            name: segments.isNotEmpty ? segments.last : 'unknown',
            uri: playableUri(segments),
            path: segments,
            size: 0,
            type: ContentType.other,
          ),
        ],
        directories: const [],
        sortField: ScenarioPlaybackActions.scenarioSortFieldFromMedia(
            _store.state.sortField),
        sortDirection: _store.state.sortDirection,
        force: force,
      ),
    );
  }

  Future<FileItem> _fileItemForSource(
      BuildContext ctx, MediaLibrarySource source) async {
    final segments =
        (source.path ?? const <String>[]).where((s) => s.isNotEmpty).toList();
    final node = await DbModule.mediaNodeRepo.getNodeByPath(
      storageId: source.storageId,
      path: segments,
    );
    if (node != null && node.isFile) {
      return _mediaFileToFileItem(node as MediaFile);
    }
    return FileItem(
      storageId: source.storageId,
      name: segments.isNotEmpty ? segments.last : 'unknown',
      uri: playableUri(segments),
      path: segments,
      size: 0,
      type: ContentType.other,
    );
  }

  @override
  List<GenericItemAction<LibContentItem>> getItemTrailingActions(
    BuildContext context,
    LibContentItem item,
  ) {
    // Offline-grey: queueing a row needs its live files, so rows on a
    // disconnected storage get disabled play entries (dirs included — tapping
    // a dir still browses the snapshot, but queueing it needs the live
    // tree). Rename / delete-source / add-as-source / info are pure local-DB
    // ops and stay enabled. One-shot read: the tile already subscribes to
    // connectivity via isItemUnavailable, so this re-reads fresh on rebuild.
    final rowOnline = _isStorageOnlineSync(_storageIdOf(item));
    return [
      GenericItemAction(
        label: getLocalizations(context).lib_override_queue,
        icon: const Icon(Icons.playlist_play, size: 16),
        enabled: rowOnline,
        onPressed: (ctx, i) async {
          if (_useScenarioMode) {
            // F-004 (BUG-1): scenario branch FIRST — files reuse the click
            // semantics, dir/source override as recursive sources; failures
            // route through the No Media helper (D15) and success closes the
            // popup unless pinned (D33).
            final navigator = Navigator.of(ctx);
            final stay = usePlaybackScenarioStore().storagesDbStayOnPlay;
            final result = await _trailingOverrideScenario(ctx, i);
            if (result == NoMediaActionResult.success) {
              if (navigator.mounted && !stay && navigator.canPop()) {
                navigator.pop();
              }
            }
            return;
          }
          final files = await _gatherMediaFiles([i]);
          // The popup may have been dismissed while gathering.
          if (!ctx.mounted) return;
          if (files.isEmpty) {
            await showDialog(
              context: ctx,
              builder: (dialogCtx) {
                final t = getLocalizations(dialogCtx);
                return AlertDialog(
                  title: Text(t.lib_no_media),
                  content: Text(t.lib_no_media_found),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogCtx),
                      child: Text(t.ok),
                    ),
                  ],
                );
              },
            );
            return;
          }
          final fileItems = files.map((f) => _mediaFileToFileItem(f)).toList();
          final playQueue = fileItems
              .asMap()
              .entries
              .map((e) => PlayQueueItem(file: e.value, index: e.key))
              .toList();
          usePlayQueueStore().setSource(
            PlayQueueSource.explicit(items: playQueue),
            initialPos: 0,
          );
        },
      ),
      GenericItemAction(
        label: getLocalizations(context).lib_append_queue,
        icon: const Icon(Icons.playlist_add, size: 16),
        enabled: rowOnline,
        onPressed: (ctx, i) async {
          if (_useScenarioMode) {
            if (!ctx.mounted) return;
            await _trailingAppendScenario(ctx, i);
            return;
          }
          final files = await _gatherMediaFiles([i]);
          // The popup may have been dismissed while gathering.
          if (!ctx.mounted) return;
          if (files.isEmpty) {
            await showDialog(
              context: ctx,
              builder: (dialogCtx) {
                final t = getLocalizations(dialogCtx);
                return AlertDialog(
                  title: Text(t.lib_no_media),
                  content: Text(t.lib_no_media_found),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogCtx),
                      child: Text(t.ok),
                    ),
                  ],
                );
              },
            );
            return;
          }
          final fileItems = files.map((f) => _mediaFileToFileItem(f)).toList();
          final prepend = await showAppendQueueDialog(ctx);
          if (prepend != null) {
            // v14-D2: append with a before/after feedback dialog.
            if (!ctx.mounted) return;
            await appendToPlayQueueWithFeedback(
              ctx,
              files: fileItems,
              prepend: prepend,
            );
          }
        },
      ),
      if (item is SourceLibContentItem) ...[
        GenericItemAction(
          label: getLocalizations(context).lib_rename,
          icon: const Icon(Icons.edit, size: 16),
          onPressed: (ctx, i) async {
            final source = (i as SourceLibContentItem).source;
            final t = getLocalizations(ctx);
            final newName = await showKeyboardTextPrompt(
              context: ctx,
              title: t.lib_rename,
              initialValue: i.title,
              label: t.lib_new_name_label,
              confirmLabel: t.lib_rename,
              cancelLabel: t.cancel,
            );
            if (newName != null && newName.isNotEmpty) {
              await DbModule.sourcesRepository.updateSource(
                source.copyWith(name: newName),
              );
              await _store.refresh();
            }
          },
        ),
        GenericItemAction(
          label: getLocalizations(context).lib_delete_action,
          icon: const Icon(Icons.delete, color: Colors.red, size: 16),
          onPressed: (ctx, i) async {
            final source = (i as SourceLibContentItem).source;
            final confirmed = await showDialog<bool>(
              context: ctx,
              builder: (dialogCtx) {
                final t = getLocalizations(dialogCtx);
                return AlertDialog(
                  title: Text(t.lib_confirm_delete),
                  content: Text(t.lib_delete_source_body(i.title)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogCtx, false),
                      child: Text(t.cancel),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(dialogCtx, true),
                      child: Text(t.lib_delete_action,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  ],
                );
              },
            );
            if (confirmed == true) {
              await DbModule.sourcesRepository.removeSource(source.id);
              await _store.refresh();
            }
          },
        ),
      ],
      GenericItemAction(
        label: getLocalizations(context).lib_add_as_source,
        icon: const Icon(Icons.library_add, size: 16),
        onPressed: (ctx, i) => _addAsSourceToLibrary(ctx, [i]),
      ),
      // Folder quick-adds: a DB directory node becomes a virtual-merge rule,
      // prefilled with storage+folder defaults.
      if (item is NodeLibContentItem && item.node.isDir) ...[
        if (VirtualMediaGate.enabled)
          GenericItemAction(
            label: getLocalizations(context).lib_add_as_vm_merge,
            icon: const Icon(Icons.merge_type, size: 16),
            onPressed: (ctx, i) {
              final node = (i as NodeLibContentItem).node;
              final storage = _lookupStorage(node.storageId);
              openVmRuleEditorForFolder(
                ctx,
                storageName: storage?.name ?? node.storageId,
                folderName: node.name,
                folderPath: relativeToStoragePath(
                  node.path.join('/'),
                  [storage?.basePath.join('/') ?? ''],
                ),
              );
            },
          ),
      ],
      // Windows desktop: hand the row to Explorer. Built from the same node →
      // FileItem projection the tile already uses, so the entry matches the
      // rest of the row's identity; empty off-Windows or for remote rows.
      ...buildExplorerRevealActions<LibContentItem>(
        context: context,
        item: item,
        fileOf: _libContentRevealFile,
      ),
      GenericItemAction(
        label: getLocalizations(context).lib_info_action,
        icon: const Icon(Icons.info_outline, size: 16),
        onPressed: (ctx, i) {
          showDialog(
            context: ctx,
            builder: (dialogCtx) => buildTileInfoDialog(dialogCtx, i),
          );
        },
      ),
    ];
  }

  // --- ADD AS SOURCE ---

  Future<void> _addAsSourceToLibrary(
    BuildContext context,
    List<LibContentItem> items,
  ) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final targetId = await showAddToLibraryDialog(context);
    if (targetId == null) return;

    final now = DateTime.now();
    final ts = '${now.year}-${_pad2(now.month)}-${_pad2(now.day)} '
        '${_pad2(now.hour)}:${_pad2(now.minute)}:${_pad2(now.second)}';

    final sources = <MediaLibrarySource>[];
    for (final item in items) {
      if (item is SourceLibContentItem) {
        sources.add(
          item.source.copyWith(
            id: 0,
            libraryId: targetId,
            name: item.source.name ?? '${item.title}_$ts',
          ),
        );
      } else if (item is NodeLibContentItem) {
        final node = item.node;
        sources.add(
          MediaLibrarySource(
            id: 0,
            libraryId: targetId,
            storageId: node.storageId,
            path: node.path,
            name: '${node.name}_$ts',
            pathDepth: node.path.length,
            kind: node.isDir ? MediaSourceKind.directory : MediaSourceKind.file,
          ),
        );
      }
    }

    if (sources.isEmpty) return;

    final added = await addSourcesToLibrary(
      targetLibraryId: targetId,
      sources: sources,
    );

    await showMessageDialog(
      navigator,
      message: 'Added $added source(s) to library',
      type: MessageDialogType.success,
    );
  }

  // --- HELPER: MediaFile -> FileItem ---

  FileItem _mediaFileToFileItem(MediaFile file) {
    final storage = _lookupStorage(file.storageId);
    final uri = mediaNodePlayableUri(storage, file.path, uri: file.uri);

    final contentType = file.mediaType == MediaType.video
        ? ContentType.video
        : file.mediaType == MediaType.audio
            ? ContentType.audio
            : ContentType.other;

    return FileItem(
      storageId: file.storageId,
      storageType: storage?.type ?? StorageType.none,
      name: file.name,
      uri: uri,
      path: file.path,
      size: file.sizeInBytes ?? 0,
      durationMs: file.durationMs,
      lastModified: file.modifiedAt,
      type: contentType,
      // Subtitle associations persisted at scan time (schema v50).
      subtitles: file.subtitles ?? const [],
    );
  }

  Storage? _lookupStorage(String storageId) {
    // A shared-scope node stores its scope id; prefer the entry currently being
    // browsed (freshest resolved host) and fall back across the scope.
    return useStorageStore().resolveStorageForNodeId(
      storageId,
      viewingId: _store.state.currentStorageId,
    );
  }

  /// Projects a library row to the [FileItem] the "Open in Explorer" action
  /// needs, or null when the row has no on-disk identity (a source with no
  /// resolvable storage, an unknown subclass).
  FileItem? _libContentRevealFile(LibContentItem item) {
    if (item is NodeLibContentItem) {
      final node = item.node;
      if (node.isDir) {
        final storage = _lookupStorage(node.storageId);
        return FileItem(
          storageId: node.storageId,
          storageType: storage?.type ?? StorageType.none,
          name: node.name,
          uri: mediaNodePlayableUri(storage, node.path),
          path: node.path,
          isDir: true,
          type: ContentType.other,
        );
      }
      return _mediaFileToFileItem(node as MediaFile);
    }
    if (item is SourceLibContentItem) {
      final source = item.source;
      final storage = _lookupStorage(source.storageId);
      if (storage == null) return null;
      final segments = (source.path ?? const <String>[])
          .where((s) => s.isNotEmpty)
          .toList();
      if (segments.isEmpty) return null;
      return FileItem(
        storageId: source.storageId,
        storageType: storage.type,
        name: item.title,
        uri: mediaNodePlayableUri(storage, segments),
        path: segments,
        isDir: true,
        type: ContentType.other,
      );
    }
    return null;
  }

  // --- HELPER: Gather media files recursively ---

  Future<List<MediaFile>> _gatherMediaFiles(List<LibContentItem> items) async {
    return _store.gatherAllMediaFiles(items);
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');
}

/// Immutable view of every value the page reads from [LibContentDataSource].
///
/// Equality drives whether a store emission reaches the page: two emissions
/// with the same snapshot are collapsed. The item list is compared by content
/// (freezed's deep equality) rather than identity, because the store may hand
/// back an equal-but-new list on every emission.
class _PageSnapshot {
  final String loadState;
  final int currentPage;
  final int totalPages;
  final int totalItems;
  final Object? error;
  final List<LibContentItem> items;
  final int pageSize;
  final String viewMode;
  final List<String>? breadcrumbs;

  const _PageSnapshot({
    required this.loadState,
    required this.currentPage,
    required this.totalPages,
    required this.totalItems,
    required this.error,
    required this.items,
    required this.pageSize,
    required this.viewMode,
    required this.breadcrumbs,
  });

  factory _PageSnapshot.of(LibContentDataSource ds) {
    final rt = ds._rt;
    return _PageSnapshot(
      loadState: rt.state.name,
      currentPage: rt.currentPage,
      totalPages: rt.totalPages,
      totalItems: rt.totalItems,
      error: rt.error,
      items: rt.items,
      pageSize: ds._store.state.pageSize,
      viewMode: ds._store.state.viewMode.name,
      breadcrumbs: ds.currentBreadcrumbs,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _PageSnapshot &&
        other.loadState == loadState &&
        other.currentPage == currentPage &&
        other.totalPages == totalPages &&
        other.totalItems == totalItems &&
        other.error == error &&
        other.pageSize == pageSize &&
        other.viewMode == viewMode &&
        listEquals(other.breadcrumbs, breadcrumbs) &&
        _sameItems(other.items, items);
  }

  static bool _sameItems(List<LibContentItem> a, List<LibContentItem> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        loadState,
        currentPage,
        totalPages,
        totalItems,
        error,
        pageSize,
        viewMode,
        Object.hashAll(breadcrumbs ?? const []),
        items.length,
      );

  @override
  String toString() =>
      'state=$loadState page=$currentPage/$totalPages total=$totalItems '
      'items=${items.length} pageSize=$pageSize mode=$viewMode';
}


