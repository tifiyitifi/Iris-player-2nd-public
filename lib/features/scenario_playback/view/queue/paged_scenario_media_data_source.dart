import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart' hide Chip;
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/features/media_library/store/use_media_lib_browser_store.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/paginated_browser/data_source/playlist_key_target.dart';
import 'package:iris/features/windows/desktop_keyboard/model/playlist_action.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/enum/duplicate_policy.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_lifetime.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_scope.dart';
import 'package:iris/features/scenario_playback/model/enum/playback_order.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_queue_layout.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_queue_profile.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart';
import 'package:iris/features/media_library/search/model/search_context.dart';
import 'package:iris/features/media_library/search/model/search_scope.dart';
import 'package:iris/features/media_library/search/store/search_browser_store.dart';
import 'package:iris/features/scenario_playback/actions/scenario_media_rescan_actions.dart';
import 'package:iris/features/scenario_playback/actions/scenario_explicit_dedup_actions.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_actions.dart';
import 'package:iris/features/scenario_playback/resolver/explicit_redundancy.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/scan/commands/scenario_source_scan_command.dart';
import 'package:iris/features/scenario_playback/logging/scenario_log_keys.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/store/playback_scenario_store_state.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/coordinator/scenario_browser.dart';
import 'package:iris/features/scenario_playback/view/coordinator/scenario_browser_store.dart';
import 'package:iris/features/scenario_playback/view/dialogs/show_save_scenario_dialog.dart';
import 'package:iris/features/scenario_playback/view/sort/scenario_order_choice.dart';
import 'package:iris/features/scenario_playback/view/widgets/playback_meta_row.dart';
import 'package:iris/features/tag_play/model/db/repositories/tag_play_repository.dart';
import 'package:iris/features/tag_play/model/domain/tag_play_view_state.dart';
import 'package:iris/features/tag_play/model/enum/tag_play_sort_field.dart';
import 'package:iris/features/tag_play/playback/tag_play_controller.dart';
import 'package:iris/features/tag_play/resolver/tag_view_resolver.dart';
import 'package:iris/features/tag_play/store/use_tag_play_store.dart';
import 'package:iris/features/virtual_media/resolver/vm_preflight.dart';
import 'package:iris/features/virtual_media/rule/vm_title_composer.dart'
    show kVmDisplayPrefix;
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/view/vm_child_segment_list.dart';
import 'package:iris/features/windows/explorer/menu/explorer_reveal_action.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/chip.dart';
import 'package:iris/widgets/popup.dart';
import 'package:iris/widgets/popups/storages/db/storages_db.dart';

final areaKeyLog = AreaKeyLog(ScenarioLogKeys.queue);

/// How an "Open in folder" jump leaves the current queue surface.
///
/// The floating queue popup IS itself a route, so [replacePopup] correctly swaps
/// it for the StoragesDb popup. The docked panel is NOT a route (it is embedded
/// in Home), so a route replacement would replace the ROOT route — white screen,
/// player unmounted (see the [ScenarioBrowserStore] doc). There the StoragesDb
/// must be PUSHED as a floating popup on top instead.
enum OpenInFolderHost { replaceCurrentRoute, pushPopup }

OpenInFolderHost resolveOpenInFolderHost({required bool dockedPanel}) =>
    dockedPanel
        ? OpenInFolderHost.pushPopup
        : OpenInFolderHost.replaceCurrentRoute;

/// Icon of the layout the queue's layout-switch button moves TO.
///
/// Each target is drawn as "what you will get", so the icon and the label always
/// describe the same destination: a list for V1, a single condensed row for V2,
/// a floating grid of tiles for V3.
IconData _queueLayoutIcon(ScenarioQueueLayout target) =>
    switch (target) {
      ScenarioQueueLayout.v1 => Icons.view_list_outlined,
      ScenarioQueueLayout.v2 => Icons.view_agenda_outlined,
      ScenarioQueueLayout.v3 => Icons.grid_view_rounded,
    };

/// Label of the layout the queue's layout-switch button moves TO.
String _queueLayoutLabel(ScenarioQueueLayout target, AppLocalizations t) =>
    switch (target) {
      ScenarioQueueLayout.v1 => t.scn_queue_layout_v1,
      ScenarioQueueLayout.v2 => t.scn_queue_layout_v2,
      ScenarioQueueLayout.v3 => t.scn_queue_layout_v3,
    };

/// Target rows of the queue's keyboard bulk-removes (remove-selected,
/// remove-unselected, remove-missing).
///
/// [predicate] selects the rows the action means to hit; non-selectable rows
/// are then dropped unconditionally, because a bulk remove writes a single-file
/// exclude rule and a virtual merged representative's identity IS its first
/// segment — removing it would degrade the merge to that one file.
///
/// Note that "remove-unselected" MUST run through this gate: merged rows are
/// never selectable, so without it every one of them would land in the
/// "unselected" set by construction and be removed on the first keypress.
///
/// [isSelectable] is the data source's own `isItemSelectable`, so the gate and
/// the multi-select UI can never disagree. Pure, so the filter contract is
/// unit-testable without a scenario store.
List<EffectivePlaybackItem> resolveKeyboardRemoveTargets({
  required List<EffectivePlaybackItem> pageItems,
  required bool Function(EffectivePlaybackItem item) isSelectable,
  required bool Function(EffectivePlaybackItem item) predicate,
}) =>
    [
      for (final item in pageItems)
        if (isSelectable(item) && predicate(item)) item,
    ];

