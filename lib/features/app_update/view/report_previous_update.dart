import 'package:flutter/material.dart';
import 'package:iris/features/app_update/services/update_check_service.dart';
import 'package:iris/features/app_update/services/update_downloader.dart';
import 'package:iris/features/app_update/services/update_handoff.dart';
import 'package:iris/utils/app_paths.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';
import 'package:path/path.dart' as p;

final _log = AreaKeyLog(LogKeys.appUpdate);

/// Reports what became of the last portable hand-off, if there was one.
///
/// A portable update is the only app action that cannot report itself: IRIS
/// closes, a script it does not control either replaces the program files or
/// does not, and the user is left to work out which happened. The record read
/// here is what closes that gap — "updated to v2.1.0", or "the last update did
/// not finish, here is the package to run by hand".
///
/// One-shot: the record is consumed whether or not the update landed, so a
/// stale note can never greet the user a second time. Silent on every other
/// platform, and silent when there is nothing to report.
///
/// [navigator] must be the ROOT navigator, captured before the first await.
Future<void> reportPreviousPortableUpdate(NavigatorState navigator) async {
  if (!isWindows || !AppPaths.isPortable) return;

  final PreviousUpdateReport? report;
  try {
    report = await takePreviousUpdateReport(
      workDir: await updatePackageDirectory(),
      runningVersion: await currentAppVersion(),
    );
  } catch (error) {
    // A note to self must never be able to break the launch it describes.
    _log.w('could not report the previous portable update: $error');
    return;
  }
  if (report == null || !navigator.mounted) return;

  final t = getLocalizations(navigator.context);
  if (report.applied) {
    await showMessageDialog(
      navigator,
      type: MessageDialogType.success,
      title: t.update_report_applied_title,
      message: t.update_report_applied_body(report.toVersion),
    );
    return;
  }
  await showMessageDialog(
    navigator,
    type: MessageDialogType.info,
    title: t.update_report_incomplete_title,
    message: t.update_report_incomplete_body(
      report.toVersion,
      p.dirname(report.packagePath),
    ),
  );
}
