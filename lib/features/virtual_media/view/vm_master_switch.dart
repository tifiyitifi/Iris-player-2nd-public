import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/virtual_media/commands/vm_master_actions.dart';
import 'package:iris/features/virtual_media/store/vm_prefs.dart';
import 'package:iris/utils/get_localizations.dart';

/// Global virtual-merge master switch shown at the top of the manager page.
///
/// OFF only PAUSES merging: rules stay editable and the currently playing file
/// keeps playing (see [setVmMasterEnabled]).
class VmMasterSwitch extends HookWidget {
  const VmMasterSwitch({super.key, this.onChanged});

  /// Runs after a successful toggle (the manager uses it to refresh previews).
  final Future<void> Function()? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final enabled = useState(true);
    final loading = useState(true);
    final saving = useState(false);

    useEffect(() {
      var cancelled = false;
      VmPrefs.masterEnabled().then((v) {
        if (cancelled) return;
        enabled.value = v;
        loading.value = false;
      });
      return () => cancelled = true;
    }, const []);

    Future<void> toggle(bool next) async {
      if (saving.value) return;
      saving.value = true;
      try {
        await setVmMasterEnabled(enabled: next);
        enabled.value = next;
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
        saving.value = false;
      }
    }

    return SwitchListTile.adaptive(
      key: const ValueKey('vm_master_switch'),
      value: enabled.value,
      onChanged: loading.value || saving.value ? null : toggle,
      secondary: const Icon(Icons.auto_awesome_motion_rounded),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      dense: true,
      title: Text(t.vm_master_title),
      subtitle: Text(
        enabled.value ? t.vm_master_subtitle_on : t.vm_master_subtitle_off,
      ),
    );
  }
}
