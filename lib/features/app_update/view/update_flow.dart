import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:iris/app_shutdown.dart';
import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/features/app_update/services/update_check_service.dart';
import 'package:iris/features/app_update/services/update_downloader.dart';
import 'package:iris/features/app_update/services/update_installer.dart';
import 'package:iris/features/app_update/view/gated_update_check.dart';
import 'package:iris/features/app_update/view/gated_update_download.dart';
import 'package:iris/features/app_update/view/show_update_release_dialog.dart';
import 'package:iris/features/app_update/view/show_update_result_dialog.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:permission_handler/permission_handler.dart';

/// Entry point for the About page's "Check update" row.
///
/// Deliberately manual: nothing polls GitHub on startup, so a slow or blocked
/// network can never delay or interrupt the app, and a failed check only ever
/// surfaces to someone who asked for one.
///
/// [check] is the same seam [GatedUpdateCheck] takes, forwarded so the whole
/// flow — window, answer, and the dialog that reports it — is exercisable
/// without a network. It is also what a retry has to go through, or the second
/// attempt would hit the real GitHub while the first one was a fake.
Future<void> runUpdateCheckFlow(
  BuildContext context, {
  UpdateChecker? check,
}) async {
  // Taken before the first await, and it is the ROOT navigator: the checking
  // window has to sit above whatever route hosts the About page, and a
  // BuildContext must not be used across an await.
  final navigator = Navigator.of(context, rootNavigator: true);

  final version = await currentAppVersion();
  if (!context.mounted) return;

  // The window and the check share one owner, so the spinner is always closed
  // before the answer is shown, and a dismissed check reports nothing at all.
  final result = await GatedUpdateCheck(
    currentVersion: version,
    check: check ?? checkForUpdate,
  ).run(navigator: navigator);
  if (result == null || !context.mounted) return;

  switch (result) {
    // Bound, not just promoted: the install callback outlives this case's
    // promotion, and it has to hand the same release to the download step.
    case final UpdateAvailable available:
      await showUpdateReleaseDialog(
        context,
        available,
        onInstall: (asset) => runUpdateInstallFlow(context, available, asset),
      );
    case UpToDate() || AheadOfPublic() || CheckFailed():
      await showUpdateResultDialog(
        context,
        result,
        onRetry: () => runUpdateCheckFlow(context, check: check),
      );
  }
}

/// Downloads [asset] and hands control to the platform installer.
///
/// The two steps are separated by an explicit confirmation because both are
/// destructive: the app is about to close, and on Windows the installer or the
/// updater script takes over the window. Playback position is saved by the
/// shutdown chain that runs right after (desktop) or by the lifecycle pause the
/// installer triggers (Android), so the confirmation says so rather than
/// promising it.
Future<void> runUpdateInstallFlow(
  BuildContext context,
  UpdateAvailable result,
  ReleaseAsset asset,
) async {
  final t = getLocalizations(context);

  final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.update_install_confirm_title),
          content: Text(t.update_install_confirm_body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.download_and_update),
            ),
          ],
        ),
      ) ??
      false;
  if (!confirmed || !context.mounted) return;

  final package = await _downloadWithProgress(context, result, asset);
  if (package == null || !context.mounted) return;

  if (result.platform == UpdatePlatform.android) {
    await _installAndroidPackage(context, package);
    return;
  }
  await _installWindowsPackage(context, result, package);
}

Future<File?> _downloadWithProgress(
  BuildContext context,
  UpdateAvailable result,
  ReleaseAsset asset,
) async {
  // Fetched before the transfer so a wrong digest is discovered up front rather
  // than after a long download. Absent index is not fatal: the byte-count check
  // still applies.
  final checksums = await fetchPublishedChecksums(tag: result.tag);
  if (!context.mounted) return null;

  // The window and the transfer share one owner, so a success, a failure and a
  // cancel all end up closing it and none of them can install anything.
  final download = GatedUpdateDownload(
    asset: asset,
    expectedSha256: checksums[asset.name],
    // This context is the whole of what the run has to hand its package to. It
    // can be gone by the time the transfer settles — the surface hosting this
    // flow is a route, and a dismissal landing inside the window's close
    // animation pops that route rather than the window — so the run is told to
    // drop and delete the package instead of being left to abandon it in the
    // download directory.
    stillWanted: () => context.mounted,
  );
  final package = await download.run(
    navigator: Navigator.of(context, rootNavigator: true),
  );
  // Everything that can withhold this package — a failure, a cancel, a caller
  // that went away — is reported as null by the run itself, after it deleted
  // what it had verified. What comes back is a package this flow can install.
  return package;
}

Future<void> _installAndroidPackage(BuildContext context, File apk) async {
  final t = getLocalizations(context);
  try {
    await installAndroidPackage(apk);
  } on UpdateInstallException catch (error) {
    if (!context.mounted) return;
    if (error.reason == InstallFailure.needsPermission) {
      // Android 8+ grants "install unknown apps" per app, so the fix is a
      // settings trip rather than a retry.
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.update_install_needs_permission_title),
          content: Text(t.update_install_needs_permission_body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t.cancel),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                unawaited(openAppSettings());
              },
              child: Text(t.update_open_settings),
            ),
          ],
        ),
      );
      return;
    }
    await _showInstallFailed(context);
  }
}

Future<void> _installWindowsPackage(
  BuildContext context,
  UpdateAvailable result,
  File package,
) async {
  if (result.portable) {
    final script = findPortableUpdater();
    if (script == null) {
      // A portable build shipped without its updater: the release page is the
      // only remaining route.
      if (context.mounted) {
        await showUpdateResultDialog(
          context,
          const CheckFailed(UpdateFailure.noAsset),
        );
      }
      return;
    }
    try {
      await launchPortableSelfUpdate(scriptPath: script, zip: package);
    } on UpdateInstallException {
      if (context.mounted) await _showInstallFailed(context);
      return;
    }
    // The script waits for this process to disappear before touching a single
    // file, so the shutdown must complete rather than be abandoned.
    await _shutdownForUpdate();
    return;
  }

  try {
    await launchWindowsInstaller(package);
  } on UpdateInstallException {
    if (context.mounted) await _showInstallFailed(context);
    return;
  }
  // The installer is up; step aside so it can take the window and the files.
  await _shutdownForUpdate();
}

Future<void> _showInstallFailed(BuildContext context) async {
  final t = getLocalizations(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(t.update_install_failed),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(t.cancel),
        ),
      ],
    ),
  );
}

/// Hands the machine over to the updater.
///
/// [AppShutdown] persists playback position through the callbacks the player
/// hooks registered, then releases the player and destroys the window — the
/// same ordered teardown a normal window close performs, so a switch to the
/// updater cannot leave a half-released mpv behind. The hard exit is a
/// backstop: the updater needs a writable, unlocked executable within a couple
/// of seconds and will not wait indefinitely for a graceful close.
Future<void> _shutdownForUpdate() async {
  await AppShutdown.run();
  exit(0);
}
