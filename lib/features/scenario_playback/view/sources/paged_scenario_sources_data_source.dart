import 'dart:async';

import 'package:flutter/material.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart';
import 'package:iris/features/media_library/search/model/search_context.dart';
import 'package:iris/features/media_library/search/model/search_scope.dart';
import 'package:iris/features/media_library/search/store/search_browser_store.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_explicit_item.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_manage_sort_by.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/actions/scenario_explicit_dedup_actions.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_actions.dart';
import 'package:iris/features/scenario_playback/resolver/explicit_redundancy.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/scan/commands/scenario_source_scan_command.dart';
import 'package:iris/features/scenario_playback/store/playback_scenario_store_state.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/coordinator/scenario_browser.dart';
import 'package:iris/features/scenario_playback/view/coordinator/scenario_browser_store.dart';
import 'package:iris/features/scenario_playback/view/dialogs/show_override_confirm_dialog.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/path_conv.dart';

enum ScenarioManageItemKind { source, exclude, include }

/// Visibility/order groups of the Layer-1 management list (spec §5.7 filter).
enum ScenarioManageGroup {
  dirSources,
  itemSources,
  dirExclude,
  itemExclude;

  String label(AppLocalizations t) => switch (this) {
        ScenarioManageGroup.dirSources => t.scn_group_dir_sources,
        ScenarioManageGroup.itemSources => t.scn_group_item_sources,
        ScenarioManageGroup.dirExclude => t.scn_group_dir_exclude,
        ScenarioManageGroup.itemExclude => t.scn_group_item_exclude,
      };
}

/// A management entry of the Sources sub-interface (a scenario source, an
/// exclude rule or an explicit include).
class ScenarioManageItem {
  final ScenarioManageItemKind kind;
  final ScenarioManageGroup group;
  final int? sourceId;
  final int? ruleId;
  final int? includeId;
  final String title;
  final String subtitle;

  /// Un-prefixed basename used as the sort key (the displayed [title] carries
  /// the type prefix and is not used for sorting, D6).
  final String sortName;

  /// Grouping key for the container-first sort: `$storageId:/<containerPath>`.
  /// File entries use their parent directory; directory entries use their own
  /// directory; whole-storage entries use the storage root (D8).
  final String containerKey;

  /// Resolved storage display name (precomputed at build time so the sort
  /// comparator never hits the storage store, D6).
  final String storageName;

  /// Creation time of the underlying record (source / exclude rule / explicit
  /// item); used by the Created sort field. Null sorts as epoch 0.
  final DateTime? createdAt;

  /// Storage and (storage-relative) path of the entry, when it maps onto a
  /// real location — used to seed the Layer-2 path browse.
  final String? storageId;
  final String? path;

  /// Whether the entry points at a single media file (vs a directory). File
  /// entries browse to their parent folder.
  final bool isFile;

  const ScenarioManageItem({
    required this.kind,
    required this.group,
    this.sourceId,
    this.ruleId,
    this.includeId,
    required this.title,
    required this.subtitle,
    required this.sortName,
    required this.containerKey,
    required this.storageName,
    this.createdAt,
    this.storageId,
    this.path,
    this.isFile = false,
  });

  String get id => '${kind.name}_${sourceId ?? ruleId ?? includeId ?? 0}';
}

/// Position snapshot of the Sources (Layer-1) page, restored when returning
/// from the search page (v5-D1): page number + group filter order/hidden set.
class PagedScenarioSourcesRestore {
  final int page;
  final List<ScenarioManageGroup>? groupOrder;
  final Set<ScenarioManageGroup>? hiddenGroups;

  const PagedScenarioSourcesRestore({
    this.page = 0,
    this.groupOrder,
    this.hiddenGroups,
  });
}

