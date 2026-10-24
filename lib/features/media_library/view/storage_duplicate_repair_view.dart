import 'package:flutter/material.dart';
import 'package:iris/features/media_library/services/storage_duplicate_repair.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/app_instance.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Startup repair for duplicate storage entries.
///
/// Runs AFTER the startup sequence (DB + stores ready) and BEFORE the app is
/// shown. Never silent: merging removes an entry the user created, so it is an
/// always-on confirmation. Declining is per-launch — a duplicate is a data
/// hazard (path-keyed writes can miss the other entry's rows), so it asks again
/// next time instead of remembering "no".
Future<void> runStorageDuplicateRepairFlow(BuildContext context) async {
  if (!isDesktop) return;
  // The DB is shared across instances; let the primary window own the repair.
  if (!AppInstance.isPrimary) return;

  final groups = await detectDuplicateStorageGroups();
  if (groups.isEmpty) return;

  final nodeCounts = <String, int>{};
  final dao = DbModule.mediaNodesDao;
  for (final group in groups) {
    var total = 0;
    for (final storage in <LocalStorage>[group.survivor, ...group.losers]) {
      final scope = storage.dataScopeId ?? storage.id;
      try {
        total += (await dao.rowsInScope(scope)).length;
      } catch (_) {}
    }
    nodeCounts[group.survivor.id] = total;
  }

  if (!context.mounted) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  final confirmed = await _showMergeDialog(context, groups, nodeCounts);
  if (!confirmed || !navigator.mounted) return;

  var stats = const StorageMergeStats();
  try {
    for (final group in groups) {
      stats += await mergeDuplicateStorageGroup(group);
    }
  } catch (e, s) {
    _log.e('storage duplicate merge failed: $e', e, s);
    if (!navigator.mounted) return;
    final t = getLocalizations(navigator.context);
    await showMessageDialog(
      navigator,
      type: MessageDialogType.error,
      title: t.storage_duplicate_failed_title,
      message: t.storage_duplicate_failed_body('$e'),
    );
    return;
  }

  if (!navigator.mounted) return;
  final t = getLocalizations(navigator.context);
  await showMessageDialog(
    navigator,
    type: MessageDialogType.success,
    title: t.storage_duplicate_done_title,
    message: t.storage_duplicate_done_body(
      stats.mergedNodes,
      stats.movedNodes,
      stats.ghostRowsMarked,
    ),
  );
  _log.i('storage duplicate repair finished [${stats.summary}]');
}

Future<bool> _showMergeDialog(
  BuildContext context,
  List<StorageDuplicateGroup> groups,
  Map<String, int> nodeCounts,
) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) {
      final t = getLocalizations(dialogCtx);
      final colorScheme = Theme.of(dialogCtx).colorScheme;
      return AlertDialog(
        icon: Icon(Icons.merge_type_rounded, color: colorScheme.primary),
        title: Text(t.storage_duplicate_title),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.storage_duplicate_intro),
                const SizedBox(height: 12),
                for (final group in groups)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      t.storage_duplicate_group(
                        group.survivor.name,
                        group.survivor.basePath.join('/'),
                        group.losers.length + 1,
                        nodeCounts[group.survivor.id] ?? 0,
                      ),
                      style: Theme.of(dialogCtx).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(t.storage_duplicate_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(t.storage_duplicate_merge),
          ),
        ],
      );
    },
  );
  return result == true;
}
