import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:iris/features/background_playback/services/background_scenario_pool.dart';
import 'package:iris/models/file.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';

/// Picks a replacement background file from the 副音 candidate pool (the
/// reserved 「副音备选」tag's view), with the same double-play guard the playback
/// launcher uses.
///
/// The pool is re-resolved on every call (`guardedBgPool` → the tag view): the
/// retired source rules and their session cache are gone, so opening the picker
/// reflects whatever the tag holds right now.
///
/// Returns the chosen [FileItem], or null on cancel/empty. When the pool is
/// empty the caller sees an explanatory dialog (project rule: Dialog, never
/// SnackBar).
Future<FileItem?> showBackgroundCandidatePicker(
  BuildContext context, {
  String? currentPath,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final t = getLocalizations(context);

  List<FileItem> candidates;
  try {
    candidates = await guardedBgPool();
  } catch (_) {
    candidates = const <FileItem>[];
  }
  if (!context.mounted) return null;
  if (candidates.isEmpty) {
    await showMessageDialog(
      navigator,
      title: t.bg_mapping_manager_pick_bg_title,
      message: t.bg_mapping_manager_pick_bg_empty,
      type: MessageDialogType.info,
    );
    return null;
  }

  return showDialog<FileItem>(
    context: context,
    builder: (ctx) => _CandidatePickerDialog(
      candidates: candidates,
      currentPath: currentPath,
    ),
  );
}

class _CandidatePickerDialog extends StatelessWidget {
  const _CandidatePickerDialog({
    required this.candidates,
    this.currentPath,
  });

  final List<FileItem> candidates;
  final String? currentPath;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final current = currentPath == null ? null : canonicalDbPath(currentPath!);

    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        key: const ValueKey('bg_candidate_picker'),
        constraints: BoxConstraints(
          maxWidth: math.min(460, size.width - 24),
          maxHeight: size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t.bg_mapping_manager_pick_bg_title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: t.bg_mapping_manager_close,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: candidates.length,
                itemBuilder: (context, i) {
                  final f = candidates[i];
                  final path = canonicalDbPath(f.path.join('/'));
                  final isCurrent = current != null && path == current;
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      Icons.audiotrack_rounded,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text(
                      f.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: isCurrent
                        ? Icon(Icons.check_rounded,
                            color: theme.colorScheme.primary)
                        : null,
                    onTap: () => Navigator.of(context).pop(f),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
