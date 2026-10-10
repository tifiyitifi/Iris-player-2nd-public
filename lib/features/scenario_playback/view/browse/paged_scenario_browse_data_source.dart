import 'dart:async';

import 'package:flutter/material.dart';
import 'package:iris/features/background_playback/background_playback_gate.dart';
import 'package:iris/features/background_playback/view/bg_source_rule_editor.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_result.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/features/media_library/search/model/search_context.dart';
import 'package:iris/features/meta_settings/engine/browse_scope_snapshot.dart'
    show currentBrowseScopeMediaTypes;
import 'package:iris/features/media_library/search/model/search_scope.dart';
import 'package:iris/features/media_library/search/store/search_browser_store.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_actions.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/store/playback_scenario_store_state.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/coordinator/scenario_browser_store.dart';
import 'package:iris/features/virtual_media/commands/vm_actions.dart';
import 'package:iris/features/virtual_media/vm_gate.dart';
import 'package:iris/features/windows/explorer/menu/explorer_reveal_action.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';

enum ScenarioBrowseItemKind { storage, directory, file }

/// A browsable entry: a storage, a directory node or a media file node.
class ScenarioBrowseItem {
  final ScenarioBrowseItemKind kind;
  final String storageId;
  final String path;
  final String name;

  const ScenarioBrowseItem({
    required this.kind,
    required this.storageId,
    required this.path,
    required this.name,
  });

  String get id => '${kind.name}_$storageId:$path';
}

