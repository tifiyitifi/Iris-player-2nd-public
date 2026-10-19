import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/actions/background_playback_actions.dart';
import 'package:iris/features/background_playback/background_playback_gate.dart';
import 'package:iris/features/background_playback/model/domain/background_mapping.dart';
import 'package:iris/features/background_playback/model/domain/background_mapping_summary.dart';
import 'package:iris/features/background_playback/model/domain/segment_edit_draft.dart';
import 'package:iris/features/background_playback/resolver/active_mapping_resolver.dart';
import 'package:iris/features/background_playback/resolver/mapping_binding.dart';
import 'package:iris/features/background_playback/resolver/mapping_overview_math.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/services/apb_edit_context.dart';
import 'package:iris/features/background_playback/services/background_file_builder.dart';
import 'package:iris/features/background_playback/services/mapping_staging_service.dart';
import 'package:iris/features/background_playback/store/use_apb_edit_session_store.dart';
import 'package:iris/features/background_playback/store/use_background_mapping_staging_store.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/manager/background_candidate_picker.dart';
import 'package:iris/features/background_playback/view/manager/mapping_timeline_overview.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/format_duration_hms.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';
import 'package:iris/widgets/popup.dart';

/// Opens the two-level 副音 mapping manager (副音 menu only).
///
/// Gate OFF → the feature does not exist for legacy-persistence users; the
/// entry explains instead of opening (project rule: Dialog, never SnackBar).
Future<void> showBackgroundMappingManager(BuildContext context) async {
  if (!BackgroundPlaybackGate.enabled) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final t = getLocalizations(context);
    await showMessageDialog(
      navigator,
      title: t.bg_mapping_manager_title,
      message: t.bg_gate_meta_body,
      type: MessageDialogType.info,
    );
    return;
  }
  final direction = useAppStore().state.defaultPopupDirection;
  await showPopup(
    context: context,
    child: const BackgroundMappingManagerPage(),
    direction: direction,
  );
}

/// Host of the two levels: loads the saved timelines once, then swaps between
/// the Level-1 list and the Level-2 detail in place (no extra routes).
class BackgroundMappingManagerPage extends HookWidget {
  const BackgroundMappingManagerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final staging = useBackgroundMappingStagingStore();
    final staged = staging.select(context, (s) => s.staged);
    final summaries = useState<List<BackgroundMappingSummary>?>(null);
    // The selected fg's committed timeline ONLY (lazy per-key fetch — the
    // manager never materializes every timeline at once).
    final detail = useState<BackgroundMappingTimeline?>(null);
    final detailKey = useState<String?>(null);
    final selectedKey = useState<String?>(null);
    final reloadSeq = useState(0);

    useEffect(() {
      var stale = false;
      Future<void> load() async {
        try {
          final rows = await DbModule.bgMappingRepo.listSummaries();
          if (stale) return;
          summaries.value = rows;
        } catch (_) {
          if (!stale) summaries.value = const <BackgroundMappingSummary>[];
        }
      }

      unawaited(load());
      return () => stale = true;
    }, [reloadSeq.value]);

    final rows = summaries.value;
    final key = selectedKey.value;
    BackgroundMappingSummary? selected;
    if (rows != null && key != null) {
      for (final s in rows) {
        if (s.key == key) {
          selected = s;
          break;
        }
      }
    }

    // (Re)load the committed timeline when the selection or the data changes.
    useEffect(() {
      final s = selected;
      if (s == null) {
        detail.value = null;
        detailKey.value = null;
        return null;
      }
      var stale = false;
      detailKey.value = null;
      DbModule.bgMappingRepo
          .getTimelineForFg(storageId: s.storageId, path: s.path)
          .then((t) {
        if (stale) return;
        detail.value = t;
        detailKey.value = s.key;
      });
      return () => stale = true;
    }, [selected?.key, reloadSeq.value]);

    if (selected != null) {
      final committed =
          detailKey.value == selected.key ? detail.value : null;
      final entry = staged[selected.key];
      final display = entry?.timeline ??
          committed ??
          BackgroundMappingTimeline(
            storageId: selected.storageId,
            path: selected.path,
          );

      return BackgroundMappingDetailView(
        summary: selected,
        timeline: display,
        dirty: entry?.dirty ?? false,
        onDeleteSegment: (seg) =>
            _deleteSegment(staging, committed, selected!, seg),
        onReplaceBg: (seg) =>
            _replaceBg(context, staging, committed, selected!, seg),
        onEditSegment: (seg) => _editSegment(context, selected!, seg),
        onToggleSegmentActive: (seg) =>
            _toggleSegmentActive(staging, committed, selected!, seg),
        onApply: () =>
            _apply(context, staging, selected!, onApplied: () => reloadSeq.value++),
        onDiscard: () => staging.discard(selected!.key),
        onBack: () => selectedKey.value = null,
        onClose: () => Navigator.of(context).maybePop(),
      );
    }

