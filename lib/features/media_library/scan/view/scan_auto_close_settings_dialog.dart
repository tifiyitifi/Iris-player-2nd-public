import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/get_localizations.dart';

Future<void> openScanAutoCloseSettings(BuildContext context) {
  return showDialog(
    context: context,
    builder: (_) => const ScanAutoCloseSettingsDialog(),
  );
}

class ScanAutoCloseSettingsDialog extends HookWidget {
  const ScanAutoCloseSettingsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final scanStore = useRecursiveScanStore();
    final delay = useState(scanStore.state.autoCloseDelay);
    // Same switch as the pre-scan prompt: this is where a "don't show this
    // again" choice is undone.
    final prompt = useState(scanStore.state.autoClosePrompt);
    final AppLocalizations t = getLocalizations(context);

    final navigator = Navigator.of(context);
    // One decimal everywhere: the slider steps by 0.5 s, so trimming zeros
    // would make "2" and "2.5" look like different controls.
    final seconds = delay.value.toStringAsFixed(1);

    return AlertDialog(
      title: Text(t.set_scan_auto_close),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: prompt.value,
              onChanged: (v) => prompt.value = v,
              title: Text(t.scan_info_silent_label),
              subtitle: Text(t.set_scan_completion_prompt_desc),
            ),
            const SizedBox(height: 8),
            Text(
              t.set_scan_auto_close_desc,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Text(
              delay.value <= 0
                  ? t.scan_auto_close_immediate
                  : t.scan_auto_close_seconds(seconds),
            ),
            Slider(
              value: delay.value,
              min: 0,
              max: 15,
              divisions: 30,
              label: delay.value <= 0
                  ? t.scan_auto_close_slider_immediate
                  : t.scan_auto_close_slider_seconds(seconds),
              onChanged: (v) => delay.value = v,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: navigator.pop,
          child: Text(t.cancel),
        ),
        ElevatedButton(
          onPressed: () async {
            await scanStore.updateAutoCloseDelay(delay.value);
            await scanStore.updateAutoClosePrompt(prompt.value);
            navigator.pop();
          },
          child: Text(t.ok),
        ),
      ],
    );
  }
}