/// Paginated management data source of the Sources sub-interface.
///
/// Groups a scenario's sources, exclude rules and explicit includes into one
/// browsable list. Removing an entry operates on the corresponding record.
/// Layer-1 items are filterable by [ScenarioManageGroup] (spec §5.7) and
/// reordered by dragging inside the filter dialog.
class PagedScenarioSourcesDataSource
    extends PaginatedBrowserDataSource<ScenarioManageItem> {
  int _currentPage = 0;
  bool _isLoading = false;
  bool _isError = false;
  List<ScenarioManageItem> _allItems = [];
  List<ScenarioManageItem> _items = [];
  int _totalItems = 0;

  /// Last seen persisted page size (reactivity filter for the scenario store).
  late int _lastPageSize;
  StreamSubscription<PlaybackScenarioStoreState>? _storeSub;

  /// Visible groups in display order (spec default: dir sources, item
  /// sources, dir exclude, item exclude — all checked).
  List<ScenarioManageGroup> _groupOrder = [
    ScenarioManageGroup.dirSources,
    ScenarioManageGroup.itemSources,
    ScenarioManageGroup.dirExclude,
    ScenarioManageGroup.itemExclude,
  ];
  Set<ScenarioManageGroup> _hiddenGroups = {};

  /// Ids of explicit includes that a directory / whole-storage source already
  /// covers (see [redundantExplicitItems]). Drives the row's "Remove redundant
  /// addition" label; recomputed in [load].
  Set<int> _redundantIncludeIds = const {};

  /// Test seam for [load]'s redundancy pass.
  @visibleForTesting
  Set<int> get debugRedundantIncludeIds => _redundantIncludeIds;

  final String scenarioId;

  /// True when rendered inside [StoragesDb] (BrowserOpenMode.scenario). In the
  /// embedded case Layer-1 back falls through to the storagedb tabs; in the
  /// standalone popup it returns to the play queue.
  final bool embeddedInStoragesDb;

  /// True when this data source belongs to a `modeQueueOverride` browser
  /// (floating queue popup / docked panel). Passed explicitly by the owning
  /// page instead of reading the global
  /// [ScenarioBrowserStore.queueOverrideActive], which is set by ANY mounted
  /// queue-override browser (e.g. the always-on Windows dock).
  final bool queueOverride;

  /// Position to restore when returning from the search page (v5-D1/v6-D3).
  final PagedScenarioSourcesRestore? restorePosition;

  PagedScenarioSourcesDataSource({
    required this.scenarioId,
    required this.embeddedInStoragesDb,
    this.queueOverride = false,
    this.restorePosition,
  }) {
    _lastPageSize = _store.state.scenarioManagePageSize;
    _storeSub = _store.stream.listen((state) {
      if (state.scenarioManagePageSize != _lastPageSize) {
        _lastPageSize = state.scenarioManagePageSize;
        notifyListeners();
      }
    });
    _applyRestore();
    load();
  }

  /// v6-D3: read-only position getters for the search-entry snapshot.
  List<ScenarioManageGroup> get groupOrder => List.unmodifiable(_groupOrder);
  Set<ScenarioManageGroup> get hiddenGroups => Set.unmodifiable(_hiddenGroups);

  void _applyRestore() {
    final restore = restorePosition;
    if (restore == null) return;
    _currentPage = restore.page;
    if (restore.groupOrder != null && restore.groupOrder!.isNotEmpty) {
      _groupOrder = List.of(restore.groupOrder!);
    }
    if (restore.hiddenGroups != null) {
      _hiddenGroups = Set.of(restore.hiddenGroups!);
    }
  }

  @override
  void dispose() {
    _storeSub?.cancel();
    super.dispose();
  }

  PlaybackScenarioStore get _store => usePlaybackScenarioStore();

  String _storageNameOf(String storageId) =>
      useStorageStore().findById(storageId)?.name ?? storageId;

  /// Basename of a storage-relative [path]; whole-storage (empty) paths fall
  /// back to the storage name (D1).
  String _basenameOf(String path, String storageName) {
    if (path.isEmpty) return storageName;
    final parts = pathConv(path);
    if (parts.isEmpty) return storageName;
    return parts.last;
  }

  /// Container grouping key `$storageId:/<containerPath>`: file entries use
  /// their parent directory, directory entries their own directory, and
  /// whole-storage entries the storage root (D8).
  String _containerKeyOf(String storageId, String? path, bool isFile) {
    final base = '$storageId:';
    if (path == null || path.isEmpty) return '$base/';
    final parts = pathConv(path);
    if (isFile) {
      if (parts.length <= 1) return '$base/';
      return '$base/${parts.sublist(0, parts.length - 1).join('/')}';
    }
    return '$base/${parts.join('/')}';
  }

  ScenarioManageItem _sourceItem(ScenarioSource s) {
    final storageName = _storageNameOf(s.storageId);
    final isFile = s.sourceKind == ScenarioSourceKind.file;
    final basename = _basenameOf(s.path, storageName);
    final fullPath = '[$storageName] ${s.path.isEmpty ? '/' : s.path}';
    return ScenarioManageItem(
      kind: ScenarioManageItemKind.source,
      group: isFile
          ? ScenarioManageGroup.itemSources
          : ScenarioManageGroup.dirSources,
      sourceId: s.id,
      title: 'Source · $basename',
      subtitle: '${s.recursive ? 'recursive' : 'non-recursive'} · $fullPath',
      sortName: basename,
      containerKey:
          _containerKeyOf(s.storageId, s.path.isEmpty ? null : s.path, isFile),
      storageName: storageName,
      createdAt: s.createdAt,
      storageId: s.storageId,
      path: s.path.isEmpty ? null : s.path,
      isFile: isFile,
    );
  }

  ScenarioManageItem _excludeItem(ScenarioExcludeRule r) {
    final storageName = _storageNameOf(r.storageId);
    final isDir = r.kind == ExcludeRuleKind.directory;
    final basename = _basenameOf(r.path, storageName);
    final fullPath = '[$storageName] ${r.path.isEmpty ? '/' : r.path}';
    return ScenarioManageItem(
      kind: ScenarioManageItemKind.exclude,
      group: isDir
          ? ScenarioManageGroup.dirExclude
          : ScenarioManageGroup.itemExclude,
      ruleId: r.id,
      title: 'Excluded · $basename',
      subtitle: [
        if (isDir)
          'directory · ${r.recursive ? 'recursive' : 'non-recursive'}'
        else
          'media',
        if (r.scope.name == 'source') 'source-scoped' else 'scenario',
        if (r.lifetime.name == 'temporary') 'tmp' else 'persistent',
        fullPath,
      ].join(' · '),
      sortName: basename,
      containerKey:
          _containerKeyOf(r.storageId, r.path.isEmpty ? null : r.path, !isDir),
      storageName: storageName,
      createdAt: r.createdAt,
      storageId: r.storageId,
      path: r.path.isEmpty ? null : r.path,
      isFile: !isDir,
    );
  }

  ScenarioManageItem _includeItem(ScenarioExplicitItem i) {
    final storageName = _storageNameOf(i.storageId);
    final basename = _basenameOf(i.path, storageName);
    final fullPath = '[$storageName] ${i.path.isEmpty ? '/' : i.path}';
    return ScenarioManageItem(
      kind: ScenarioManageItemKind.include,
      group: ScenarioManageGroup.itemSources,
      includeId: i.id,
      title: 'Explicit · $basename',
      subtitle: fullPath,
      sortName: basename,
      containerKey: _containerKeyOf(i.storageId, i.path, true),
      storageName: storageName,
      createdAt: i.createdAt,
      storageId: i.storageId,
      path: i.path,
      isFile: true,
    );
  }

  /// Global container-first preference of the manage list (default true),
  /// stored in the scenario store state.
  bool _manageContainerFirst() => _store.state.manageContainerFirst;

  /// Reactive read for the sort-menu checkbox.
  bool _activeManageContainerFirst(BuildContext context) =>
      _store.select(context, (s) => s.manageContainerFirst);

  Future<void> load() async {
    _isLoading = true;
    _isError = false;
    notifyListeners();
    try {
      final sources = await _store.getSources(scenarioId);
      final rules = await _store.getExcludeRules(scenarioId);
      final includes = await _store.getExplicitItems(scenarioId);

      _redundantIncludeIds = {
        for (final e in redundantExplicitItems(
          sources: sources,
          items: includes,
        ))
          e.id,
      };

      final items = <ScenarioManageItem>[
        for (final s in sources)
          _sourceItem(s),
        for (final r in rules)
          _excludeItem(r),
        for (final i in includes)
          _includeItem(i),
      ];

      _allItems = items;
      _applyFilterAndSort();
    } catch (e) {
      _isError = true;
    }
    _isLoading = false;
    notifyListeners();
  }

  void _applyFilterAndSort() {
    var visible =
        _allItems.where((i) => !_hiddenGroups.contains(i.group)).toList();
    visible.sort((a, b) => compareManageItems(
          a,
          b,
          groupOrder: _groupOrder,
          sortBy: _store.state.manageSortBy,
          direction: _store.state.manageSortDirection,
          withinGroup: _store.state.manageSortWithinGroup,
          containerFirst: _manageContainerFirst(),
        ));
    _totalItems = visible.length;
    _applyPage(visible);
  }

  /// Persists a new filter configuration (groups, checked set and display
  /// order) and reloads the page. Sort field/direction/within-group are
  /// managed by the sort menu via the scenario store, not here.
  void updateFilter({
    required List<ScenarioManageGroup> groupOrder,
    required Set<ScenarioManageGroup> hiddenGroups,
  }) {
    _groupOrder = groupOrder;
    _hiddenGroups = hiddenGroups;
    _currentPage = 0;
    _applyFilterAndSort();
    notifyListeners();
  }

  void _applyPage([List<ScenarioManageItem>? items]) {
    final source = items ?? _allItems;
    final start = _currentPage * pageSize;
    _items = start >= source.length
        ? []
        : source.sublist(start, (start + pageSize).clamp(0, source.length));
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
  List<ScenarioManageItem> get items => _items;

  @override
  String getItemId(ScenarioManageItem item) => item.id;

  @override
  Future<void> fetchPage(int targetPage, int currentSize) async {
    _currentPage = targetPage;
    _applyFilterAndSort();
    notifyListeners();
  }

  @override
  Future<void> changePageSize(int newSize) async {
    if (newSize < 1) return;
    newSize = clampPageSize(newSize);
    await _store.updateScenarioManagePageSize(newSize);
    _currentPage = 0;
    _applyFilterAndSort();
    notifyListeners();
  }

  @override
  Future<void> changeSort(SortOption sortOption) async {}

  @override
  Future<bool> handleNavigationBack() async {
    // Queue-override panel (floating popup / dock): the manager was swapped
    // in IN PLACE — back returns to the queue inside the same panel; no
    // route exists to pop.
    if (queueOverride) {
      useScenarioBrowserStore().setQueueOverrideMode(ScenarioBrowserMode.queue);
      return true;
    }
    // One-shot: manager entered from queue -> back returns to playing queue (in-place).
    if (useScenarioBrowserStore().consumeManagerEnteredFromQueue()) {
      useScenarioBrowserStore().setMode(ScenarioBrowserMode.queue);
      return true;
    }
    // Standalone popup (player queue button): back returns to the play queue.
    if (!embeddedInStoragesDb) {
      useScenarioBrowserStore().setMode(ScenarioBrowserMode.queue);
      return true;
    }
    // Embedded in StoragesDb: Layer-1 is the root — back falls through to the
    // storagedb tabs (onHomePage).
    return false;
  }

  @override
  Future<void> handleNavigationHome() async {}

  @override
  Future<void> navigateToCrumb(int index) async {}

  @override
  bool get supportsSearch => false;

  @override
  Future<void> openSearchDialog(
      BuildContext scenario, VoidCallback onSearchInitiated) async {}

  @override
  bool handleItemTap(BuildContext scenario, ScenarioManageItem item) {
    final storageId = item.storageId;
    if (storageId == null) return false;

    // Media entries (file sources, explicit includes) play directly with the
    // origin/version guard; directories and excludes browse into Layer-2.
    final playable = item.isFile &&
        (item.kind == ScenarioManageItemKind.source ||
            item.kind == ScenarioManageItemKind.include);
    if (playable && item.path != null) {
      _playManageMedia(scenario, item);
      return true;
    }

    final String? path;
    if (item.isFile) {
      final parts = item.path == null ? <String>[] : pathConv(item.path!);
      path = parts.length <= 1
          ? null
          : parts.sublist(0, parts.length - 1).join('/');
    } else {
      path = (item.path == null || item.path!.isEmpty) ? null : item.path;
    }
    final browserStore = useScenarioBrowserStore();
    browserStore
      ..setBrowseSeed(storageId: storageId, path: path)
      ..setMode(ScenarioBrowserMode.browse);
    return true;
  }

  Future<void> _playManageMedia(
      BuildContext scenario, ScenarioManageItem item) async {
    final storageId = item.storageId;
    final path = item.path;
    if (storageId == null || path == null) return;
    final resolved = await _store.resolveItemByOccurrence(
      scenarioId: scenarioId,
      occurrence: PlaybackOccurrenceId(storageId: storageId, path: path),
    );
    if (resolved == null) {
      // Excluded/absent in the effective queue — browse the parent folder.
      if (!scenario.mounted) return;
      final parts = pathConv(path);
      final parent = parts.length <= 1
          ? null
          : parts.sublist(0, parts.length - 1).join('/');
      useScenarioBrowserStore()
        ..setBrowseSeed(storageId: storageId, path: parent)
        ..setMode(ScenarioBrowserMode.browse);
      return;
    }
    if (!scenario.mounted) return;
    await ScenarioPlaybackActions.playResolvedItem(
      scenario,
      store: _store,
      scenarioId: scenarioId,
      item: resolved,
    );
  }

  @override
  Widget buildTileInfoDialog(BuildContext scenario, ScenarioManageItem item) {
    final t = getLocalizations(scenario);
    return AlertDialog(
      title: Text(item.title),
      content: Text(item.subtitle),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(scenario),
          child: Text(t.scn_close),
        ),
      ],
    );
  }

  @override
  Widget? buildItemLeading(BuildContext scenario, ScenarioManageItem item) {
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
  String? buildItemTitle(ScenarioManageItem item) => item.title;

  @override
  Widget? buildItemSubtitle(BuildContext scenario, ScenarioManageItem item) =>
      Text(item.subtitle);

  @override
  List<String>? get currentBreadcrumbs => const ['Sources'];

  @override
  bool get isRightToLeftBreadcrumbs => false;

  @override
  Widget? buildTileContent(BuildContext scenario, ScenarioManageItem item) =>
      null;

  @override
  Widget buildSortMenu(BuildContext context) {
    final t = getLocalizations(context);
    final containerFirst = _activeManageContainerFirst(context);
    final sortBy = _store.select(context, (s) => s.manageSortBy);
    final direction = _store.select(context, (s) => s.manageSortDirection);
    final withinGroup = _store.select(context, (s) => s.manageSortWithinGroup);

    return PopupMenuButton<ScenarioManageSortBy>(
      icon: const Icon(Icons.sort_rounded),
      onSelected: (value) async {
        final current = _store.state.manageSortBy;
        final dir = _store.state.manageSortDirection;
        // filesdb-style: re-clicking the current field toggles asc/desc;
        // switching to a different field keeps the current direction.
        final next = current == value
            ? (dir == SortDirection.asc ? SortDirection.desc : SortDirection.asc)
            : dir;
        await _store.setManageSort(value, next);
        _currentPage = 0;
        _applyFilterAndSort();
        notifyListeners();
      },
      itemBuilder: (_) => [
        _sortItem(
            context, ScenarioManageSortBy.name, t.scn_manage_name, sortBy, direction),
        _sortItem(context, ScenarioManageSortBy.storage, t.scn_manage_storage,
            sortBy, direction),
        _sortItem(
            context, ScenarioManageSortBy.path, t.scn_manage_path, sortBy, direction),
        _sortItem(
            context, ScenarioManageSortBy.type, t.scn_manage_type, sortBy, direction),
        _sortItem(context, ScenarioManageSortBy.createdAt, t.scn_manage_created,
            sortBy, direction),
        const PopupMenuDivider(),
        _checkboxItem(
          context,
          t.scn_manage_container_first,
          containerFirst,
          onToggle: () async {
            await _store.setManageContainerFirst(!containerFirst);
            _currentPage = 0;
            _applyFilterAndSort();
            notifyListeners();
          },
        ),
        _checkboxItem(
          context,
          t.scn_group_sort,
          withinGroup,
          onToggle: () async {
            await _store.setManageSortWithinGroup(!withinGroup);
            _currentPage = 0;
            _applyFilterAndSort();
            notifyListeners();
          },
        ),
      ],
    );
  }

  /// filesdb-style sort item: the current item shows an up/down arrow.
  PopupMenuItem<ScenarioManageSortBy> _sortItem(
    BuildContext context,
    ScenarioManageSortBy target,
    String label,
    ScenarioManageSortBy current,
    SortDirection order,
  ) {
    final selected = current == target;
    return PopupMenuItem(
      value: target,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          if (selected)
            Icon(
              order == SortDirection.asc
                  ? Icons.arrow_upward
                  : Icons.arrow_downward,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
        ],
      ),
    );
  }

  /// Checkbox row at the bottom of the sort menu (same style as filesdb's
  /// folder_first). Toggling persists the option, resets to page 0, re-sorts,
  /// then closes the menu.
  PopupMenuItem<ScenarioManageSortBy> _checkboxItem(
    BuildContext context,
    String label,
    bool value, {
    required Future<void> Function() onToggle,
  }) {
    return PopupMenuItem(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Checkbox(
            value: value,
            onChanged: (_) async {
              await onToggle();
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  @override
  List<PageAction> buildCustomPageActions(BuildContext context) {
    // Offline-grey audit: search / filter / preview all operate on the saved
    // scenario config + snapshot (rows grey inside the preview); nothing here
    // lists the live tree, so all three stay enabled while offline.
    return [
      PageAction(
        icon: const Icon(Icons.search, size: 18),
        label: getLocalizations(context).browser_search,
        onPressed: () => _openSearch(context),
      ),
      PageAction(
        icon: const Icon(Icons.filter_list, size: 18),
        label: getLocalizations(context).scn_filter,
        onPressed: () => _showFilterDialog(context),
      ),
      PageAction(
        icon: const Icon(Icons.visibility_outlined, size: 18),
        label: getLocalizations(context).scn_preview_queue,
        onPressed: () => openScenarioPreview(
          context,
          scenarioId: scenarioId,
          returnMode: ScenarioBrowserMode.sources,
          queueOverride: queueOverride,
        ),
      ),
      PageAction(
        icon: const Icon(Icons.autorenew_rounded, size: 16),
        label: getLocalizations(context).scn_rescan_sources,
        onPressed: ScenarioSourceScanCommand.isEnabled()
            ? () async {
                await ScenarioSourceScanCommand.run(
                  context,
                  scenarioId: scenarioId,
                );
                await load();
              }
            : null,
      ),
      PageAction(
        icon: const Icon(Icons.cleaning_services_outlined, size: 18),
        label: getLocalizations(context).scn_dedupe_explicit_action,
        onPressed: () async {
          await ScenarioExplicitDedupActions.runWithDialogs(
            context,
            scenarioId: scenarioId,
          );
          await load();
        },
      ),
    ];
  }

  /// Search entry (F-001): snapshots the current position (v5-D1/v6-D3) and
  /// the scenario sources/explicit items, then switches to the search mode.
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
      entryContext: SearchEntryContext.scenarioSourcesRoot,
      scenarioId: scenarioId,
      sources: searchSources,
      explicitItems: [
        for (final e in explicitItems)
          SearchExplicitItem(storageId: e.storageId, path: e.path),
      ],
    );
    useSearchBrowserStore().setScenarioSourcesEntry(
      context: searchContext,
      returnPage: _currentPage,
      groupOrder: _groupOrder,
      hiddenGroups: _hiddenGroups,
    );
    final b = useScenarioBrowserStore();
    if (queueOverride) {
      b.setQueueOverrideMode(ScenarioBrowserMode.search);
    } else {
      b.setMode(ScenarioBrowserMode.search);
    }
  }

  /// Spec §5.7 filter dialog: toggle show/hide per group and drag to reorder
  /// display priority. Default: all checked, order = dir sources, item
  /// sources, dir exclude, item exclude.
  Future<void> _showFilterDialog(BuildContext context) async {
    final result =
        await showDialog<(List<ScenarioManageGroup>, Set<ScenarioManageGroup>)>(
      context: context,
      builder: (_) => _ManageFilterDialog(
        initialOrder: _groupOrder,
        initialHidden: _hiddenGroups,
      ),
    );
    if (result == null) return;
    updateFilter(
      groupOrder: result.$1,
      hiddenGroups: result.$2,
    );
  }

  @override
  List<GenericItemAction<ScenarioManageItem>> getItemTrailingActions(
    BuildContext scenario,
    ScenarioManageItem item,
  ) {
    final t = getLocalizations(scenario);
    // A redundant explicit include is still removed by the same single-row
    // operation; only the label changes so the user sees WHY it is safe to go.
    final redundant = item.kind == ScenarioManageItemKind.include &&
        item.includeId != null &&
        _redundantIncludeIds.contains(item.includeId);
    return [
      GenericItemAction<ScenarioManageItem>(
        label: redundant
            ? t.scn_remove_redundant_addition
            : t.scn_remove_from_scenario,
        icon: Icon(
          redundant
              ? Icons.cleaning_services_outlined
              : Icons.remove_circle_outline,
          size: 16,
        ),
        onPressed: (ctx, i) {
          removeItem(i as ScenarioManageItem);
        },
      ),
    ];
  }

  @override
  List<CustomSelectionAction<ScenarioManageItem>> buildCustomSelectionActions(
      BuildContext scenario) {
    final app = useAppStore().state;
    final scenarioMode =
        !app.useLegacyStoragePersistence && app.useScenarioDrivenPlayback;
    // Offline-grey: plain store reads (no `select`) — this surface is also
    // pumped bare in widget tests without store providers, and every
    // recovery path (retry/refresh) rebuilds the page anyway. The bar
    // re-evaluates on each selection change via `enabledFor`.
    return [
      // F-007: multi-select override of the SystemPlaying workspace. Gated on
      // the scenario mode; asks for confirmation before overriding (v3-D3/D24).
      // Offline-grey: overriding queues live files, so any selected item on a
      // disconnected storage disables the action (Remove below is a pure
      // local-DB op and stays enabled).
      if (scenarioMode)
        CustomSelectionAction<ScenarioManageItem>(
          icon: const Icon(Icons.playlist_play, size: 18),
          label: getLocalizations(scenario).scn_play_selected,
          enabledFor: (selected) => selected.every((i) {
            final id = i.storageId;
            return id == null || useStorageStore().isConnected(id);
          }),
          onPressed: (ctx, selected) => _playSelectedItems(ctx, selected),
        ),
      CustomSelectionAction<ScenarioManageItem>(
        icon: const Icon(Icons.remove_circle_outline, size: 18),
        label: getLocalizations(scenario).scn_remove_selected_from_scenario,
        onPressed: (ctx, selected) async {
          await removeAll(selected);
          return true;
        },
      ),
    ];
  }

  /// F-007: `Play selected items` — Override the SystemPlaying workspace with
  /// the selected sources/includes (excludes ignored). dir-sources keep their
  /// saved `recursive` flag (v2-D1), files/includes become explicit items
  /// (v6-D40). Confirmation first (cancel keeps selection, D24); then the
  /// shared No Media helper handles empty/unplayable selections (D31).
  Future<bool> _playSelectedItems(
      BuildContext ctx, Set<ScenarioManageItem> selected) async {
    final t = getLocalizations(ctx);
    final navigator = Navigator.of(ctx);
    final sources = await _store.getSources(scenarioId);
    final sourceById = {for (final s in sources) s.id: s};

    final files = <FileItem>[];
    final dirs = <ScenarioSourceSpec>[];
    for (final item in selected) {
      if (item.kind == ScenarioManageItemKind.exclude) continue;
      final storageId = item.storageId;
      if (storageId == null) continue;
      final path = item.path ?? '';
      if (item.kind == ScenarioManageItemKind.source && !item.isFile) {
        final recursive = sourceById[item.sourceId]?.recursive ?? false;
        dirs.add((
          storageId: storageId,
          path: path,
          recursive: recursive,
          kind: ScenarioSourceKind.folder,
        ));
      } else {
        final segments = path.isEmpty ? const <String>[] : path.split('/');
        files.add(FileItem(
          storageId: storageId,
          name: segments.isNotEmpty ? segments.last : path,
          uri: '/$path',
          path: segments,
          size: 0,
          type: ContentType.other,
        ));
      }
    }

    final confirmed = await showOverrideConfirmDialog(
      navigator,
      sourceScenarioName: t.scn_selected_content,
    );
    if (!confirmed || !navigator.mounted) return false;

    await ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
      navigator.context,
      action: ({bool force = false}) =>
          ScenarioPlaybackActions.playSelectionInDefaultScenario(
        files: files,
        directories: dirs,
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.asc,
        force: force,
      ),
    );
    return true;
  }

  Future<void> _remove(ScenarioManageItem item) async {
    switch (item.kind) {
      case ScenarioManageItemKind.source:
        if (item.sourceId != null) await _store.removeSource(item.sourceId!);
      case ScenarioManageItemKind.exclude:
        if (item.ruleId != null) await _store.removeExcludeRule(item.ruleId!);
      case ScenarioManageItemKind.include:
        if (item.includeId != null) {
          await _store.removeExplicitInclude(item.includeId!);
        }
    }
  }

  /// Removes [item] (source / exclude / include) and tells the playback layer
  /// the scenario's effective queue changed. Public + await-able so the
  /// single-item path is directly testable; the trailing action routes here.
  Future<void> removeItem(ScenarioManageItem item) async {
    await _remove(item);
    await _signalDefinitionChanged();
    await load();
  }

  /// Batch variant of [removeItem]: ONE notification for the whole selection,
  /// never one per item (a per-item bump would re-fetch an open queue N times).
  Future<void> removeAll(Iterable<ScenarioManageItem> items) async {
    for (final item in items) {
      await _remove(item);
    }
    await _signalDefinitionChanged();
    await load();
  }

  /// A definition edit changes the effective queue: re-validate the current
  /// item so playback never hangs on a just-removed entry (only when the edited
  /// scenario IS the active one), then re-resolve the player chrome and re-fetch
  /// any open queue list.
  Future<void> _signalDefinitionChanged() async {
    if (scenarioId == _store.state.activeScenarioId) {
      await ScenarioPlaybackProvider(store: _store).revalidateCurrent();
    }
    await _store.notifyDefinitionChanged();
  }
}

