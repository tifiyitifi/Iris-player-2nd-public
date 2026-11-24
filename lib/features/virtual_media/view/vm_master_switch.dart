import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/virtual_media/commands/vm_master_actions.dart';
import 'package:iris/utils/get_localizations.dart';

/// Global virtual-merge master switch shown at the top of the manager page.
///
/// CONTROLLED on purpose: the manager owns the single preference read, so the
/// switch and the "merging is paused" banner can never disagree. A second,
/// mount-time read here is exactly what left the switch showing OFF after a
/// folder action had already resumed merging.
///
/// OFF only PAUSES merging: rules stay editable and the currently playing file
/// keeps playing (see [setVmMasterEnabled]).
class VmMasterSwitch extends HookWidget {
  const VmMasterSwitch({super.key, this.enabled, this.onChanged});

  /// Current switch state; null until the owner's first read lands. A missing
  /// preference row means ON, so the placeholder shows ON (disabled) instead of
  /// flashing "paused" for a frame.
  final bool? enabled;

  /// Runs after a successful toggle, so the owner can re-read the preference.
  final Future<void> Function()? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final saving = useState(false);
    final loading = enabled == null;

    Future<void> toggle(bool next) async {
      if (saving.value) return;
      saving.value = true;
      try {
        final applied = await setVmMasterEnabled(enabled: next);
        if (!applied) {
          // The preference write failed: the runtime state is unchanged, so do
          // not report the toggle as successful.
          if (!context.mounted) return;
          await showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: Text(t.vm_master_title),
              content: Text(t.vm_mgr_action_failed_body),
            ),
          );
          return;
        }
        await onChanged?.call();
      } catch (_) {
        if (!context.mounted) return;
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(t.vm_master_title),
            content: Text(t.vm_mgr_action_failed_body),
          ),
        );
      } finally {
        if (context.mounted) saving.value = false;
      }
    }

    return SwitchListTile.adaptive(
      key: const ValueKey('vm_master_switch'),
      value: enabled ?? true,
      onChanged: loading || saving.value ? null : toggle,
      secondary: const Icon(Icons.auto_awesome_motion_rounded),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      dense: true,
      title: Text(t.vm_master_title),
      subtitle: Text(
        (enabled ?? true) ? t.vm_master_subtitle_on : t.vm_master_subtitle_off,
      ),
    );
  }
}
