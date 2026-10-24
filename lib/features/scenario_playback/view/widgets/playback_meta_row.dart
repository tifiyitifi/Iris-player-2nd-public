import 'package:flutter/material.dart' hide Chip;
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/virtual_child_entry.dart';
import 'package:iris/features/scenario_playback/view/widgets/duplicate_badge.dart';
import 'package:iris/features/scenario_playback/view/widgets/live_progress_chip.dart';
import 'package:iris/features/scenario_playback/view/widgets/vm_group_progress_chip.dart';
import 'package:iris/utils/file_size_convert.dart' show formatFileSize;
import 'package:iris/utils/format_duration_hms.dart';
import 'package:iris/utils/get_localizations.dart';

/// Subtitle content shared by the scenario queue and preview tiles.
///
/// Layout contract (mobile-first):
/// - Line 1 is ALWAYS a single ellipsized line: the merged summary
///   (`N seg · duration · size`, plus the optional sort date) shrinks inside a
///   [Flexible] while the important progress chip stays intrinsic. This is the
///   common case and keeps tile heights uniform — no accidental wrapping.
/// - Line 2 exists ONLY when a low-frequency secondary marker is present
///   (duplicate occurrence / explicit item), so those rare rows are a
///   deliberate extra line instead of overflowing or pushing the progress chip
///   onto a stray run. The explicit marker is PLAIN text aligned with line 1 —
///   the duplicate badge is the only pill-shaped one, because an occurrence
///   index is genuinely a badge while "this file was added by hand" is not.
///
/// The virtual-degraded warning is intentionally NOT rendered here: both the
/// queue and preview leading slots already draw the yellow warning + tooltip,
/// so repeating it in the subtitle only burned scarce width.
class PlaybackMetaRow extends StatelessWidget {
  const PlaybackMetaRow({
    super.key,
    required this.size,
    required this.durationMs,
    required this.isMerged,
    required this.segmentCount,
    required this.showProgress,
    required this.media,
    required this.fileDurationMs,
    required this.isCurrent,
    required this.duplicated,
    required this.occurrenceIndex,
    required this.explicit,
    this.sortValue,
    this.vmChildren = const [],
    this.vmTotalDurationMs = 0,
    this.vmAnchorKey = '',
  });

  /// Merged totals for a virtual-merged representative, otherwise the single
  /// file's own values (the caller resolves which).
  final int size;
  final int durationMs;
  final bool isMerged;
  final int segmentCount;

  /// Whether to render the per-second progress chip (video items).
  final bool showProgress;
  final MediaNode media;
  final int fileDurationMs;
  final bool isCurrent;

  /// Low-frequency secondary badges; they go to their own line when present.
  final bool duplicated;
  final int occurrenceIndex;
  final bool explicit;

  /// Sort-field value (only Added/Modified show a date), or null.
  final String? sortValue;

  /// Merged-item children (with their own durations/positions) so the row can
  /// show the WHOLE item's progress plus the current segment's. Empty for an
  /// ordinary single-file row.
  final List<VirtualChildEntry> vmChildren;
  final int vmTotalDurationMs;

  /// Canonical key of the row's anchor segment (the merged item's first
  /// segment) — identifies the live session that owns this row.
  final String vmAnchorKey;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final summary = <String>[
      if (isMerged && segmentCount > 1) t.vm_list_meta_segments(segmentCount),
      if (durationMs > 0) formatDurationHms(Duration(milliseconds: durationMs)),
      if (size > 0) formatFileSize(size),
      if (sortValue != null && sortValue!.isNotEmpty) sortValue!,
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (summary.isNotEmpty)
              Flexible(
                child: Text(
                  summary.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (showProgress) ...[
              if (summary.isNotEmpty) const SizedBox(width: 8),
              // A merged item has no single file to report on: show the whole
              // item's progress (and, while it plays, the current segment's)
              // instead of the anchor file's own percentage.
              if (isMerged && vmChildren.isNotEmpty)
                VmGroupProgressChip(
                  anchorKey: vmAnchorKey,
                  children: vmChildren,
                  totalDurationMs: vmTotalDurationMs,
                  isCurrent: isCurrent,
                  showWhenEmpty: isCurrent,
                )
              else
                LiveProgressChip(
                  media: media,
                  durationMs: fileDurationMs,
                  showWhenEmpty: isCurrent,
                ),
            ],
          ],
        ),
        if (duplicated || explicit) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (duplicated) DuplicateBadge(occurrenceIndex: occurrenceIndex),
              // A PLAIN, DELIBERATELY GREY line aligned with the meta line
              // above: the marker is secondary information, so it must not be
              // a badge/pill and must not carry full-strength text either.
              // Every container shape (highlighted "Added", a grey chip, a
              // lighter chip) still drew the eye from the row title; the field
              // report asked for ordinary grey text.
              if (explicit)
                Text(
                  t.scn_explicit_item_label,
                  style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.45),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