/// Layer-1 filter dialog: checkbox show/hide + drag reorder of the display
/// groups (spec §5.7).
class _ManageFilterDialog extends HookWidget {
  final List<ScenarioManageGroup> initialOrder;
  final Set<ScenarioManageGroup> initialHidden;

  const _ManageFilterDialog({
    required this.initialOrder,
    required this.initialHidden,
  });

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final order = useState<List<ScenarioManageGroup>>(List.of(initialOrder));
    final hidden = useState<Set<ScenarioManageGroup>>(Set.of(initialHidden));

    return AlertDialog(
      title: Text(t.scn_filter_layer),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      content: SizedBox(
        width: 320,
        height: 260,
        child: ReorderableListView.builder(
          buildDefaultDragHandles: false,
          itemCount: order.value.length,
          onReorder: (oldIndex, newIndex) {
            final list = List.of(order.value);
            if (newIndex > oldIndex) newIndex--;
            final group = list.removeAt(oldIndex);
            list.insert(newIndex, group);
            order.value = list;
          },
          itemBuilder: (context, index) {
            final t = getLocalizations(context);
            final group = order.value[index];
            return ListTile(
              key: ValueKey(group),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              dense: true,
              leading: ReorderableDragStartListener(
                index: index,
                child: const Icon(Icons.drag_indicator),
              ),
              title: Text(group.label(t)),
              trailing: Checkbox(
                value: !hidden.value.contains(group),
                onChanged: (checked) {
                  final set = Set.of(hidden.value);
                  if (checked ?? false) {
                    set.remove(group);
                  } else {
                    set.add(group);
                  }
                  hidden.value = set;
                },
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.scn_cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (List.of(order.value), Set.of(hidden.value)),
          ),
          child: Text(t.scn_apply),
        ),
      ],
    );
  }
}

/// Stable kind tie-break order: source < include < exclude (D9/D10).
int manageKindOrdinal(ScenarioManageItemKind kind) => switch (kind) {
      ScenarioManageItemKind.source => 0,
      ScenarioManageItemKind.include => 1,
      ScenarioManageItemKind.exclude => 2,
    };

/// Sort key of [item] for the given [sortBy] field (D8/D14).
///
/// - name → case-insensitive basename
/// - storage → case-insensitive storage display name
/// - path → case-insensitive `$storageId:path` (root for empty/null path)
/// - type → kind ordinal (source < include < exclude)
/// - createdAt → creation time, null treated as epoch 0
Comparable manageSortKeyOf(ScenarioManageItem item, ScenarioManageSortBy sortBy) {
  switch (sortBy) {
    case ScenarioManageSortBy.name:
      return item.sortName.toLowerCase();
    case ScenarioManageSortBy.storage:
      return item.storageName.toLowerCase();
    case ScenarioManageSortBy.path:
      final base = item.storageId ?? '';
      final p = item.path;
      return (p == null || p.isEmpty) ? '$base:'.toLowerCase() : '$base:$p'.toLowerCase();
    case ScenarioManageSortBy.type:
      return manageKindOrdinal(item.kind);
    case ScenarioManageSortBy.createdAt:
      return item.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
  }
}

/// Pure comparison of two manage-list entries (D8/D13).
///
/// Sort chain:
/// 1. group order (only when [withinGroup]) — primary key
/// 2. container grouping (only when [containerFirst]) — direction applied
/// 3. selected [sortBy] field — direction applied
/// 4. kind tie-break (source < include < exclude) — direction-neutral
/// 5. container tie-break (only when !containerFirst) — direction-neutral
/// 6. id — lexical, direction-neutral
///
/// The container tie-breaks (steps 4–5) are direction-neutral so re-sorting in
/// the opposite direction stays a stable reverse of the forward order.
int compareManageItems(
  ScenarioManageItem a,
  ScenarioManageItem b, {
  required List<ScenarioManageGroup> groupOrder,
  required ScenarioManageSortBy sortBy,
  required SortDirection direction,
  required bool withinGroup,
  required bool containerFirst,
}) {
  final dir = direction == SortDirection.asc ? 1 : -1;
  final orderMap = {
    for (var i = 0; i < groupOrder.length; i++) groupOrder[i]: i,
  };

  if (withinGroup) {
    final groupDiff =
        (orderMap[a.group] ?? 999).compareTo(orderMap[b.group] ?? 999);
    if (groupDiff != 0) return groupDiff;
  }

  if (containerFirst) {
    final containerDiff = a.containerKey.compareTo(b.containerKey) * dir;
    if (containerDiff != 0) return containerDiff;
  }

  final fieldDiff = manageSortKeyOf(a, sortBy).compareTo(manageSortKeyOf(b, sortBy)) * dir;
  if (fieldDiff != 0) return fieldDiff;

  final kindDiff = manageKindOrdinal(a.kind).compareTo(manageKindOrdinal(b.kind));
  if (kindDiff != 0) return kindDiff;

  if (!containerFirst) {
    final containerDiff = a.containerKey.compareTo(b.containerKey);
    if (containerDiff != 0) return containerDiff;
  }
  return a.id.compareTo(b.id);
}