    return BackgroundMappingListView(
      summaries: rows ?? const <BackgroundMappingSummary>[],
      loading: rows == null,
      dirtyKeys: staging.dirtyKeys,
      onSelect: (s) {
        if (!s.hasFgDuration) {
          showMessageDialog(
            Navigator.of(context, rootNavigator: true),
            title: t.bg_mapping_manager_title,
            message: t.bg_mapping_manager_no_duration,
            type: MessageDialogType.info,
          );
          return;
        }
        selectedKey.value = s.key;
      },
      onClose: () => Navigator.of(context).maybePop(),
    );
  }

  /// Opens the existing APB editor for [segment] inside a transient single-fg
  /// context (leaves SystemPlaying untouched), with Save routed to the session
  /// staging draft.
  Future<void> _editSegment(
    BuildContext context,
    BackgroundMappingSummary summary,
    MappingSegment segment,
  ) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final t = getLocalizations(context);

    final node = await DbModule.mediaNodeRepo.getNodeByPath(
      storageId: summary.storageId,
      path: pathConv(summary.path),
    );
    final fg = node?.maybeMap(
      file: (v) => backgroundFileItemFromMediaFile(v),
      orElse: () => null,
    );
    if (fg == null) {
      await showMessageDialog(
        navigator,
        title: t.bg_mapping_manager_title,
        message: t.bg_mapping_manager_edit_no_fg,
        type: MessageDialogType.error,
      );
      return;
    }

    // Close the manager so the player surface (and the editor) becomes visible.
    navigator.pop();

    final session = await ApbEditContext.enter(fg: fg);
    if (session == null) {
      await showMessageDialog(
        navigator,
        title: t.bg_mapping_manager_title,
        message: t.bg_mapping_manager_edit_no_fg,
        type: MessageDialogType.error,
      );
      return;
    }
    useApbEditSessionStore().begin(session);

    final bg = useBackgroundPlaybackStore();
    if (!bg.state.enabled) {
      final window = await BackgroundPlaybackActions.resolveCandidates();
      if (window == null) {
        useApbEditSessionStore().clear();
        await ApbEditContext.exit(session);
        await showMessageDialog(
          navigator,
          title: t.bg_mapping_manager_title,
          message: t.bg_mapping_manager_edit_no_bg,
          type: MessageDialogType.info,
        );
        return;
      }
      await BackgroundPlaybackActions.startWithCandidates(
        window.files,
        window: window,
        replace: false,
      );
    }
    var draft = SegmentEditDraft.fromSegment(segment);
    // Unify on the LIVE bg queue: when the saved segment's bg is in the queue,
    // jump the live queue to it so the editor edits the file being heard
    // (prev/next and the queue panel then move from there). When it is absent,
    // re-bind the draft to the live bg so the mapping always names the file
    // that is actually playing.
    final preview = await _previewFor(segment);
    if (!_jumpLiveQueueTo(bg, preview)) {
      final live = bg.currentFile;
      if (live != null) {
        draft = draft.copyWith(
          bgStorageId: live.storageId,
          bgPath: live.path.join('/'),
        );
      }
    }
    bg.enterSegmentEdit(draft, stageOnly: true);
  }

  /// Jumps the LIVE background queue to [file] when present; returns whether it
  /// matched.
  bool _jumpLiveQueueTo(BackgroundPlaybackStore bg, FileItem? file) {
    if (file == null) return false;
    final key = backgroundMediaKey(file);
    final idx =
        bg.state.queue.indexWhere((f) => backgroundMediaKey(f) == key);
    if (idx < 0) return false;
    bg.jumpTo(idx);
    return true;
  }

  /// Resolves the saved row's bg file for the editor preview (null when the
  /// file vanished — the switcher then walks the pool from its head).
  Future<FileItem?> _previewFor(MappingSegment segment) async {
    try {
      final sid = segment.bgStorageId;
      final bpath = segment.bgPath;
      if (sid == null || bpath == null || bpath.isEmpty) return null;
      final node = await DbModule.mediaNodeRepo.getNodeByPath(
        storageId: sid,
        path: pathConv(bpath),
      );
      return node?.maybeMap(
        file: (v) => backgroundFileItemFromMediaFile(v),
        orElse: () => null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Stages flipping one segment's activation. Activating assigns the NEXT
  /// sequence so the freshly lit segment wins wherever it overlaps (the
  /// mapping analogue of the WebDAV default-name lit order); deactivating keeps
  /// the sequence but removes the segment from resolution entirely.
  void _toggleSegmentActive(
    BackgroundMappingStagingStore staging,
    BackgroundMappingTimeline? committed,
    BackgroundMappingSummary summary,
    MappingSegment segment,
  ) {
    final base = _baseTimeline(staging, committed, summary);
    final nextSeq = segment.isActive
        ? segment.activeSeq
        : ActiveMappingResolver.nextActiveSeq(base.segments);
    final next = base.copyWith(
      segments: [
        for (final s in base.segments)
          _isSameSegment(s, segment)
              ? s.copyWith(isActive: !s.isActive, activeSeq: nextSeq)
              : s,
      ],
    );
    staging.stage(next, baselineUpdatedAt: committed?.updatedAt);
  }

  /// The timeline a staged edit starts from: the in-progress draft, else the
  /// committed row, else an empty timeline for the fg.
  BackgroundMappingTimeline _baseTimeline(
    BackgroundMappingStagingStore staging,
    BackgroundMappingTimeline? committed,
    BackgroundMappingSummary summary,
  ) =>
      staging.stagedFor(summary.key)?.timeline ??
      committed ??
      BackgroundMappingTimeline(
        storageId: summary.storageId,
        path: summary.path,
      );

  /// Matches a list row to the segment it was built from (id when both have
  /// one, otherwise the fg range — staged rows carry id 0).
  static bool _isSameSegment(MappingSegment a, MappingSegment b) {
    if (a.id != 0 && b.id != 0) return a.id == b.id;
    return a.fgStartMs == b.fgStartMs && a.fgEndMs == b.fgEndMs;
  }

  /// Stages swapping one segment's background file from the candidate pool,
  /// keeping its foreground placement and alignment (position/binding
  /// decoupling).
  Future<void> _replaceBg(
    BuildContext context,
    BackgroundMappingStagingStore staging,
    BackgroundMappingTimeline? committed,
    BackgroundMappingSummary summary,
    MappingSegment segment,
  ) async {
    final picked = await showBackgroundCandidatePicker(
      context,
      currentPath: segment.bgPath,
    );
    if (picked == null || !context.mounted) return;
    final bgTotalMs = await _durationMsFor(picked);
    final base = staging.stagedFor(summary.key)?.timeline ??
        committed ??
        BackgroundMappingTimeline(
          storageId: summary.storageId,
          path: summary.path,
        );
    final next = replaceSegmentBg(
      base,
      segment,
      bgStorageId: picked.storageId,
      bgPath: picked.path.join('/'),
      bgTotalMs: bgTotalMs,
    );
    staging.stage(next, baselineUpdatedAt: committed?.updatedAt);
  }

  /// Probed duration of a candidate, used to refresh the segment's normalized
  /// bg fractions so the overview can show the uncovered part. Null when the
  /// node is unknown (an unprobed candidate simply counts as fully covered).
  Future<int?> _durationMsFor(FileItem file) async {
    try {
      final nodes = await DbModule.mediaNodeRepo.nodesByMediaKeys(
        {canonicalKey(file.storageId, file.path.join('/'))},
      );
      for (final n in nodes) {
        final d = n.maybeMap(file: (v) => v.durationMs, orElse: () => null);
        if (d != null && d > 0) return d;
      }
    } catch (_) {
      // A probe failure must not block the swap; leave the duration unknown.
    }
    return null;
  }

  /// Stages the removal of one segment. Baseline is the COMMITTED row's
  /// `updatedAt` so a later Apply can detect an external change.
  void _deleteSegment(
    BackgroundMappingStagingStore staging,
    BackgroundMappingTimeline? committed,
    BackgroundMappingSummary summary,
    MappingSegment segment,
  ) {
    final base = staging.stagedFor(summary.key)?.timeline ??
        committed ??
        BackgroundMappingTimeline(
          storageId: summary.storageId,
          path: summary.path,
        );
    final next = base.copyWith(
      segments: [
        for (final s in base.segments)
          if (s.id != segment.id ||
              s.fgStartMs != segment.fgStartMs ||
              s.fgEndMs != segment.fgEndMs)
            s,
      ],
    );
    staging.stage(next, baselineUpdatedAt: committed?.updatedAt);
  }

  Future<void> _apply(
    BuildContext context,
    BackgroundMappingStagingStore staging,
    BackgroundMappingSummary summary, {
    required VoidCallback onApplied,
  }) async {
    final entry = staging.stagedFor(summary.key);
    if (entry == null) return;
    final outcome = await applyStagedMappingTimeline(
      staged: entry.timeline,
      baselineUpdatedAt: entry.baselineUpdatedAt,
    );
    if (!context.mounted) return;
    final t = getLocalizations(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    switch (outcome.status) {
      case MappingApplyStatus.ok:
        staging.discard(summary.key);
        onApplied();
        await showMessageDialog(
          navigator,
          title: t.bg_mapping_manager_apply_ok_title,
          message: t.bg_mapping_manager_apply_ok_body,
          type: MessageDialogType.success,
        );
      case MappingApplyStatus.conflict:
        await showMessageDialog(
          navigator,
          title: t.bg_mapping_manager_conflict_title,
          message: t.bg_mapping_manager_conflict_body,
          type: MessageDialogType.error,
        );
      case MappingApplyStatus.invalid:
        await showMessageDialog(
          navigator,
          title: t.bg_mapping_manager_apply_invalid_title,
          message: outcome.message ?? '',
          type: MessageDialogType.error,
        );
      case MappingApplyStatus.writeFailed:
        await showMessageDialog(
          navigator,
          title: t.bg_mapping_manager_apply_failed_title,
          message: outcome.message ?? '',
          type: MessageDialogType.error,
        );
    }
  }
}

/// Level 1 — one row per foreground file that owns a saved mapping.
class BackgroundMappingListView extends StatelessWidget {
  const BackgroundMappingListView({
    super.key,
    required this.summaries,
    required this.loading,
    required this.onSelect,
    required this.onClose,
    this.dirtyKeys = const <String>{},
  });

  final List<BackgroundMappingSummary> summaries;
  final bool loading;
  final ValueChanged<BackgroundMappingSummary> onSelect;
  final VoidCallback onClose;

  /// fg keys with a staged (not yet applied) draft — shown as a badge.
  final Set<String> dirtyKeys;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    return Column(
      key: const ValueKey('bg_mapping_manager_list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(title: t.bg_mapping_manager_title, onClose: onClose),
        const Divider(height: 1),
        Expanded(
          child: loading
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              : summaries.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        t.bg_mapping_manager_empty,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: summaries.length,
                      itemBuilder: (context, i) => _SummaryTile(
                        summary: summaries[i],
                        dirty: dirtyKeys.contains(summaries[i].key),
                        onTap: () => onSelect(summaries[i]),
                      ),
                    ),
        ),
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.summary,
    required this.onTap,
    this.dirty = false,
  });

  final BackgroundMappingSummary summary;
  final VoidCallback onTap;
  final bool dirty;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final theme = Theme.of(context);
    final available = summary.hasFgDuration;
    final bgText = summary.bgNames.isEmpty
        ? t.bg_mapping_manager_unknown_bg
        : t.bg_mapping_manager_bg_names(summary.bgNames.join('、'));
    return ListTile(
      enabled: available,
      onTap: onTap,
      leading: Icon(
        available ? Icons.timeline_rounded : Icons.report_problem_outlined,
        color: available ? theme.colorScheme.primary : theme.colorScheme.error,
      ),
      title: Text(
        summary.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        available
            ? '${t.bg_mapping_manager_segment_count(summary.segmentCount)} · $bgText'
            : t.bg_mapping_manager_no_duration,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: available
            ? theme.textTheme.bodySmall
            : theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
      ),
      trailing: available
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (dirty)
                  Container(
                    margin: const EdgeInsets.only(right: 4),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      t.bg_mapping_manager_staged,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                const Icon(Icons.chevron_right_rounded),
              ],
            )
          : const Icon(Icons.lock_outline_rounded, size: 16),
    );
  }
}

