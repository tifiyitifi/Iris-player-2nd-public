import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/virtual_media/commands/vm_actions.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/service/vm_duration_scan.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/service/vm_preflight_coordinator.dart'
    show showVmVerifyReportDialog;
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/features/virtual_media/view/vm_info_banner.dart';
import 'package:iris/features/virtual_media/view/vm_manager_page.dart'
    show showVirtualMediaManager;
import 'package:iris/models/db/db_module.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/a11y_tooltip.dart'
    show a11yTooltip, a11yTooltipIconButton, rowTooltip;

String _fmt(int ms) {
  final d = Duration(milliseconds: ms);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0
      ? '${h}h${m.toString().padLeft(2, '0')}m'
      : '${m}m${s.toString().padLeft(2, '0')}s';
}

/// Virtual Merge rules management sheet: active-session panel (with chapter
/// list) plus rule tiles.
///
/// Tile front = 启用开关 + 置顶图钉（"最前面依旧是激活启用与 pin 固定优先
/// 显示"）。There is NO priority column: every rule resolves independently,
/// matched rules each produce their own virtual videos, and duplicate
/// avoidance is the user's job (stated in the banner).
class VirtualMediaSheet extends HookWidget {
  const VirtualMediaSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final vm = useVmPlaybackStore().select(context, (s) => s);
    final resolved = useState<ResolvedRules?>(null);
    final loading = useState(true);
    // Any mutation bumps this so the resolved preview never goes stale.
    final revision = useState(0);

    useEffect(() {
      var cancelled = false;
      loading.value = true;
      resolveEnabledRules().then((v) {
        if (!cancelled) {
          resolved.value = v;
          loading.value = false;
        }
      });
      return () => cancelled = true;
    }, [revision.value]);

    Future<void> afterMutate() async {
      // Propagate to the global merge layer + scenario lists immediately
      // ("一旦激活改变，立刻更新 scenario play 列表").
      await VirtualMediaService.instance.notifyRulesChanged();
      revision.value++;
    }

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.72,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
            child: Row(
              children: [
                Text(t.vm_sheet_title,
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                a11yTooltipIconButton(
                  context: context,
                  tooltip: t.vm_sheet_manage_tip,
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () {
                    Navigator.of(context).pop();
                    showVirtualMediaManager(context);
                  },
                ),
                a11yTooltipIconButton(
                  context: context,
                  tooltip: t.vm_sheet_new_rule_tip,
                  icon: const Icon(Icons.add),
                  onPressed: () async {
                    await openVmRuleEditor(context);
                    await afterMutate();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: VmInfoBanner(
              id: 'sheet.rules',
              text: t.vm_sheet_rules_banner,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                if (vm.item != null) ...[
                  _SessionCard(state: vm),
                  const Divider(),
                ],
                if (loading.value)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  for (final entry in resolved.value!.entries)
                    _RuleTile(
                        entry: entry,
                        onMutated: afterMutate,
                        libraryCount: resolved.value!.libraryCount),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionCard extends HookWidget {
  const _SessionCard({required this.state});

  final VmPlaybackState state;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final ctl = VirtualMediaController.instance;
    final item = state.item!;
    final chaptersOpen = useState(false);
    final segIdx = state.segmentIndex.clamp(0, item.segments.length - 1);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.play_circle_fill_rounded,
                color: Colors.green, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${item.displayName}  ·  ${t.vm_sheet_segment_label(segIdx + 1, item.segments.length)}',
                style: Theme.of(context).textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (state.lastError != null)
              // AXTree stability (#182444): tap-only under a UIA client.
              a11yTooltip(
                context: context,
                message: state.lastError!,
                child: const Icon(Icons.error, color: Colors.red),
              ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            a11yTooltipIconButton(
              context: context,
              tooltip: t.vm_sheet_prev_segment,
              onPressed: () => ctl.step(forward: false),
              icon: const Icon(Icons.skip_previous_rounded),
            ),
            a11yTooltipIconButton(
              context: context,
              tooltip: t.vm_sheet_next_segment,
              onPressed: () => ctl.step(forward: true),
              icon: const Icon(Icons.skip_next_rounded),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => chaptersOpen.value = !chaptersOpen.value,
              icon: Icon(chaptersOpen.value
                  ? Icons.unfold_less
                  : Icons.unfold_more),
              label: Text(t.vm_sheet_chapters),
            ),
            TextButton.icon(
              onPressed: () => ctl.stop(),
              icon: const Icon(Icons.stop_rounded),
              label: Text(t.vm_sheet_stop),
            ),
          ]),
          if (chaptersOpen.value)
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: item.segments.length,
                itemBuilder: (_, i) {
                  final seg = item.segments[i];
                  final dur = seg.durationMs;
                  return ListTile(
                    dense: true,
                    selected: i == segIdx,
                    leading: Text('${i + 1}'),
                    title: Text(seg.name, overflow: TextOverflow.ellipsis),
                    trailing:
                        dur == null ? null : Text(_fmt(dur)),
                    onTap: () => ctl.jumpToSegment(i),
                  );
                },
              ),
            ),
        ]),
      ),
    );
  }
}

class _RuleTile extends HookWidget {
  const _RuleTile({
    required this.entry,
    required this.onMutated,
    required this.libraryCount,
  });

  final MapEntry<VirtualMediaRule, List<VirtualMediaItem>> entry;
  final Future<void> Function() onMutated;

