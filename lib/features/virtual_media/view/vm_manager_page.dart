import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/virtual_media/commands/vm_actions.dart';
import 'package:iris/features/virtual_media/commands/vm_dir_toggle.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/rule/vm_dir_use.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/store/vm_prefs.dart';
import 'package:iris/features/virtual_media/view/vm_conflict_dialog.dart';
import 'package:iris/features/virtual_media/view/vm_master_off_dialog.dart';
import 'package:iris/features/virtual_media/view/vm_master_switch.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';
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
  return h > 0
      ? '${h}h${m.toString().padLeft(2, '0')}m'
      : '${m}m${s.toString().padLeft(2, '0')}s';
}

class VmManagerPage extends HookWidget {
  const VmManagerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final resolved = useState<ResolvedRules?>(null);
    final loading = useState(true);
    final revision = useState(0);
    // Null until the first read lands: the banner must not flash "paused" on
    // every open before the preference has actually been read.
    final masterPaused = useState<bool?>(null);

    // Freeze the file playing when the manager OPENED. Playback may advance to
    // the next episode while the popup stays open; the folder toggle must keep
    // acting on the original video's direct folder (product contract).
    final playQueue = usePlayQueueStore().select(context, (s) => s.playQueue);
    final currentIndex =
        usePlayQueueStore().select(context, (s) => s.currentIndex);
    final storages = useStorageStore().select(context, (s) => s.storages);
    final currentFile = useMemoized<FileItem?>(
      () => (currentIndex < 0 || currentIndex >= playQueue.length)
          ? null
          : playQueue[currentIndex].file,
      const [],
    );

    useEffect(() {
      var cancelled = false;
      loading.value = true;
      resolveEnabledRules().then((v) {
        if (!cancelled) {
          resolved.value = v;
          loading.value = false;
        }
      });
      VmPrefs.masterEnabled().then((v) {
        if (!cancelled) masterPaused.value = !v;
      });
      return () => cancelled = true;
    }, [revision.value]);

    /// [notify] is false when the command already refreshed the open surfaces
    /// itself (a folder action does), so one action never runs the fan-out
    /// twice. The local rules list still reloads either way.
    Future<void> afterMutate({bool notify = true}) async {
      if (notify) await VirtualMediaService.instance.notifyRulesChanged();
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
                  // The editor is the one notification choke point for editor
                  // saves; the manager only reloads its local rule list.
                  await openVmRuleEditor(context);
                  await afterMutate(notify: false);
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
            // The manager is the ONE reader of the preference: the same value
            // drives this switch and the panel's paused banner, so a folder
            // action that resumes merging updates both at once.
            enabled: masterPaused.value == null ? null : !masterPaused.value!,
            onChanged: () async => revision.value++,
          ),
        ),
        _DirTogglePanel(
          file: currentFile,
          rules: resolved.value?.rules ?? const [],
          storages: storages,
          masterPaused: masterPaused.value ?? false,
          onMutated: afterMutate,
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
                      await afterMutate(notify: false);
                    })
                  : Builder(builder: (context) {
                      // Materialize once per build: entries is a lazy
                      // Iterable.map — length + elementAt(i) per row is O(n²).
                      final snapshot = resolved.value!;
                      final entries = snapshot.entries.toList(growable: false);
                      return ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                        itemCount: entries.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
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
                    await afterMutate(notify: false);
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

/// "Use / not use this video's direct folder" panel.
///
/// Non-recursive by construction: the toggle writes a `specifiedDir` rule for
/// the DIRECT parent only, so a recursive rule above it keeps covering the
/// parent and the children while this one folder is carved out.
class _DirTogglePanel extends StatelessWidget {
  const _DirTogglePanel({
    required this.file,
    required this.rules,
    required this.storages,
    required this.masterPaused,
    required this.onMutated,
  });

  final FileItem? file;
  final List<VirtualMediaRule> rules;
  final List<Storage> storages;

  /// The global switch is a deliberate pause: the toggle must say so instead of
  /// looking broken, and "use" must ask before resuming the whole feature.
  final bool masterPaused;

  /// Reloads the manager after a change. `notify: false` skips the queue/tag
  /// fan-out when the command already did it.
  final Future<void> Function({bool notify}) onMutated;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final scheme = Theme.of(context).colorScheme;

    Widget body;
    if (file == null) {
      body = Text(t.vm_dir_no_current,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant));
    } else if (file!.path.isEmpty) {
      // SAF single document pick: an empty path has no parent directory.
      body = Text(t.vm_dir_no_folder,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant));
    } else {
      final f = file!;
      final parentRaw = f.path.length <= 1
          ? ''
          : f.path.sublist(0, f.path.length - 1).join('/');
      final basePaths = [for (final s in storages) s.basePath.join('/')];
      final folderPath = relativeToStoragePath(parentRaw, basePaths);
      final seg = VirtualSegment(
        mediaKey: canonicalMediaKey(f.storageId, f.path, uri: f.uri),
        storageId: f.storageId,
        path: f.path,
        name: f.name,
        parentPath: folderPath,
        uri: f.uri,
      );
      final merged = vmFileUseState(rules, seg) == VmFileUseState.merged;
      Storage? storage;
      for (final s in storages) {
        if (s.id == f.storageId) {
          storage = s;
          break;
        }
      }
      Future<VmDirToggleResult> run(VmMasterOffChoice? choice) =>
          toggleVmDirUseMode(
            storageId: f.storageId,
            storageName: storage?.name ?? '',
            name: f.name,
            path: f.path,
            storageBasePaths: basePaths,
            uri: f.uri,
            masterOffChoice: choice,
          );
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.vm_dir_current(f.name),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: () async {
                var res = await run(null);
                if (res.needsMasterChoice) {
                  // A paused master switch may not be resumed silently: the
                  // command wrote nothing, so a dismissed prompt is a cancel.
                  if (!context.mounted) return;
                  final choice = await showVmMasterOffDialog(
                    context,
                    otherEnabledCount: res.otherEnabledCount,
                  );
                  if (choice == null) return;
                  res = await run(choice);
                }
                // The command already refreshed the open surfaces on success;
                // a failed/partial action did not, so let the manager do it.
                await onMutated(notify: !res.notified);
                if (!context.mounted) return;
                // Speak up only when the click did NOT do what the label
                // promised: a rolled-back choice, a switch that refused the
                // write, a paused switch (exclusion saved for later), or a
                // group that could not attach to the already-playing feed.
                final message = res.failed
                    ? t.vm_dir_action_failed
                    : res.masterSaveFailed
                        ? t.vm_dir_master_save_failed
                        : res.masterPaused
                            ? t.vm_dir_result_paused
                            : (res.nowUsing && !res.adopted
                                ? t.vm_dir_result_next_feed
                                : null);
                if (message == null) return;
                await showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: Text(t.vm_dir_current(f.name)),
                    content: Text(message),
                  ),
                );
              },
              icon: Icon(merged
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined),
              label: Text(merged ? t.vm_dir_not_use : t.vm_dir_use),
            ),
          ),
          if (masterPaused)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.pause_circle_outline_rounded,
                      size: 14, color: scheme.error),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      t.vm_dir_paused_banner,
                      style: TextStyle(fontSize: 12, color: scheme.error),
                    ),
                  ),
                ],
              ),
            ),
          // The tile paints its ink on the nearest Material; without one it
          // would sit behind this panel's colored DecoratedBox and assert.
          Material(
            type: MaterialType.transparency,
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: Text(t.vm_dir_help_title,
                  style: TextStyle(fontSize: 13, color: scheme.primary)),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(t.vm_dir_help_body,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.30),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outline.withValues(alpha: 0.35)),
        ),
        child: body,
      ),
    );
  }
}

