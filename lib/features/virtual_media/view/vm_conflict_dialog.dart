import 'package:flutter/material.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/utils/get_localizations.dart';

/// Which same-path rule keeps `enabled` after a manual add/switch conflict.
enum VmConflictChoice { keepNew, keepExisting }

/// Asks which of two non-recursive `specifiedDir` rules on the SAME path stays
/// enabled. [conflicts] are the already-enabled competitors.
Future<VmConflictChoice?> showVmDirConflictDialog(
  BuildContext context,
  List<VirtualMediaRule> conflicts,
) {
  final t = getLocalizations(context);
  final names = conflicts.map((r) => r.name).join(', ');
  return showDialog<VmConflictChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.vm_conflict_title),
      content: Text(t.vm_conflict_body(names)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(t.vm_conflict_cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, VmConflictChoice.keepExisting),
          child: Text(t.vm_conflict_keep_existing),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, VmConflictChoice.keepNew),
          child: Text(t.vm_conflict_keep_new),
        ),
      ],
    ),
  );
}
