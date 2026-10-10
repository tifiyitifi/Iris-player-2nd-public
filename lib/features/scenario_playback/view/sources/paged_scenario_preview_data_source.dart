import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart' hide Chip;
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/store/use_media_lib_browser_store.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/paginated_browser/data_source/playlist_key_target.dart';
import 'package:iris/features/windows/desktop_keyboard/model/playlist_action.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_sort_spec.dart';
import 'package:iris/features/scenario_playback/model/enum/duplicate_policy.dart';
import 'package:iris/features/scenario_playback/model/enum/playback_order.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_actions.dart';
import 'package:iris/features/scenario_playback/actions/stay_mode_page_action.dart';
import 'package:iris/features/scenario_playback/store/playback_scenario_store_state.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/features/scenario_playback/view/sort/scenario_order_choice.dart';
import 'package:iris/features/scenario_playback/view/widgets/playback_meta_row.dart';
import 'package:iris/features/virtual_media/resolver/vm_preflight.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/view/vm_child_segment_list.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/chip.dart';

/// Read-only resolve preview of any scenario (spec §7.3 / B2).
///
/// Swapped in-place inside the management page when "Preview resolve queue" is
/// toggled: shows the resolved effective items (global index, progress%) with
/// its own preview action bar (self-switching: exit preview / sort / page nav /
/// home). Items never mutate the workspace directly; tapping prompts the
/// destructive Override confirm (B2) before playing.
///
/// Sorting is TEMPORARY and LOCAL to the preview: the sort menu (full
/// filesdb/queue-style Shuffled / Original / field / direction / 去重 / 同目录
/// 连续) only mutates the in-memory [ScenarioSortSpec] and re-resolves through
/// [PlaybackScenarioStore.resolvePageFor] overrides. Nothing is written to any
/// scenario — the active and the previewed scenario's DB Definition stay
/// untouched until an item is tapped (which commits the sort view to the
/// systemPlaying workspace), and the view is discarded on dispose.
class PagedScenarioPreviewDataSource
    extends PaginatedBrowserDataSource<EffectivePlaybackItem>
    implements PlaylistKeyTarget {
  int _currentPage = 0;
  bool _isLoading = true;
  bool _isError = false;
  List<EffectivePlaybackItem> _items = [];
  int _totalItems = 0;

  /// Expanded virtual-merged row, keyed by the representative's mediaKey
  /// (single-open: the dropdown floats over the list). Presentation-only, never
  /// persisted; lives on the data source because the paged tile is recycled.
  String? _expandedVmKey;

  /// Local, non-persisted sort view of the previewed scenario. Seeded from the
  /// scenario's DB Definition + state in [_init]; mutated only by the preview
  /// sort menu / Shuffle refresh via `copyWith`.
  ScenarioSortSpec _sortConfig = const ScenarioSortSpec(
    sortField: ScenarioSortField.name,
    sortDirection: SortDirection.asc,
    order: PlaybackOrder.sequential,
  );

  /// Last seen persisted stay-on-tap flag (reactivity filter for the scenario store).
  bool _lastStayOnTap = false;

  /// Last seen persisted page size (reactivity filter for the scenario store).
  late int _lastPageSize;
  StreamSubscription<PlaybackScenarioStoreState>? _storeSub;
  VoidCallback? _vmFailUnsub;

  final String scenarioId;

  /// Called when the user exits preview mode (back to the management list).
  final VoidCallback onExitPreview;

  PagedScenarioPreviewDataSource({
    required this.scenarioId,
    required this.onExitPreview,
  }) {
    _lastPageSize = _store.state.scenarioPreviewQueuePageSize;
    _lastStayOnTap = _store.state.scenarioPreviewStayOnTap;
    _storeSub = _store.stream.listen((state) {
      if (state.scenarioPreviewQueuePageSize != _lastPageSize ||
          state.scenarioPreviewStayOnTap != _lastStayOnTap) {
        _lastPageSize = state.scenarioPreviewQueuePageSize;
        _lastStayOnTap = state.scenarioPreviewStayOnTap;
        notifyListeners();
      }
    });
    // VM heal reactivity (see PagedScenarioMediaDataSource): healed
    // segments republish the fail fingerprint — jump back to page 0 so the
    // degraded singles collapse into their merged item.
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
    _init();
  }

  /// Seeds the sort view from the scenario's DB Definition + state (the same
  /// source the dirty-check reads), so the preview order matches the persisted
  /// order — including the playing shuffle seed for the systemPlaying scenario.
  Future<void> _init() async {
    final scenario = await _store.getScenario(scenarioId);
    final state = await _store.getState(scenarioId);
    _sortConfig = ScenarioSortSpec.fromScenario(
      scenario ?? Scenario(id: scenarioId, name: ''),
      state?.shuffleSeed,
    );
    await fetchPage(0, pageSize);
  }

  @override
  void dispose() {
    _storeSub?.cancel();
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
  int get pageSize => _store.state.scenarioPreviewQueuePageSize;

  @override
  bool get isLoading => _isLoading;

  @override
  bool get isError => _isError;

  @override
  List<EffectivePlaybackItem> get items => _items;

  @override
  String getItemId(EffectivePlaybackItem item) => item.mediaKey;

  @override
  Future<void> fetchPage(int targetPage, int currentSize) async {
    _isLoading = true;
    _isError = false;
    notifyListeners();

    try {
      final result = await _store.resolvePageFor(
        scenarioId,
        page: targetPage,
        pageSize: currentSize,
        sortField: _sortConfig.sortField,
        sortDirection: _sortConfig.sortDirection,
        sourceInternalFirst: _sortConfig.sourceInternalFirst,
        order: _sortConfig.order,
        shuffleSeed: _sortConfig.shuffleSeed,
        duplicatePolicy: _sortConfig.duplicatePolicy,
      );
      _currentPage = targetPage;
      _items = result.items;
      _totalItems = result.totalItems;
    } catch (e) {
      _isError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  @override
  Future<void> changePageSize(int newSize) async {
    if (newSize < 1) return;
    newSize = clampPageSize(newSize);
    await _store.updateScenarioPreviewQueuePageSize(newSize);
    _currentPage = 0;
    await fetchPage(0, pageSize);
  }

  @override
  Future<void> changeSort(SortOption sortOption) async {
    // Sorting is controlled by the preview's local [_sortConfig] (see
    // [buildSortMenu]); the generic page-level hook is intentionally a no-op.
  }

  @override
  Future<bool> handleNavigationBack() async {
    onExitPreview();
    return true;
  }

  @override
  Future<void> handleNavigationHome() async {}

  @override
  Future<void> navigateToCrumb(int index) async {
    if (index == 0) onExitPreview();
  }

  @override
  bool get supportsSearch => false;

  @override
  Future<void> openSearchDialog(
      BuildContext scenario, VoidCallback onSearchInitiated) async {}

  @override
  bool handleItemTap(BuildContext scenario, EffectivePlaybackItem item) {
    if (!item.available) return true;
    _playPreviewItem(scenario, item);
    return true;
  }

  /// Shared play path for a row tap and a "play from this child" tap: the
  /// preview's stay/close policy and Override confirm apply to both.
  void _playPreviewItem(
    BuildContext scenario,
    EffectivePlaybackItem item, {
    String? vmStartMediaKey,
    int? vmStartOccurrenceIndex,
  }) {
    final stay = _store.state.scenarioPreviewStayOnTap;
    final navigator = Navigator.of(scenario);
    ScenarioPlaybackActions.playResolvedItem(
      scenario,
      store: _store,
      scenarioId: scenarioId,
      item: item,
      previewSort: _sortConfig,
      vmStartMediaKey: vmStartMediaKey,
      vmStartOccurrenceIndex: vmStartOccurrenceIndex,
      // A preview is a read-only look: jumping to a scenario that is not the
      // current playing workspace always asks for confirmation first.
      forceConfirmIfNotPlaying: true,
      // Stay: keep the preview open for continuous auditions. Close: reset the
      // browser open mode, then pop the whole StoragesDb (queue-style).
      onExitAfterPlay: stay
          ? () {}
          : () {
              useMediaLibBrowserStore().openScenarioTab();
              if (navigator.mounted) navigator.pop();
            },
    );
  }

  // ── Virtual-merged row expansion (mirrors the queue surface) ──

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
      onPlayChild: (index) {
        if (!item.available || index < 0 || index >= item.vmChildren.length) {
          return;
        }
        // Drop the floating dropdown before playback (may navigate away).
        if (_expandedVmKey != null) {
          _expandedVmKey = null;
          notifyListeners();
        }
        _playPreviewItem(
          context,
          item,
          vmStartMediaKey: item.vmChildren[index].mediaKey,
          vmStartOccurrenceIndex: item.vmChildren[index].occurrenceIndex,
        );
      },
    );
  }

  @override
  Widget buildTileInfoDialog(
      BuildContext scenario, EffectivePlaybackItem item) {
    final t = getLocalizations(scenario);
    return AlertDialog(
      title: Text(item.media.name),
      content: Text(t.scn_path_prefix(item.pathValue)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(scenario),
          child: Text(t.scn_close),
        ),
      ],
    );
  }

  /// Reactive current-item check: reads the store's in-memory occurrence
  /// mirror via `select` during build, so the highlight follows play/next/
  /// previous live even while the preview stays open. Both sides are
  /// canonicalized (queue-style) so a files-paged mirror still matches the
  /// resolver's queue item.
  @override
  bool isCurrentItem(BuildContext context, EffectivePlaybackItem item) {
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
    return currentKey != null &&
        (currentKey == itemKey ||
            item.vmChildren.any(
              (c) => currentKey == '${c.mediaKey}#${c.occurrenceIndex}',
            ));
  }

  /// D28/v6-D38: `available: false` placeholders render greyed + un-tappable.
  /// Offline-grey: the resolver's `available` is content-level; connection
  /// state is link-level — either one down greys the row. Plain store read
  /// (no `select`): this predicate is also invoked outside builds, and the
  /// tile rebuilds with the page anyway.
  @override
  bool isItemUnavailable(BuildContext context, EffectivePlaybackItem item) {
    if (!item.available) return true;
    return !useStorageStore().isConnected(item.occurrenceId.storageId);
  }

  @override
  Widget? buildItemLeading(BuildContext scenario, EffectivePlaybackItem item) {
    // The row's position in the PREVIEW list. `virtualIndex` is that element
    // position on both read paths (one ordinary file, or one whole merged
    // group, = one element), so `virtualIndex + 1` reads the same number the
    // page window the row came from implies.
    final number = item.virtualIndex + 1;
    final isCurrent = isCurrentItem(scenario, item);
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
  String? buildItemTitle(EffectivePlaybackItem item) => item.media.name;

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

  @override
  List<String>? get currentBreadcrumbs => const ['Sources', 'Preview'];

  @override
  bool get isRightToLeftBreadcrumbs => false;

  @override
  Widget? buildTileContent(BuildContext scenario, EffectivePlaybackItem item) =>
      null;

  @override
  Widget buildSortMenu(BuildContext context) {
    final t = getLocalizations(context);
    final scenario = _previewScenario(context);
    final current = resolveScenarioOrderChoice(
      order: _sortConfig.order,
      sortField: _sortConfig.sortField,
    );
    final direction = _sortConfig.sortDirection;
    final sourceInternalFirst = _sortConfig.sourceInternalFirst;
    final isDedup = _sortConfig.duplicatePolicy == DuplicatePolicy.deduplicate;
    final captured = scenario?.originalSortField;

    return PopupMenuButton<ScenarioOrderChoice>(
      icon: const Icon(Icons.sort_rounded),
      onSelected: _onOrderSelected,
      itemBuilder: (_) => [
        _sortItem(
          context,
          ScenarioOrderChoice.shuffled,
          t.scn_sort_shuffled,
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
              ? t.scn_sort_original
              : t.scn_sort_original_of(_orderFieldLabel(t, captured)),
          current,
          direction,
          disabled: captured == null,
        ),
        _sortItem(
            context, ScenarioOrderChoice.name, t.scn_sort_name, current, direction),
        _sortItem(context, ScenarioOrderChoice.modifiedAt, t.scn_sort_modified,
            current, direction),
        _sortItem(context, ScenarioOrderChoice.durationMs, t.scn_sort_duration,
            current, direction),
        _sortItem(context, ScenarioOrderChoice.sizeInBytes, t.scn_sort_size, current,
            direction),
        const PopupMenuDivider(),
        _checkboxItem(
          t.scn_group_same_dir,
          sourceInternalFirst,
          onToggle: () async {
            _sortConfig = _sortConfig.copyWith(
              sourceInternalFirst: !_sortConfig.sourceInternalFirst,
            );
            await fetchPage(0, pageSize);
          },
        ),
        _checkboxItem(
          t.scn_dedupe,
          isDedup,
          onToggle: () async {
            _sortConfig = _sortConfig.copyWith(
              duplicatePolicy: isDedup
                  ? DuplicatePolicy.allowDuplicate
                  : DuplicatePolicy.deduplicate,
            );
            await fetchPage(0, pageSize);
          },
        ),
      ],
    );
  }

  /// Reactively reads the previewed scenario from the store mirror (source of
  /// truth). Local sort state lives in [_sortConfig], never written back.
  Scenario? _previewScenario(BuildContext context) =>
      usePlaybackScenarioStore().select(
        context,
        (s) => s.scenarios.where((c) => c.id == scenarioId).firstOrNull,
      );

  /// queue-style sort item: the current item shows an up/down arrow;
  /// re-clicking the current item toggles the direction (see
  /// [_onOrderSelected]). All state changes are local to the preview.
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
  /// folder_first). The WHOLE ROW is the tap target — the checkbox only mirrors
  /// the state, so a click on the label toggles just like a click on the box.
  /// Toggling updates the local [_sortConfig] and refreshes page 0; the menu
  /// closes ITSELF, because `PopupMenuItem.handleTap` pops the menu route before
  /// it runs this callback — a pop from here would land on the route underneath
  /// and take the hosting management page with it. Nothing is persisted.
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
        return t.scn_sort_name;
      case ScenarioSortField.modifiedAt:
        return t.scn_sort_modified;
      case ScenarioSortField.durationMs:
        return t.scn_sort_duration;
      case ScenarioSortField.sizeInBytes:
        return t.scn_sort_size;
    }
  }

  Future<void> _onOrderSelected(ScenarioOrderChoice choice) async {
    final scenario = _store.state.scenarios
        .where((c) => c.id == scenarioId)
        .firstOrNull;

    if (choice == ScenarioOrderChoice.shuffled) {
      // Shuffled supports asc/desc like the other items: when already shuffled
      // a re-click flips the direction (reverse of the shuffled sequence);
      // otherwise it enables shuffle (forward, asc) with a fresh local seed.
      if (_sortConfig.shuffled) {
        _sortConfig = _sortConfig.copyWith(
          sortDirection: _sortConfig.sortDirection == SortDirection.asc
              ? SortDirection.desc
              : SortDirection.asc,
        );
      } else {
        _sortConfig = _sortConfig.copyWith(
          order: PlaybackOrder.shuffled,
          shuffleSeed: () => Random().nextInt(1 << 30),
          sortDirection: SortDirection.asc,
        );
      }
      await fetchPage(0, pageSize);
      return;
    }

    // Leaving shuffled back to a concrete order (local only).
    if (_sortConfig.shuffled) {
      _sortConfig = _sortConfig.copyWith(
        order: PlaybackOrder.sequential,
        shuffleSeed: () => null,
      );
    }

    final sortField = _sortConfig.sortField;
    final currentDir = _sortConfig.sortDirection;

    if (choice == ScenarioOrderChoice.original) {
      // Original asc = the captured first-add sort; re-click toggles to
      // desc = reversed original order.
      final original = scenario?.originalSortField;
      if (original != null) {
        final direction = sortField == original
            ? (currentDir == SortDirection.asc
                ? SortDirection.desc
                : SortDirection.asc)
            : SortDirection.asc;
        _sortConfig = _sortConfig.copyWith(
          sortField: original,
          sortDirection: direction,
        );
      }
    } else {
      // queue-style: re-clicking the CURRENT field toggles asc/desc; switching
      // to a different field starts from that field's natural direction. The
      // menu marks that same field (see [resolveScenarioOrderChoice]).
      // `shuffled`/`original` returned above, so this row has a field.
      final target = choice.sortField!;
      final isCurrent = sortField == target;
      final direction = isCurrent
          ? (currentDir == SortDirection.asc
              ? SortDirection.desc
              : SortDirection.asc)
          : target.naturalDirection;
      _sortConfig = _sortConfig.copyWith(
        sortField: target,
        sortDirection: direction,
      );
    }
    await fetchPage(0, pageSize);
  }

  // ── PotPlayer playlist keyboard (PL >) ──

  /// The preview is READ-ONLY, so scenario mutations (remove / save / add
  /// source) are consumed as no-ops; play and the local sort view are wired.
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
    switch (action) {
      case PlaylistAction.play:
        if (item != null) handleItemTap(context, item);
        return true;
      case PlaylistAction.sortAscending:
        return _applyLocalSort(direction: SortDirection.asc);
      case PlaylistAction.sortDescending:
        return _applyLocalSort(direction: SortDirection.desc);
      case PlaylistAction.sortByFolder:
        _sortConfig = _sortConfig.copyWith(
          sourceInternalFirst: !_sortConfig.sourceInternalFirst,
        );
        await fetchPage(0, pageSize);
        return true;
      case PlaylistAction.sortByName:
        return _applyLocalSort(field: ScenarioSortField.name);
      case PlaylistAction.sortBySize:
        return _applyLocalSort(field: ScenarioSortField.sizeInBytes);
      case PlaylistAction.sortByDuration:
        return _applyLocalSort(field: ScenarioSortField.durationMs);
      case PlaylistAction.sortByDate:
        return _applyLocalSort(field: ScenarioSortField.modifiedAt);
      case PlaylistAction.sortRandom:
        _sortConfig = _sortConfig.copyWith(
          order: PlaybackOrder.shuffled,
          shuffleSeed: () => Random().nextInt(1 << 30),
          sortDirection: SortDirection.asc,
        );
        await fetchPage(0, pageSize);
        return true;
      case PlaylistAction.fileInformation:
        if (item == null) return true;
        await showDialog<void>(
          context: context,
          builder: (_) => buildTileInfoDialog(context, item),
        );
        return true;
      default:
        return true; // consumed no-op
    }
  }

  Future<bool> _applyLocalSort({
    ScenarioSortField? field,
    SortDirection? direction,
  }) async {
    if (_sortConfig.shuffled) {
      _sortConfig = _sortConfig.copyWith(
        order: PlaybackOrder.sequential,
        shuffleSeed: () => null,
      );
    }
    final target = field ?? _sortConfig.sortField;
    _sortConfig = _sortConfig.copyWith(
      sortField: target,
      // A field switch picks that field's natural direction; an explicit
      // direction (the sortAscending / sortDescending actions) always wins, and
      // re-selecting the current field keeps the current direction.
      sortDirection: direction ??
          (target == _sortConfig.sortField
              ? _sortConfig.sortDirection
              : target.naturalDirection),
    );
    await fetchPage(0, pageSize);
    return true;
  }

  /// The current local sort field's value to display in the subtitle slot
  /// (null when nothing should be shown: name/shuffled order, duration/size
  /// sorts whose value is already the fixed size+duration text, or a null
  /// date).
  String? _sortValueLabel(BuildContext context, EffectivePlaybackItem item) {
    final scenario = _previewScenario(context);
    if (scenario == null ||
        _sortConfig.order == PlaybackOrder.shuffled) {
      return null;
    }
    final DateTime? date = item.media.maybeMap(
      file: (f) => switch (_sortConfig.sortField) {
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
  List<PageAction> buildCustomPageActions(BuildContext scenarioContext) {
    final stay = _store.state.scenarioPreviewStayOnTap;
    final t = getLocalizations(scenarioContext);
    return [
      buildStayModePageAction(
        stay: stay,
        onToggle: () => _store.updateScenarioPreviewStayOnTap(!stay),
        stayLabel: t.scn_preview_stay,
        leaveLabel: t.scn_preview_leave,
      ),
      PageAction(
        icon: const Icon(Icons.casino_outlined),
        label: t.scn_shuffle_refresh,
        onPressed: () async {
          _sortConfig = _sortConfig.copyWith(
            order: PlaybackOrder.shuffled,
            shuffleSeed: () => Random().nextInt(1 << 30),
          );
          await fetchPage(0, pageSize);
        },
      ),
    ];
  }

  @override
  List<GenericItemAction<EffectivePlaybackItem>> getItemTrailingActions(
    BuildContext scenario,
    EffectivePlaybackItem item,
  ) {
    return const [];
  }

  @override
  List<CustomSelectionAction<EffectivePlaybackItem>>
      buildCustomSelectionActions(BuildContext scenario) {
    return const [];
  }
}