/// Single fence for turning a rule ON: a non-recursive `specifiedDir` rule may
/// not coexist (enabled) with another on the same path, so EVERY enable entry
/// point — this card switch and the editor save — asks which one to keep.
Future<void> _setRuleEnabledGuarded(
  BuildContext context,
  VirtualMediaRule rule,
  bool enabled,
  Future<void> Function() onMutated,
) async {
  if (enabled) {
    final all = await DbModule.virtualMediaRepo.loadRules();
    final caseInsensitive = useStorageStore()
        .state
        .storages
        .any((s) => s.basePath.any(pathRidesCaseInsensitiveFs));
    final conflicts = vmDirRuleConflicts(rule.copyWith(enabled: true), all,
        caseInsensitive: caseInsensitive);
    if (conflicts.isNotEmpty) {
      if (!context.mounted) return;
      final choice = await showVmDirConflictDialog(context, conflicts);
      if (choice == null || choice == VmConflictChoice.keepExisting) return;
      for (final c in conflicts) {
        await DbModule.virtualMediaRepo.setRuleEnabled(c.id, false);
      }
    }
  }
  await DbModule.virtualMediaRepo.setRuleEnabled(rule.id, enabled);
  await onMutated();
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
            Text(t.vm_mgr_empty_title,
                style: Theme.of(context).textTheme.titleMedium),
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
  final Future<void> Function({bool notify}) onMutated;

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
      if (rule.useDurationCap) t.vm_mgr_limit_min(rule.maxDurationMinutes),
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
                onChanged: (v) =>
                    _setRuleEnabledGuarded(context, rule, v, onMutated),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(rule.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              decoration: rule.enabled
                                  ? null
                                  : TextDecoration.lineThrough,
                            )),
                      ),
                      if (rule.useMode == VmRuleUseMode.notUse) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.errorContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(t.vm_mgr_excluded_badge,
                              style: TextStyle(
                                  fontSize: 10,
                                  color: scheme.onErrorContainer)),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (rule.description.isNotEmpty) rule.description,
                        rule.useMode == VmRuleUseMode.notUse
                            ? t.vm_mgr_excluded_subtitle
                            : t.vm_sheet_count_videos(items.length),
                        if (limits.isNotEmpty) t.vm_mgr_limits_prefix(limits),
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: rule.pinned ? t.vm_sheet_pinned : t.vm_sheet_pin,
                icon: Icon(
                  rule.pinned
                      ? Icons.push_pin_rounded
                      : Icons.push_pin_outlined,
                  size: 18,
                  color: rule.pinned ? scheme.primary : null,
                ),
                onPressed: () async {
                  await DbModule.virtualMediaRepo
                      .setRulePinned(rule.id, !rule.pinned);
                  await onMutated();
                },
              ),
              PopupMenuButton<String>(
                tooltip: rowTooltip(null),
                onSelected: (v) async {
                  switch (v) {
                    case 'edit':
                      // The editor already notified on save; reload only.
                      await openVmRuleEditor(context, initial: rule);
                      await onMutated(notify: false);
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
