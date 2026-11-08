import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/media_library/scan/probe/scan_probe_preference.dart';
import 'package:iris/features/media_library/scan/view/scan_info_dialog.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/get_localizations.dart';

/// Which pre-scan prompt a recursive scan shows.
///
/// `false` (current): the explainer dialog — scope, measured cost, caveats and
/// the silent-completion option.
///
/// `true`: the legacy "read media info?" checkbox. KEPT ON PURPOSE, not dead
/// code: it is the only way to start a scan that skips the media-info pass, and
/// the whole path (preference persistence included) still works. Flipping this
/// constant is the entire change needed to bring it back.
const bool kShowScanProbeOption = false;

/// Shown before a recursive scan starts.
///
/// Returns:
/// - `null`  → user cancelled, do not start the scan;
/// - `true`  → start with the deep media-info probe enabled;
/// - `false` → start plain scan (only reachable from the legacy dialog while
///   [kShowScanProbeOption] is true: the explainer always probes).
Future<bool?> showScanOptionsDialog(
  BuildContext context, {
  required Storage storage,
  String? rootPath,
  ScanInfoScope? scope,
}) {
  if (kShowScanProbeOption) {
    return showDialog<bool>(
      context: context,
      builder: (_) => ScanOptionsDialog(storageType: storage.type),
    );
  }
  return showDialog<bool>(
    context: context,
    builder: (_) => ScanInfoDialog(
      storage: storage,
      rootPath: rootPath,
      scope: scope,
    ),
  );
}

/// Immediately-visible time estimate for the probe checkbox (general-case
/// magnitudes, no pre-count wait): platform × storage aware so each surface
/// states its own cost model up front.
String scanProbeEstimateText({
  required AppLocalizations t,
  required bool isWindows,
  required bool isAndroid,
  required StorageType storageType,
}) {
  if (storageType == StorageType.ftp ||
      storageType == StorageType.webdav ||
      storageType == StorageType.network) {
    return t.scan_estimate_remote;
  }
  if (isWindows) {
    return t.scan_estimate_win;
  }
  if (isAndroid) {
    return t.scan_estimate_android;
  }
  return t.scan_estimate_none;
}

/// The legacy pre-scan prompt (probe checkbox).
///
/// Only reachable when [kShowScanProbeOption] is flipped to `true`; the widget
/// itself stays fully functional so that flip is a one-line change. Restored
/// verbatim from the pre-explainer version: the checkbox is always visible,
/// the choice is always persisted, and the dialog returns it.
class ScanOptionsDialog extends HookWidget {
  const ScanOptionsDialog({super.key, required this.storageType});

  final StorageType storageType;

  @override
  Widget build(BuildContext context) {
    // Probe defaults ON (第一次未保存过时勾选 — "默认勾选扫描时间"); an
    // explicit earlier choice overrides the default.
    final probe = useState(true);
    final loaded = useState(false);

    useEffect(() {
      var cancelled = false;
      ScanProbePreference.load().then((v) {
        if (!cancelled) {
          if (v != null) probe.value = v;
        }
        if (!cancelled) loaded.value = true;
      });
      return () => cancelled = true;
    }, const []);

    final theme = Theme.of(context);
    final t = getLocalizations(context);
    final bodySmall = theme.textTheme.bodySmall;

    final strategyText = Platform.isWindows
        ? t.scan_strategy_win
        : Platform.isAndroid
            ? t.scan_strategy_android
            : t.scan_strategy_none;

    return AlertDialog(
      title: Text(t.scan_title),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
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
            Text(strategyText, style: bodySmall),
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
            const SizedBox(height: 8),
            Text(t.scan_caveat, style: bodySmall),
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
            if (context.mounted) Navigator.of(context).pop(probe.value);
          },
          child: Text(t.scan_start),
        ),
      ],
    );
  }
}