/// Directory Explorer sub-interface of the scenario browser.
///
/// Browses the media database tree (storages -> folders -> files) with
/// actions to set a folder as a source, add a file as an explicit include,
/// or exclude a folder/file. State (current storage/path) is owned here.
class PagedScenarioBrowseDataSource
    extends PaginatedBrowserDataSource<ScenarioBrowseItem> {
  int _currentPage = 0;
  bool _isLoading = false;
  bool _isError = false;
  List<ScenarioBrowseItem> _items = [];
  int _totalItems = 0;

  /// Last seen persisted page size (reactivity filter for the scenario store).
  late int _lastPageSize;
  StreamSubscription<PlaybackScenarioStoreState>? _storeSub;

  /// Selected storage; null means the storage list is shown.
  String? _storageId;

  /// Storage-relative path of the browsed directory; null = storage root.
  String? _parentPath;

  final String scenarioId;

  /// When seeded from a Layer-1 source/exclude, the browse starts directly at
  /// [initialStorageId]/[initialPath] instead of the storage list.
  final String? initialStorageId;
  final String? initialPath;

  /// True when this browse was entered from a Layer-1 source/exclude (seeded).
  late final bool _seeded;

  /// The storage-relative path at the Layer-2 entry point. Back at this level
  /// returns directly to the source/exclude list.
  late final String? _seedPath;

  /// Display breadcrumb segments after "Sources" — the seed folder name plus
  /// the drilled-in subdirectories. The storage mount prefix is intentionally
  /// omitted (user spec: `sources › folderName › subdir › …`). Mutable: the
  /// non-seeded entry (constructor) and a later back-to-storage-list both
  /// (re)initialize it.
  late List<String> _crumbTail;

  /// Number of non-empty path segments in [_parentPath] that precede the crumb
  /// tail (the seed folder's ancestors). Constant per browse session.
  late int _baseSegmentCount;

  /// Position to restore when returning from the search page (v5-D1/v6-D2):
  /// storageId + parentPath + crumbTail + baseSegmentCount + seedPath + seeded.
  final BrowseReturnPosition? restorePosition;

  /// True when this data source belongs to a `modeQueueOverride` browser
  /// (floating queue popup / docked panel). Passed explicitly by the owning
  /// page instead of reading the global
  /// [ScenarioBrowserStore.queueOverrideActive], which is set by ANY mounted
  /// queue-override browser (e.g. the always-on Windows dock).
  final bool queueOverride;

  /// Leaves the scenario manager after the Play action starts playback (the
  /// video must be directly visible). Supplied by the owning page — embedded
  /// storagedb / dock exit differs from a standalone popup.
  final VoidCallback? onExitAfterPlay;

  PagedScenarioBrowseDataSource({
    required this.scenarioId,
    this.initialStorageId,
    this.initialPath,
    this.restorePosition,
    this.queueOverride = false,
    this.onExitAfterPlay,
  }) {
    _lastPageSize = _store.state.scenarioManagePageSize;
    _storeSub = _store.stream.listen((state) {
      if (state.scenarioManagePageSize != _lastPageSize) {
        _lastPageSize = state.scenarioManagePageSize;
        notifyListeners();
      }
    });
    final restore = restorePosition;
    if (restore != null) {
      _storageId = restore.storageId;
      _parentPath = restore.parentPath;
      _crumbTail = List.of(restore.crumbTail);
      _baseSegmentCount = restore.baseSegmentCount;
      _seeded = restore.seeded;
      _seedPath = restore.seedPath;
      _loadDirectory(0, pageSize);
      return;
    }
    _seeded = initialStorageId != null;
    _seedPath = initialPath;
    _crumbTail = <String>[];
    _baseSegmentCount = 0;
    if (_seeded) {
      _storageId = initialStorageId;
      _parentPath = initialPath;
      final seed = initialPath;
      final seedSegs = seed == null ? <String>[] : _splitPath(seed);
      if (seedSegs.isNotEmpty) {
        _crumbTail.add(seedSegs.last);
        _baseSegmentCount = seedSegs.length - 1;
      }
      _loadDirectory(0, pageSize);
    } else {
      _loadStorages();
    }
  }

  @override
  void dispose() {
    _storeSub?.cancel();
    super.dispose();
  }

  PlaybackScenarioStore get _store => usePlaybackScenarioStore();

  static List<String> _splitPath(String path) =>
      // SAF-aware: a `content://.../tree/...` prefix stays one segment so
      // the sealed base count never splits the URI scheme (`emulated`-style
      // leak inside the URI is impossible).
      pathConv(path);

  String? get currentStorageId => _storageId;

  String? get currentParentPath => _parentPath;

  /// v6-D3: read-only position getters for the search-entry snapshot.
  bool get seeded => _seeded;
  String? get seedPath => _seedPath;
  List<String> get crumbTail => List.unmodifiable(_crumbTail);
  int get baseSegmentCount => _baseSegmentCount;

  Future<void> _loadStorages() async {
    _storageId = null;
    _parentPath = null;
    _crumbTail = <String>[];
    _baseSegmentCount = 0;
    _isLoading = true;
    _isError = false;
    notifyListeners();
    final storages = useStorageStore().state.storages;
    _items = storages
        .map((s) => ScenarioBrowseItem(
              kind: ScenarioBrowseItemKind.storage,
              storageId: s.id,
              path: '',
              name: s.name,
            ))
        .toList();
    _totalItems = _items.length;
    _currentPage = 0;
    _isLoading = false;
    notifyListeners();
  }

  Future<void> _loadDirectory(int page, int pageSize) async {
    final storageId = _storageId;
    if (storageId == null) return;
    _isLoading = true;
    _isError = false;
    _currentPage = page;
    notifyListeners();
    try {
      final result = await DbModule.mediaNodeRepo.getDirectoryChildren(
        storageId: storageId,
        parentPath: _parentPath,
        page: page + 1,
        pageSize: pageSize,
        sortField: MediaSortField.name,
        sortDirection: SortDirection.asc,
        folderFirst: true,
        // Mixed listing: the DAO scopes dirs via EXISTS and files via IN.
        mediaTypes: currentBrowseScopeMediaTypes(),
      );
      _applyPageResult(result);
    } catch (e) {
      _isError = true;
    }
    _isLoading = false;
    notifyListeners();
  }

  void _applyPageResult(MediaNodePageResult result) {
    _items = result.items.map((node) {
      final isDir = node.isDir;
      final path = node.path.join('/');
      return ScenarioBrowseItem(
        kind: isDir
            ? ScenarioBrowseItemKind.directory
            : ScenarioBrowseItemKind.file,
        storageId: node.storageId,
        path: path,
        name: node.name,
      );
    }).toList();
    _totalItems = result.totalItems;
  }

  void enterStorage(String storageId) {
    _storageId = storageId;
    _parentPath = null;
    _crumbTail = <String>[];
    final storage = useStorageStore().findById(storageId);
    _baseSegmentCount = _splitPath(storage?.basePath.join('/') ?? '').length;
    _loadDirectory(0, pageSize);
  }

  void enterDirectory(String path, {String? name}) {
    _parentPath = path;
    final segs = _splitPath(path);
    _crumbTail.add(name ?? (segs.isEmpty ? path : segs.last));
    _loadDirectory(0, pageSize);
  }

  @override
  int get totalItems => _totalItems;

  @override
  int get currentPage => _currentPage;

  @override
  int get totalPages => (totalItems / pageSize).ceil().clamp(1, 99999);

  /// Persisted per-surface page size (source of truth: the scenario store).
  @override
  int get pageSize => _store.state.scenarioManagePageSize;

  @override
  bool get isLoading => _isLoading;

  @override
  bool get isError => _isError;

  @override
  List<ScenarioBrowseItem> get items => _items;

  @override
  String getItemId(ScenarioBrowseItem item) => item.id;

  @override
  Future<void> fetchPage(int targetPage, int currentSize) async {
    if (_storageId == null) {
      _currentPage = targetPage;
      notifyListeners();
      return;
    }
    await _loadDirectory(targetPage, currentSize);
  }

  @override
  Future<void> changePageSize(int newSize) async {
    if (newSize < 1) return;
    newSize = clampPageSize(newSize);
    await _store.updateScenarioManagePageSize(newSize);
    await fetchPage(0, pageSize);
  }

  @override
  Future<void> changeSort(SortOption sortOption) async {}

  @override
  Future<bool> handleNavigationBack() async {
    if (_storageId == null) {
      // Back at the storage list: return to Layer-1 and clear the browse seed.
      final s = useScenarioBrowserStore();
      s.setBrowseSeed(storageId: null, path: null);
      if (queueOverride) {
        s.setQueueOverrideMode(ScenarioBrowserMode.sources);
      } else {
        s.setMode(ScenarioBrowserMode.sources);
      }
      return true;
    }
    if (_seeded && _parentPath == _seedPath) {
      // At the seeded Layer-2 entry point: return DIRECTLY to the
      // source/exclude list (not up the whole path tree).
      final s = useScenarioBrowserStore();
      s.setBrowseSeed(storageId: null, path: null);
      if (queueOverride) {
        s.setQueueOverrideMode(ScenarioBrowserMode.sources);
      } else {
        s.setMode(ScenarioBrowserMode.sources);
      }
      return true;
    }
    if (_parentPath == null) {
      await _loadStorages();
      return true;
    }
    final segments = pathConv(_parentPath!);
    final up = segments.length <= 1
        ? null
        : segments.sublist(0, segments.length - 1).join('/');
    _parentPath = up;
    if (_crumbTail.isNotEmpty) _crumbTail.removeLast();
    await _loadDirectory(0, pageSize);
    return true;
  }

  @override
  Future<void> handleNavigationHome() async {}

  @override
  Future<void> navigateToCrumb(int index) async {
    if (index == 0) {
      // "Sources" crumb → back to the source/exclude list.
      final s = useScenarioBrowserStore();
      s.setBrowseSeed(storageId: null, path: null);
      if (queueOverride) {
        s.setQueueOverrideMode(ScenarioBrowserMode.sources);
      } else {
        s.setMode(ScenarioBrowserMode.sources);
      }
      return;
    }
    if (_storageId == null || index > _crumbTail.length) return;
    // Reconstruct the internal path preserving its exact format (the DAO
    // matches parentPath exactly), then trim the crumb tail.
    final target = _truncatePath(_parentPath, _baseSegmentCount + index);
    if (target == null || target == _parentPath) return;
    _parentPath = target;
    _crumbTail = _crumbTail.sublist(0, index);
    await _loadDirectory(0, pageSize);
  }

  /// Keeps the first [keep] path segments of [path], preserving the
  /// leading-slash / SAF format so the DB query still matches.
  static String? _truncatePath(String? path, int keep) {
    if (path == null) return null;
    final segs = pathConv(path);
    if (segs.length <= keep) return path;
    final head = segs.sublist(0, keep);
    // pathConv is SAF-aware (tree prefix = 1 segment); joining the kept
    // segments can never cut inside the `content://` scheme.
    if (isSafPathSegments(head)) return safJoin(head);
    final joined = head.join('/');
    return path.startsWith('/') ? '/$joined' : joined;
  }

  @override
  bool get supportsSearch => false;

  @override
  Future<void> openSearchDialog(
      BuildContext scenario, VoidCallback onSearchInitiated) async {}

  @override
  bool handleItemTap(BuildContext scenario, ScenarioBrowseItem item) {
    switch (item.kind) {
      case ScenarioBrowseItemKind.storage:
        enterStorage(item.storageId);
        return true;
      case ScenarioBrowseItemKind.directory:
        enterDirectory(item.path, name: item.name);
        return true;
      case ScenarioBrowseItemKind.file:
        _playBrowseMedia(scenario, item);
        return true;
    }
  }

  /// Plays a media file like a files-paged tap (origin/version guarded).
  Future<void> _playBrowseMedia(
      BuildContext scenario, ScenarioBrowseItem item) async {
    final resolved = await _store.resolveItemByOccurrence(
      scenarioId: scenarioId,
      occurrence: PlaybackOccurrenceId(
        storageId: item.storageId,
        path: item.path,
      ),
    );
    if (resolved == null) return;
    if (!scenario.mounted) return;
    await ScenarioPlaybackActions.playResolvedItem(
      scenario,
      store: _store,
      scenarioId: scenarioId,
      item: resolved,
    );
  }

  @override
  Widget buildTileInfoDialog(BuildContext scenario, ScenarioBrowseItem item) {
    return AlertDialog(
      title: Text(item.name),
      content: Text(getLocalizations(scenario)
          .browse_path(item.path.isEmpty ? '/' : item.path)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(scenario),
          child: Text(getLocalizations(scenario).close),
        ),
      ],
    );
  }

  @override
  Widget? buildItemLeading(BuildContext scenario, ScenarioBrowseItem item) {
    final index = _items.indexOf(item);
    final number = _currentPage * pageSize + index + 1;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 16),
      child: Text(
        '$number',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 14),
      ),
    );
  }

  @override
  String? buildItemTitle(ScenarioBrowseItem item) => item.name;

  @override
  Widget? buildItemSubtitle(BuildContext scenario, ScenarioBrowseItem item) {
    if (item.kind == ScenarioBrowseItemKind.storage) return null;
    // Sealed display: show only the tail relative to the current browse
    // position, never the absolute mount prefix (`emulated / 0`).
    final segs = pathConv(item.path);
    final parent = segs.length <= 1 ? const <String>[] : segs.sublist(0, segs.length - 1);
    final tail = parent.length <= 2 ? parent : parent.sublist(parent.length - 2);
    return Text(tail.isEmpty ? '/' : tail.join('/'));
  }

  @override
  List<String>? get currentBreadcrumbs => <String>['Sources', ..._crumbTail];

  @override
  bool get isRightToLeftBreadcrumbs => false;

  @override
  Widget? buildTileContent(BuildContext scenario, ScenarioBrowseItem item) =>
      null;

  @override
  Widget buildSortMenu(BuildContext scenario) => const SizedBox.shrink();

  @override
  List<PageAction> buildCustomPageActions(BuildContext context) {
    // Offline-grey audit: search snapshots the saved config (no live
    // listing), so it stays enabled while offline.
    return <PageAction>[
      // Play the scenario currently being managed (SystemPlaying / saved /
      // entry workspace). Direct when it is the live workspace, else Override.
      PageAction(
        icon: const Icon(Icons.play_arrow_rounded, size: 18),
        label: getLocalizations(context).play,
        onPressed: () => ScenarioPlaybackActions.playManagedScenario(
          context,
          scenarioId: scenarioId,
          onExitAfterPlay: onExitAfterPlay,
        ),
      ),
      // F-001: unconditional search entry (root / storage level / concrete dir).
      PageAction(
        icon: const Icon(Icons.search, size: 18),
        label: getLocalizations(context).browse_search,
        onPressed: () => _openSearch(context),
      ),
    ];
  }

  /// Search entry (F-001): snapshots the browse position (live getters,
  /// v5-D1/v6-D3) and scenario sources/explicit items, then switches mode.
  /// Browse at the storage-list root snapshots no position (→ allSources
  /// fallback on return, D1).
  Future<void> _openSearch(BuildContext context) async {
    final sources = await _store.getSources(scenarioId);
    final explicitItems = await _store.getExplicitItems(scenarioId);
    final searchSources = <SearchSource>[
      for (final s in sources)
        SearchSource(
          storageId: s.storageId,
          path: s.path.isEmpty ? null : s.path,
          // See paged_scenario_media_data_source: an empty-path folder source
          // must keep its recursion flag, not collapse to whole-storage.
          kind: s.sourceKind == ScenarioSourceKind.file
              ? MediaSourceKind.file
              : MediaSourceKind.directory,
          recursive: s.recursive,
          scenarioSourceId: s.id,
        ),
    ];
    final searchContext = SearchContext(
      entryContext: SearchEntryContext.scenarioBrowse,
      storageId: _storageId,
      parentPath: _parentPath,
      scenarioId: scenarioId,
      sources: searchSources,
      explicitItems: [
        for (final e in explicitItems)
          SearchExplicitItem(storageId: e.storageId, path: e.path),
      ],
    );
    final position = _storageId == null
        ? null
        : BrowseReturnPosition(
            storageId: _storageId!,
            parentPath: _parentPath,
            crumbTail: _crumbTail,
            baseSegmentCount: _baseSegmentCount,
            seedPath: _seedPath,
            seeded: _seeded,
          );
    useSearchBrowserStore().setScenarioBrowseEntry(
      context: searchContext,
      position: position,
    );
    final b = useScenarioBrowserStore();
    if (queueOverride) {
      b.setQueueOverrideMode(ScenarioBrowserMode.search);
    } else {
      b.setMode(ScenarioBrowserMode.search);
    }
  }

  @override
  List<GenericItemAction<ScenarioBrowseItem>> getItemTrailingActions(
    BuildContext scenario,
    ScenarioBrowseItem item,
  ) {
    final t = getLocalizations(scenario);
    final isDir = item.kind == ScenarioBrowseItemKind.directory;
    final isStorage = item.kind == ScenarioBrowseItemKind.storage;
    String storageNameOf(String storageId) =>
        useStorageStore().findById(storageId)?.name ?? storageId;
    // Storage root → '' (whole storage); a directory → its storage-relative
    // canonical path.
    String folderPathOf(ScenarioBrowseItem e) {
      if (e.kind == ScenarioBrowseItemKind.storage) return '';
      final base =
          useStorageStore().findById(e.storageId)?.basePath.join('/') ?? '';
      return relativeToStoragePath(e.path, [base]);
    }

    return [
      if (isStorage || isDir)
        GenericItemAction<ScenarioBrowseItem>(
          label: t.browse_set_source,
          icon: const Icon(Icons.folder_special_outlined, size: 16),
          onPressed: (ctx, i) {
            final e = i as ScenarioBrowseItem;
            _setDirectoryAsSource(isStorage ? '' : e.path);
          },
        ),
      if (isStorage || isDir)
        GenericItemAction<ScenarioBrowseItem>(
          label: t.browse_exclude_dir,
          icon: const Icon(Icons.block, size: 16),
          onPressed: (ctx, i) {
            final e = i as ScenarioBrowseItem;
            _excludeDirectory(isStorage ? '' : e.path);
          },
        ),
      // Folder quick-adds: the storage root / a directory becomes a 副音 source
      // rule / a virtual-merge rule, prefilled with storage+folder defaults.
      if ((isStorage || isDir) && BackgroundPlaybackGate.enabled)
        GenericItemAction<ScenarioBrowseItem>(
          label: t.lib_add_as_bg_source,
          icon: const Icon(Icons.queue_music, size: 16),
          onPressed: (ctx, i) {
            final e = i as ScenarioBrowseItem;
            openBgSourceRuleEditorForFolder(
              ctx,
              storageName: storageNameOf(e.storageId),
              folderName: isStorage ? '' : e.name,
              folderPath: folderPathOf(e),
            );
          },
        ),
      if ((isStorage || isDir) && VirtualMediaGate.enabled)
        GenericItemAction<ScenarioBrowseItem>(
          label: t.lib_add_as_vm_merge,
          icon: const Icon(Icons.merge_type, size: 16),
          onPressed: (ctx, i) {
            final e = i as ScenarioBrowseItem;
            openVmRuleEditorForFolder(
              ctx,
              storageName: storageNameOf(e.storageId),
              folderName: isStorage ? '' : e.name,
              folderPath: folderPathOf(e),
            );
          },
        ),
      if (item.kind == ScenarioBrowseItemKind.file) ...[
        GenericItemAction<ScenarioBrowseItem>(
          label: t.browse_add_scenario,
          icon: const Icon(Icons.add_circle_outline, size: 16),
          onPressed: (ctx, i) {
            final e = i as ScenarioBrowseItem;
            _addExplicitItem(e);
          },
        ),
        GenericItemAction<ScenarioBrowseItem>(
          label: t.browse_exclude_media,
          icon: const Icon(Icons.block, size: 16),
          onPressed: (ctx, i) {
            final e = i as ScenarioBrowseItem;
            _excludeMedia(e);
          },
        ),
      ],
      // Windows desktop: reveal the row's location in Explorer. Storage rows
      // resolve to the mount root; remote storages return nothing.
      ...buildExplorerRevealActions<ScenarioBrowseItem>(
        context: scenario,
        item: item,
        fileOf: _revealFileFor,
      ),
    ];
  }

  @override
  List<CustomSelectionAction<ScenarioBrowseItem>> buildCustomSelectionActions(
      BuildContext scenario) {
    return [];
  }

  /// F-008/BUG-2: the browse page has no selection actions, so multi-select is
  /// disabled entirely (long-press no longer enters a dead selection mode).
  @override
  bool get supportsSelection => false;

  // ── Actions ──

  Future<void> _setDirectoryAsSource(String path) async {
    await _store.addSource(
      storageId: _storageId ?? '',
      path: path,
      recursive: true,
    );
    await _signalDefinitionChanged();
  }

  Future<void> _excludeDirectory(String path) async {
    if (_storageId == null) return;
    await _store.addExcludeRule(
      ScenarioExcludeRule(
        id: 0,
        scenarioId: scenarioId,
        kind: ExcludeRuleKind.directory,
        storageId: _storageId!,
        path: path,
        recursive: true,
      ),
    );
    await _signalDefinitionChanged();
  }

  Future<void> _addExplicitItem(ScenarioBrowseItem item) async {
    await _store.addExplicitItemFor(
      scenarioId: scenarioId,
      storageId: item.storageId,
      path: item.path,
    );
    await _signalDefinitionChanged();
  }

  Future<void> _excludeMedia(ScenarioBrowseItem item) async {
    await _store.addExcludeRule(
      ScenarioExcludeRule(
        id: 0,
        scenarioId: scenarioId,
        kind: ExcludeRuleKind.media,
        storageId: item.storageId,
        path: item.path,
      ),
    );
    await _signalDefinitionChanged();
  }

  /// Projects a browse row to the [FileItem] the "Open in Explorer" action
  /// needs. Directory/file rows carry their full DB path; a storage row has an
  /// empty path and resolves to the mount root.
  FileItem? _revealFileFor(ScenarioBrowseItem item) {
    final storage = useStorageStore().findById(item.storageId);
    if (storage == null) return null;
    final segments =
        item.path.isEmpty ? storage.basePath : pathConv(item.path);
    if (segments.isEmpty) return null;
    final isDir = item.kind != ScenarioBrowseItemKind.file;
    return FileItem(
      storageId: item.storageId,
      storageType: storage.type,
      name: item.name,
      uri: mediaNodePlayableUri(storage, segments),
      path: segments,
      isDir: isDir,
      type: isDir ? ContentType.other : ContentType.video,
    );
  }

  /// A definition edit changes the effective queue: re-validate the current
  /// item when the edited scenario is the active one, then re-resolve the
  /// player chrome and re-fetch any open queue list. Mirrors the Sources /
  /// Manage "Remove" signal so a Browse edit cannot leave the chrome stale.
  Future<void> _signalDefinitionChanged() async {
    if (scenarioId == _store.state.activeScenarioId) {
      await ScenarioPlaybackProvider(store: _store).revalidateCurrent();
    }
    await _store.notifyDefinitionChanged();
  }
}
