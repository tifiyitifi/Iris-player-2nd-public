import 'package:collection/collection.dart';
import 'package:flutter/material.dart' hide Chip;
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart' show MediaFile;
import 'package:iris/features/tag_play/model/domain/tag_play_tag.dart';
import 'package:iris/features/tag_play/playback/tag_play_controller.dart' show TagPlayGate;
import 'package:iris/features/windows/explorer/menu/explorer_reveal_action.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';

import 'package:iris/models/storages/local.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_history_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/file_size_convert.dart' show formatFileSize;
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/adaptive/keyboard_form_shell.dart';
import 'package:iris/widgets/chip.dart';
import 'package:iris/widgets/popup.dart';
import 'package:iris/widgets/popups/storages/db/storages_db.dart';

/// Canonical membership key of a [FileItem], matching [TagPlayMember.mediaKey].
String _tagKeyOf(String storageId, List<String> pathSegments) =>
    '$storageId:${canonicalDbPath(pathSegments.join('/'))}';

/// Rows the queue's toolbar trash deletes, per `playq_delete_body`: the
/// CURRENT PAGE's selection, or with no selection the currently playing row.
///
/// Empty means there is nothing to delete, so no confirmation may be offered
/// (prompting would only invite a guess).
///
/// The playing row comes from the STORE and may sit on another page, so it is
/// never looked up in [pageItems] — whose scope is the rendered page only.
/// Pure so the contract is unit-testable without a widget tree.
List<PlayQueueItem> resolveTrashTargets({
  required List<PlayQueueItem> pageItems,
  required Set<PlayQueueItem> selection,
  required PlayQueueItem? currentPlayingItem,
}) {
  // Defensive: the bar already intersects the selection with the rendered
  // page, but an out-of-page id must never widen the blast radius.
  final selected = pageItems.where(selection.contains).toList(growable: false);
  if (selected.isNotEmpty) return selected;
  return currentPlayingItem == null
      ? const <PlayQueueItem>[]
      : [currentPlayingItem];
}

/// Fills [FileItem.durationMs] on [items] from [durationByKey]
/// (`storageId:canonicalPath` → ms). Items that already carry a duration, or
/// lack a storage/path key, are returned unchanged.
///
/// Pure so the duration sort is unit-testable without a DB; the caller resolves
/// [durationByKey] from `media_nodes.duration_ms` + the history store.
List<PlayQueueItem> resolveQueueDurations(
  List<PlayQueueItem> items,
  Map<String, int> durationByKey,
) {
  if (durationByKey.isEmpty) return items;
  return [for (final item in items) _withResolvedDuration(item, durationByKey)];
}

PlayQueueItem _withResolvedDuration(
  PlayQueueItem item,
  Map<String, int> durationByKey,
) {
  if (item.file.durationMs != null ||
      item.file.storageId.isEmpty ||
      item.file.path.isEmpty) {
    return item;
  }
  final ms =
      durationByKey[canonicalKey(item.file.storageId, item.file.path.join('/'))];
  if (ms == null) return item;
  return item.copyWith(file: item.file.copyWith(durationMs: ms));
}

/// Duration axis: ascending by [FileItem.durationMs]; unknown (null) counts as
/// 0, so unknowns sort first. Never falls back to `lastModified` — that is the
/// DATE axis (Ctrl+8 / `playq_sort_date`), and conflating them made the two
/// sorts byte-identical.
List<PlayQueueItem> sortPlayQueueByDuration(List<PlayQueueItem> items) {
  return [...items]
    ..sort((a, b) => (a.file.durationMs ?? 0).compareTo(b.file.durationMs ?? 0));
}

