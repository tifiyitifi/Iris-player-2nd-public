import 'package:flutter/material.dart';
import 'package:iris/features/app_instance/model/new_window_request.dart';
import 'package:iris/features/app_instance/services/new_window_launcher.dart';
import 'package:iris/utils/get_localizations.dart';

/// Starts a second window for [request] and explains a failure with a dialog.
///
/// Returns true when the process was spawned. Never a silent no-op: a build that
/// cannot multi-instance (Store/MSIX), an oversized selection and a failed
/// spawn each get their own explanation.
Future<bool> launchNewWindow(
  BuildContext context,
  NewWindowRequest request,
) async {
  final NewWindowLaunchResult result = await NewWindowLauncher.launch(request);
  if (result == NewWindowLaunchResult.launched) return true;
  if (context.mounted) {
    if (result == NewWindowLaunchResult.payloadTooLong) {
      await showNewWindowTooManyFilesDialog(context);
    } else {
      await showNewWindowUnavailableDialog(context);
    }
  }
  return false;
}

Future<void> showNewWindowUnavailableDialog(BuildContext context) async {
  final t = getLocalizations(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.new_window_unavailable_title),
      content: Text(t.new_window_unavailable_body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(t.ok),
        ),
      ],
    ),
  );
}

Future<void> showNewWindowTooManyFilesDialog(BuildContext context) async {
  final t = getLocalizations(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.new_window_too_many_files_title),
      content: Text(t.new_window_too_many_files_body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(t.ok),
        ),
      ],
    ),
  );
}