/// Level 2 — the whole foreground duration (0–100%) with every saved segment
/// and the background bound to it.
class BackgroundMappingDetailView extends StatelessWidget {
  const BackgroundMappingDetailView({
    super.key,
    required this.summary,
    required this.timeline,
    required this.onBack,
    required this.onClose,
    this.dirty = false,
    this.onDeleteSegment,
    this.onReplaceBg,
    this.onEditSegment,
    this.onToggleSegmentActive,
    this.onApply,
    this.onDiscard,
  });

  final BackgroundMappingSummary summary;
  final BackgroundMappingTimeline timeline;
  final VoidCallback onBack;
  final VoidCallback onClose;

  /// There is a staged, not-yet-applied draft for this fg.
  final bool dirty;
  final ValueChanged<MappingSegment>? onDeleteSegment;
  final ValueChanged<MappingSegment>? onReplaceBg;
  final ValueChanged<MappingSegment>? onEditSegment;
  final ValueChanged<MappingSegment>? onToggleSegmentActive;
  final VoidCallback? onApply;
  final VoidCallback? onDiscard;

  /// 1-based activation rank of an ACTIVE segment among the active ones
  /// (ascending `activeSeq`), so the list reads as a lit order. Null for a
  /// disabled segment (it has no order).
  static int? _activeOrderOf(
    MappingSegment segment,
    List<MappingSegment> all,
  ) {
    if (!segment.isActive) return null;
    final seqs = <int>{
      for (final s in all)
        if (s.isActive) s.activeSeq,
    }.toList()
      ..sort();
    final idx = seqs.indexOf(segment.activeSeq);
    return idx < 0 ? null : idx + 1;
  }

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final theme = Theme.of(context);
    final fgTotalMs = summary.fgTotalMs ?? 0;
    final segments = timeline.sortedSegments;
    final blocks = MappingOverviewMath.layout(
      segments: segments,
      fgTotalMs: fgTotalMs,
    );

