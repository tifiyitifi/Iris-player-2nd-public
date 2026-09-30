import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/bg_source_manage_page.dart';
import 'package:iris/features/background_playback/view/control_target_indicator.dart';
import 'package:iris/models/file.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';

/// Fixed row extent of a queue row (dense ListTile 48 + 2 separation). Using an
/// explicit extent keeps the list LAZY: `shrinkWrap: true` forced the viewport
/// to lay out every row to size itself, which stalled on a long 副音 queue.
const double _kQueueRowExtent = 50;

/// List vertical padding (4 top + 4 bottom).
const double _kQueueListPadding = 8;

/// Conservative header (row + divider) height, subtracted from the available
/// height so the panel never overflows its host.
const double _kQueueHeaderExtent = 48;

/// Play queue panel of the 副音 playback subsystem.
///
/// Shown from the play-queue button (and, where possible, the docked side
/// panel) whenever the shared control target is the background engine. It
/// reads ONLY the background store — never `Provider<MediaPlayer>` — so
/// opening it from the queue button never touches the foreground runtime.
///
/// Title row: current file name + `cur/total`. Body: the queue list with the
/// current row highlighted; tapping a row starts that file on the background
/// engine ([BackgroundPlaybackStore.jumpTo]). Empty state (feature off or no
/// candidates) shows a short explanatory line.
class BackgroundQueuePanel extends HookWidget {
  const BackgroundQueuePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final bg = useBackgroundPlaybackStore();

    // Subscribe reactively: the queue/current row must follow live changes
    // (row tap, natural advance, refresh) while the panel or dock is open.
    final enabled = bg.select(context, (s) => s.enabled);
    final queue = bg.select(context, (s) => s.queue);
    final currentIndex = bg.select(context, (s) => s.currentIndex);

    if (!enabled || queue.isEmpty) {
      return _PanelCache(
        child: SizedBox(
          width: 320,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.bg_queue_empty,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => showBgSourceManage(context),
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: Text(t.bg_source_manage_open),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return _PanelCache(
      child: SizedBox(
        width: 320,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Explicit, clamped height: lazy rows for a long queue, compact
            // shrink-to-content for a short one. An unbounded host (the docked
            // panel's scroll view) falls back to a screen-relative cap.
            final double available = constraints.maxHeight.isFinite
                ? math.max(
                    0, constraints.maxHeight - _kQueueHeaderExtent)
                : MediaQuery.sizeOf(context).height * 0.6;
            final double content =
                queue.length * _kQueueRowExtent + _kQueueListPadding;
            final double listHeight =
                math.max(_kQueueRowExtent, math.min(content, available));
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _HeaderRow(
                  file: currentIndex >= 0 && currentIndex < queue.length
                      ? queue[currentIndex]
                      : null,
                  currentIndex: currentIndex,
                  total: queue.length,
                ),
                const Divider(height: 1),
                SizedBox(
                  height: listHeight,
                  child: ListView.builder(
                    padding:
                        const EdgeInsets.symmetric(vertical: 4),
                    itemExtent: _kQueueRowExtent,
                    itemCount: queue.length,
                    itemBuilder: (context, index) {
                      final file = queue[index];
                      final isCurrent = index == currentIndex;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: _QueueTile(
                          file: file,
                          isCurrent: isCurrent,
                          onTap: () => unawaited(
                            _jumpTo(bg, index, context),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Row tap. A refused jump (the row is the foreground's own file) explains
  /// itself instead of silently ignoring the tap — the row is legitimately in
  /// the list, it just cannot play at the same time as the video it came from.
  static Future<void> _jumpTo(
    BackgroundPlaybackStore bg,
    int index,
    BuildContext context,
  ) async {
    final outcome = await bg.jumpTo(index, userInitiated: true);
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

/// Caches the panel's theme/layout chrome so rebuilding when the store notifies
/// only re-paints the list body. Panel pops are full-screen routes; this keeps
/// the sheet cheap. (Shared with the dock body, which does not need the player
/// Stack's Positioned contract — this is a normal layout widget.)
class _PanelCache extends StatelessWidget {
  const _PanelCache({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('background_queue_panel_material'),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      child: child,
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.file,
    required this.currentIndex,
    required this.total,
  });

  final FileItem? file;
  final int currentIndex;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.multitrack_audio_rounded,
              size: 18, color: kBackgroundTargetColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              file?.name ?? '—',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${(currentIndex + 1).clamp(1, total)}/$total',
            style: textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: getLocalizations(context).bg_source_manage_open,
            style: IconButton.styleFrom(
              minimumSize: const Size(28, 28),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            iconSize: 18,
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => showBgSourceManage(context),
          ),
        ],
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({
    required this.file,
    required this.isCurrent,
    required this.onTap,
  });

  final FileItem file;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      // Row identity for tests.
      title: Text(
        file.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: isCurrent
              ? kBackgroundTargetColor
              : theme.colorScheme.onSurface,
          fontWeight: isCurrent ? FontWeight.w600 : null,
        ),
      ),
      leading: Icon(
        isCurrent
            ? Icons.graphic_eq_rounded
            : file.type == ContentType.video
                ? Icons.videocam_rounded
                : Icons.audio_file_rounded,
        size: 18,
        color: isCurrent ? kBackgroundTargetColor : theme.colorScheme.onSurfaceVariant,
      ),
      selected: isCurrent,
      onTap: onTap,
    );
  }
}