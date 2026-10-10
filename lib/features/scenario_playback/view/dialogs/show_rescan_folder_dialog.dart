import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/media_library/scan/probe/scan_probe_preference.dart';
import 'package:iris/features/media_library/scan/view/scan_options_dialog.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/get_localizations.dart';

/// What a "Rescan containing folder" row action does when the folder is not
/// covered by the queue's sources.
enum RescanFolderPolicy {
  /// Add the folder as a recursive source (subfolders included) — the default.
  addRecursive,

  /// Add the folder as a non-recursive source (this level only).
  addNonRecursive,

  /// Only scan; leave the queue's sources untouched.
  scanOnly,
}

/// The user's answer to [showRescanFolderDialog]: what to do with the folder,
/// plus the scan's deep-probe choice folded into the same dialog.
class RescanFolderChoice {
  const RescanFolderChoice({required this.policy, required this.probe});

  final RescanFolderPolicy policy;
  final bool probe;
}

/// One dialog for a rescan of a folder the queue does not source: pick whether
/// the folder joins the sources (recursive / this level) or the scan stays
/// list-neutral, AND whether to deep-probe. Returns null when cancelled.
Future<RescanFolderChoice?> showRescanFolderDialog(
  BuildContext context, {
  required StorageType storageType,
  required String folderName,
}) {
  return showDialog<RescanFolderChoice>(
    context: context,
    builder: (_) => RescanFolderDialog(
      storageType: storageType,
      folderName: folderName,
    ),
  );
}

class RescanFolderDialog extends HookWidget {
  const RescanFolderDialog({
    super.key,
    required this.storageType,
    required this.folderName,
  });

  final StorageType storageType;
  final String folderName;

  @override
  Widget build(BuildContext context) {
    // "加入递归" is the primary intent of the action, so it is preselected.
    final policy = useState(RescanFolderPolicy.addRecursive);
    // Probe defaults ON, matching ScanOptionsDialog; an earlier explicit choice
    // overrides the default once loaded.
    final probe = useState(true);
    final loaded = useState(false);

    useEffect(() {
      var cancelled = false;
      ScanProbePreference.load().then((v) {
        if (cancelled) return;
        if (v != null) probe.value = v;
        loaded.value = true;
      });
      return () => cancelled = true;
    }, const []);

    final theme = Theme.of(context);
    final bodySmall = theme.textTheme.bodySmall;
    final t = getLocalizations(context);

    return AlertDialog(
      title: Text(t.scn_rescan_folder_title),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.scn_rescan_folder_body(folderName), style: bodySmall),
            const SizedBox(height: 8),
            RadioGroup<RescanFolderPolicy>(
              groupValue: policy.value,
              onChanged: (v) {
                if (v != null) policy.value = v;
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<RescanFolderPolicy>(
                    contentPadding: EdgeInsets.zero,
                    value: RescanFolderPolicy.addRecursive,
                    title: Text(t.scn_rescan_folder_add_recursive),
                  ),
                  RadioListTile<RescanFolderPolicy>(
                    contentPadding: EdgeInsets.zero,
                    value: RescanFolderPolicy.addNonRecursive,
                    title: Text(t.scn_rescan_folder_add_non_recursive),
                  ),
                  RadioListTile<RescanFolderPolicy>(
                    contentPadding: EdgeInsets.zero,
                    value: RescanFolderPolicy.scanOnly,
                    title: Text(t.scn_rescan_folder_scan_only),
                  ),
                ],
              ),
            ),
            const Divider(),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: loaded.value ? probe.value : null,
              tristate: true,
              onChanged: (v) => probe.value = v == true,
              title: Text(t.scan_probe_label),
            ),
            const SizedBox(height: 8),
            Text(t.scan_purpose, style: bodySmall),
            const SizedBox(height: 8),
            Text(
              scanProbeEstimateText(
                t: t,
                isWindows: Platform.isWindows,
                isAndroid: Platform.isAndroid,
                storageType: storageType,
              ),
              style: bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(t.scan_cancel),
        ),
        ElevatedButton(
          onPressed: () async {
            await ScanProbePreference.save(probe.value);
            if (context.mounted) {
              Navigator.of(context).pop(
                RescanFolderChoice(policy: policy.value, probe: probe.value),
              );
            }
          },
          child: Text(t.scan_start),
        ),
      ],
    );
  }
}