    return Column(
      key: const ValueKey('bg_mapping_manager_detail'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: summary.displayName,
          onBack: onBack,
          onClose: onClose,
        ),
        const Divider(height: 1),
        if (dirty && onApply != null && onDiscard != null)
          _StagedBanner(
            hint: t.bg_mapping_manager_staged_hint,
            applyLabel: t.bg_mapping_manager_apply,
            discardLabel: t.bg_mapping_manager_discard,
            onApply: onApply!,
            onDiscard: onDiscard!,
          ),
        Expanded(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(12),
            children: [
              if (!summary.hasFgDuration)
                Text(
                  t.bg_mapping_manager_no_duration,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.error),
                )
              else ...[
                MappingTimelineOverview(
                  blocks: blocks,
                  fgTotalMs: fgTotalMs,
                  semanticsLabel: t.bg_mapping_manager_overview_label,
                ),
                const SizedBox(height: 8),
                _Legend(
                  covered: t.bg_mapping_manager_overview_label,
                  silence: t.bg_mapping_manager_silence,
                  uncovered: t.bg_mapping_manager_uncovered,
                  gap: t.bg_mapping_manager_gap,
                ),
                const SizedBox(height: 8),
                const Divider(height: 1),
              ],
              if (segments.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    t.bg_mapping_manager_empty,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                )
              else
                for (final s in segments)
                  _SegmentTile(
                    segment: s,
                    activeOrder: _activeOrderOf(s, segments),
                    onToggleActive: onToggleSegmentActive == null
                        ? null
                        : () => onToggleSegmentActive!(s),
                    onDelete: onDeleteSegment == null
                        ? null
                        : () => onDeleteSegment!(s),
                    onReplaceBg: onReplaceBg == null || !s.isPlayMedia
                        ? null
                        : () => onReplaceBg!(s),
                    onEdit: onEditSegment == null
                        ? null
                        : () => onEditSegment!(s),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Dirty-draft banner: explains that the edits are not live and offers the
/// per-fg Apply / Discard pair.
class _StagedBanner extends StatelessWidget {
  const _StagedBanner({
    required this.hint,
    required this.applyLabel,
    required this.discardLabel,
    required this.onApply,
    required this.onDiscard,
  });

  final String hint;
  final String applyLabel;
  final String discardLabel;
  final VoidCallback onApply;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('bg_mapping_manager_staged_banner'),
      color: theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('bg_mapping_manager_discard'),
            onPressed: onDiscard,
            child: Text(discardLabel),
          ),
          FilledButton(
            key: const ValueKey('bg_mapping_manager_apply'),
            onPressed: onApply,
            child: Text(applyLabel),
          ),
        ],
      ),
    );
  }
}