/// Paginated data source for the Queue View of a PlaybackScenario.
///
/// It streams [EffectivePlaybackItem]s through the resolver and exposes the
/// required queue actions: play, remove explicit include, exclude media and
/// add to another scenario. Missing explicit items stay visible but disabled.
class PagedScenarioMediaDataSource
    extends PaginatedBrowserDataSource<EffectivePlaybackItem>
    implements PlaylistKeyTarget {
  int _currentPage = 0;
  bool _isLoading = false;
  bool _isError = false;
  List<EffectivePlaybackItem> _items = [];
  int _totalItems = 0;

  /// Expanded virtual-merged row, keyed by the representative's mediaKey
  /// (single-open: the dropdown floats over the list, so two open panels would
  /// overlap). Presentation-only (never persisted) and lives here — not in the
  /// recycled tile — so scroll recycling cannot lose it.
  String? _expandedVmKey;

  /// Canonical media keys of this scenario's explicit items that a directory /
  /// whole-storage source already covers (see [redundantExplicitItems]).
  ///
  /// Refreshed on every page fetch so the row's trailing / right-click menu can
  /// offer "Remove redundant addition" WITHOUT an async read during build or a
  /// gesture callback. Empty in the tag view (a read-only window).
  Set<String> _redundantExplicitKeys = const {};

  /// Last seen persisted page size (reactivity filter for the scenario store).
  late int _lastPageSize;

  /// Last seen media-snapshot revision (bumped by the scenario-source refresh
  /// after its scans). Used to re-fetch the page in place exactly once per run.
  late int _lastSourceScanRevision;

  StreamSubscription<PlaybackScenarioStoreState>? _storeSub;
  StreamSubscription<dynamic>? _tagViewSub;
  VoidCallback? _vmFailUnsub;

  final String scenarioId;

  /// When set (temporary Playing Queue), the back button destroys the queue
  /// instead of navigating — the queue is recreated fresh on the next open.
  final VoidCallback? onBackExit;

  /// True when this data source belongs to a `modeQueueOverride` browser
  /// (floating queue popup / docked panel). Passed explicitly by the owning
  /// page instead of reading the global
  /// [ScenarioBrowserStore.queueOverrideActive], which is set by ANY mounted
  /// queue-override browser (e.g. the always-on Windows dock).
  final bool queueOverride;

  /// True when this data source is hosted inside the right-side dock panel (not
  /// a route). "Open in folder" must then PUSH a floating popup instead of
  /// replacing the current route — see [resolveOpenInFolderHost].
  final bool dockedPanel;

  PagedScenarioMediaDataSource({
    required this.scenarioId,
    this.onBackExit,
    this.queueOverride = false,
    this.dockedPanel = false,
  }) {
    _lastPageSize = _store.state.playingScenarioQueuePageSize;
    _lastSourceScanRevision = _store.state.sourceScanRevision;
    _storeSub = _store.stream.listen((state) {
      if (state.playingScenarioQueuePageSize != _lastPageSize) {
        _lastPageSize = state.playingScenarioQueuePageSize;
        notifyListeners();
      }
      // A scenario-source refresh finished: re-fetch page 0 so newly scanned /
      // removed media appear. Keyed on its OWN revision (never playbackVersion,
      // whose mutating call sites already fetch explicitly) so this cannot
      // double-resolve.
      if (state.sourceScanRevision != _lastSourceScanRevision) {
        _lastSourceScanRevision = state.sourceScanRevision;
        fetchPage(0, pageSize);
      }
    });
    // Tag-view reactivity: entering/exiting a tag view while the queue page
    // is open must swap the rendered list live.
    _tagViewSub = useTagPlayStore().stream.listen((_) {
      if (_tagActive != _lastTagActive) {
        _lastTagActive = _tagActive;
        fetchPage(0, pageSize);
      }
    });
    _lastTagActive = _tagActive;
    // VM heal reactivity: a duration scan healing its segments republishes
    // the fail map with a new fingerprint — jump back to page 0 so the
    // degraded singles collapse into their merged item. The notifier fires
    // only on content change, so the re-resolve this fetch triggers (same
    // fingerprint) never self-loops.
    final vm = VirtualMediaService.instance;
    var lastVmFail = vm.failFingerprint;
    void onVmFail() {
      if (vm.failFingerprint == lastVmFail) return;
      lastVmFail = vm.failFingerprint;
      fetchPage(0, pageSize);
    }

    vm.failFingerprintListenable.addListener(onVmFail);
    _vmFailUnsub = () =>
        vm.failFingerprintListenable.removeListener(onVmFail);
    fetchPage(0, pageSize);
  }

  // ── Tag view mode (Playing Queue reflects the active tag play view) ──

  bool _lastTagActive = false;

  TagPlayRepository get _tagRepo => DbModule.tagPlayRepo;

  bool get _tagActive =>
      TagPlayGate.viewSwitchingEnabled &&
      useTagPlayStore().state.activeViewTagId != null;

  @override
  void dispose() {
    _storeSub?.cancel();
    _tagViewSub?.cancel();
    _vmFailUnsub?.call();
    _vmFailUnsub = null;
    super.dispose();
  }

  PlaybackScenarioStore get _store => usePlaybackScenarioStore();

  @override
  int get totalItems => _totalItems;

  @override
  int get currentPage => _currentPage;

  @override
  int get totalPages => (totalItems / pageSize).ceil().clamp(1, 99999);

  /// Persisted per-surface page size (source of truth: the scenario store).
  @override
  int get pageSize => _store.state.playingScenarioQueuePageSize;

  @override
  bool get isLoading => _isLoading;

  @override
  bool get isError => _isError;

  @override
  List<EffectivePlaybackItem> get items => _items;

  @override
  String getItemId(EffectivePlaybackItem item) => item.mediaKey;

  /// Virtual merged groups stay tappable (to play) but cannot take part in
  /// multi-selection: every bulk operation reachable here — "Exclude selected",
  /// "从 Tag 移除" and the keyboard bulk-removes — carries single-file
  /// semantics, because [_excludeRule] and the tag repo build their rules from
  /// the row's own identity and a representative's identity IS its first
  /// segment (see [EffectivePlaybackItem.virtualMerged]). Acting on it would
  /// silently degrade the merge into that one file.
  ///
  /// [media_search_data_source] enforces the same gate for the same reason.
  @override
  bool isItemSelectable(EffectivePlaybackItem item) => !item.virtualMerged;

  /// Desktop right-click reuses the row's trailing actions (see
  /// [getItemTrailingActions]).
  @override
  bool get supportsRowContextMenu => !isMobilePlatform;

  @override
  Future<void> fetchPage(int targetPage, int currentSize) async {
    _isLoading = true;

    _isError = false;
    notifyListeners();

    try {
      if (_tagActive) {
        // TAG VIEW: pages come from the tag's resolved snapshot so the
        // Playing Queue reflects exactly what the tag view plays.
        final snap = await PlaybackProviderRegistry.tagPlay.ensureSnapshot() ??
            await PlaybackProviderRegistry.tagPlay.resolveSnapshot(
              useTagPlayStore().state.activeViewTagId!,
              scenarioId,
            );
        _currentPage = targetPage;
        _totalItems = snap.length;
        final start = targetPage * currentSize;
        final end = (start + currentSize).clamp(0, snap.length);
        _items =
            start < snap.length ? snap.items.sublist(start, end) : const [];
      } else {
        final result = await _store.resolvePageFor(
          scenarioId,
          page: targetPage,
          pageSize: currentSize,
        );
        _currentPage = targetPage;
        _items = result.items;
        _totalItems = result.totalItems;
      }
    } catch (e, st) {
      _isError = true;
      // Never swallow a resolve failure: it leaves the previous page in place,
      // which reads as "the scan / sort did nothing".
      areaKeyLog.e(
          'queue fetch failed scenario=$scenarioId page=$targetPage: $e', st);
    }

    await _refreshRedundantExplicitKeys();
    _isLoading = false;
    notifyListeners();
  }

  /// Recomputes [_redundantExplicitKeys] for the just-resolved page.
  ///
  /// Only runs when the page actually shows an explicit row, so an ordinary
  /// page never pays the two definition reads. Best-effort: a failure clears
  /// the set (the row menu simply falls back to "Remove manual addition").
  Future<void> _refreshRedundantExplicitKeys() async {
    if (_tagActive || !_items.any((e) => e.explicit)) {
      _redundantExplicitKeys = const {};
      return;
    }
    try {
      final sources = await _store.getSources(scenarioId);
      final items = await _store.getExplicitItems(scenarioId);
      final redundant = redundantExplicitItems(sources: sources, items: items);
      _redundantExplicitKeys = {
        for (final e in redundant) canonicalKey(e.storageId, e.path),
      };
    } catch (e) {
      _redundantExplicitKeys = const {};
    }
  }

  /// Whether [item] is an explicit row already covered by a directory source.
  bool _isRedundantExplicit(EffectivePlaybackItem item) =>
      item.explicit &&
      _redundantExplicitKeys
          .contains(canonicalKey(item.media.storageId, item.pathValue));

  @override
  bool get supportsCurrentItem => true;

  @override
  Future<int?> resolveCurrentItemIndex() async {
    if (_tagActive) {
      final snap = await PlaybackProviderRegistry.tagPlay.ensureSnapshot();
      final cur =
          PlaybackProviderRegistry.tagPlay.currentCachedEntry;
      if (snap == null || cur == null) return null;
      return snap.indexOfKey(cur.key);
    }
    // The provider owns the coherent-prefix locate and answers with the DENSE
    // display position — exactly the number `pageForIndex`,
    // `rowInCurrentPage` and the leading column work in, so nothing has to be
    // converted back into some other space first.
    if (_store.state.activeScenarioId != scenarioId) {
      // A non-active scenario must locate ITS OWN persisted current item. The
      // active workspace's item belongs to a different queue and used to
      // highlight/scroll this row to an unrelated position.
      return (await _store.currentItemFor(scenarioId))?.virtualIndex;
    }
    if (await _store.getCurrentItem() == null) return null;
    return PlaybackProviderRegistry.scenario.establishCurrentPosition();
  }

  @override
  int rowInCurrentPage(int index) {
    // Pages ARE dense display windows, but a row can still be missing from a
    // page (a group whose members all failed to rebuild) — so locate the row
    // by the position it carries instead of trusting the offset arithmetic.
    if (_tagActive) return super.rowInCurrentPage(index);
    return _items.indexWhere((e) => e.virtualIndex == index);
  }

  @override
  Future<void> changePageSize(int newSize) async {
    if (newSize < 1) return;
    newSize = clampPageSize(newSize);
    await _store.updatePlayingScenarioQueuePageSize(newSize);
    _currentPage = 0;
    await fetchPage(0, pageSize);
  }

  @override
  Future<void> changeSort(SortOption sortOption) async {
    // Sorting is controlled by the Scenario state.
  }

  @override
  Future<bool> handleNavigationBack() async {
    final exit = onBackExit;
    if (exit != null) {
      exit();
      return true;
    }
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
  bool handleItemTap(BuildContext scenario, EffectivePlaybackItem item) {
    if (!item.available) return true;
    if (_tagActive) {
      // Tag view: jump within the tag's resolved order (bookmark persists).
      final index = _items.indexOf(item);
      if (index >= 0) {
        PlaybackProviderRegistry.tagPlay
            .jumpToIndex(_currentPage * pageSize + index);
      }
      return true;
    }
    ScenarioPlaybackActions.playResolvedItem(
      scenario,
      store: _store,
      scenarioId: scenarioId,
      item: item,
    );
    return true;
  }

  @override
  Widget buildTileInfoDialog(
      BuildContext scenario, EffectivePlaybackItem item) {
    return AlertDialog(
      title: Text(item.media.name),
      content: Text('Path: ${item.pathValue}'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(scenario),
          child: const Text('Close'),
        ),
      ],
    );
  }

  /// Reactive current-item check: reads the store's in-memory occurrence
  /// mirror via `select` during build, so the highlight follows play/next/
  /// previous live (list-independent order, positioning connection). Both
  /// sides are canonicalized so a files-paged (raw `/a/b`) mirror still
  /// matches the resolver's (`//a/b`) queue item.
  @override
  bool isCurrentItem(BuildContext context, EffectivePlaybackItem item) {
    if (_tagActive) {
      final entry = PlaybackProviderRegistry.tagPlay.currentCachedEntry;
      if (entry == null) return false;
      return canonicalKey(item.occurrenceId.storageId, item.occurrenceId.path) ==
              entry.key &&
          item.occurrenceId.occurrenceIndex == entry.occurrenceIndex;
    }
    final currentKey = usePlaybackScenarioStore().select(
      context,
      (s) => s.currentOccurrenceKey,
    );
    final itemKey = canonicalOccurrenceKey(
      item.occurrenceId.storageId,
      item.occurrenceId.path,
      item.occurrenceId.occurrenceIndex,
    );
    // A merged row stands for many physical files: when the session books a
    // member that is not the row's anchor (a sibling-group advance, or a tag
    // hand-off that captured the live segment), the row still owns it.
    final isCurrent = currentKey != null &&
        (currentKey == itemKey ||
            item.vmChildren.any(
              (c) => currentKey == '${c.mediaKey}#${c.occurrenceIndex}',
            ));
    if (currentKey != null &&
        canonicalKey(item.occurrenceId.storageId, item.occurrenceId.path) ==
            currentKey.split('#').first) {
      // CLOSE_DEBUG_LOG
      areaKeyLog.d(
          'isCurrent candidate item=$itemKey mirror=$currentKey isCurrent=$isCurrent');
    }
    return isCurrent;
  }

  /// D28/v6-D38: `available: false` placeholders render greyed + un-tappable.
  /// Offline-grey: same two-level rule as the preview surface — resolver
  /// `available` (content) OR storage disconnected (link) greys the row.
  /// Plain store read (no `select`): this predicate is also invoked outside
  /// builds (tests, preflight), and the tile rebuilds with the page anyway.
  @override
  bool isItemUnavailable(BuildContext context, EffectivePlaybackItem item) {
    if (!item.available) return true;
    return !useStorageStore().isConnected(item.media.storageId);
  }

  @override
  Widget? buildItemLeading(BuildContext scenario, EffectivePlaybackItem item) {
    final isCurrent = isCurrentItem(scenario, item);
    // The leading number is the row's position in the LIST the user is reading.
    //
    // Queue: `virtualIndex` IS that position on the element axis (one ordinary
    // file = one element, one merged group = one element whose members take no
    // row of their own), so `virtualIndex + 1` reads 1,2,3,… densely and the
    // page window it belongs to is `[position ~/ pageSize]`. The merged title's
    // `seq` is deliberately a different number: the chunk's stable identity,
    // which does not renumber when rows are filtered in or out.
    //
    // Tag view: the list is the tag's own dense snapshot. Its items now carry
    // the tag-view position (the resolver renumbers after its own sort/shuffle),
    // but the ordinal is still read from the page offset so a row that failed to
    // rebuild (absent from `_items`) cannot shift the numbering.
    final number = _tagActive
        ? _currentPage * pageSize + _items.indexOf(item) + 1
        : item.virtualIndex + 1;
    // Preflight-degraded virtual member: yellow mark, still plays as normal.
    final vmFail = VirtualMediaService.instance.failInfoFor(
      canonicalKey(item.occurrenceId.storageId, item.occurrenceId.path),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (vmFail != null)
          Tooltip(
            message: vmFailTooltip(vmFail, getLocalizations(scenario)),
            child: const Icon(
              Icons.warning_amber_rounded,
              size: 16,
              color: Colors.amber,
            ),
          ),
        if (vmFail != null) const SizedBox(width: 4),
        if (isCurrent) ...[
          Icon(
            Icons.graphic_eq,
            size: 16,
            color: Theme.of(scenario).colorScheme.primary,
          ),
          const SizedBox(width: 4),
        ],
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 16),
          child: Text(
            '$number',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent ? Theme.of(scenario).colorScheme.primary : null,
            ),
          ),
        ),
      ],
    );
  }

  @override
  String? buildItemTitle(EffectivePlaybackItem item) => item.virtualMerged
      ? '$kVmDisplayPrefix${item.media.name}'
      : item.media.name;

  @override
  Widget? buildItemSubtitle(BuildContext scenario, EffectivePlaybackItem item) {
    if (!item.available) {
      return const Chip(text: 'Unavailable', primary: true);
    }
    final isCurrent = isCurrentItem(scenario, item);
    final fileSize = item.media.maybeMap(
      file: (f) => f.sizeInBytes ?? 0,
      orElse: () => 0,
    );
    final fileDuration = item.media.maybeMap(
      file: (f) => f.durationMs ?? 0,
      orElse: () => 0,
    );
    // A virtual-merged representative carries the group's summed totals; the
    // subtitle shows those plus the segment count instead of the first
    // segment's own metadata. The progress chip keeps the single-file duration
    // (progress is stored per file).
    final segCount = item.vmSegmentCount ?? 1;
    final isMerged = item.virtualMerged && segCount > 1;
    final size = isMerged ? (item.vmTotalSizeBytes ?? fileSize) : fileSize;
    final duration =
        isMerged ? (item.vmTotalDurationMs ?? fileDuration) : fileDuration;
    final isVideo = item.media.maybeMap(
      file: (f) => f.mediaType == MediaType.video,
      orElse: () => false,
    );
    return PlaybackMetaRow(
      size: size,
      durationMs: duration,
      isMerged: isMerged,
      segmentCount: segCount,
      sortValue: _sortValueLabel(scenario, item),
      showProgress: isVideo,
      media: item.media,
      fileDurationMs: fileDuration,
      isCurrent: isCurrent,
      duplicated: item.duplicated,
      occurrenceIndex: item.occurrenceId.occurrenceIndex,
      explicit: item.explicit,
      vmChildren: item.vmChildren,
      vmTotalDurationMs: item.vmTotalDurationMs ?? duration,
      vmAnchorKey: canonicalKey(
        item.occurrenceId.storageId,
        item.occurrenceId.path,
      ),
    );
  }

  // ── Virtual-merged row expansion () ──

  @override
  bool isItemExpandable(EffectivePlaybackItem item) =>
      item.virtualMerged && item.vmChildren.length > 1;

  @override
  bool isItemExpanded(EffectivePlaybackItem item) =>
      _expandedVmKey == item.mediaKey;

  @override
  void toggleItemExpanded(EffectivePlaybackItem item) {
    if (!isItemExpandable(item)) return;
    _expandedVmKey = _expandedVmKey == item.mediaKey ? null : item.mediaKey;
    notifyListeners();
  }

  @override
  Widget? buildItemExpandedContent(
    BuildContext context,
    EffectivePlaybackItem item,
  ) {
    if (!item.virtualMerged || item.vmChildren.length <= 1) return null;
    return VmChildSegmentList(
      children: item.vmChildren,
      onPlayChild: (index) => _playVmChild(context, item, index),
    );
  }

  /// Plays the merged [item] starting from child [index]'s physical file,
  /// routing through the active surface (tag view vs scenario workspace).
  void _playVmChild(
    BuildContext context,
    EffectivePlaybackItem item,
    int index,
  ) {
    if (!item.available || index < 0 || index >= item.vmChildren.length) {
      return;
    }
    // The child's own mediaKey + occurrence is the segment bookmark: the VM
    // planner opens THAT file (its own saved progress steers the intra-segment
    // offset), and the occurrence keeps duplicated files distinct.
    final targetKey = item.vmChildren[index].mediaKey;
    final targetOcc = item.vmChildren[index].occurrenceIndex;
    // Drop the floating dropdown before playback (the row may navigate away).
    if (_expandedVmKey != null) {
      _expandedVmKey = null;
      notifyListeners();
    }
    if (_tagActive) {
      final rowIndex = _items.indexOf(item);
      if (rowIndex >= 0) {
        PlaybackProviderRegistry.tagPlay.jumpToIndexWithFile(
          _currentPage * pageSize + rowIndex,
          targetKey,
          targetOcc,
        );
      }
      return;
    }
    ScenarioPlaybackActions.playResolvedItem(
      context,
      store: _store,
      scenarioId: scenarioId,
      item: item,
      vmStartMediaKey: targetKey,
      vmStartOccurrenceIndex: targetOcc,
    );
  }

  /// The current sort field's value to display in the subtitle slot (null when
  /// nothing should be shown: name/shuffled order, duration/size sorts whose
  /// value is already the fixed size+duration text, or a null date).
  String? _sortValueLabel(
      BuildContext context, EffectivePlaybackItem item) {
    final scenario = usePlaybackScenarioStore().select(
      context,
      (s) => s.scenarios.where((c) => c.id == s.activeScenarioId).firstOrNull,
    );
    if (scenario == null ||
        scenario.order == PlaybackOrder.shuffled) {
      return null;
    }
    final DateTime? date = item.media.maybeMap(
      file: (f) => switch (scenario.sortField) {
        ScenarioSortField.modifiedAt => f.modifiedAt,
        _ => null,
      },
      orElse: () => null,
    );
    return _formatDateTime(date);
  }

  String? _formatDateTime(DateTime? date) {
    if (date == null) return null;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
  }

  @override
  List<String>? get currentBreadcrumbs {
    // Sentinels let the generic breadcrumb renderer colour the tag segment:
    // `\u0000tag:` = tag name (primary), [kNoTagCrumb] = no-tag marker
    // (subdued, localized by the renderer via `tag_no_tag`).
    const tagSentinel = '\u0000tag:';

    final scenarioName = _store.state.scenarios
        .where((c) => c.id == scenarioId)
        .firstOrNull
        ?.name;
    final crumbs = <String>[
      if (scenarioName != null && scenarioName.isNotEmpty) scenarioName,
    ];

    if (_tagActive) {
      final tagId = useTagPlayStore().state.activeViewTagId;
      final name = _tagNameCache;
      if (name != null) {
        crumbs.add('$tagSentinel$name');
        return crumbs;
      }
      if (tagId != null) {
        _tagRepo.tagById(tagId).then((t) {
          if (t != null && t.name != _tagNameCache) {
            _tagNameCache = t.name;
            notifyListeners();
          }
        });
      }
      crumbs.add('Tag 播放视图');
      return crumbs;
    }

    // Tag feature active but no tag view → canonical no-tag payload; the
    // renderer shows the localized `tag_no_tag` in subdued grey, so a real
    // tag literally named like the label can never be confused with it.
    if (TagPlayGate.enabled) {
      crumbs.add(kNoTagCrumb);
    }
    return crumbs.isEmpty ? null : crumbs;
  }

  String? _tagNameCache;

  @override
  bool get isRightToLeftBreadcrumbs => false;

  // ── Tag view helpers ──

  /// Removes the media from the ACTIVE tag, then re-resolves the view so the
  /// queue and playback stay consistent (jump-back rules relocate if needed).
  Future<void> _removeFromActiveTag(EffectivePlaybackItem item) async {
    final tagId = useTagPlayStore().state.activeViewTagId;
    if (tagId == null) return;
    final path = _pathOf(item);
    if (item.media.storageId.isEmpty || path.isEmpty) return;
    await _tagRepo.removeMember(
      tagId: tagId,
      storageId: item.media.storageId,
      pathSegments: path,
    );
    await PlaybackProviderRegistry.tagPlay.revalidate();
    await fetchPage(_currentPage, pageSize);
  }

  /// Order menu for the ACTIVE TAG VIEW: operates on the tag's own spec
  /// (never the scenario's). Shuffled toggles + re-click flips direction;
  /// Name / Tag-added are plain sort fields with filesdb-style flip.
  Widget _buildTagSortMenu(BuildContext context) {
    final t = getLocalizations(context);
    return PopupMenuButton<_TagOrderChoice>(
      icon: const Icon(Icons.sort_rounded),
      onSelected: _onTagOrderSelected,
      itemBuilder: (_) => [
        for (final choice in _TagOrderChoice.values)
          PopupMenuItem(
            value: choice,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(switch (choice) {
                  _TagOrderChoice.shuffled => t.scn_sort_shuffled,
                  _TagOrderChoice.name => t.scn_sort_name,
                  _TagOrderChoice.tagAddedAt => t.scn_tag_sort_added,
                }),
                FutureBuilder<TagPlayViewState?>(
                  future: _tagRepo
                      .stateOf(useTagPlayStore().state.activeViewTagId ?? 0),
                  builder: (ctx, snap) {
                    final s = snap.data;
                    final selected = switch (choice) {
                      _TagOrderChoice.shuffled =>
                        s?.order == PlaybackOrder.shuffled,
                      _TagOrderChoice.name =>
                        s != null &&
                            s.order != PlaybackOrder.shuffled &&
                            s.sortField == TagPlaySortField.name,
                      _TagOrderChoice.tagAddedAt =>
                        s == null ||
                            (s.order != PlaybackOrder.shuffled &&
                                s.sortField == TagPlaySortField.tagAddedAt),
                    };
                    if (!selected) return const SizedBox.shrink();
                    final desc =
                        s?.sortDirection == SortDirection.desc ||
                            s?.order == PlaybackOrder.shuffled &&
                                s?.sortDirection == SortDirection.desc;
                    return Icon(
                      desc ? Icons.arrow_downward : Icons.arrow_upward,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    );
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _onTagOrderSelected(_TagOrderChoice choice) async {
    final tagId = useTagPlayStore().state.activeViewTagId;
    if (tagId == null) return;
    final prev =
        await _tagRepo.stateOf(tagId) ?? TagViewResolver.defaultStateFor(tagId);

    TagPlayViewState next;
    if (choice == _TagOrderChoice.shuffled) {
      if (prev.order == PlaybackOrder.shuffled) {
        // Re-click flips the shuffled walk direction.
        next = prev.copyWith(
          sortDirection: prev.sortDirection == SortDirection.asc
              ? SortDirection.desc
              : SortDirection.asc,
        );
      } else {
        next = prev.copyWith(
          order: PlaybackOrder.shuffled,
          shuffleSeed: DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
          shuffleVersion: prev.shuffleVersion + 1,
          shuffleItemCount: snapshotLengthOfActiveView,
        );
      }
    } else {
      final field = switch (choice) {
        _TagOrderChoice.name => TagPlaySortField.name,
        _TagOrderChoice.tagAddedAt => TagPlaySortField.tagAddedAt,
        _TagOrderChoice.shuffled => TagPlaySortField.tagAddedAt,
      };
      final wasCurrent =
          prev.sortField == field && prev.order != PlaybackOrder.shuffled;
      next = prev.copyWith(
        order: PlaybackOrder.sequential,
        sortField: field,
        sortDirection: wasCurrent && prev.sortDirection == SortDirection.asc
            ? SortDirection.desc
            : SortDirection.asc,
      );
    }

    await _tagRepo.saveState(next);
    await PlaybackProviderRegistry.tagPlay.revalidate();
    await fetchPage(0, pageSize);
  }

  int get snapshotLengthOfActiveView =>
      PlaybackProviderRegistry.tagPlay.snapshot?.length ?? 0;

  @override
  Widget? buildTileContent(BuildContext scenario, EffectivePlaybackItem item) =>
      null;

  /// Reactively reads the active scenario definition from the store mirror
  /// (source of truth), used by the order menu and dedup button.
  Scenario? _activeScenario(BuildContext context) =>
      usePlaybackScenarioStore().select(
        context,
        (s) => s.scenarios.where((c) => c.id == s.activeScenarioId).firstOrNull,
      );

  @override
  Widget buildSortMenu(BuildContext context) {
    if (_tagActive) return _buildTagSortMenu(context);
    final scenario = _activeScenario(context);
    final current = resolveScenarioOrderChoice(
      order: scenario?.order ?? PlaybackOrder.sequential,
      sortField: scenario?.sortField ?? ScenarioSortField.name,
    );
    final direction = scenario?.sortDirection ?? SortDirection.asc;
    final sourceInternalFirst = scenario?.sourceInternalFirst ?? false;
    final isDedup = scenario?.duplicatePolicy == DuplicatePolicy.deduplicate;
    final captured = scenario?.originalSortField;
    final t = getLocalizations(context);

    return PopupMenuButton<ScenarioOrderChoice>(
      icon: const Icon(Icons.sort_rounded),
      onSelected: _onOrderSelected,
      itemBuilder: (_) => [
        _sortItem(
          context,
          ScenarioOrderChoice.shuffled,
          t.scn_order_shuffled,
          current,
          direction,
        ),
        // An ACTION, never a marked state: it restores the captured rule, so it
        // names the field it will restore instead of competing with that field's
        // own row for the arrow.
        _sortItem(
          context,
          ScenarioOrderChoice.original,
          captured == null
              ? t.scn_order_original
              : t.scn_order_original_of(_orderFieldLabel(t, captured)),
          current,
          direction,
          disabled: captured == null,
        ),
        _sortItem(
            context, ScenarioOrderChoice.name, t.scn_order_name, current, direction),
        _sortItem(context, ScenarioOrderChoice.modifiedAt, t.scn_order_modified,
            current, direction),
        _sortItem(context, ScenarioOrderChoice.durationMs, t.scn_order_duration,
            current, direction),
        _sortItem(context, ScenarioOrderChoice.sizeInBytes, t.scn_order_size,
            current, direction),
        const PopupMenuDivider(),
        _checkboxItem(
          t.scn_source_internal_first,
          sourceInternalFirst,
          onToggle: () async {
            await _store.setSourceInternalFirst(!sourceInternalFirst);
            await fetchPage(0, pageSize);
          },
        ),
        _checkboxItem(
          t.scn_dedupe,
          isDedup,
          onToggle: () async {
            await _store.toggleDuplicatePolicy();
            await fetchPage(0, pageSize);
          },
        ),
      ],
    );
  }

  /// filesdb-style sort item: the current item shows an up/down arrow;
  /// re-clicking the current item toggles the direction (see
  /// [_onOrderSelected]).
  PopupMenuItem<ScenarioOrderChoice> _sortItem(
    BuildContext context,
    ScenarioOrderChoice choice,
    String label,
    ScenarioOrderChoice current,
    SortDirection direction, {
    bool disabled = false,
  }) {
    final selected = choice == current;
    return PopupMenuItem(
      value: choice,
      enabled: !disabled,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          if (selected)
            Icon(
              direction == SortDirection.asc
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
  /// folder_first). The WHOLE ROW is the tap target, so a click on the label
  /// toggles exactly like a click on the box; the checkbox only mirrors the
  /// state and must not swallow the tap (same contract as the V2/V3 overflow
  /// rows). Toggling persists the option and refreshes page 0; the menu closes
  /// ITSELF, because `PopupMenuItem.handleTap` pops the menu route before it
  /// runs this callback — a pop from here would land on the route underneath,
  /// taking the floating queue popup (or, in the side dock, the hosting page)
  /// with it.
  PopupMenuItem<ScenarioOrderChoice> _checkboxItem(
    String label,
    bool value, {
    required Future<void> Function() onToggle,
  }) {
    return PopupMenuItem(
      onTap: onToggle,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          IgnorePointer(
            child: Checkbox(
              value: value,
              onChanged: (_) {},
            ),
          ),
        ],
      ),
    );
  }

  /// The localized label of one sort field, for the Original row's hint
  /// ("Original (Name)"): the row names the field it will restore, so the
  /// captured rule never competes with that field's own row for the arrow.
  String _orderFieldLabel(AppLocalizations t, ScenarioSortField field) {
    switch (field) {
      case ScenarioSortField.name:
        return t.scn_order_name;
      case ScenarioSortField.modifiedAt:
        return t.scn_order_modified;
      case ScenarioSortField.durationMs:
        return t.scn_order_duration;
      case ScenarioSortField.sizeInBytes:
        return t.scn_order_size;
    }
  }

  Future<void> _onOrderSelected(ScenarioOrderChoice choice) async {
    final scenario = _store.state.scenarios
        .where((c) => c.id == _store.state.activeScenarioId)
        .firstOrNull;

    if (choice == ScenarioOrderChoice.shuffled) {
      // Shuffled supports asc/desc like the other items: when already shuffled
      // a re-click flips the direction (reverse of the shuffled sequence);
      // otherwise it enables shuffle (forward, asc).
      if (scenario?.order == PlaybackOrder.shuffled) {
        await _store.toggleShuffleDirection();
      } else {
        await _store.toggleShuffle();
      }
      await fetchPage(0, pageSize);
      return;
    }

    // Leaving shuffled back to a concrete order (same source of truth as the
    // player shuffle button — both write scenario.order).
    if (scenario?.order == PlaybackOrder.shuffled) {
      await _store.toggleShuffle();
    }

    final sortField = scenario?.sortField ?? ScenarioSortField.name;
    final currentDir = scenario?.sortDirection ?? SortDirection.asc;

    if (choice == ScenarioOrderChoice.original) {
      // Original asc = the captured first-add sort; re-click toggles to
      // desc = reversed original order (D3).
      final original = scenario?.originalSortField;
      if (original != null) {
        final direction = sortField == original
            ? (currentDir == SortDirection.asc
                ? SortDirection.desc
                : SortDirection.asc)
            : SortDirection.asc;
        await _store.setSort(original, direction);
      }
    } else {
      // filesdb-style: re-clicking the CURRENT field toggles asc/desc; switching
      // to a different field starts from that field's natural direction (name
      // A→Z, the numeric axes newest/largest first). The current field is the
      // underlying scenario.sortField, so every field click responds — and the
      // menu marks that same field (see [resolveScenarioOrderChoice]).
      // `shuffled`/`original` returned above, so this row has a field.
      final target = choice.sortField!;
      final isCurrent = sortField == target;
      final direction = isCurrent
          ? (currentDir == SortDirection.asc
              ? SortDirection.desc
              : SortDirection.asc)
          : target.naturalDirection;
      await _store.setSort(target, direction);
    }
    await fetchPage(0, pageSize);
  }

  // ── PotPlayer playlist keyboard (PL >) ──

  /// Dispatches a bound `PL >` key from the focused queue list.
  ///
  /// The tag view is a read-only window onto the tag's stream, so scenario
  /// mutations (remove / sort-by-field / save / add source) are consumed as
  /// no-ops there, mirroring its hidden page actions.
  @override
  Future<bool> handlePlaylistAction(
    BuildContext context,
    PlaylistAction action, {
    int? cursorIndex,
    Set<String> selectedIds = const {},
  }) async {
    final item = (cursorIndex != null &&
            cursorIndex >= 0 &&
            cursorIndex < _items.length)
        ? _items[cursorIndex]
        : null;

    if (_tagActive) {
      switch (action) {
        case PlaylistAction.play:
          if (item == null) return true;
          final index = _items.indexOf(item);
          if (index >= 0) {
            PlaybackProviderRegistry.tagPlay
                .jumpToIndex(_currentPage * pageSize + index);
          }
          return true;
        case PlaylistAction.fileInformation:
          if (item != null) return _showInfo(context, item);
          return true;
        case PlaylistAction.openLocation:
          return _openLocation(context, item);
        case PlaylistAction.search:
          await _openQueueSearch(context);
          return true;
        default:
          return true; // consumed no-op (read-only tag window)
      }
    }

    switch (action) {
      case PlaylistAction.play:
        if (item == null) return true;
        ScenarioPlaybackActions.playResolvedItem(
          context,
          store: _store,
          scenarioId: scenarioId,
          item: item,
        );
        return true;
      case PlaylistAction.sortAscending:
        return _keyboardSetSort(direction: SortDirection.asc);
      case PlaylistAction.sortDescending:
        return _keyboardSetSort(direction: SortDirection.desc);
      case PlaylistAction.sortByFolder:
        final scenario = _store.activeScenario;
        await _store.setSourceInternalFirst(!(scenario?.sourceInternalFirst ?? false));
        await fetchPage(0, pageSize);
        return true;
      case PlaylistAction.sortByName:
        return _keyboardSetSort(field: ScenarioSortField.name);
      case PlaylistAction.sortBySize:
        return _keyboardSetSort(field: ScenarioSortField.sizeInBytes);
      case PlaylistAction.sortByDuration:
        return _keyboardSetSort(field: ScenarioSortField.durationMs);
      case PlaylistAction.sortByDate:
        return _keyboardSetSort(field: ScenarioSortField.modifiedAt);
      case PlaylistAction.sortRandom:
        await _store.shuffleRefresh();
        await fetchPage(0, pageSize);
        return true;
      case PlaylistAction.removeSelected:
        await _keyboardRemoveSelected(item, selectedIds);
        return true;
      case PlaylistAction.removeUnselected:
        await _keyboardRemoveUnselected(selectedIds);
        return true;
      case PlaylistAction.removeMissing:
        await _keyboardRemoveMissing();
        return true;
      case PlaylistAction.fileInformation:
        if (item != null) return _showInfo(context, item);
        return true;
      case PlaylistAction.openLocation:
        return _openLocation(context, item);
      case PlaylistAction.search:
        await _openQueueSearch(context);
        return true;
      case PlaylistAction.savePlaylist:
        await _runSaveScenario(context);
        return true;
      case PlaylistAction.openPlaylist:
        await openManagerFromQueue(
          context,
          scenarioId: scenarioId,
          direction: useAppStore().state.defaultPopupDirection,
        );
        return true;
      case PlaylistAction.closePlaylist:
        await handleNavigationBack();
        return true;
      case PlaylistAction.addToPlaybackQueue:
        if (item != null) await _showAddToOtherScenarioDialog(context, item);
        return true;
      case PlaylistAction.addFiles:
      case PlaylistAction.addFolder:
        _openAddSource();
        return true;
      case PlaylistAction.detectDurations:
      case PlaylistAction.addUrl:
      case PlaylistAction.copy:
      case PlaylistAction.paste:
      case PlaylistAction.pasteRecent:
      case PlaylistAction.editTitle:
      case PlaylistAction.renameFile:
      case PlaylistAction.albumNew:
      case PlaylistAction.albumEdit:
      case PlaylistAction.albumDelete:
      // Cursor + selection are owned by the page (never delegated here).
      case PlaylistAction.cursorUp:
      case PlaylistAction.cursorDown:
      case PlaylistAction.cursorFirst:
      case PlaylistAction.cursorLast:
      case PlaylistAction.selectAll:
      case PlaylistAction.invertSelection:
        return true; // consumed no-op (no IRIS flow)
    }
  }

  /// Sets [field] (default: the current field) with an explicit direction and
  /// refreshes. Leaves shuffle first, mirroring the order menu.
  ///
  /// A field SWITCH without an explicit direction picks the field's natural
  /// direction; re-selecting the current field keeps the current direction (the
  /// paired `sortAscending` / `sortDescending` actions set it outright).
  Future<bool> _keyboardSetSort({
    ScenarioSortField? field,
    SortDirection? direction,
  }) async {
    final scenario = _store.activeScenario;
    if (scenario?.order == PlaybackOrder.shuffled) {
      await _store.toggleShuffle();
    }
    final current = scenario?.sortField ?? ScenarioSortField.name;
    final target = field ?? current;
    final dir = direction ??
        (target == current
            ? (scenario?.sortDirection ?? SortDirection.asc)
            : target.naturalDirection);
    await _store.setSort(target, dir);
    await fetchPage(0, pageSize);
    return true;
  }

  Future<void> _keyboardRemoveSelected(
    EffectivePlaybackItem? cursorItem,
    Set<String> selectedIds,
  ) async {
    final targets = selectedIds.isNotEmpty
        ? resolveKeyboardRemoveTargets(
            pageItems: _items,
            isSelectable: isItemSelectable,
            predicate: (i) => selectedIds.contains(getItemId(i)),
          )
        : <EffectivePlaybackItem>[
            // Cursor fallback: the row under the cursor obeys the same gate —
            // it may be a merged representative.
            if (cursorItem != null && isItemSelectable(cursorItem)) cursorItem,
          ];
    for (final e in targets) {
      if (e.explicit) {
        await _removeExplicitInclude(e);
      } else {
        // Await the write: _afterQueueMutation re-reads the content signature
        // below, which is derived from these very rows. A fire-and-forget
        // insert races the refresh and can serve the pre-edit stream.
        await _store.addExcludeRule(_excludeRule(e,
            scope: ExcludeScope.scenario,
            lifetime: ExcludeLifetime.temporary));
      }
    }
    if (targets.any((e) => !e.explicit)) await _afterQueueMutation();
  }

  Future<void> _keyboardRemoveUnselected(Set<String> selectedIds) async {
    if (selectedIds.isEmpty) return;
    // The gate is load-bearing here: merged rows are never selectable, so
    // without it they would all count as "unselected" and be removed at once.
    final targets = resolveKeyboardRemoveTargets(
      pageItems: _items,
      isSelectable: isItemSelectable,
      predicate: (i) => !selectedIds.contains(getItemId(i)),
    );
    for (final e in targets) {
      await _store.addExcludeRule(_excludeRule(e,
          scope: ExcludeScope.scenario, lifetime: ExcludeLifetime.temporary));
    }
    await _afterQueueMutation();
  }

  Future<void> _keyboardRemoveMissing() async {
    final missing = resolveKeyboardRemoveTargets(
      pageItems: _items,
      isSelectable: isItemSelectable,
      predicate: (i) => !i.available,
    );
    if (missing.isEmpty) return;
    for (final e in missing) {
      await _store.addExcludeRule(_excludeRule(e,
          scope: ExcludeScope.scenario, lifetime: ExcludeLifetime.temporary));
    }
    await _afterQueueMutation();
  }

  Future<bool> _showInfo(
    BuildContext context,
    EffectivePlaybackItem item,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => buildTileInfoDialog(context, item),
    );
    return true;
  }

  Future<bool> _openLocation(
    BuildContext context,
    EffectivePlaybackItem? item,
  ) async {
    if (item == null) return true;
    final path = _pathOf(item);
    if (path.isEmpty) return true;
    await _openInFolderDb(
      context,
      item,
      path,
      useAppStore().state.defaultPopupDirection,
    );
    return true;
  }

  /// Save the SystemPlaying workspace (shared by the Save page action and the
  /// `F2` playlist key).
  Future<void> _runSaveScenario(BuildContext context) async {
    final sys = _store.systemPlayingScenario;
    if (sys == null || !context.mounted) return;
    final result = await showSaveScenarioDialog(context, workspace: sys);
    if (!context.mounted) return;
    final ok = await runSaveScenarioAction(
      context,
      sys,
      action: result.action,
      name: result.name,
      description: result.description,
      targetScenarioId: result.targetScenarioId,
    );
    if (!ok) return;
    await _store.refreshScenarios();
    await _store.bumpPlaybackVersion();
    await fetchPage(0, pageSize);
  }

  /// Opens the source browser so `Ctrl+I` / `Ctrl+O` can add files/folders.
  void _openAddSource() {
    final b = useScenarioBrowserStore()
      ..setBrowseSeed(storageId: null, path: null);
    if (queueOverride) {
      b.setQueueOverrideMode(ScenarioBrowserMode.browse);
    } else {
      b.setMode(ScenarioBrowserMode.browse);
    }
  }

  @override
  List<PageAction> buildTrailingPageActions(BuildContext scenarioContext) {
    final appStore = useAppStore();
    // The layout switch is a QUEUE-wide control, so it lives in the trailing
    // group in every layout: V1 renders it as a button left of the close X, V2
    // and V3 fold the whole trailing group into their overflow menu.
    //
    // It cycles within the CURRENT screen shape only — using the button on a
    // phone must not change what the desktop will render.
    final profile = scenarioQueueProfileOf(scenarioContext, state: appStore.state);
    final layout =
        appStore.select(scenarioContext, (s) => s.scenarioQueueLayoutFor(profile));
    // The label names the layout the button moves TO, which is what makes a
    // three-step cycle usable without a submenu.
    final target = nextScenarioQueueLayout(layout);
    final t = getLocalizations(scenarioContext);
    final actions = <PageAction>[
      PageAction(
        icon: Icon(_queueLayoutIcon(target), size: 18),
        label: _queueLayoutLabel(target, t),
        onPressed: () => unawaited(appStore.toggleScenarioQueueLayout(profile)),
      ),
    ];

    if (isMobilePlatform) return actions;
    // Dock/float toggle is desktop-only (手机不需要侧边/浮动).
    // Dock/float toggle pinned at the far right of the toolbar (just left of
    // the close button), for both the tag view and the normal queue.
    final docked = appStore
        .select(scenarioContext, (s) => s.playlistPanelMode.name == 'dockedRight');
    actions.add(PageAction(
      icon: Icon(
        docked ? Icons.view_sidebar_rounded : Icons.open_in_new_rounded,
        size: 18,
        color: docked ? Theme.of(scenarioContext).colorScheme.primary : null,
      ),
      label: docked ? t.dock_playlist_to_float : t.dock_playlist_to_dock,
      onPressed: () => unawaited(appStore.togglePlaylistPanelMode()),
    ));
    return actions;
  }

  @override
  List<PageAction> buildCustomPageActions(BuildContext scenarioContext) {
    // Tag view: the queue is a read window onto the tag's resolved stream —
    // scenario mutation entries (save/manage/shuffle-refresh) stay hidden.
    if (_tagActive) {
      if (!useAppStore().select(scenarioContext, (s) => s.useMetadataSettings)) return const [];
      return [
        PageAction(
          icon: const Icon(Icons.search, size: 18),
          label: getLocalizations(scenarioContext).browser_search,
          onPressed: () => _openQueueSearch(scenarioContext),
        ),
      ];
    }

    final t = getLocalizations(scenarioContext);
    final actions = <PageAction>[
      PageAction(
        icon: const Icon(Icons.search, size: 18),
        label: t.browser_search,
        onPressed: () => _openQueueSearch(scenarioContext),
      ),
      PageAction(
        icon: const Icon(Icons.tune, size: 18),
        label: t.scn_manage_scenario,
        onPressed: () => openManagerFromQueue(
          scenarioContext,
          scenarioId: scenarioId,
          direction: useAppStore().state.defaultPopupDirection,
        ),
      ),
      PageAction(
        icon: const Icon(Icons.autorenew_rounded, size: 16),
        label: t.scn_rescan_sources,
        onPressed: ScenarioSourceScanCommand.isEnabled()
            ? () async {
                await ScenarioSourceScanCommand.run(
                  scenarioContext,
                  scenarioId: scenarioId,
                );
                await fetchPage(0, pageSize);
              }
            : null,
      ),
      PageAction(
        icon: const Icon(Icons.cleaning_services_outlined, size: 18),
        label: t.scn_dedupe_explicit_action,
        onPressed: () async {
          await ScenarioExplicitDedupActions.runWithDialogs(
            scenarioContext,
            scenarioId: scenarioId,
          );
          await fetchPage(0, pageSize);
        },
      ),
      PageAction(
        icon: const Icon(Icons.casino_outlined, size: 18),
        label: t.scn_shuffle_refresh,
        onPressed: () async {
          await _store.shuffleRefresh();
          await fetchPage(0, pageSize);
        },
      ),
    ];

    // D19: the Save dialog ALWAYS operates on the systemPlaying workspace row
    // (never the data source's scenarioId); hide the button defensively when
    // the workspace row is absent.
    final sys = _store.systemPlayingScenario;
    if (sys != null) {
      actions.insert(
        0,
        PageAction(
          icon: const Icon(Icons.save_outlined),
          label: t.browser_save,
          onPressed: () async {
            if (!scenarioContext.mounted) return;
            await _runSaveScenario(scenarioContext);
          },
        ),
      );
    }
    return actions;
  }

  @override
  List<GenericItemAction<EffectivePlaybackItem>> getItemTrailingActions(
    BuildContext scenario,
    EffectivePlaybackItem item,
  ) {
    final actions = <GenericItemAction<EffectivePlaybackItem>>[];
    // NOT a reactive select: this action list is built both during `build`
    // (trailing "more" button) and from a gesture callback (desktop right-click
    // menu), and provider asserts `select` outside build. The value only feeds
    // the onPressed handlers, so a snapshot read is correct on both paths (and
    // matches the three other `defaultPopupDirection` reads in this file).
    final popupDirection = useAppStore().state.defaultPopupDirection;
    final t = getLocalizations(scenario);

    if (_tagActive) {
      // Tag view semantics: Remove = un-tag this media from the ACTIVE tag
      // (scenario excludes/explicit edits stay scenario-only).
      actions.add(GenericItemAction<EffectivePlaybackItem>(
        label: t.scn_remove_from_tag,
        icon: const Icon(Icons.remove_circle_outline, size: 16),
        onPressed: (ctx, i) {
          _removeFromActiveTag(i as EffectivePlaybackItem);
        },
      ));
      final path = _pathOf(item);
      if (path.isNotEmpty) {
        actions.add(GenericItemAction<EffectivePlaybackItem>(
          label: t.open_in_folder,
          icon: const Icon(Icons.folder_open, size: 16),
          onPressed: (ctx, i) {
            _openInFolderDb(
              ctx,
              i as EffectivePlaybackItem,
              path,
              popupDirection,
            );
          },
        ));
      }
      // Windows desktop: the same row in Explorer (empty off-Windows / remote).
      actions.addAll(buildExplorerRevealActions<EffectivePlaybackItem>(
        context: scenario,
        item: item,
        fileOf: _revealFileFor,
      ));
      return actions;
    }

    if (item.explicit) {
      // An explicit row already covered by a directory source is redundant:
      // label the removal so the user understands why it can go (the operation
      // is the same single-row removal either way).
      final redundant = _isRedundantExplicit(item);
      actions.add(GenericItemAction<EffectivePlaybackItem>(
        label: redundant
            ? t.scn_remove_redundant_addition
            : t.scn_remove_manual_addition,
        icon: Icon(
          redundant
              ? Icons.cleaning_services_outlined
              : Icons.remove_circle_outline,
          size: 16,
        ),
        onPressed: (ctx, i) {
          _removeExplicitInclude(i as EffectivePlaybackItem);
        },
      ));
    }

    // Remove for this playing session only (temporary scenario-scope exclude).
    actions.add(GenericItemAction<EffectivePlaybackItem>(
      label: t.scn_add_temp_exclude,
      icon: const Icon(Icons.remove_circle_outline, size: 16),
      onPressed: (ctx, i) async {
        final e = i as EffectivePlaybackItem;
        await _store.addExcludeRule(_excludeRule(e,
            scope: ExcludeScope.scenario, lifetime: ExcludeLifetime.temporary));
        await _afterQueueMutation();
      },
    ));

    // Skip from this source only (source-scope persistent exclude).
    final originSourceId =
        item.origins.isEmpty ? null : item.origins.first.sourceId;
    if (originSourceId != null) {
      actions.add(GenericItemAction<EffectivePlaybackItem>(
        label: t.scn_add_source_exclude,
        icon: const Icon(Icons.filter_alt_off, size: 16),
        onPressed: (ctx, i) async {
          final e = i as EffectivePlaybackItem;
          await _store.addExcludeRule(_excludeRule(e,
              scope: ExcludeScope.source,
              lifetime: ExcludeLifetime.persistent,
              sourceId: originSourceId));
          await _afterQueueMutation();
        },
      ));
    }

    // Permanent block (persistent scenario-scope exclude — does NOT survive
    // the next Override, E1).
    actions.add(GenericItemAction<EffectivePlaybackItem>(
      label: t.scn_add_perm_exclude,
      icon: const Icon(Icons.block, size: 16),
      onPressed: (ctx, i) async {
        final e = i as EffectivePlaybackItem;
        await _store.addExcludeRule(_excludeRule(e,
            scope: ExcludeScope.scenario,
            lifetime: ExcludeLifetime.persistent));
        await _afterQueueMutation();
      },
    ));

    actions.add(GenericItemAction<EffectivePlaybackItem>(
      label: t.browse_add_scenario,
      icon: const Icon(Icons.playlist_add, size: 16),
      onPressed: (ctx, i) {
        _showAddToOtherScenarioDialog(ctx, i as EffectivePlaybackItem);
      },
    ));

    final path = _pathOf(item);
    if (path.isNotEmpty) {
      actions.add(GenericItemAction<EffectivePlaybackItem>(
        label: t.open_in_folder,
        icon: const Icon(Icons.folder_open, size: 16),
        onPressed: (ctx, i) {
          _openInFolderDb(
            ctx,
            i as EffectivePlaybackItem,
            path,
            popupDirection,
          );
        },
      ));
    }

    // Desktop-only rescan trio: this file / its containing folder / the source
    // that produced it. Each scope invalidates through the same media-revision
    // funnel as a full source refresh. "Rescan source" is GREYED (not hidden)
    // when the row has no originating source (an explicit single-file pick).
    if (!isMobilePlatform && path.isNotEmpty && item.media is MediaFile) {
      // Offline-grey. An unknown storage greys too: every scope needs the
      // Storage object to act on, and an enabled entry that then silently
      // no-ops is worse than a visibly disabled one.
      final storage = useStorageStore().findById(item.media.storageId);
      final online =
          storage != null && useStorageStore().isConnected(storage.id);
      actions.add(GenericItemAction<EffectivePlaybackItem>(
        label: t.scn_rescan_file,
        icon: const Icon(Icons.refresh_rounded, size: 16),
        enabled: online,
        onPressed: (ctx, i) => _runRowRescan(
          ctx,
          'file',
          i as EffectivePlaybackItem,
          ScenarioMediaRescanActions.rescanFile,
        ),
      ));
      actions.add(GenericItemAction<EffectivePlaybackItem>(
        label: t.scn_rescan_dir,
        icon: const Icon(Icons.manage_search_rounded, size: 16),
        enabled: online,
        onPressed: (ctx, i) => _runRowRescan(
          ctx,
          'dir',
          i as EffectivePlaybackItem,
          ScenarioMediaRescanActions.rescanDirectory,
        ),
      ));
      actions.add(GenericItemAction<EffectivePlaybackItem>(
        label: t.scn_rescan_source,
        icon: const Icon(Icons.autorenew_rounded, size: 16),
        enabled: online && item.origins.isNotEmpty,
        onPressed: (ctx, i) => _runRowRescan(
          ctx,
          'source',
          i as EffectivePlaybackItem,
          ScenarioMediaRescanActions.rescanSource,
        ),
      ));
    }

    // Windows desktop: hand the row to Explorer. Added last so it trails the
    // queue-management entries, matching the other surfaces.
    actions.addAll(buildExplorerRevealActions<EffectivePlaybackItem>(
      context: scenario,
      item: item,
      fileOf: _revealFileFor,
    ));

    return actions;
  }

  /// Runs one row rescan scope, then refreshes page 0 in place.
  ///
  /// [GenericItemAction.onPressed] is a `void` callback, so nothing can await
  /// it: without this guard a throw (DAO error, failed scan, unmounted context)
  /// would surface as an unhandled async error instead of a log line. SnackBars
  /// are out of convention — a failed rescan is logged on `log.scenario.queue`
  /// and the page is still refreshed, because a partial write is better shown
  /// than hidden.
  void _runRowRescan(
    BuildContext context,
    String scope,
    EffectivePlaybackItem item,
    Future<void> Function(BuildContext, EffectivePlaybackItem) action,
  ) async {
    try {
      await action(context, item);
    } catch (e, st) {
      areaKeyLog.e('rescan $scope failed: $e', st);
    }
    try {
      await fetchPage(0, pageSize);
    } catch (e, st) {
      areaKeyLog.e('rescan $scope page refresh failed: $e', st);
    }
  }

  /// Storage-relative path segments of the media item.
  List<String> _pathOf(EffectivePlaybackItem item) => item.media.maybeMap(
        file: (f) => f.path,
        orElse: () => const <String>[],
      );

  /// Projects a queue row to the [FileItem] the "Open in Explorer" action
  /// needs, or null for non-file rows (directories never appear in the queue).
  FileItem? _revealFileFor(EffectivePlaybackItem item) => item.media.maybeMap(
        file: (f) => _revealFileItem(f, item.media.storageId),
        orElse: () => null,
      );

  FileItem _revealFileItem(MediaFile file, String storageId) {
    final storage = useStorageStore().findById(storageId);
    return FileItem(
      storageId: storageId,
      storageType: storage?.type ?? StorageType.none,
      name: file.name,
      uri: mediaNodePlayableUri(storage, file.path, uri: file.uri),
      path: file.path,
      size: file.sizeInBytes ?? 0,
      durationMs: file.durationMs,
      lastModified: file.modifiedAt,
      type: switch (file.mediaType) {
        MediaType.video => ContentType.video,
        MediaType.audio => ContentType.audio,
        _ => ContentType.other,
      },
    );
  }

  /// Jumps into the storagedb file browser at the item's folder
  /// (open-in-folder mechanism).
  Future<void> _openInFolderDb(
    BuildContext scenario,
    EffectivePlaybackItem item,
    List<String> path,
    PopupDirection direction,
  ) async {
    if (path.isEmpty) return;
    final storageStore = useStorageStore();

    final storageId = item.media.storageId;
    Storage? storage = storageStore.findById(storageId);
    if (storage == null) {
      final localStorages = await getLocalStorages(scenario);
      storage ??= localStorages.firstWhereOrNull(
        (element) =>
            element.basePath.isNotEmpty && element.basePath.first == path.first,
      );
      storage ??= LocalStorage(
        type: StorageType.internal,
        name: path.first,
        basePath: [path.first],
      );
    }

    if (!scenario.mounted) return;

    // The media's parent folder (storage-relative path, basePath included).
    final parentSegments =
        path.length > 1 ? path.sublist(0, path.length - 1) : const <String>[];

    // Defensive: if the resolved storage's basePath is not already a prefix of
    // the parent path (media stored without basePath), prepend it so the
    // storage browser lands on the correct folder.
    final List<String> target;
    if (storage.basePath.isNotEmpty &&
        !_isPrefix(storage.basePath, parentSegments)) {
      target = [...storage.basePath, ...parentSegments];
    } else {
      target = parentSegments;
    }

    storageStore.updateCurrentPath(target);
    storageStore.updateCurrentStorage(storage);

    // Leave any scenario/lib sub-interface mode so the fresh StoragesDb
    // renders the file browser instead of the stale sub-interface.
    useMediaLibBrowserStore().closeBrowser();

    // The docked panel is embedded in Home (not a route): replacing the current
    // route there would replace the ROOT route and blank the whole app. Push a
    // floating StoragesDb popup instead (see [resolveOpenInFolderHost]).
    if (resolveOpenInFolderHost(dockedPanel: dockedPanel) ==
        OpenInFolderHost.pushPopup) {
      showPopup(
        context: scenario,
        child: const StoragesDb(),
        direction: direction,
      );
    } else {
      replacePopup(
        context: scenario,
        child: const StoragesDb(),
        direction: direction,
      );
    }
  }

  static bool _isPrefix(List<String> prefix, List<String> path) {
    if (prefix.length > path.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (prefix[i] != path[i]) return false;
    }
    return true;
  }

  @override
  List<CustomSelectionAction<EffectivePlaybackItem>>
      buildCustomSelectionActions(BuildContext scenario) {
    // Offline-grey audit: both actions here (remove-from-tag, exclude) are
    // pure local-DB mutations — no live listing involved — so they stay
    // enabled while offline. Playback of offline rows fails at the player
    // with its existing error UI; queue rows themselves grey via
    // isItemUnavailable.
    if (_tagActive) {
      final t = getLocalizations(scenario);
      return [
        CustomSelectionAction<EffectivePlaybackItem>(
          icon: const Icon(Icons.remove_circle_outline, size: 18),
          label: t.scn_remove_from_tag,
          onPressed: (ctx, selected) async {
            for (final item in selected) {
              await _removeFromActiveTag(item);
            }
            return true;
          },
        ),
      ];
    }
    final t = getLocalizations(scenario);
    return [
      CustomSelectionAction<EffectivePlaybackItem>(
        icon: const Icon(Icons.remove_circle_outline, size: 18),
        label: t.scn_add_perm_exclude_selected,
        onPressed: (ctx, selected) async {
          for (final item in selected) {
            await _store.addExcludeRule(_excludeRule(item,
                scope: ExcludeScope.scenario,
                lifetime: ExcludeLifetime.persistent));
          }
          await _afterQueueMutation();
          return true;
        },
      ),
    ];
  }

  // ── Actions ──

  /// Re-validates the current item (B3) and refreshes the page after any
  /// mutation that may have removed the currently playing item.
  Future<void> _afterQueueMutation() async {
    await _store.bumpPlaybackVersion();
    await ScenarioPlaybackProvider(store: _store).revalidateCurrent();
    await fetchPage(_currentPage, pageSize);
  }

  Future<void> _removeExplicitInclude(EffectivePlaybackItem item) async {
    final includes = await _store.getExplicitItems(scenarioId);
    final match = includes.firstWhereOrNull(
      (inc) =>
          inc.storageId == item.media.storageId && inc.path == item.pathValue,
    );
    if (match != null) {
      await _store.removeExplicitInclude(match.id);
      await _afterQueueMutation();
    }
  }

  Future<void> _showAddToOtherScenarioDialog(
      BuildContext scenario, EffectivePlaybackItem item) async {
    final scenarios = _store.state.scenarios;
    final others = scenarios.where((c) => c.id != scenarioId).toList();
    if (others.isEmpty) return;
    if (!scenario.mounted) return;

    await showDialog<void>(
      context: scenario,
      builder: (ctx) => SimpleDialog(
        title: Text(getLocalizations(ctx).browse_add_scenario),
        children: others
            .map(
              (c) => SimpleDialogOption(
                onPressed: () {
                  _store.addExplicitItemFor(
                    scenarioId: c.id,
                    storageId: item.media.storageId,
                    path: item.pathValue,
                  );
                  Navigator.pop(ctx);
                },
                child: Text(c.name),
              ),
            )
            .toList(),
      ),
    );
  }

  Future<void> _openQueueSearch(BuildContext context) async {
    final sources = await _store.getSources(scenarioId);
    final explicitItems = await _store.getExplicitItems(scenarioId);
    final searchSources = <SearchSource>[
      for (final s in sources)
        SearchSource(
          storageId: s.storageId,
          path: s.path.isEmpty ? null : s.path,
          // An empty-path folder source is NOT whole-storage: the `directory`
          // predicate carries recursion, so a non-recursive root source stays
          // root-level (matching playback, which resolves it to direct
          // children only). Mapping it to `storage` ignored `recursive`.
          kind: s.sourceKind == ScenarioSourceKind.file
              ? MediaSourceKind.file
              : MediaSourceKind.directory,
          recursive: s.recursive,
          scenarioSourceId: s.id,
        ),
    ];
    final searchContext = SearchContext(
      entryContext: SearchEntryContext.scenarioQueue,
      scenarioId: scenarioId,
      sources: searchSources,
      explicitItems: [
        for (final e in explicitItems)
          SearchExplicitItem(storageId: e.storageId, path: e.path),
      ],
    );
    useSearchBrowserStore().setScenarioQueueEntry(context: searchContext);
    final browser = useScenarioBrowserStore();
    if (queueOverride) {
      // Queue-override panel (floating popup / dock): switch the page IN
      // PLACE — the persisted manager mode must stay untouched, and a route
      // swap is impossible in the docked case (queue is not a route).
      browser.setQueueOverrideMode(ScenarioBrowserMode.search);
    } else {
      browser.setMode(ScenarioBrowserMode.search);
    }
  }

  ScenarioExcludeRule _excludeRule(
    EffectivePlaybackItem item, {
    required ExcludeScope scope,
    required ExcludeLifetime lifetime,
    int? sourceId,
  }) {
    return ScenarioExcludeRule(
      id: 0,
      scenarioId: scenarioId,
      scope: scope,
      lifetime: lifetime,
      sourceId: sourceId,
      kind: ExcludeRuleKind.media,
      storageId: item.media.storageId,
      path: item.pathValue,
    );
  }
}

/// Order choices of the ACTIVE TAG VIEW's menu.
enum _TagOrderChoice {
  shuffled,
  name,
  tagAddedAt,
}
