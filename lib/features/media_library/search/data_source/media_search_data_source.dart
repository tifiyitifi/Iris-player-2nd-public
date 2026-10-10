import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:iris/features/media_library/model/db/dao/for_page/media_node_page_result.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/search/model/search_context.dart';
import 'package:iris/features/media_library/search/model/search_exclude_rule.dart';
import 'package:iris/features/media_library/search/model/search_path_match.dart';
import 'package:iris/features/media_library/search/model/search_result_item.dart';
import 'package:iris/features/media_library/search/model/search_scope.dart';
import 'package:iris/features/media_library/search/store/search_browser_store.dart';
import 'package:iris/features/media_library/search/store/use_media_lib_search_store.dart';
import 'package:iris/features/media_library/search/view/widgets/search_highlight_text.dart';
import 'package:iris/features/media_library/services/system_library_open_check.dart';
import 'package:iris/features/meta_settings/engine/browse_scope_snapshot.dart'
    show currentBrowseScopeMediaTypes;
import 'package:iris/features/media_library/store/use_media_lib_browser_store.dart';
import 'package:iris/features/media_library/view/content/model/lib_content_item.dart';
import 'package:iris/features/media_library/view/content/model/media_lib_content_mode.dart';
import 'package:iris/features/media_library/view/content/store/use_media_lib_content_store.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_actions.dart';
import 'package:iris/features/scenario_playback/actions/stay_mode_page_action.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/resolver/scenario_resolver.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/coordinator/scenario_browser_store.dart';
import 'package:iris/features/scenario_playback/view/dialogs/show_override_confirm_dialog.dart';
import 'package:iris/features/scenario_playback/view/dialogs/show_version_changed_dialog.dart';
import 'package:iris/features/virtual_media/resolver/vm_stream_merge.dart';
import 'package:iris/features/virtual_media/rule/vm_title_composer.dart'
    show kVmDisplayPrefix;
import 'package:iris/features/virtual_media/store/vm_prefs.dart';
import 'package:iris/features/virtual_media/vm_gate.dart';
import 'package:iris/features/windows/explorer/menu/explorer_reveal_action.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/escape_like.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/dialogs/show_copyable_error_dialog.dart';

/// Default scope of an entry context (§2.3): no-location contexts fall back to
/// allSources; located contexts default to currentDirRecursive — except
/// libAllDirs L2 which follows the `allDirsRecursive` switch (v6-D1 covers the
/// scenarioBrowse storage-level state, which is also currentDirRecursive).
SearchScope defaultScopeFor(SearchContext context,
    {required bool allDirsRecursive}) {
  if (context.hasNoLocation) return SearchScope.allSources;
  switch (context.entryContext) {
    case SearchEntryContext.libAllDirsL2:
      return allDirsRecursive
          ? SearchScope.currentDirRecursive
          : SearchScope.currentDirDirect;
    default:
      return SearchScope.currentDirRecursive;
  }
}

/// Pure two-segment virtual-index merger (v5-D2): walks the concatenated
/// [dbTotal] DB segment + [explicit] segment, collecting a page without
/// materializing either. Extracted for unit-testability of the跨页无丢无重 +
/// 显式段整块附后 + total 一致 behavior.
class SearchVirtualPageMerger {
  final int dbTotal;
  final List<SearchResultItem> explicit;

  const SearchVirtualPageMerger({
    required this.dbTotal,
    required this.explicit,
  });

  int get total => dbTotal + explicit.length;

  Future<List<SearchResultItem>> buildPage(
    int page,
    int pageSize,
    Future<SearchResultItem?> Function(int index) dbAt,
  ) async {
    final result = <SearchResultItem>[];
    var probe = page * pageSize;
    while (result.length < pageSize && probe < total) {
      final SearchResultItem? item;
      if (probe < dbTotal) {
        item = await dbAt(probe);
      } else {
        final idx = probe - dbTotal;
        item = idx < explicit.length ? explicit[idx] : null;
      }
      if (item != null) result.add(item);
      probe++;
    }
    return result;
  }
}

/// The immutable parameters of one query run, captured so stale page builds
/// never read a newer run's mutable fields.
class _QuerySnapshot {
  final List<SearchSource> sources;
  final String query;
  final List<SearchExcludeRule> excludeRules;
  final MediaSortField sortField;
  final SortDirection sortDirection;
  final int dbTotal;

  const _QuerySnapshot({
    required this.sources,
    required this.query,
    required this.excludeRules,
    required this.sortField,
    required this.sortDirection,
    required this.dbTotal,
  });
}

/// Data source of the independent search page (F-003…F-008).
///
/// Implements the two-segment model (v5-D2): a DB segment (global
/// `pathGroupFirst` query over the current scope sources, window-cached) plus
/// an explicit segment (scenario explicit items matched in memory, whole block
/// appended). `total = dbTotal + explicitCount`. Real-time query via debounce
/// (F-005) with concurrency guard; selection is disabled (O8).
class MediaSearchDataSource extends PaginatedBrowserDataSource<SearchResultItem> {
  final SearchContext searchContext;

  /// True when this search belongs to a `modeQueueOverride` browser (floating
  /// queue popup / docked panel). Captured at construction so parked/resumed
  /// sessions keep the context they were created in; never read the global
  /// [ScenarioBrowserStore.queueOverrideActive], which is set by ANY mounted
  /// queue-override browser (e.g. the always-on Windows dock).
  final bool queueOverride;

  MediaSearchDataSource({
    required this.searchContext,
    this.queueOverride = false,
  }) {
    _scope = defaultScopeFor(
      searchContext,
      allDirsRecursive: useMediaLibContentStore().state.allDirsRecursive,
    );
  }

  /// v6-D2: the SystemPlaying workspace override revision captured at session
  /// creation. Recorded when the data source is built (NOT at park time) so a
  /// session parked right after an override play ("Play scenario" /
  /// "Play search result") is still detected as stale on resume.
  final int _workspaceRevisionAtCreation =
      usePlaybackScenarioStore().workspaceOverrideRevision;

  /// Debounce window of real-time queries (F-005).
  static const Duration _debounceDelay = Duration(milliseconds: 250);

  /// DB segment window size: `max(pageSize, this)` (NFR-007).
  static const int _minWindowSize = 64;

  String _query = '';
  String get query => _query;

  bool get isEmptyQuery => _query.trim().isEmpty;

  /// The query that produced the currently displayed items. Differs from
  /// [_query] during the debounce window (typing updates [_query] instantly);
  /// highlighting must follow the results, not the live text (v10-D1).
  String _appliedQuery = '';

  late SearchScope _scope;
  SearchScope get scope => _scope;

  MediaSortField _sortField = MediaSortField.name;
  SortDirection _sortDirection = SortDirection.asc;

  Timer? _debounce;
  int _execution = 0;

  bool _isLoading = false;
  bool _isError = false;
  List<SearchResultItem> _items = const [];
  int _totalItems = 0;
  int _currentPage = 0;

  // DB segment window cache (current query state only).
  int _dbTotal = 0;
  int _dbWindowOffset = -1;
  List<SearchResultItem> _dbWindow = const [];

  /// The snapshot [_dbWindow]/[_dbWindowOffset] were fetched for. Guards the
  /// window cache against a newer `_runQuery` clobbering it mid-flight: a stale
  /// page build (or "Play search result" materialization) must never read rows
  /// from a newer query's window just because the offset happens to match.
  _QuerySnapshot? _dbWindowSnapshot;