class _SegmentTile extends StatelessWidget {
  const _SegmentTile({
    required this.segment,
    this.activeOrder,
    this.onToggleActive,
    this.onDelete,
    this.onReplaceBg,
    this.onEdit,
  });

  final MappingSegment segment;

  /// 1-based lit order among active segments; null when disabled.
  final int? activeOrder;
  final VoidCallback? onToggleActive;
  final VoidCallback? onDelete;
  final VoidCallback? onReplaceBg;
  final VoidCallback? onEdit;

  static String _fmt(int ms) =>
      formatDurationHms(Duration(milliseconds: ms));

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final theme = Theme.of(context);
    final isPlay = segment.isPlayMedia;
    final active = segment.isActive;
    final range = t.bg_mapping_manager_segment_range(
      _fmt(segment.fgStartMs),
      _fmt(segment.fgEndMs),
    );
    final bg = segment.bgPath;
    final bgName = (bg == null || bg.isEmpty)
        ? t.bg_mapping_manager_unknown_bg
        : bg.split('/').last;

    final window = (segment.bgStartMs != null && segment.bgEndMs != null)
        ? t.bg_mapping_manager_bg_window(
            _fmt(segment.bgStartMs!),
            _fmt(segment.bgEndMs!),
          )
        : null;

    // Lead-in before A (`-mm:ss`) is bg content skipped because the video
    // starts after the bg's 00:00; the uncovered tail is shown by the bar.
    final leadIn = MappingBinding.offsetMsOf(segment);
    final leadText = leadIn > 0 ? '-${_fmt(leadIn)}' : null;