  /// Size of the library snapshot this preview was resolved against — shown
  /// in the preview so "0 匹配" is attributable (empty snapshot vs path
  /// mismatch).
  final int libraryCount;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final rule = entry.key;
    final items = entry.value;

    void showPreview() {
      // Segments without a known duration block their whole group from
      // merging — offer an in-place scan so the preview (and playback) can
      // merge normally afterwards.
      final seenKeys = <String>{};
      final unknownSegs = <VirtualSegment>[
        for (final it in items)
          for (final s in it.segments)
            if ((s.durationMs == null || s.durationMs! <= 0) &&
                seenKeys.add(s.mediaKey))
              s,
      ];

      Future<void> scanMissing() async {
        final navigator = Navigator.of(context);
        final outcome = await scanWithProgressDialog(
          navigator,
          title: t.vm_sheet_scan_missing_title,
          total: unknownSegs.length,
          task: (onProgress, isCancelled) => scanVmGroupDurations(
            unknownSegs,
            onProgress: onProgress,
            shouldCancel: isCancelled,
            skipKeys:
                VirtualMediaService.instance.shellUnsupportedKeys,
          ),
        );
        if (!context.mounted) return;
        if (outcome.cancelled) return;
        VirtualMediaService.instance
            .markShellUnsupported(outcome.failedKeys);
        if (outcome.succeededKeys.isNotEmpty) {
          // Close the preview and refresh: the sheet re-resolves against
          // the now-complete durations.
          Navigator.of(context).pop();
          await onMutated();
          return;
        }
        final parts = <String>[
          if (outcome.skipped > 0)
            t.vm_sheet_scan_skipped_remote(outcome.skipped),
          if (outcome.failedKeys.isNotEmpty)
            t.vm_sheet_scan_failed(outcome.failedKeys.length),
        ];
        await showVmVerifyReportDialog(
          navigator,
          t.vm_sheet_scan_kept_normal(parts.join(', ')),
        );
      }

      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(rule.name),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.vm_sheet_match_prefix(vmMatchSummary(rule, t)),
                    style: Theme.of(context).textTheme.bodySmall),
                Text(
                    t.vm_sheet_preview_all(libraryCount, items.length),
                    style: Theme.of(context).textTheme.bodySmall),
                if (unknownSegs.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  TextButton.icon(
                    onPressed: scanMissing,
                    icon: const Icon(Icons.warning_amber_rounded,
                        color: Colors.amber, size: 18),
                    label: Text(
                        t.vm_sheet_scan_missing_btn(unknownSegs.length)),
                  ),
                ],
                const SizedBox(height: 8),
                if (items.isEmpty)
                  Text(t.vm_sheet_empty)
                else
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final it in items.take(8))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                  '· ${it.displayName}  '
                                  '${t.vm_sheet_item_meta(_fmt(it.totalDurationMs), it.segments.length)}',
                                  style: Theme.of(context).textTheme.bodySmall),
                            ),
                          if (items.length > 8)
                            Text(t.vm_sheet_more_items(items.length),
                                style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.vm_sheet_close),
            ),
          ],
        ),
      );
    }

    return ListTile(
      leading: Row(mainAxisSize: MainAxisSize.min, children: [
        Switch(
          value: rule.enabled,
          onChanged: (v) async {
            await DbModule.virtualMediaRepo.setRuleEnabled(rule.id, v);
            await onMutated();
          },
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: rule.pinned ? t.vm_sheet_pinned : t.vm_sheet_pin,
          icon: Icon(
            rule.pinned
                ? Icons.push_pin_rounded
                : Icons.push_pin_outlined,
            size: 20,
            color: rule.pinned
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          onPressed: () async {
            await DbModule.virtualMediaRepo.setRulePinned(
                rule.id, !rule.pinned);
            await onMutated();
          },
        ),
      ]),
      title: Text(rule.name,
          style: TextStyle(
              decoration:
                  rule.enabled ? null : TextDecoration.lineThrough)),
      subtitle: Text(
        items.isEmpty
            ? (rule.description.isEmpty
                ? t.vm_sheet_no_match
                : t.vm_sheet_no_match_desc(rule.description))
            : (rule.description.isEmpty
                ? t.vm_sheet_count_videos(items.length)
                : t.vm_sheet_count_videos_desc(
                    rule.description, items.length)),
        overflow: TextOverflow.ellipsis,
      ),
      onTap: showPreview,
      trailing: PopupMenuButton<String>(
        tooltip: rowTooltip(null),
        onSelected: (v) async {
          switch (v) {
            case 'edit':
              await openVmRuleEditor(context, initial: rule);
              await onMutated();
              break;
            case 'delete':
              // Same object, same semantics as the manager page: cascade so
              // no vm_progress/anchor rows left dangling. Atomic in the repo — a
              // failure surfaces a dialog instead of a half-delete.
              try {
                await DbModule.virtualMediaRepo.deleteRuleCascade(rule.id);
              } catch (_) {
                if (!context.mounted) break;
                await showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: Text(t.vm_mgr_delete_title),
                    content: Text(t.vm_mgr_action_failed_body),
                  ),
                );
                break;
              }
              await onMutated();
              break;
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'edit', child: Text(t.vm_sheet_edit)),
          PopupMenuItem(value: 'delete', child: Text(t.vm_sheet_delete)),
        ],
      ),
    );
  }
}
