import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/virtual_media/commands/vm_actions.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/view/vm_master_switch.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/a11y_tooltip.dart' show rowTooltip;
import 'package:iris/widgets/popup.dart';

Future<void> showVirtualMediaManager(BuildContext context) {
  return showPopup(
    context: context,
    direction: PopupDirection.right,
    child: const VmManagerPage(),
  );
}

String _fmt(int ms) {
  final d = Duration(milliseconds: ms);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0 ? '${h}h${m.toString().padLeft(2, '0')}m' : '${m}m${s.toString().padLeft(2, '0')}s';
}

class VmManagerPage extends HookWidget {
  const VmManagerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final resolved = useState<ResolvedRules?>(null);
    final loading = useState(true);
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
      await VirtualMediaService.instance.notifyRulesChanged();
      revision.value++;
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(t.vm_mgr_title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              IconButton(
                tooltip: t.vm_sheet_new_rule_tip,
                icon: const Icon(Icons.add_rounded),
                onPressed: () async {
                  await openVmRuleEditor(context);
                  await afterMutate();
                },
              ),
              IconButton(
                tooltip: t.vm_mgr_close_escape,
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: VmMasterSwitch(
            onChanged: () async => revision.value++,
          ),
        ),
        Divider(
          height: 0,
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
        ),
        Expanded(
          child: loading.value
              ? const Center(child: CircularProgressIndicator())
              : (resolved.value == null || resolved.value!.rules.isEmpty)
                  ? _EmptyState(onCreate: () async {
                      await openVmRuleEditor(context);
                      await afterMutate();
                    })
                  : Builder(builder: (context) {
                      // Materialize once per build: entries is a lazy
                      // Iterable.map — length + elementAt(i) per row is O(n²).
                      final snapshot = resolved.value!;
                      final entries =
                          snapshot.entries.toList(growable: false);
                      return ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                        itemCount: entries.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final entry = entries[i];
                          return _ManagerCard(
                            entry: entry,
                            onMutated: afterMutate,
                            libraryCount: snapshot.libraryCount,
                          );
                        },
                      );
                    }),
        ),
        Divider(
          height: 0,
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    await openVmRuleEditor(context);
                    await afterMutate();
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: Text(t.vm_mgr_new_rule),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate});
  final VoidCallback onCreate;
  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.video_collection_outlined,
                size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(t.vm_mgr_empty_title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(t.vm_mgr_empty_body,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    )),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded),
              label: Text(t.vm_mgr_new_rule),
            ),
          ],
        ),
      ),
    );
  }
}

class _ManagerCard extends StatelessWidget {
  const _ManagerCard({
    required this.entry,
    required this.onMutated,
    required this.libraryCount,
  });
  final MapEntry<VirtualMediaRule, List<VirtualMediaItem>> entry;
  final Future<void> Function() onMutated;

  /// Library snapshot size (see [_RuleTile] counterpart in the sheet).
  final int libraryCount;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final rule = entry.key;
    final items = entry.value;
    final scheme = Theme.of(context).colorScheme;

    void showPreview() {
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
                Text(t.vm_sheet_preview_all(libraryCount, items.length),
                    style: Theme.of(context).textTheme.bodySmall),
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
                                  '· ${it.displayName}  ${t.vm_sheet_item_meta(_fmt(it.totalDurationMs), it.segments.length)}',
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
                child: Text(t.vm_sheet_close)),
          ],
        ),
      );
    }

    final limits = [
      if (rule.useDurationCap)
        t.vm_mgr_limit_min(rule.maxDurationMinutes),
      if (rule.useCountCap) t.vm_mgr_limit_count(rule.maxItemCount),
      if (rule.useExcludeOverlong)
        t.vm_mgr_limit_exclude_min(rule.maxSingleDurationMinutes),
      if (rule.skipSingleSegment) t.vm_mgr_skip_single,
    ].join(' / ');

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.30),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outline.withValues(alpha: 0.45)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: showPreview,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            children: [
              Switch(
                value: rule.enabled,
                onChanged: (v) async {
                  await DbModule.virtualMediaRepo.setRuleEnabled(rule.id, v);
                  await onMutated();
                },
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(rule.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          decoration: rule.enabled ? null : TextDecoration.lineThrough,
                        )),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (rule.description.isNotEmpty) rule.description,
                        t.vm_sheet_count_videos(items.length),
                        if (limits.isNotEmpty)
                          t.vm_mgr_limits_prefix(limits),
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: rule.pinned ? t.vm_sheet_pinned : t.vm_sheet_pin,
                icon: Icon(
                  rule.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                  size: 18,
                  color: rule.pinned ? scheme.primary : null,
                ),
                onPressed: () async {
                  await DbModule.virtualMediaRepo.setRulePinned(rule.id, !rule.pinned);
                  await onMutated();
                },
              ),
              PopupMenuButton<String>(
                tooltip: rowTooltip(null),
                onSelected: (v) async {
                  switch (v) {
                    case 'edit':
                      await openVmRuleEditor(context, initial: rule);
                      await onMutated();
                      break;
                    case 'duplicate':
                      try {
                        await duplicateVmRule(rule);
                      } catch (_) {
                        if (!context.mounted) return;
                        await showDialog<void>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: Text(t.vm_sheet_copy_failed),
                            content: Text(t.vm_sheet_copy_failed_body),
                          ),
                        );
                        return;
                      }
                      await onMutated();
                      break;
                    case 'delete':
                      if (!context.mounted) break;
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: Text(t.vm_mgr_delete_title),
                          content: Text(t.vm_mgr_delete_body(rule.name)),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text(t.vm_mgr_delete_cancel),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: Text(t.vm_mgr_delete_confirm),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true) break;
                      try {
                        await DbModule.virtualMediaRepo
                            .deleteRuleCascade(rule.id);
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
                  PopupMenuItem(
                      value: 'duplicate', child: Text(t.vm_sheet_duplicate)),
                  PopupMenuItem(
                      value: 'delete', child: Text(t.vm_sheet_delete)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