  // Explicit segment (current query state only).
  List<SearchResultItem> _explicitList = const [];

  // Virtual Media segment (current query state only): merged groups derived
  // from the scenario's effective stream. Empty for non-scenario searches.
  List<SearchResultItem> _vmList = const [];

  /// The in-memory tail appended after the DB segment, in display order:
  /// explicit items first, then virtual merged groups.
  List<SearchResultItem> get _tailItems => [..._explicitList, ..._vmList];

  /// Snapshot of the latest query run — kept so "Play search result" (v15-D2,
  /// context B) can materialize the full result set across DB windows + the
  /// explicit segment without re-running the query.
  _QuerySnapshot? _currentQuery;

  bool get _respectExcludes =>
      searchContext.scenarioId != null &&
      useMediaLibSearchStore().state.respectExcludes;

  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _debounce?.cancel();
    super.dispose();
  }

  // ── Scope / query / persistence ──

  List<SearchSource> _sourcesFor(SearchScope scope) {
    switch (scope) {
      case SearchScope.allSources:
        return searchContext.sources;
      case SearchScope.currentDirRecursive:
        if (searchContext.storageId == null) return searchContext.sources;
        return [
          SearchSource(
            storageId: searchContext.storageId!,
            path: searchContext.parentPath,
            kind: MediaSourceKind.directory,
            recursive: true,
          ),
        ];
      case SearchScope.currentDirDirect:
        if (searchContext.storageId == null) return searchContext.sources;
        return [
          SearchSource(
            storageId: searchContext.storageId!,
            path: searchContext.parentPath,
            kind: MediaSourceKind.directory,
            recursive: false,
          ),
        ];
    }
  }

  Future<List<SearchExcludeRule>> _fetchExcludeRules() async {
    final scenarioId = searchContext.scenarioId;
    if (scenarioId == null) return const [];
    final rules = await usePlaybackScenarioStore().getExcludeRules(scenarioId);
    return rules.map(SearchExcludeRule.from).toList();
  }

  /// Real-time input: debounce then query page 0 (F-005). Empty query clears.
  void updateQuery(String q) {
    if (_query == q) return;
    _query = q;
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () => fetchPage(0, pageSize));
  }

  /// Clears the query immediately (search bar clear button, F-004).
  void clearQuery() {
    _query = '';
    _debounce?.cancel();
    fetchPage(0, pageSize);
  }

  /// Explicit submit (Enter, F-009): records history then queries page 0.
  Future<void> submitQuery(String q) async {
    _query = q;
    _debounce?.cancel();
    if (q.trim().isNotEmpty) {
      await useMediaLibSearchStore().addHistory(q);
    }
    await fetchPage(0, pageSize);
  }

  /// History-panel click (F-009 / v6-D6): bumps MRU and queries immediately
  /// (skips the debounce).
  Future<void> applyHistoryEntry(String q) async {
    _query = q;
    _debounce?.cancel();
    if (q.trim().isNotEmpty) {
      await useMediaLibSearchStore().bumpHistory(q);
    }
    await fetchPage(0, pageSize);
  }

  Future<void> applyScope(SearchScope scope) async {
    if (_scope == scope) return;
    _scope = scope;
    await useMediaLibSearchStore().updateScope(scope);
    await fetchPage(0, pageSize);
  }

  Future<void> applyRespectExcludes(bool value) async {
    if (useMediaLibSearchStore().state.respectExcludes == value) return;
    await useMediaLibSearchStore().updateRespectExcludes(value);
    await fetchPage(0, pageSize);
  }

  // ── Pagination accessors ──

  @override
  int get totalItems => _totalItems;

  @override
  int get currentPage => _currentPage;

  @override
  int get totalPages => (totalItems / pageSize).ceil().clamp(1, 99999);

  @override
  int get pageSize => useMediaLibSearchStore().state.pageSize;

  @override
  bool get isLoading => _isLoading;

  @override
  bool get isError => _isError;

  @override
  List<SearchResultItem> get items => _items;

  @override
  String getItemId(SearchResultItem item) => item.id;

  @override
  List<String>? get currentBreadcrumbs => null;

  @override
  bool get isRightToLeftBreadcrumbs => false;

  @override
  bool get supportsSearch => false;

  @override
  bool get supportsCurrentItem => false;

  @override
  bool get supportsSelection => true;

  /// Virtual merged groups stay tappable (to play) but cannot take part in
  /// multi-selection: their non-playback operations are unsupported.
  @override
  bool isItemSelectable(SearchResultItem item) => !item.isVirtualGroup;

  /// One-shot hint shown when the user enters multi-select while the results
  /// contain virtual merged groups (which render greyed / unselectable). The
  /// "Don't show again" choice persists via [VmPrefs]; the settings row
  /// re-enables it. Never shown when there are no virtual results.
  Future<void> maybeShowVirtualSelectionHint(BuildContext context) async {
    if (_vmList.isEmpty) return;
    if (await VmPrefs.multiSelectHintHidden()) return;
    if (!context.mounted) return;
    final t = getLocalizations(context);
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(t.vm_multiselect_hint_title),
        content: Text(t.vm_multiselect_hint_body),
        actions: [
          TextButton(
            onPressed: () {
              unawaited(VmPrefs.setMultiSelectHintHidden(true));
              Navigator.pop(dialogCtx);
            },
            child: Text(t.vm_multiselect_hint_never),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(t.ok),
          ),
        ],
      ),
    );
  }

  /// v11-D3: in-memory pin — when true tap-play/override-play keep the search
  /// page open; when false (default) they destroy it. Append never exits.
  bool get _pinned => useSearchBrowserStore().pinned;

  // ── Query execution (two-segment virtual walk, v5-D2) ──

  @override
  Future<void> fetchPage(int targetPage, int currentSize) =>
      _runQuery(targetPage);

  Future<void> _runQuery(int targetPage) async {
    final version = ++_execution;
    final query = _query.trim();
    if (query.isEmpty) {
      _dbTotal = 0;
      _dbWindow = const [];
      _dbWindowOffset = -1;
      _dbWindowSnapshot = null;
      _explicitList = const [];
      _vmList = const [];
      _items = const [];
      _totalItems = 0;
      _currentPage = 0;
      _appliedQuery = '';
      _currentQuery = null;
      _isLoading = false;
      _isError = false;
      notifyListeners();
      return;
    }

    _isLoading = true;
    _isError = false;
    notifyListeners();
    try {
      final sources = _sourcesFor(_scope);
      final excludeRules =
          _respectExcludes ? await _fetchExcludeRules() : const <SearchExcludeRule>[];
      final pageSize = this.pageSize;
      final tokens = tokenizeQuery(query);

      final MediaNodePageResult dbResult;
      if (sources.isEmpty) {
        // Pure-explicit scenario: skip the DB query (v4/B3).
        dbResult = _emptyDbPage();
      } else {
        dbResult = await DbModule.mediaNodeRepo.searchNodesForSources(
          sources: sources,
          searchQuery: query,
          excludeRules: excludeRules.isEmpty ? null : excludeRules,
          nodeKind: MediaNodeKind.file,
          // Browse-media-scope projection (null under all/gate OFF).
          mediaTypes: currentBrowseScopeMediaTypes(),
          sortField: _sortField,
          sortDirection: _sortDirection,
          page: 1,
          pageSize: math.max(pageSize, _minWindowSize),
        );
      }
      if (version != _execution) return;

      final explicit = await _computeExplicitSegment(
        tokens: tokens,
        sources: sources,
        excludeRules: excludeRules,
      );
      if (version != _execution) return;

      final virtual = await _computeVirtualSegment(tokens: tokens);
      if (version != _execution) return;

      final snapshot = _QuerySnapshot(
        sources: sources,
        query: query,
        excludeRules: excludeRules,
        sortField: _sortField,
        sortDirection: _sortDirection,
        dbTotal: dbResult.totalItems,
      );
      _dbTotal = dbResult.totalItems;
      _dbWindowOffset = 0;
      _dbWindow = dbResult.items.map(_fromNode).toList();
      _dbWindowSnapshot = snapshot;
      _explicitList = explicit;
      _vmList = virtual;
      _currentQuery = snapshot;
      final total = _dbTotal + _explicitList.length + _vmList.length;
      _totalItems = total;

      final items = await _buildPage(snapshot, targetPage, pageSize, total, _tailItems);
      if (version != _execution) return;
      _items = items;
      _currentPage = targetPage;
      _appliedQuery = query;
      _isLoading = false;
      _isError = false;
      notifyListeners();
    } catch (e) {
      if (version != _execution) return;
      _isError = true;
      _isLoading = false;
      notifyListeners();
    }
  }

  MediaNodePageResult _emptyDbPage() {
    return MediaNodePageResult(
      items: const [],
      totalItems: 0,
      totalPages: 1,
      currentPage: 1,
      pageSize: pageSize,
    );
  }

  /// In-memory explicit segment (F-007 / v5-D2 / v6-D4): token-match on the
  /// basename (with extension, lowercase), synthesize out-of-scope or not-in-DB
  /// items, sort by name, dedupe on canonicalKey.
  Future<List<SearchResultItem>> _computeExplicitSegment({
    required List<String> tokens,
    required List<SearchSource> sources,
    required List<SearchExcludeRule> excludeRules,
  }) async {
    final explicitItems = searchContext.explicitItems;
    if (explicitItems.isEmpty || tokens.isEmpty) return const [];

    final inScope = <SearchExplicitItem>[];
    final outOfScope = <SearchExplicitItem>[];
    for (final e in explicitItems) {
      final name = _basenameOf(e.path);
      if (!matchesAllTokens(name, tokens)) continue;
      if (anySourceCovers(sources, e.storageId, e.path)) {
        inScope.add(e);
      } else {
        outOfScope.add(e);
      }
    }

    // Lightweight batch existence check for in-scope items (v4-D2): an
    // in-scope, in-DB item is covered by the DB segment — do not synthesize.
    final existing = <String>{};
    if (inScope.isNotEmpty) {
      final byStorage = <String, List<String>>{};
      for (final e in inScope) {
        byStorage.putIfAbsent(e.storageId, () => []).add(e.path);
      }
      for (final entry in byStorage.entries) {
        final found = await DbModule.mediaNodeRepo.getExistingFilePaths(
          storageId: entry.key,
          paths: entry.value,
        );
        for (final p in found) {
          existing.add('${entry.key}:${canonicalDbPath(p)}');
        }
      }
    }

    final results = <SearchResultItem>[];
    final seen = <String>{};
    void add(SearchExplicitItem e) {
      final key = '${e.storageId}:${canonicalDbPath(e.path)}';
      if (!seen.add(key)) return;
      results.add(_synthesize(e));
    }

    for (final e in inScope) {
      if (existing.contains('${e.storageId}:${canonicalDbPath(e.path)}')) {
        continue;
      }
      add(e);
    }
    for (final e in outOfScope) {
      add(e);
    }

    if (excludeRules.isNotEmpty) {
      results.removeWhere(
        (r) => explicitExcludedByScenarioRules(excludeRules, r.storageId, r.path),
      );
    }

    results.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return results;
  }

  /// Virtual Media segment: merged groups of the searched scenario's OWN
  /// effective stream (the same derivation the queue overlay uses), matched
  /// against the `[vm]`-prefixed composed name.
  ///
  /// Only active for a scenario-bound search in the all-sources scope with the
  /// feature enabled — media-library searches are unaffected.
  ///
  /// The group set comes from the persisted derived index (O(#groups)); when
  /// the index is unavailable the O(N) derivation is still used, and it is
  /// cached by signature inside the resolver either way, so per-keystroke
  /// queries only do an in-memory token filter.
  Future<List<SearchResultItem>> _computeVirtualSegment({
    required List<String> tokens,
  }) async {
    final scenarioId = searchContext.scenarioId;
    if (scenarioId == null || tokens.isEmpty) return const [];
    if (!VirtualMediaGate.enabled) return const [];
    // Virtual groups span directories: the notion of "current dir" cannot apply.
    if (_scope != SearchScope.allSources) return const [];

    final store = usePlaybackScenarioStore();
    // Search is an index entry point: a cold scenario must not pay the O(N)
    // derivation on every keystroke. ensureQueueIndex is idempotent per content
    // signature, so only the first query of a generation builds.
    try {
      await store.ensureQueueIndex(scenarioId);
    } catch (_) {
      // Index unavailable (disabled / empty stream): the fallback below runs.
    }
    List<VmSearchGroupHit>? indexed;
    try {
      indexed = await store.resolver.searchVmGroupsIndexed(scenarioId);
    } catch (_) {
      indexed = null;
    }
    if (indexed != null) {
      final results = <SearchResultItem>[];
      for (final hit in indexed) {
        final name = '$kVmDisplayPrefix${hit.title}';
        if (!matchesAllTokens(name, tokens)) continue;
        results.add(SearchResultItem(
          storageId: hit.storageId,
          path: hit.path,
          name: name,
          mediaType: MediaType.unknown,
          durationMs: hit.totalDurationMs > 0 ? hit.totalDurationMs : null,
          uri: hit.uri,
          origin: SearchResultOrigin.virtualGroup,
          available: true,
          vmScopeKey: hit.scopeKey,
          segmentCount: hit.segmentCount,
          occurrenceIndex: hit.occurrenceIndex,
        ));
      }
      results.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return results;
    }

    final VmStreamGroups groups;
    try {
      groups = await store.resolver.resolveVmGroupsFor(
        scenarioId,
        playbackVersion: store.state.playbackVersion,
      );
    } catch (_) {
      return const [];
    }
    if (groups.inOrder.isEmpty) return const [];

    final representative = store.resolver.vmRepresentativeOccurrence;
    final results = <SearchResultItem>[];
    for (final group in groups.inOrder) {
      if (group.segments.isEmpty) continue;
      final name = '$kVmDisplayPrefix${group.displayName}';
      if (!matchesAllTokens(name, tokens)) continue;
      final first = group.segments.first;
      final occurrence = representative[first.mediaKey];
      results.add(SearchResultItem(
        storageId: first.storageId,
        path: first.path.join('/'),
        name: name,
        mediaType: MediaType.unknown,
        durationMs: group.totalDurationMs > 0 ? group.totalDurationMs : null,
        uri: first.uri,
        origin: SearchResultOrigin.virtualGroup,
        available: true,
        vmScopeKey: group.scopeKey,
        segmentCount: group.segments.length,
        occurrenceIndex: occurrence?.occurrenceIndex,
      ));
    }
    results.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return results;
  }

  /// Virtual-index page walk (v5-D2): DB segment first, in-memory tail after
  /// (explicit items, then virtual groups).
  Future<List<SearchResultItem>> _buildPage(
    _QuerySnapshot snap,
    int targetPage,
    int pageSize,
    int total,
    List<SearchResultItem> tail,
  ) {
    final merger = SearchVirtualPageMerger(dbTotal: snap.dbTotal, explicit: tail);
    return merger.buildPage(targetPage, pageSize, (index) => _dbAt(snap, index));
  }

  /// Window-cached DB segment accessor (NFR-007, window = max(pageSize, 64)).
  ///
  /// The cache is keyed by BOTH offset AND snapshot: a window fetched for a
  /// different (newer) query must not be served to a stale [snap], even when the
  /// requested index falls inside its offset range.
  Future<SearchResultItem?> _dbAt(_QuerySnapshot snap, int index) async {
    if (identical(_dbWindowSnapshot, snap) &&
        _dbWindowOffset <= index &&
        index < _dbWindowOffset + _dbWindow.length) {
      return _dbWindow[index - _dbWindowOffset];
    }
    final windowSize = math.max(pageSize, _minWindowSize);
    final offset = (index ~/ windowSize) * windowSize;
    final result = await DbModule.mediaNodeRepo.searchNodesForSources(
      sources: snap.sources,
      searchQuery: snap.query,
      excludeRules: snap.excludeRules.isEmpty ? null : snap.excludeRules,
      nodeKind: MediaNodeKind.file,
      mediaTypes: currentBrowseScopeMediaTypes(),
      sortField: snap.sortField,
      sortDirection: snap.sortDirection,
      page: offset ~/ windowSize + 1,
      pageSize: windowSize,
    );
    final fetched = result.items.map(_fromNode).toList();
    // Only the snapshot that still owns the shared cache may publish into it;
    // otherwise a concurrent newer run would be clobbered by our stale fetch.
    if (identical(_currentQuery, snap)) {
      _dbWindowOffset = offset;
      _dbWindow = fetched;
      _dbWindowSnapshot = snap;
    }
    final rel = index - offset;
    return (rel >= 0 && rel < fetched.length) ? fetched[rel] : null;
  }

  // ── Item mapping ──

  SearchResultItem _fromNode(MediaNode node) {
    final file = node as MediaFile;
    return SearchResultItem(
      storageId: file.storageId,
      path: file.path.join('/'),
      name: file.name,
      mediaType: file.mediaType,
      sizeInBytes: file.sizeInBytes,
      durationMs: file.durationMs,
      uri: file.uri,
      origin: SearchResultOrigin.dbSource,
      available: file.isPresent,
    );
  }

  SearchResultItem _synthesize(SearchExplicitItem e) {
    return SearchResultItem(
      storageId: e.storageId,
      path: canonicalDbPath(e.path),
      name: _basenameOf(e.path),
      mediaType: MediaType.unknown,
      origin: SearchResultOrigin.explicitItem,
      available: false,
    );
  }

  String _basenameOf(String path) {
    final parts = pathConv(path);
    return parts.isEmpty ? path : parts.last;
  }

  // ── Navigation (destroy-restore, F-002) ──

  @override
  Future<bool> handleNavigationBack() async {
    // v11-D4: Back destroys the search session entirely — the next open is a
    // fresh (empty) search page.
    destroySearch();
    return true;
  }

  @override
  Future<void> handleNavigationHome() async {}

  @override
  Future<void> navigateToCrumb(int index) async {}

  /// Parks the live session for a later resume (Close, v13-D1): the data
  /// source is kept alive (query/page/results preserved) so reopening the
  /// storagedb popup resumes it. The caller decides how to leave (Close pops
  /// the whole popup). Only [destroySearch] discards the session.
  void parkSearch() {
    useSearchBrowserStore().parkSession(this);
  }

  /// Leaves the search page after a play-without-pin (v14-D1): parks the live
  /// session (so reopening the storagedb popup resumes the search — "保留状态",
  /// mirroring [parkSearch]'s Close semantics) and closes the whole storagedb
  /// popup so the player is unobstructed after playback starts. Unlike
  /// [destroySearch] (Back), the session is NOT discarded.
  ///
  /// Queue-override panels (floating popup / docked queue panel) have no
  /// route of their own (the dock would otherwise pop the ROOT route — white
  /// screen): the panel returns to the queue instead.
  void parkSearchAndClosePopup(BuildContext context) {
    parkSearch();
    final browser = useScenarioBrowserStore();
    if (queueOverride) {
      browser.setQueueOverrideMode(ScenarioBrowserMode.queue);
      return;
    }
    final navigator = Navigator.of(context);
    if (navigator.mounted && navigator.canPop()) navigator.pop();
  }

  /// Leaves the search page permanently via Back: destroys the session
  /// (dispose + pin reset), clears the seeds and restores the interface it was
  /// entered from (the popup stays open). Scenario return-position seeds are
  /// left for the rebuilt sources/browse page to consume; media-library seeds
  /// are cleared (state lives in the persistent content store). Play-without-pin
  /// uses [parkSearchAndClosePopup] instead (v14-D1).
  void destroySearch() {
    final sb = useSearchBrowserStore();
    sb.destroySession();
    final scenarioMode = sb.scenarioSearchReturnMode;
    if (scenarioMode != null) {
      final browser = useScenarioBrowserStore();
      if (queueOverride) {
        // Search opened from the playing queue (override panel): return to
        // the queue IN PLACE without writing the persisted manager mode.
        browser.setQueueOverrideMode(ScenarioBrowserMode.queue);
        return;
      }
      browser.setMode(scenarioMode);
      return;
    }
    sb.clearAll();
    useMediaLibBrowserStore().openLibContent();
  }

  // ── Context discrimination (v15-D1) ──

  /// Context A: the search was entered from the system playing scenario — the
  /// searched scenario IS the SystemPlaying workspace.
  bool get _isSystemPlayingSearch {
    final scenarioId = searchContext.scenarioId;
    if (scenarioId == null) return false;
    final sys = usePlaybackScenarioStore().systemPlayingScenario;
    return sys != null && sys.id == scenarioId;
  }

  /// Context C: the media library — explicit via [SearchContext.isMediaLibEntry].
  bool get _isMediaLibSearch => searchContext.isMediaLibEntry;

  /// v6-D2: a scenario-bound (A/B) session is stale when the SystemPlaying
  /// workspace was overridden after this session was created — its cached
  /// results reflect a workspace that no longer exists. Media-library (C)
  /// sessions are never stale: their results are DB-scoped, not bound to the
  /// workspace. Consumed by [SearchBrowserStore.takeParkedSession] to decide
  /// whether a parked session may be resumed.
  bool get isStaleByWorkspaceOverride {
    if (searchContext.scenarioId == null) return false;
    return usePlaybackScenarioStore().workspaceOverrideRevision !=
        _workspaceRevisionAtCreation;
  }

  // ── Tap handling (play, F-008 / v15-D2 per-context) ──

  @override
  bool handleItemTap(BuildContext context, SearchResultItem item) {
    _onItemTap(context, item);
    return true;
  }

  Future<void> _onItemTap(BuildContext context, SearchResultItem item) async {
    // Virtual merged groups have no single-file semantics: always play the
    // merge (installing the scenario when it is not the active workspace).
    if (item.isVirtualGroup) {
      await _playVirtualGroup(context, item);
      return;
    }
    if (_isSystemPlayingSearch) {
      await _playResolvedOrThrow(context, item);
      return;
    }
    if (_isMediaLibSearch) {
      await _playParentDirDirect(context, item);
      return;
    }
    // B: user saved scenario → the play-options dialog.
    _showPlayOptionsDialog(context, item);
  }

  /// Plays a Virtual Media merged group. Context A resolves and plays it
  /// directly; context B first installs the searched scenario as the workspace
  /// (same confirmations as "Play scenario"), then resolves the group.
  Future<void> _playVirtualGroup(
      BuildContext context, SearchResultItem item) async {
    try {
      if (!_isSystemPlayingSearch) {
        final installed = await _installSearchedScenario(context);
        if (!context.mounted || !installed) return;
      }
      await _playResolvedOrThrow(context, item);
    } catch (e) {
      if (!context.mounted) return;
      await _showPlayError(context, e);
    }
  }

  /// Context A click: resolve in the SystemPlaying workspace and play directly.
  /// By design this should not fail (results come from the playing queue); any
  /// failure surfaces the uniform copyable error dialog (v15-D6) and leaves the
  /// player untouched.
  Future<void> _playResolvedOrThrow(
      BuildContext context, SearchResultItem item) async {
    try {
      final store = usePlaybackScenarioStore();
      final sys = store.systemPlayingScenario;
      if (item.origin == SearchResultOrigin.explicitItem || sys == null) {
        await _showPlayError(
          context,
          '无法播放「${item.name}」：'
          '${item.origin == SearchResultOrigin.explicitItem ? '该文件不在媒体数据库中。' : '当前没有正在播放的场景。'}',
        );
        return;
      }
      final resolved = await store.resolveItemByOccurrence(
        scenarioId: sys.id,
        occurrence: PlaybackOccurrenceId(
          storageId: item.storageId,
          path: item.path,
          occurrenceIndex: item.occurrenceIndex ?? 0,
        ),
      );
      if (!context.mounted) return;
      if (resolved == null) {
        await _showPlayError(
            context, '无法播放「${item.name}」：该文件不在当前播放队列中。');
        return;
      }
      await ScenarioPlaybackActions.playResolvedItem(
        context,
        store: store,
        scenarioId: sys.id,
        item: resolved,
        // v5-D4: whole-interface replacement → destroy-restore, not pop().
        // v14-D1: pinned keeps the page open; otherwise park the session and
        // close the whole storagedb popup (queue-style) so the player is clear.
        onExitAfterPlay:
            _pinned ? () {} : () => parkSearchAndClosePopup(context),
      );
    } catch (e) {
      if (!context.mounted) return;
      await _showPlayError(context, e);
    }
  }

  /// Context C click: play the tapped file's parent directory (direct children,
  /// non-recursive) — mirrors the media-library pathTree click, no dialog.
  Future<void> _playParentDirDirect(
      BuildContext context, SearchResultItem item) async {
    final parent = parentOf(canonicalDbPath(item.path));
    final ok = await ScenarioPlaybackActions.runPlayAction(
      context,
      () => ScenarioPlaybackActions.playFolderScopeInDefaultScenario(
        storageId: item.storageId,
        folderPath: parent ?? '',
        tapped: _toFileItem(item),
        recursive: false,
        sortField:
            ScenarioPlaybackActions.scenarioSortFieldFromMedia(_sortField),
        sortDirection: _sortDirection,
      ),
    );
    if (!context.mounted) return;
    if (ok && !_pinned) parkSearchAndClosePopup(context);
  }

  /// Shared play-options dialog (v15-D2, context B) — click and the trailing
  /// Override action use the same component.
  void _showPlayOptionsDialog(BuildContext context, SearchResultItem item) {
    showDialog<_PlayChoice>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(item.name),
        content: const Text('This media cannot be played from the current '
            'playing scenario queue.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, _PlayChoice.playFile),
            child: const Text('Play this media only'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, _PlayChoice.playFolder),
            child: const Text('Play its folder'),
          ),
          if (_totalItems > 0)
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogCtx, _PlayChoice.playSearchResult),
              child: const Text('Play search result'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, _PlayChoice.playScenario),
            child: const Text('Play scenario'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    ).then((choice) async {
      if (choice == null) return;
      if (!context.mounted) return;
      final fileItem = _toFileItem(item);
      final sortField =
          ScenarioPlaybackActions.scenarioSortFieldFromMedia(_sortField);
      final sortDirection = _sortDirection;
      switch (choice) {
        case _PlayChoice.playFile:
          await _runPlayAndExit(
            context,
            () => ScenarioPlaybackActions.playSelectionInDefaultScenario(
              files: [fileItem],
              directories: const [],
              sortField: sortField,
              sortDirection: sortDirection,
            ),
          );
        case _PlayChoice.playFolder:
          final parent = parentOf(canonicalDbPath(item.path));
          await _runPlayAndExit(
            context,
            () => ScenarioPlaybackActions.playFolderScopeInDefaultScenario(
              storageId: item.storageId,
              folderPath: parent ?? '',
              tapped: fileItem,
              recursive: false,
              sortField: sortField,
              sortDirection: sortDirection,
            ),
          );
        case _PlayChoice.playSearchResult:
          await _playSearchResultsChoice(context);
        case _PlayChoice.playScenario:
          await _playScenarioChoice(context);
      }
    });
  }

  /// Runs [action] via the uniform error surface; on success parks the session
  /// and closes the whole popup unless pinned (v14-D1).
  Future<void> _runPlayAndExit(
      BuildContext context, Future<void> Function() action) async {
    final ok = await ScenarioPlaybackActions.runPlayAction(context, action);
    if (!context.mounted) return;
    if (ok && !_pinned) parkSearchAndClosePopup(context);
  }

  Future<void> _playSearchResultsChoice(BuildContext context) async {
    try {
      await _playSearchResults();
    } catch (e) {
      if (!context.mounted) return;
      await _showPlayError(context, e);
      return;
    }
    if (!context.mounted) return;
    if (!_pinned) parkSearchAndClosePopup(context);
  }

  Future<void> _playScenarioChoice(BuildContext context) async {
    try {
      final played = await _playScenario(context);
      if (!context.mounted) return;
      if (played && !_pinned) parkSearchAndClosePopup(context);
    } catch (e) {
      if (!context.mounted) return;
      await _showPlayError(context, e);
    }
  }

  /// "Play search result" (v15-D2, context B): materialize the full current
  /// result set (DB all pages + explicit segment, cap 500) as explicit items
  /// and override the SystemPlaying workspace.
  ///
  /// Virtual merged groups are SKIPPED: they have no single-file identity, so
  /// materializing the representative would degrade a merge into one file.
  ///
  /// The snapshot (query + total + tail) is captured ONCE up front so a new
  /// keystroke that starts another `_runQuery` mid-materialization cannot splice
  /// rows from the newer generation into this play list.
  Future<void> _playSearchResults() async {
    final snap = _currentQuery;
    if (snap == null) {
      throw const PlaybackUnavailableException('没有可播放的内容：当前搜索结果为空。');
    }
    final tail = List<SearchResultItem>.of(_tailItems);
    final files = <FileItem>[];
    const cap = 500;
    final total = math.min(snap.dbTotal + tail.length, cap);
    for (var i = 0; i < total; i++) {
      final SearchResultItem? item;
      if (i < snap.dbTotal) {
        item = await _dbAt(snap, i);
      } else {
        final idx = i - snap.dbTotal;
        item = idx < tail.length ? tail[idx] : null;
      }
      if (item == null || item.isVirtualGroup) continue;
      files.add(_toFileItem(item));
    }
    if (files.isEmpty) {
      throw const PlaybackUnavailableException('没有可播放的内容：当前搜索结果为空。');
    }
    await ScenarioPlaybackActions.playSelectionInDefaultScenario(
      files: files,
      directories: const [],
      sortField: ScenarioPlaybackActions.scenarioSortFieldFromMedia(_sortField),
      sortDirection: _sortDirection,
    );
  }

  /// "Play scenario" (v15-D2, context B): install the searched scenario's full
  /// definition into the SystemPlaying workspace and play. Returns false when
  /// the user cancels the version/override confirmation (no error).
  Future<bool> _playScenario(BuildContext context) async {
    final installed = await _installSearchedScenario(context);
    if (!installed) return false;
    await ScenarioPlaybackActions.playCurrentWorkspace();
    return true;
  }

  /// Installs the searched scenario's definition into the SystemPlaying
  /// workspace (version-changed + override confirmations included) and makes it
  /// active, WITHOUT starting playback. Shared by "Play scenario" and virtual
  /// group playback (context B). Returns false when the user cancels.
  Future<bool> _installSearchedScenario(BuildContext context) async {
    final navigator = Navigator.of(context);
    final store = usePlaybackScenarioStore();
    final scenarioId = searchContext.scenarioId!;
    final scenario = await store.getScenario(scenarioId);
    if (scenario == null) {
      throw const PlaybackUnavailableException('被搜索的场景不存在。');
    }
    final sys = await ensurePlaybackWorkspace();
    final wsState = await store.getState(sys.id);
    final importVersion = wsState?.importVersion;
    if (importVersion != null && importVersion < (scenario.version ?? 0)) {
      if (!context.mounted) return false;
      final proceed =
          await showVersionChangedDialog(context, scenarioName: scenario.name);
      if (!proceed) return false;
    }
    final ok = await showOverrideConfirmDialog(
        navigator, sourceScenarioName: scenario.name);
    if (!ok) return false;
    await store.overrideWorkspace(workspace: sys, source: scenario);
    await store.bumpPlaybackVersion();
    await store.setActiveScenario(sys.id);
    return true;
  }

  /// Uniform error surface (v15-D6): [error] → copyable dialog.
  Future<void> _showPlayError(BuildContext context, Object error) async {
    final message = error is PlaybackUnavailableException
        ? error.message
        : '播放失败：$error';
    await showCopyableErrorDialog(context, title: '播放出错', message: message);
  }

  FileItem _toFileItem(SearchResultItem item) {
    final storage = useStorageStore().resolveStorageForNodeId(item.storageId);
    final segments = pathConv(item.path);
    return FileItem(
      storageId: item.storageId,
      storageType: storage?.type ?? StorageType.none,
      name: item.name,
      uri: mediaNodePlayableUri(storage, segments, uri: item.uri),
      path: segments,
      size: item.sizeInBytes ?? 0,
      durationMs: item.durationMs,
      type: item.mediaType == MediaType.video
          ? ContentType.video
          : item.mediaType == MediaType.audio
              ? ContentType.audio
              : ContentType.other,
    );
  }

  // ── Tile presentation ──

  @override
  Widget? buildItemLeading(BuildContext context, SearchResultItem item) {
    final isExplicit = item.origin == SearchResultOrigin.explicitItem;
    final icon = item.isVirtualGroup
        ? Icons.merge_type
        : isExplicit
            ? Icons.push_pin_outlined
            : item.mediaType == MediaType.audio
                ? Icons.music_note_outlined
                : Icons.movie_outlined;
    return Icon(
      icon,
      size: 20,
      color: item.isVirtualGroup || isExplicit
          ? Theme.of(context).colorScheme.primary
          : Colors.blue,
    );
  }

  @override
  String? buildItemTitle(SearchResultItem item) => item.name;

  @override
  Widget? buildItemTitleWidget(BuildContext context, SearchResultItem item) {
    // Highlight only against the query that produced the shown results
    // (_appliedQuery), never the in-flight text (v10-D1).
    if (_appliedQuery.trim().isEmpty || item.name.isEmpty) return null;
    return SearchHighlightText(name: item.name, query: _appliedQuery);
  }

  @override
  Widget? buildItemSubtitle(BuildContext context, SearchResultItem item) {
    final isScenario = searchContext.scenarioId != null;
    final parts = <Widget>[];
    if (isScenario) {
      final isExplicit = item.origin == SearchResultOrigin.explicitItem;
      final label = item.isVirtualGroup
          ? 'Virtual'
          : isExplicit
              ? 'Explicit'
              : 'Source';
      parts.add(_OriginBadge(
        label: label,
        explicit: item.isVirtualGroup || isExplicit,
      ));
    }
    if (item.isVirtualGroup) {
      final t = getLocalizations(context);
      final meta = <String>[
        if (item.segmentCount != null)
          t.vm_list_meta_segments(item.segmentCount!),
        if (item.durationMs != null && item.durationMs! > 0)
          NodeLibContentItem.formatDurationHumanReadable(item.durationMs!),
      ];
      if (meta.isNotEmpty) {
        parts.add(Flexible(
          child: Text(
            meta.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ));
      }
    }
    if (item.origin == SearchResultOrigin.dbSource) {
      final meta = <String>[
        if (item.mediaType == MediaType.video)
          'Video'
        else if (item.mediaType == MediaType.audio)
          'Audio',
        if (item.durationMs != null && item.durationMs! > 0)
          NodeLibContentItem.formatDurationHumanReadable(item.durationMs!),
        if (item.sizeInBytes != null && item.sizeInBytes! > 0)
          NodeLibContentItem.formatSize(item.sizeInBytes!),
      ];
      if (meta.isNotEmpty) {
        parts.add(Flexible(
          child: Text(
            meta.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ));
      }
    }
    if (parts.isEmpty) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, part) in parts.indexed) ...[
          if (i > 0) const SizedBox(width: 6),
          part,
        ],
      ],
    );
  }

  @override
  Widget? buildTileContent(BuildContext context, SearchResultItem item) => null;

  @override
  Widget buildTileInfoDialog(BuildContext context, SearchResultItem item) {
    return AlertDialog(
      title: Text(item.name),
      content: Text(
        'Path: ${item.path.isEmpty ? '/' : item.path}\n'
        'Origin: ${item.origin == SearchResultOrigin.explicitItem ? 'Explicit' : 'Source'}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  // ── Bottom-bar UI: scope menu (buildSortMenu slot, see note) + sort ──

  /// The scope menu is rendered via the `buildSortMenu` slot (a full
  /// [PopupMenuButton]) because the `PageAction.subActions` model cannot
  /// express the disabled/grayed scope entries or the excludes checkbox that
  /// F-007 requires. The sort menu therefore occupies the custom-page-actions
  /// slot as a [PageAction] with sub-actions.
  @override
  Widget buildSortMenu(BuildContext context) {
    final searchStore = useMediaLibSearchStore();
    final lastScope = searchStore.state.lastScope;
    final hasNoLocation = searchContext.hasNoLocation;
    final isScenario = searchContext.scenarioId != null;
    final respectExcludes = searchStore.state.respectExcludes;
    final t = getLocalizations(context);

    return PopupMenuButton<Object>(
      tooltip: t.search_scope_tip,
      icon: const Icon(Icons.tune),
      onSelected: (value) {
        if (value is SearchScope) {
          applyScope(value);
        } else if (value == _kToggleExcludes) {
          applyRespectExcludes(!respectExcludes);
        }
      },
      itemBuilder: (_) => [
        _scopeEntry(SearchScope.allSources, t.search_scope_all,
            enabled: true, current: _scope, context: context),
        _scopeEntry(SearchScope.currentDirRecursive, t.search_scope_recursive,
            enabled: !hasNoLocation, current: _scope, context: context),
        _scopeEntry(SearchScope.currentDirDirect, t.search_scope_direct,
            enabled: !hasNoLocation, current: _scope, context: context),
        if (lastScope != null)
          PopupMenuItem<Object>(
            enabled: false,
            child: Row(
              children: [
                const Icon(Icons.history, size: 18),
                const SizedBox(width: 8),
                Text(t.search_last_scope(_scopeLabel(t, lastScope)),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        if (isScenario)
          PopupMenuItem<Object>(
            value: _kToggleExcludes,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(t.search_excludes_label),
                Checkbox(
                  value: respectExcludes,
                  onChanged: null,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
      ],
    );
  }

  static const Object _kToggleExcludes = 'toggleExcludes';

  PopupMenuItem<Object> _scopeEntry(
    SearchScope scope,
    String label, {
    required bool enabled,
    required SearchScope current,
    required BuildContext context,
  }) {
    final active = scope == current;
    return PopupMenuItem<Object>(
      value: scope,
      enabled: enabled,
      child: Row(
        children: [
          Icon(
            active
                ? Icons.radio_button_checked
                : enabled
                    ? Icons.radio_button_unchecked
                    : Icons.block,
            size: 18,
            color: active
                ? Theme.of(context).colorScheme.primary
                : enabled
                    ? null
                    : Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }

  String _scopeLabel(AppLocalizations t, SearchScope scope) => switch (scope) {
        SearchScope.allSources => t.search_scope_all,
        SearchScope.currentDirRecursive => t.search_scope_recursive,
        SearchScope.currentDirDirect => t.search_scope_direct,
      };

  /// Sort + pin via the custom-page-actions slot (v6-D7 sort; v11-D3 pin).
  ///
  /// v12-D2: the pin toggle also notifies so the icon/label refresh immediately
  /// (setPinned only mutates a plain field; the page rebuilds via useListenable).
  @override
  List<PageAction> buildCustomPageActions(BuildContext context) {
    final t = getLocalizations(context);
    return [
      buildStayModePageAction(
        stay: _pinned,
        onToggle: () {
          useSearchBrowserStore().setPinned(!_pinned);
          notifyListeners();
        },
        stayLabel: t.search_stay_open,
        leaveLabel: t.search_close_on_play,
      ),
      PageAction(
        icon: const Icon(Icons.sort_rounded, size: 18),
        label: t.search_sort_tip,
        subActions: [
          for (final field in _sortFields)
            PageAction(
              icon: Icon(
                field == _sortField
                    ? (_sortDirection == SortDirection.asc
                        ? Icons.arrow_upward
                        : Icons.arrow_downward)
                    : Icons.sort_rounded,
                size: 16,
              ),
              label: '${_sortFieldLabel(t, field)}'
                  '${field == _sortField ? ' ${_sortDirection == SortDirection.asc ? '▲' : '▼'}' : ''}',
              onPressed: () => _applySort(field),
            ),
        ],
      ),
    ];
  }

  static const List<MediaSortField> _sortFields = [
    MediaSortField.name,
    MediaSortField.path,
    MediaSortField.modifiedAt,
    MediaSortField.sizeInBytes,
    MediaSortField.durationMs,
    MediaSortField.pixelCount,
  ];

  String _sortFieldLabel(AppLocalizations t, MediaSortField field) =>
      switch (field) {
        MediaSortField.name => t.search_sort_name,
        MediaSortField.path => t.search_sort_path,
        MediaSortField.modifiedAt => t.search_sort_modified,
        MediaSortField.sizeInBytes => t.search_sort_size,
        MediaSortField.durationMs => t.search_sort_duration,
        MediaSortField.pixelCount => t.search_sort_resolution,
        _ => field.name,
      };

  Future<void> _applySort(MediaSortField field) async {
    if (field == _sortField) {
      _sortDirection =
          _sortDirection == SortDirection.asc ? SortDirection.desc : SortDirection.asc;
    } else {
      _sortField = field;
    }
    await fetchPage(0, pageSize);
  }

  @override
  Future<void> changePageSize(int newSize) async {
    if (newSize < 1) return;
    newSize = clampPageSize(newSize);
    await useMediaLibSearchStore().updatePageSize(newSize);
    await fetchPage(0, pageSize);
  }

  @override
  Future<void> changeSort(SortOption sortOption) async {}

  @override
  Future<void> openSearchDialog(
      BuildContext context, VoidCallback onSearchInitiated) async {}

  // ── Trailing actions (v15-D3 per-context) ──

  @override
  List<GenericItemAction<SearchResultItem>> getItemTrailingActions(
    BuildContext context,
    SearchResultItem item,
  ) {
    if (item.isVirtualGroup) {
      // Virtual merges only support playback + navigation — no Override /
      // Append, which would degrade the group to its representative file.
      return [
        _trailingAction('Open in lib', Icons.library_music_outlined,
            (ctx) => _openInLib(ctx, item)),
        _trailingAction('Open in folder', Icons.folder_open,
            (ctx) => _openInFolder(ctx, item)),
        ...buildExplorerRevealActions<SearchResultItem>(
          context: context,
          item: item,
          fileOf: _toFileItem,
        ),
      ];
    }
    if (_isSystemPlayingSearch) {
      // A: no Override / Append — playback/queue operations live in multi-select.
      return [
        _trailingAction('Open in lib', Icons.library_music_outlined,
            (ctx) => _openInLib(ctx, item)),
        _trailingAction('Open in folder', Icons.folder_open,
            (ctx) => _openInFolder(ctx, item)),
        ...buildExplorerRevealActions<SearchResultItem>(
          context: context,
          item: item,
          fileOf: _toFileItem,
        ),
      ];
    }
    if (_isMediaLibSearch) {
      // C: explicit play/override lives in multi-select; no "Open in lib"
      // (this search already comes from the lib itself, v15-D3).
      return [
        _trailingAction('Play single', Icons.playlist_play,
            (ctx) => _playSingle(ctx, item)),
        _trailingAction('Append', Icons.playlist_add,
            (ctx) => _appendPlay(ctx, item)),
        _trailingAction('Open in folder', Icons.folder_open,
            (ctx) => _openInFolder(ctx, item)),
        ...buildExplorerRevealActions<SearchResultItem>(
          context: context,
          item: item,
          fileOf: _toFileItem,
        ),
      ];
    }
    // B: user scenario — Override opens the shared play-options dialog.
    return [
      _trailingAction('Override', Icons.playlist_play,
          (ctx) => _overridePlay(ctx, item)),
      _trailingAction('Append', Icons.playlist_add,
          (ctx) => _appendPlay(ctx, item)),
      _trailingAction('Open in lib', Icons.library_music_outlined,
          (ctx) => _openInLib(ctx, item)),
      _trailingAction('Open in folder', Icons.folder_open,
          (ctx) => _openInFolder(ctx, item)),
      ...buildExplorerRevealActions<SearchResultItem>(
        context: context,
        item: item,
        fileOf: _toFileItem,
      ),
    ];
  }

  GenericItemAction<SearchResultItem> _trailingAction(
    String label,
    IconData icon,
    void Function(BuildContext) onPressed,
  ) {
    return GenericItemAction<SearchResultItem>(
      label: label,
      icon: Icon(icon, size: 16),
      onPressed: (ctx, i) => onPressed(ctx),
    );
  }

  /// Context B trailing Override: opens the shared play-options dialog
  /// (v15-D2) — the same choices as clicking the item.
  void _overridePlay(BuildContext context, SearchResultItem item) {
    _showPlayOptionsDialog(context, item);
  }

  /// Context C trailing "Play single": single-file override (v11-D2 semantics,
  /// v15-D3).
  Future<void> _playSingle(BuildContext context, SearchResultItem item) async {
    final ok = await ScenarioPlaybackActions.runPlayAction(
      context,
      () => ScenarioPlaybackActions.playFilesOverride(
        files: [_toFileItem(item)],
        sortField: ScenarioPlaybackActions.scenarioSortFieldFromMedia(_sortField),
        sortDirection: _sortDirection,
      ),
    );
    if (!context.mounted) return;
    if (ok && !_pinned) parkSearchAndClosePopup(context);
  }

  /// Append play of a single file (v11-D2 / v14-D2): adds the file to the
  /// SystemPlaying workspace as an explicit item WITHOUT clearing it, then
  /// shows a before/after feedback dialog. Always keeps the page.
  Future<void> _appendPlay(BuildContext context, SearchResultItem item) async {
    await ScenarioPlaybackActions.appendToDefaultScenarioWithFeedback(
      context,
      [_toFileItem(item)],
    );
  }

  /// Open in lib: destroy search → media-library content page located at the
  /// file's parent directory (pathTree), opening the storage's per-storage
  /// system lib (`sys_<storageId>`, v11-D5) so the target directory resolves.
  Future<void> _openInLib(BuildContext context, SearchResultItem item) async {
    final contentStore = useMediaLibContentStore();
    final libId = await resolveLibraryForStorage(item.storageId);
    if (libId != null) {
      await contentStore.setLibrary(libId);
    }
    await contentStore.setViewMode(MediaLibContentMode.pathTree);
    final parent = parentOf(canonicalDbPath(item.path));
    await contentStore.setNavigationContext(
      storageId: item.storageId,
      parentPath: parent,
    );
    useSearchBrowserStore().destroySession();
    useSearchBrowserStore().clearAll();
    useMediaLibBrowserStore().openLibContent();
  }

  /// Open in folder: destroy search → storagedb files paged browser located at
  /// the file's parent directory (v5-D4: updateCurrentStorage takes a Storage).
  Future<void> _openInFolder(BuildContext context, SearchResultItem item) async {
    final storageStore = useStorageStore();
    final storage = storageStore.resolveStorageForNodeId(item.storageId);
    if (storage == null) return; // Q7: unknown storage → leave as-is.
    final segments = pathConv(item.path);
    final parentSegments = segments.length <= 1
        ? const <String>[]
        : segments.sublist(0, segments.length - 1);
    await storageStore.updateCurrentStorage(storage);
    await storageStore.updateCurrentPath(parentSegments);
    useSearchBrowserStore().destroySession();
    useSearchBrowserStore().clearAll();
    useMediaLibBrowserStore().openStorage();
  }

  // ── Selection actions (v15-D4 per-context) ──

  @override
  List<CustomSelectionAction<SearchResultItem>> buildCustomSelectionActions(
      BuildContext context) {
    final overrideQueue = CustomSelectionAction<SearchResultItem>(
      icon: const Icon(Icons.playlist_play),
      label: _isSystemPlayingSearch
          ? getLocalizations(context).scn_play_selected
          : getLocalizations(context).lib_override_queue,
      onPressed: (ctx, selected) async {
        final files = selected.map(_toFileItem).toList();
        if (files.isEmpty) return false;
        final ok = await ScenarioPlaybackActions.runPlayAction(
          ctx,
          () => ScenarioPlaybackActions.playFilesOverride(
            files: files,
            sortField:
                ScenarioPlaybackActions.scenarioSortFieldFromMedia(_sortField),
            sortDirection: _sortDirection,
          ),
        );
        if (!ctx.mounted) return false;
        if (ok && !_pinned) parkSearchAndClosePopup(ctx);
        return true;
      },
    );
    if (_isSystemPlayingSearch) {
      // A: only "Play selected items" — no Append (v15-D4).
      return [overrideQueue];
    }
    // B / C: Override Queue + Append Queue (operate on the selection only).
    return [
      overrideQueue,
      CustomSelectionAction<SearchResultItem>(
        icon: const Icon(Icons.playlist_add),
        label: getLocalizations(context).lib_append_queue,
        onPressed: (ctx, selected) async {
          final files = selected.map(_toFileItem).toList();
          if (files.isEmpty) return false;
          // v11-D3: append always keeps the page open; v14-D2 shows feedback.
          await ScenarioPlaybackActions.appendToDefaultScenarioWithFeedback(
            ctx,
            files,
          );
          return true;
        },
      ),
    ];
  }
}

/// Resolves the media-library tab whose sources cover [storageId], used by
/// "Open in lib" (v11-D5):
/// 1. the per-storage system lib `sys_<storageId>` when it exists;
/// 2. otherwise the first non-detached library holding a source for the storage;
/// 3. otherwise null (the caller keeps the current library, Q7 empty-page
///    fallback for detached scenario storages).
Future<String?> resolveLibraryForStorage(String storageId) async {
  final sysLibId = SystemLibraryOpenCheckService.systemLibIdFor(storageId);
  if (await DbModule.mediaLibsDao.getById(sysLibId) != null) return sysLibId;
  final sources = await DbModule.mediaLibSourcesDao.getByStorageId(storageId);
  String? userLib;
  for (final s in sources) {
    if (s.libraryId == SystemLibraryOpenCheckService.detachedLibId) continue;
    if (s.libraryId.startsWith('sys_')) return s.libraryId;
    userLib ??= s.libraryId;
  }
  return userLib;
}

enum _PlayChoice { playFile, playFolder, playSearchResult, playScenario }

/// Small colored badge for the subtitle origin annotation (D4).
class _OriginBadge extends StatelessWidget {
  final String label;
  final bool explicit;

  const _OriginBadge({required this.label, required this.explicit});

  @override
  Widget build(BuildContext context) {
    final color = explicit
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