class PagedPlayQueueDataSource
    extends PaginatedBrowserDataSource<PlayQueueItem> {
  int _currentPage = 0;
  int _pageSize = 50;
  bool _isLoading = false;
  bool _isError = false;
  List<PlayQueueItem> _items = [];

  /// Per-row tag labels for the currently loaded page.
  Map<String, List<TagPlayTag>> _tagsByKey = const {};

  PagedPlayQueueDataSource() {
    _pageSize = usePlayQueueStore().itemsPerPage;
    _fetchInitialPage();
  }

  void _fetchInitialPage() {
    if (totalItems > 0) {
      fetchPage(0, _pageSize);
    }
  }

  @override
  int get totalItems => _isFiltered && _filteredTotal != null ? _filteredTotal! : usePlayQueueStore().totalCount;

  @override
  int get currentPage => _currentPage;

  @override
  int get totalPages => (totalItems / _pageSize).ceil().clamp(1, 99999);

  @override
  int get pageSize => _pageSize;

  @override
  bool get isLoading => _isLoading;

  @override
  bool get isError => _isError;

  @override
  List<PlayQueueItem> get items => _items;

  @override
  String getItemId(PlayQueueItem item) =>
      '${item.file.storageId}:${item.file.uri}:${item.index}';

  @override
  Future<void> fetchPage(int targetPage, int currentSize) async {
    _isLoading = true;
    _pageSize = currentSize;
    _isError = false;
    notifyListeners();

    try {
      var items = await usePlayQueueStore().getPagedQueueItems(
        page: targetPage + 1,
        pageSize: currentSize,
      );
      // Apply in-memory search filter (name contains, case-insensitive).
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        // For filtered search we need to fetch all and filter, then slice.
        // Fallback: filter current page only if total is large; otherwise fetch all.
        // To keep paging consistent after search, we fetch all items and slice.
        final all = await usePlayQueueStore().getPagedQueueItems(page: 1, pageSize: usePlayQueueStore().totalCount.clamp(1, 99999));
        final filtered = all.where((e) => e.file.name.toLowerCase().contains(q)).toList();
        final start = targetPage * currentSize;
        final end = (start + currentSize).clamp(0, filtered.length);
        items = start < filtered.length ? filtered.sublist(start, end) : <PlayQueueItem>[];
        // Update totalItems for paging by overriding via a field? We keep totalItems as filtered length via getter override.
        _filteredTotal = filtered.length;
        _isFiltered = true;
      } else {
        _isFiltered = false;
        _filteredTotal = null;
      }
      _currentPage = targetPage;
      _items = items;
      await _loadTags(items);
    } catch (e) {
      _isError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  bool _isFiltered = false;
  int? _filteredTotal;

  Future<void> _loadTags(List<PlayQueueItem> items) async {
    final app = useAppStore();
    final gate = !app.state.useLegacyStoragePersistence &&
        app.state.useMetadataSettings;
    if (!gate) {
      _tagsByKey = const {};
      return;
    }
    final keys = <String>{
      for (final item in items)
        if (item.file.storageId.isNotEmpty && item.file.path.isNotEmpty)
          _tagKeyOf(item.file.storageId, item.file.path),
    };
    if (keys.isEmpty) {
      _tagsByKey = const {};
      return;
    }
    _tagsByKey = await DbModule.tagPlayRepo.tagsOfMediaKeys(keys);
  }

  @override
  Future<void> changePageSize(int newSize) async {
    if (newSize < 1) return;
    newSize = clampPageSize(newSize);
    _pageSize = newSize;
    _currentPage = 0;
    await usePlayQueueStore().setItemsPerPage(newSize);
    await fetchPage(0, _pageSize);
  }

  @override
  Future<void> changeSort(SortOption sortOption) async {
    // No sort menu for play queue — order is controlled by store
  }

  @override
  Future<bool> handleNavigationBack() async => false;

  @override
  Future<void> handleNavigationHome() async {}

  @override
  Future<void> navigateToCrumb(int index) async {}

  String _searchQuery = '';

  @override
  bool get supportsSearch => true;

  @override
  Future<void> openSearchDialog(
      BuildContext context, VoidCallback onSearchInitiated) async {
    final t = getLocalizations(context);
    final result = await showKeyboardTextPrompt(
      context: context,
      title: t.playq_search_title,
      hint: t.playq_search_hint,
      initialValue: _searchQuery,
      confirmLabel: t.playq_search,
      cancelLabel: t.cancel,
    );
    if (result != null) {
      _searchQuery = result;
      onSearchInitiated();
      await fetchPage(0, _pageSize);
    }
  }

  void clearSearch() {
    _searchQuery = '';
    fetchPage(0, _pageSize);
  }

  // Bottom-bar helpers for dock (called from PlaylistDockPanel).
  void requestAdd(BuildContext context) {
    // Open storage browser for adding files.
    final dir = useAppStore().select(context, (s) => s.defaultPopupDirection);
    // Use the existing storage DB popup as add entry.
    showPopup(context: context, child: const StoragesDb(), direction: dir);
  }

  /// Toolbar trash (normal mode only — selection mode renders its own bulk
  /// Remove). Targets follow `playq_delete_body`: the current page's
  /// selection, else the currently playing row; with neither, there is
  /// nothing to delete and no confirmation is offered.
  void requestDeleteSelected(BuildContext context) async {
    final repo = usePlayQueueStore();
    final queue = repo.state.playQueue;
    final pos = repo.currentVirtualPos;
    final targets = resolveTrashTargets(
      pageItems: _items,
      selection: selectionForActions,
      currentPlayingItem: pos >= 0 && pos < queue.length ? queue[pos] : null,
    );
    if (targets.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final t = getLocalizations(ctx);
        return AlertDialog(
          title: Text(t.playq_delete_title),
          content: Text(t.playq_delete_body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t.cancel)),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.playq_delete)),
          ],
        );
      },
    );
    if (confirm != true) return;

    for (final target in targets) {
      await repo.remove(target);
    }
    await _refreshAfterRemoval();
    clearSelectionForActions?.call();
  }

  /// Re-reads after removals: stay on this page unless it just emptied, in
  /// which case step back one (never land past the last page). Reads
  /// [totalPages] AFTER the store mutations so the count reflects them.
  ///
  /// Shared by all three removal paths (trash, selection-mode bulk, row
  /// action) — without it a removal only mutated the store and the deleted
  /// rows kept rendering until the user happened to change page.
  Future<void> _refreshAfterRemoval() async {
    final pages = totalPages;
    final target =
        _currentPage >= pages ? (pages - 1).clamp(0, 99999) : _currentPage;
    await fetchPage(target, _pageSize);
  }

  void requestSortMenu(BuildContext context) {
    // The actual sort UI is buildSortMenu(); this is a programmatic trigger for dock bottom bar.
    // Show a simple menu dialog with PotPlayer-style options.
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(getLocalizations(ctx).playq_sort_title),
        children: [
          for (final e in _potPlayerSortOptions(context))
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(ctx);
                e.onSelected();
              },
              child: Text('${e.label}  ${e.shortcut}'),
            ),
        ],
      ),
    );
  }

  void requestSearch(BuildContext context) {
    openSearchDialog(context, () {});
  }

  List<_PotSortEntry> _potPlayerSortOptions(BuildContext context) {
    final t = getLocalizations(context);
    return [
      _PotSortEntry(t.playq_sort_asc, 'Ctrl+1', () => _applyDirection(true)),
      _PotSortEntry(t.playq_sort_desc, 'Ctrl+2', () => _applyDirection(false)),
      _PotSortEntry(t.playq_sort_title_field, 'Ctrl+3', () => _applySortBy((a, b) => _titleOf(a).compareTo(_titleOf(b)))),
      _PotSortEntry(t.playq_sort_filename, 'Ctrl+4', () => _applySortBy((a, b) => a.file.name.compareTo(b.file.name))),
      _PotSortEntry(t.playq_sort_ext, 'Ctrl+5', () => _applySortBy((a, b) => _extOf(a).compareTo(_extOf(b)))),
      _PotSortEntry(t.playq_sort_size, 'Ctrl+6', () => _applySortBy((a, b) => a.file.size.compareTo(b.file.size))),
      _PotSortEntry(t.playq_sort_duration, 'Ctrl+7', () => _applySortByDuration()),
      _PotSortEntry(t.playq_sort_date, 'Ctrl+8', () => _applySortBy((a, b) => _dateOf(a).compareTo(_dateOf(b)))),
      _PotSortEntry(t.playq_sort_shuffle, 'Ctrl+9', () => usePlayQueueStore().shuffle().then((_) => fetchPage(0, _pageSize))),
      _PotSortEntry(t.playq_sort_group_folder, 'Ctrl+0', () => _applyGroupByFolder()),
    ];
  }

  String _titleOf(PlayQueueItem i) {
    final name = i.file.name;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  String _extOf(PlayQueueItem i) {
    final name = i.file.name;
    final dot = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
  }

  /// Date axis ([FileItem.lastModified]). Kept strictly separate from the
  /// duration axis ([sortPlayQueueByDuration]) — the two were once identical,
  /// which silently made "by duration" equal "by date".
  int _dateOf(PlayQueueItem i) => i.file.lastModified?.millisecondsSinceEpoch ?? 0;

  Future<void> _applyDirection(bool asc) async {
    final store = usePlayQueueStore();
    final list = [...store.state.playQueue];
    if (!asc) {
      final reversed = list.reversed.toList();
      await store.update(playQueue: reversed, index: store.state.currentIndex);
    } else {
      // Asc = sort by index (original order)
      list.sort((a, b) => a.index.compareTo(b.index));
      await store.update(playQueue: list, index: store.state.currentIndex);
    }
    await fetchPage(0, _pageSize);
  }

  Future<void> _applySortBy(int Function(PlayQueueItem a, PlayQueueItem b) cmp) async {
    final store = usePlayQueueStore();
    final list = [...store.state.playQueue]..sort(cmp);
    await store.update(playQueue: list, index: store.state.currentIndex);
    await fetchPage(0, _pageSize);
  }

  /// Duration sort: many queue items arrive without a duration (filesystem
  /// browsing builds [FileItem]s from raw directory entries), so resolve the
  /// missing ones from the DB/history before comparing — otherwise every null
  /// collapses to 0 and the sort looks like a no-op.
  Future<void> _applySortByDuration() async {
    final store = usePlayQueueStore();
    final list = [...store.state.playQueue];
    final resolved = resolveQueueDurations(list, await _lookupDurations(list));
    await store.update(
      playQueue: sortPlayQueueByDuration(resolved),
      index: store.state.currentIndex,
    );
    await fetchPage(0, _pageSize);
  }

  /// Batch-resolves durations for items missing [FileItem.durationMs], keyed by
  /// `storageId:canonicalPath`. The DB (`media_nodes.duration_ms`) is the
  /// authority; the history store's last-known `Progress.duration` is the
  /// fallback for files not indexed (or unprobed) in the DB.
  Future<Map<String, int>> _lookupDurations(List<PlayQueueItem> items) async {
    final keys = <String>{};
    for (final item in items) {
      if (item.file.durationMs != null) continue;
      if (item.file.storageId.isEmpty || item.file.path.isEmpty) continue;
      keys.add(canonicalKey(item.file.storageId, item.file.path.join('/')));
    }
    if (keys.isEmpty) return const {};

    final out = <String, int>{};
    try {
      final nodes = await DbModule.mediaNodeRepo.nodesByMediaKeys(keys);
      for (final node in nodes) {
        if (node is! MediaFile) continue;
        final ms = node.durationMs;
        if (ms == null || ms <= 0) continue;
        out[canonicalKey(node.storageId, node.path.join('/'))] = ms;
      }
    } catch (_) {
      // DB unavailable (pure legacy boot) — the history fallback below still
      // applies, so a sort never throws on a missing DB.
    }

    final history = useHistoryStore().state.history;
    for (final key in keys) {
      if (out.containsKey(key)) continue;
      final ms = history[key]?.duration.inMilliseconds;
      if (ms != null && ms > 0) out[key] = ms;
    }
    return out;
  }

  Future<void> _applyGroupByFolder() async {
    final store = usePlayQueueStore();
    final list = [...store.state.playQueue];
    list.sort((a, b) {
      final pa = a.file.path.length > 1 ? a.file.path.sublist(0, a.file.path.length - 1).join('/') : '';
      final pb = b.file.path.length > 1 ? b.file.path.sublist(0, b.file.path.length - 1).join('/') : '';
      final c = pa.compareTo(pb);
      if (c != 0) return c;
      return a.file.name.compareTo(b.file.name);
    });
    await store.update(playQueue: list, index: store.state.currentIndex);
    await fetchPage(0, _pageSize);
  }

  @override
  bool handleItemTap(BuildContext context, PlayQueueItem item) {
    final store = usePlayQueueStore();
    store.updateCurrentIndex(item.index);
    useAppStore().updateAutoPlay(true);
    Navigator.of(context).maybePop();
    return true;
  }

  @override
  Widget buildTileInfoDialog(BuildContext context, PlayQueueItem item) {
    return AlertDialog(
      title: Text(item.file.name),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Path: ${item.file.uri}'),
          Text('Size: ${formatFileSize(item.file.size)}'),
          Text(
              'Position: ${item.index + 1} / ${usePlayQueueStore().totalCount}'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  @override
  bool isCurrentItem(BuildContext context, PlayQueueItem item) =>
      item.index == usePlayQueueStore().select(context, (s) => s.currentIndex);

  @override
  Widget? buildItemLeading(BuildContext context, PlayQueueItem item) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 14),
      child: Text(
        '${item.index + 1}',
        style: const TextStyle(fontSize: 14),
        textAlign: TextAlign.center,
      ),
    );
  }

  @override
  String? buildItemTitle(PlayQueueItem item) => item.file.name;

  @override
  Widget? buildItemTitleWidget(BuildContext context, PlayQueueItem item) {
    if (!TagPlayGate.enabled) return null;
    if (_tagsByKey.isEmpty) return null;
    final isCurrent = usePlayQueueStore().select(context, (s) => item.index == s.currentIndex);
    final tagWidgets = _tagIndicator(context, item, isCurrent);
    if (tagWidgets.isEmpty) return null;
    return Row(
      children: [
        Expanded(
          child: Text(
            item.file.name,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: isCurrent
                ? TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null,
          ),
        ),
        const SizedBox(width: 8),
        ...tagWidgets,
      ],
    );
  }

  @override
  Widget? buildItemSubtitle(BuildContext context, PlayQueueItem item) {
    final isCurrent = usePlayQueueStore()
        .select(context, (s) => item.index == s.currentIndex);

    return Row(
      children: [
        if (item.file.size > 0)
          Text(
            formatFileSize(item.file.size),
            style: TextStyle(
              fontSize: 13,
              color: isCurrent ? Theme.of(context).colorScheme.primary : null,
            ),
          ),
        const Spacer(),
        () {
          final progress = useHistoryStore().findById(
              // item.file.getID());  // legacy: surface-dependent uri key
              canonicalProgressKey(item.file.storageId, item.file.path,
                  uri: item.file.uri)); // unified
          if (progress != null && progress.file.type == ContentType.video) {
            if ((progress.duration.inMilliseconds -
                    progress.position.inMilliseconds) <=
                5000) {
              return Chip(text: '100%');
            }
            final progressString = (progress.position.inMilliseconds /
                    progress.duration.inMilliseconds *
                    100)
                .toStringAsFixed(0);
            return Chip(text: '$progressString %');
          } else {
            return const SizedBox();
          }
        }(),
        ...item.file.subtitles
            .map((subtitle) => subtitle.uri.split('.').last.toUpperCase())
            .toSet()
            .toList()
            .map(
              (subtitleType) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 4),
                  Chip(
                    text: subtitleType,
                    primary: true,
                  ),
                ],
              ),
            ),
      ],
    );
  }

  @override
  List<String>? get currentBreadcrumbs => null;

  @override
  bool get isRightToLeftBreadcrumbs => false;

  /// Per-row tag label widgets: chips when membered, a muted "无tag" once the
  /// page loaded with no memberships (kept visually distinct from a real tag
  /// literally named "无tag").
  List<Widget> _tagIndicator(
    BuildContext context,
    PlayQueueItem item,
    bool isCurrent,
  ) {
    if (_tagsByKey.isEmpty) return const [];
    final key =
        _tagKeyOf(item.file.storageId, item.file.path);
    final tags = _tagsByKey[key];
    if (tags == null || tags.isEmpty) {
      return [
        Text(
          '无tag',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ];
    }
    return [
      for (final tag in tags) ...[
        Chip(text: tag.name, primary: isCurrent),
        const SizedBox(width: 4),
      ],
    ];
  }

  @override
  Widget? buildTileContent(BuildContext context, PlayQueueItem item) => null;

  @override
  Widget buildSortMenu(BuildContext context) {
    final t = getLocalizations(context);
    return PopupMenuButton<_PotSortEntry>(
      icon: const Icon(Icons.sort_rounded),
      tooltip: t.playq_sort_tip,
      onSelected: (e) => e.onSelected(),
      itemBuilder: (_) => [
        for (final e in _potPlayerSortOptions(context))
          PopupMenuItem<_PotSortEntry>(
            value: e,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(e.label),
                Text(e.shortcut, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
              ],
            ),
          ),
      ],
    );
  }

  // Helper for auto-jump after move.
  Future<void> _afterMove(PlayQueueItem item, bool moved) async {
    if (!moved) return;
    final repo = usePlayQueueStore();
    final globalIdx = repo.globalIndexOf(item);
    if (globalIdx < 0) return;
    final targetPage = (globalIdx ~/ _pageSize).clamp(0, totalPages - 1);
    if (targetPage != _currentPage) {
      await fetchPage(targetPage, _pageSize);
    } else {
      // Stay on page but refresh to reflect new order.
      await fetchPage(_currentPage, _pageSize);
    }
    notifyListeners();
  }

  @override
  List<PageAction> buildCustomPageActions(BuildContext context) {
    // Floating queue shares the same Add/Delete/Search toolbar as the dock
    // (dock has its own dark bottom bar; floating uses these PageActions).
    // Keep it lean; dock's dark bar is the canonical PotPlayer look.
    final t = getLocalizations(context);
    return [
      PageAction(
        icon: const Icon(Icons.add, size: 16),
        label: t.playq_add,
        onPressed: () => requestAdd(context),
      ),
      PageAction(
        icon: const Icon(Icons.delete_outline, size: 16),
        label: t.playq_delete,
        onPressed: () => requestDeleteSelected(context),
      ),
      PageAction(
        icon: const Icon(Icons.search, size: 16),
        label: _searchQuery.isEmpty
            ? t.playq_search_label
            : t.playq_search_active(_searchQuery),
        onPressed: () {
          if (_searchQuery.isNotEmpty) {
            clearSearch();
          } else {
            requestSearch(context);
          }
        },
      ),
    ];
  }

  @override
  List<GenericItemAction<PlayQueueItem>> getItemTrailingActions(
    BuildContext context,
    PlayQueueItem item,
  ) {
    final t = getLocalizations(context);
    final actions = <GenericItemAction<PlayQueueItem>>[
      GenericItemAction<PlayQueueItem>(
        label: t.playq_move_top,
        icon: const Icon(Icons.vertical_align_top, size: 16),
        onPressed: (ctx, i) async {
          if (i is PlayQueueItem) {
            final ok = await usePlayQueueStore().moveToTop(i);
            await _afterMove(i, ok);
          }
        },
      ),
      GenericItemAction<PlayQueueItem>(
        label: t.playq_move_up,
        icon: const Icon(Icons.arrow_upward, size: 16),
        onPressed: (ctx, i) async {
          if (i is PlayQueueItem) {
            final ok = await usePlayQueueStore().moveUp(i);
            await _afterMove(i, ok);
          }
        },
      ),
      GenericItemAction<PlayQueueItem>(
        label: t.playq_move_down,
        icon: const Icon(Icons.arrow_downward, size: 16),
        onPressed: (ctx, i) async {
          if (i is PlayQueueItem) {
            final ok = await usePlayQueueStore().moveDown(i);
            await _afterMove(i, ok);
          }
        },
      ),
      GenericItemAction<PlayQueueItem>(
        label: t.playq_move_bottom,
        icon: const Icon(Icons.vertical_align_bottom, size: 16),
        onPressed: (ctx, i) async {
          if (i is PlayQueueItem) {
            final ok = await usePlayQueueStore().moveToBottom(i);
            await _afterMove(i, ok);
          }
        },
      ),
      GenericItemAction<PlayQueueItem>(
        label: t.playq_remove,
        icon: const Icon(Icons.remove_circle_outline, size: 16),
        onPressed: (ctx, i) async {
          if (i is PlayQueueItem) {
            await usePlayQueueStore().remove(i);
            await _refreshAfterRemoval();
          }
        },
      ),
    ];
    if (item.file.path.isNotEmpty) {
      // Snapshot read, not a reactive `select`: the action list is also built
      // outside `build` (the desktop right-click menu), where provider asserts
      // `select` is only called during build.
      final popupDirection = useAppStore().state.defaultPopupDirection;
      actions.add(
        GenericItemAction<PlayQueueItem>(
          label: t.open_in_folder,
          icon: const Icon(Icons.folder_open, size: 16),
          onPressed: (ctx, i) {
            if (i is PlayQueueItem) {
              _openInFolderDb(ctx, i.file, popupDirection);
            }
          },
        ),
      );
      // Windows desktop: the same row, handed to Explorer. Empty off-Windows
      // or for remote rows.
      actions.addAll(buildExplorerRevealActions<PlayQueueItem>(
        context: context,
        item: item,
        fileOf: (i) => i.file,
      ));
    }
    return actions;
  }

  @override
  List<CustomSelectionAction<PlayQueueItem>> buildCustomSelectionActions(
      BuildContext context) {
    return [
      CustomSelectionAction<PlayQueueItem>(
        icon: const Icon(Icons.remove_circle_outline, size: 18),
        label: getLocalizations(context).playq_remove,
        onPressed: (ctx, selected) async {
          // Awaited: fire-and-forget lets two removals race the same backend
          // index and leaves the page reading a half-applied queue.
          for (final item in selected) {
            await usePlayQueueStore().remove(item);
          }
          await _refreshAfterRemoval();
          return true;
        },
      ),
    ];
  }

  // PotPlayer sort entry helper.
  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _openInFolderDb(BuildContext context, FileItem file,
      PopupDirection popupDirection) async {
    if (file.path.isEmpty) return;
    useStorageStore()
        .updateCurrentPath(file.path.sublist(0, file.path.length - 1));

    Storage? storage = useStorageStore().resolveStorageForNodeId(file.storageId);

    if (storage != null) {
      useStorageStore().updateCurrentStorage(storage);
    } else {
      final localStorages = await getLocalStorages(context);
      storage = localStorages
          .firstWhereOrNull((element) => element.basePath[0] == file.path[0]);
      if (storage != null) {
        useStorageStore().updateCurrentStorage(storage);
      } else {
        useStorageStore().updateCurrentStorage(
          LocalStorage(
            type: file.storageType,
            name: file.path[0],
            basePath: [file.path[0]],
          ),
        );
      }
    }

    if (context.mounted) {
      replacePopup(
        context: context,
        child: const StoragesDb(),
        direction: popupDirection,
      );
    }
  }
}

class _PotSortEntry {
  final String label;
  final String shortcut;
  final Future<void> Function() onSelected;
  const _PotSortEntry(this.label, this.shortcut, this.onSelected);
}
