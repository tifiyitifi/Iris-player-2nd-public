import 'dart:async';

import 'package:flutter/material.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/services/background_tag_pool.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/paginated_browser/data_source/paginated_browser_data_source.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';

/// 副音 play-queue browser over the reserved 「副音备选」tag's view.
///
/// 副音 is a tag play view pinned to the reserved tag, so its queue surface is
/// the SAME paginated browser the foreground uses (search / sort / paging / row
/// layout) — fed by the tag view instead of a scenario. The raw membership is
/// never VM-merged, so every row is a real single file.
///
/// Tapping a row plays it on the background engine by its GLOBAL stream index:
/// `jumpToOccurrence` jumps to it when it is inside the runtime's window, or
/// SLIDES the window onto it when it falls outside (the runtime holds a WINDOW
/// over the stream, never the whole list).
class PagedBackgroundMediaDataSource
    extends PaginatedBrowserDataSource<EffectivePlaybackItem> {
  PagedBackgroundMediaDataSource({required this.scenarioId}) {
    _lastCurrentKey = _currentQueueKey;
    _lastDurationFp = _durationFingerprint;
    _bgSub = useBackgroundPlaybackStore().stream.listen((_) {
      final key = _currentQueueKey;
      final fp = _durationFingerprint;
      final keyChanged = key != _lastCurrentKey;
      final durationChanged = fp != _lastDurationFp;
      if (!keyChanged && !durationChanged) return;
      _lastCurrentKey = key;
      _lastDurationFp = fp;
      // The current-file change is a pure repaint (the row's icon); a duration
      // change is not — see [_scheduleDurationRefetch].
      if (durationChanged) _scheduleDurationRefetch();
      notifyListeners();
    });
    fetchPage(0, pageSize);
  }

  final String scenarioId;

  int _currentPage = 0;
  int _totalItems = 0;
  int _pageSize = 50;
  List<EffectivePlaybackItem> _items = const [];
  bool _isLoading = false;
  bool _isError = false;
  bool _disposed = false;
  bool _refetchScheduled = false;
  StreamSubscription<dynamic>? _bgSub;
  String? _lastCurrentKey;
  String _lastDurationFp = '';

  BackgroundPlaybackStore get _bg => useBackgroundPlaybackStore();

  /// Re-resolves the page after the duration-probe state changed.
  ///
  /// The rows read their duration from the PAGE SNAPSHOT ([_items]): the row
  /// decoration consults the store's failed/unknown SETS, but `ok` comes from
  /// the item itself, so `notifyListeners` alone repaints the SAME stale items.
  /// A probe that resolved a row's duration therefore left it an hourglass
  /// forever — and the row's 「重新读取时长」 retry looked dead. Only a fresh
  /// candidate resolve picks up the `media_nodes` duration it wrote back.
  ///
  /// Coalesced to one fetch per event-loop turn and skipped while a pass is in
  /// flight (one pass publishes `probing: true` then `probing: false`, and the
  /// fetch during the pass could only read the pre-pass rows again).
  void _scheduleDurationRefetch() {
    if (_refetchScheduled || _disposed) return;
    if (_bg.state.bgDurationProbing) return;
    _refetchScheduled = true;
    Timer.run(() {
      _refetchScheduled = false;
      if (_disposed) return;
      if (_bg.state.bgDurationProbing) return;
      unawaited(fetchPage(_currentPage, _pageSize));
    });
  }

  String? get _currentQueueKey {
    final s = _bg.state;
    if (s.currentIndex < 0 || s.currentIndex >= s.queue.length) return null;
    return backgroundMediaKey(s.queue[s.currentIndex]);
  }

  /// The 时长探测 state the rows must repaint on (the row decoration reads the
  /// failed/unknown sets and the in-flight flag).
  String get _durationFingerprint {
    final s = _bg.state;
    return '${s.bgDurationProbing ? 1 : 0}|'
        '${s.bgDurationFailedKeys.join(',')}|'
        '${s.bgDurationUnknownKeys.join(',')}';
  }

  /// The canonical media key of [item], in the SAME space the duration probe
  /// and the runtime timeline publish (`backgroundMediaKey`).
  String _keyOf(EffectivePlaybackItem item) {
    final f = item.media.maybeMap(file: (v) => v, orElse: () => null);
    if (f == null) {
      return canonicalKey(item.occurrenceId.storageId, item.occurrenceId.path);
    }
    return canonicalProgressKey(f.storageId, f.path, uri: f.uri);
  }

  /// Duration resolution state of one row: `ok` when the DB (or the live
  /// engine) already carries it, otherwise WHY it is missing. A row without a
  /// duration cannot be aligned, so it must read as a problem, never as a
  /// plausible "0:00".
  _BgDurationState _durationState(EffectivePlaybackItem item) {
    final f = item.media.maybeMap(file: (v) => v, orElse: () => null);
    final d = f?.durationMs;
    if (d != null && d > 0) return _BgDurationState.ok;
    final s = _bg.state;
    final key = _keyOf(item);
    if (s.bgDurationFailedKeys.contains(key)) {
      return _BgDurationState.failed;
    }
    if (s.bgDurationProbing) return _BgDurationState.probing;
    return _BgDurationState.unknown;
  }

  /// Explains a row's unresolved duration and offers a retry.
  Future<void> _showDurationDialog(
    BuildContext context,
    EffectivePlaybackItem item,
  ) async {
    final t = getLocalizations(context);
    final failed = _durationState(item) == _BgDurationState.failed;
    final key = _keyOf(item);
    final retry = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          Icons.error_outline_rounded,
          color: Theme.of(dialogContext).colorScheme.error,
        ),
        title: Text(t.bg_duration_failed_title),
        content: Text(
          failed
              ? t.bg_duration_failed_body(item.media.name)
              : t.bg_duration_unknown_body(item.media.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(t.bg_duration_retry),
          ),
        ],
      ),
    );
    if (retry == true) _bg.retryBgDuration(key);
  }

  @override
  void dispose() {
    _disposed = true;
    _bgSub?.cancel();
    _bgSub = null;
    super.dispose();
  }

  @override
  int get totalItems => _totalItems;
  @override
  int get currentPage => _currentPage;
  @override
  int get totalPages => (totalItems / pageSize).ceil().clamp(1, 99999);
  @override
  int get pageSize => _pageSize;
  @override
  bool get isLoading => _isLoading;
  @override
  bool get isError => _isError;
  @override
  List<EffectivePlaybackItem> get items => _items;

  @override
  String getItemId(EffectivePlaybackItem item) => item.mediaKey;

  @override
  List<String>? get currentBreadcrumbs => null;
  @override
  bool get isRightToLeftBreadcrumbs => false;

  @override
  Future<void> fetchPage(int targetPage, int currentSize) async {
    _isLoading = true;
    _isError = false;
    notifyListeners();
    try {
      final all =
          await resolveBackgroundCandidates(scenarioId: scenarioId);
      _totalItems = all.length;
      final start = targetPage * currentSize;
      _currentPage = targetPage;
      _items = start >= all.length
          ? const []
          : all.sublist(
              start, start + currentSize > all.length ? all.length : start + currentSize);
    } catch (_) {
      _isError = true;
    }
    _isLoading = false;
    notifyListeners();
  }

  @override
  Future<void> changePageSize(int newSize) async {
    if (newSize < 1) return;
    _pageSize = clampPageSize(newSize);
    await fetchPage(0, _pageSize);
  }

  /// The background scenario's sort is edited in the scenario surfaces; this
  /// browser only pages it, so a sort request is a no-op re-fetch.
  @override
  Future<void> changeSort(SortOption sortOption) async {
    await fetchPage(0, pageSize);
  }

  @override
  Future<bool> handleNavigationBack() async => false;
  @override
  Future<void> handleNavigationHome() async {}
  @override
  Future<void> navigateToCrumb(int index) async {}

  @override
  bool get supportsSearch => false;
  @override
  Future<void> openSearchDialog(
      BuildContext context, VoidCallback onSearchInitiated) async {}

  @override
  bool handleItemTap(BuildContext context, EffectivePlaybackItem item) {
    unawaited(_play(context, item));
    return true;
  }

  @override
  Widget buildTileInfoDialog(
          BuildContext context, EffectivePlaybackItem item) =>
      const SizedBox.shrink();

  @override
  Widget? buildItemLeading(BuildContext context, EffectivePlaybackItem item) {
    if (isCurrentItem(context, item)) {
      return const Icon(Icons.graphic_eq_rounded, size: 18);
    }
    // An unresolved duration is a REAL problem (副音 cannot be aligned to the
    // video without it), so the row must not read as a normal track: a red
    // error icon for a failed probe, an hourglass while one is in flight.
    switch (_durationState(item)) {
      case _BgDurationState.failed:
        return Icon(
          Icons.error_outline_rounded,
          size: 18,
          color: Theme.of(context).colorScheme.error,
        );
      case _BgDurationState.probing:
      case _BgDurationState.unknown:
        return Icon(
          Icons.hourglass_empty_rounded,
          size: 18,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
      case _BgDurationState.ok:
        break;
    }
    // Keep the old queue panel's video/audio distinction: a video row must not
    // read as just another audio track.
    final type = item.media.maybeMap(
      file: (f) => f.mediaType,
      orElse: () => null,
    );
    return Icon(
      type == MediaType.video
          ? Icons.videocam_rounded
          : Icons.audio_file_rounded,
      size: 18,
    );
  }

  @override
  String? buildItemTitle(EffectivePlaybackItem item) => item.media.name;

  @override
  Widget? buildItemSubtitle(
      BuildContext context, EffectivePlaybackItem item) {
    final theme = Theme.of(context);
    switch (_durationState(item)) {
      case _BgDurationState.ok:
        return null;
      case _BgDurationState.failed:
        return Text(
          getLocalizations(context).bg_duration_failed,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.error),
        );
      case _BgDurationState.probing:
        return Text(
          getLocalizations(context).bg_duration_probing,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        );
      case _BgDurationState.unknown:
        return Text(
          getLocalizations(context).bg_duration_unknown,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        );
    }
  }

  @override
  @Deprecated('Use buildItemLeading/buildItemTitle/buildItemSubtitle instead')
  Widget? buildTileContent(
          BuildContext context, EffectivePlaybackItem item) =>
      null;

  @override
  Widget buildSortMenu(BuildContext context) => const SizedBox.shrink();

  @override
  List<PageAction> buildCustomPageActions(BuildContext context) => const [];

  @override
  List<CustomSelectionAction<EffectivePlaybackItem>> buildCustomSelectionActions(
          BuildContext context) =>
      const [];

  @override
  List<GenericItemAction<EffectivePlaybackItem>> getItemTrailingActions(
          BuildContext context, EffectivePlaybackItem item) =>
      switch (_durationState(item)) {
        _BgDurationState.ok => const [],
        // One entry per row: explains WHY the duration is missing and offers the
        // retry, instead of a silent no-op.
        _ => [
            GenericItemAction<EffectivePlaybackItem>(
              label: getLocalizations(context).bg_duration_retry,
              icon: const Icon(Icons.refresh_rounded),
              onPressed: (ctx, _) => unawaited(_showDurationDialog(ctx, item)),
            ),
          ],
      };

  @override
  bool get supportsSelection => false;

  @override
  bool get supportsCurrentItem => true;

  @override
  Future<int?> resolveCurrentItemIndex() async {
    final key = _currentQueueKey;
    if (key == null) return null;
    bool matches(EffectivePlaybackItem e) => _keyOf(e) == key;
    // The contract is the WHOLE-list 0-based position — the generic page derives
    // `pageForIndex = index ~/ pageSize` from it — never a row inside the
    // current page. Fast path: the loaded page already holds the item.
    final local = _items.indexWhere(matches);
    if (local >= 0) return _currentPage * _pageSize + local;
    // Otherwise resolve the candidate stream to locate its global position.
    final all = await resolveBackgroundCandidates(scenarioId: scenarioId);
    final index = all.indexWhere(matches);
    return index < 0 ? null : index;
  }

  @override
  bool isCurrentItem(BuildContext context, EffectivePlaybackItem item) {
    final key = _currentQueueKey;
    if (key == null) return false;
    return key == _keyOf(item);
  }

  /// Plays [item] on the background engine: a row inside the window jumps to
  /// it; one outside slides the window onto it first (the runtime holds a
  /// WINDOW over the scenario, never the whole list).
  Future<void> _play(
      BuildContext context, EffectivePlaybackItem item) async {
    final bg = _bg;
    final outcome = await bg.jumpToOccurrence(
      virtualIndex: item.virtualIndex,
      mediaKey: _keyOf(item),
      userInitiated: true,
    );
    if (outcome != BgJumpOutcome.refusedForegroundFile) return;
    if (!context.mounted) return;
    final t = getLocalizations(context);
    await showMessageDialog(
      Navigator.of(context, rootNavigator: true),
      title: t.bg_queue_same_file_title,
      message: t.bg_queue_same_file_body,
      type: MessageDialogType.info,
    );
  }
}

/// How well a 副音 queue row's duration is resolved. Drives the row decoration:
/// anything but [ok] means the alignment cannot map this file.
enum _BgDurationState {
  /// The DB (or the live engine) already carries a usable duration.
  ok,

  /// A probe pass could not resolve it (or its write-back hit no DB row).
  failed,

  /// A probe pass is in flight.
  probing,

  /// Still missing: not (yet) probed, or a network storage the probe skips.
  unknown,
}
