import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/virtual_media/commands/vm_dir_toggle.dart';
import 'package:iris/utils/get_localizations.dart';

/// Asks how to proceed when a folder action needs the paused master switch ON.
///
/// The three options come FIRST (the decision), followed by a DEFAULT-COLLAPSED
/// "选项说明" disclosure that explains what each option does — including why a
/// paused switch made an earlier click look like a no-op. Dismissing the dialog
/// (barrier / back) is a cancel: the command writes nothing in that case.
///
/// All three tiles are ALWAYS rendered so the dialog never changes shape between
/// "there are other rules" and "there are none": with nothing else to close, the
/// folder-only choice is greyed out and says why instead of vanishing.
Future<VmMasterOffChoice?> showVmMasterOffDialog(
  BuildContext context, {
  required int otherEnabledCount,
}) {
  return showDialog<VmMasterOffChoice>(
    context: context,
    builder: (_) => _VmMasterOffDialog(otherEnabledCount: otherEnabledCount),
  );
}

class _VmMasterOffDialog extends HookWidget {
  const _VmMasterOffDialog({required this.otherEnabledCount});

  /// Enabled rules other than the acted-on folder's own rule. Zero only greys
  /// out the "keep only this folder" tile (it would be identical to a resume).
  final int otherEnabledCount;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final scheme = Theme.of(context).colorScheme;
    // Deliberately NOT an ExpansionTile: that restores its expansion state
    // from PageStorage, so a reopened dialog could start expanded. A fresh
    // local state per open guarantees the collapsed default every time.
    final expanded = useState(false);
    final onlyCurrent = otherEnabledCount > 0;

    Widget option({
      required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback onTap,
      bool enabled = true,
      ValueKey<String>? key,
    }) {
      return ListTile(
        key: key,
        enabled: enabled,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, size: 20),
        title: Text(title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        onTap: enabled ? onTap : null,
      );
    }

    return AlertDialog(
      title: Text(t.vm_master_off_title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              onlyCurrent
                  ? t.vm_master_off_intro_others(otherEnabledCount)
                  : t.vm_master_off_intro_none,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            // Always rendered: a fixed three-choice layout is predictable, and
            // with no other enabled rule this tile explains itself instead of
            // silently disappearing.
            option(
              key: const ValueKey('vm_master_off_keep_only'),
              icon: Icons.filter_alt_off_rounded,
              enabled: onlyCurrent,
              title: t.vm_master_off_keep_only,
              subtitle: onlyCurrent
                  ? t.vm_master_off_keep_only_hint(otherEnabledCount)
                  : t.vm_master_off_keep_only_hint_none,
              onTap: () =>
                  Navigator.of(context).pop(VmMasterOffChoice.keepOnlyCurrent),
            ),
            option(
              key: const ValueKey('vm_master_off_enable_all'),
              icon: Icons.power_settings_new_rounded,
              title: t.vm_master_off_enable_all,
              subtitle: t.vm_master_off_enable_all_hint,
              onTap: () =>
                  Navigator.of(context).pop(VmMasterOffChoice.enableAll),
            ),
            option(
              key: const ValueKey('vm_master_off_cancel'),
              icon: Icons.close_rounded,
              title: t.vm_master_off_cancel,
              subtitle: t.vm_master_off_cancel_hint,
              onTap: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 4),
            InkWell(
              key: const ValueKey('vm_master_off_details'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => expanded.value = !expanded.value,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      expanded.value
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      t.vm_master_off_details_title,
                      style: TextStyle(fontSize: 13, color: scheme.primary),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              alignment: Alignment.topLeft,
              child: expanded.value
                  ? Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 4),
                      child: Text(
                        onlyCurrent
                            ? t.vm_master_off_details_body(otherEnabledCount)
                            : t.vm_master_off_details_body_none,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.45,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}