    final subtitle = [
      if (activeOrder != null)
        t.bg_mapping_manager_active_order(activeOrder!),
      range,
      if (window != null) window,
      if (leadText != null) leadText,
    ].join(' · ');

    return ListTile(
      key: ValueKey('bg_mapping_segment_${segment.fgStartMs}_${segment.fgEndMs}'),
      dense: true,
      // Disabled segments stay visible (data preserved) but read as parked.
      enabled: active,
      leading: Icon(
        isPlay ? Icons.music_note_rounded : Icons.volume_off_rounded,
        color: active
            ? (isPlay
                ? theme.colorScheme.primary
                : theme.colorScheme.tertiary)
            : theme.disabledColor,
      ),
      title: Text(
        isPlay ? bgName : t.bg_mapping_manager_silence,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
      trailing: (onDelete == null &&
              onReplaceBg == null &&
              onEdit == null &&
              onToggleActive == null)
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onToggleActive != null)
                  IconButton(
                    key: const ValueKey('bg_mapping_segment_active_toggle'),
                    tooltip: active
                        ? t.bg_mapping_manager_deactivate
                        : t.bg_mapping_manager_activate,
                    icon: Icon(
                      active
                          ? Icons.toggle_on_rounded
                          : Icons.toggle_off_rounded,
                      size: 24,
                      color: active
                          ? theme.colorScheme.primary
                          : theme.disabledColor,
                    ),
                    onPressed: onToggleActive,
                  ),
                if (onEdit != null)
                  IconButton(
                    tooltip: t.bg_mapping_manager_edit_segment,
                    icon: const Icon(Icons.edit_rounded, size: 20),
                    onPressed: onEdit,
                  ),
                if (onReplaceBg != null)
                  IconButton(
                    tooltip: t.bg_mapping_manager_replace_bg,
                    icon: const Icon(Icons.swap_horiz_rounded, size: 20),
                    onPressed: onReplaceBg,
                  ),
                if (onDelete != null)
                  IconButton(
                    tooltip: t.bg_mapping_manager_delete_segment,
                    icon: const Icon(Icons.delete_outline_rounded, size: 20),
                    onPressed: onDelete,
                  ),
              ],
            ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.covered,
    required this.silence,
    required this.uncovered,
    required this.gap,
  });

  final String covered;
  final String silence;
  final String uncovered;
  final String gap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        _dot(context, scheme.primary, covered),
        _dot(context, scheme.tertiary.withValues(alpha: 0.55), silence),
        _dot(context, scheme.onSurface.withValues(alpha: 0.20), uncovered),
        _dot(context, scheme.onSurface.withValues(alpha: 0.10), gap),
      ],
    );
  }

  Widget _dot(BuildContext context, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

/// Shared manager header: optional back arrow + title + close button.
class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onClose, this.onBack});

  final String title;
  final VoidCallback onClose;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              tooltip: t.bg_mapping_manager_back,
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: onBack,
            )
          else
            const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: t.bg_mapping_manager_close,
            icon: const Icon(Icons.close_rounded),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
