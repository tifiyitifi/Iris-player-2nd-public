import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:iris/app_shutdown.dart';
import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/features/app_update/services/update_check_service.dart';
import 'package:iris/features/app_update/services/update_downloader.dart';
import 'package:iris/features/app_update/services/update_handoff.dart';
import 'package:iris/features/app_update/services/update_installer.dart';
import 'package:iris/features/app_update/services/windows_update_plan.dart';
import 'package:iris/features/app_update/view/gated_update_check.dart';
import 'package:iris/features/app_update/view/gated_update_download.dart';
import 'package:iris/features/app_update/view/show_update_release_dialog.dart';
import 'package:iris/features/app_update/view/show_update_result_dialog.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/url.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

final _log = AreaKeyLog(LogKeys.appUpdate);

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

/// The platform side of the Windows hand-off, bundled behind one seam.
///
/// Every member is something the flow cannot do inside a test: plan a hand-off
/// against whatever machine the test host happens to be, spawn a process, or end
/// the test run with `exit(0)`. Injected as a whole rather than as five
/// parameters, and the defaults are the real thing.
class WindowsUpdateEnvironment {
  const WindowsUpdateEnvironment({
    this.plan = planWindowsUpdate,
    this.launchPortable = launchPortableSelfUpdate,
    this.launchInstaller = launchWindowsInstaller,
    this.recordPending = recordPendingUpdate,
    this.clearPending = clearPendingUpdate,
    this.shutdown = shutdownForUpdate,
  });

  /// Decides how the package is applied, or refuses before the app closes.
  final WindowsUpdatePlanner plan;

  /// Starts the portable self-overwrite and returns immediately.
  final PortableUpdateLauncher launchPortable;

  /// Starts the Inno Setup installer and returns immediately.
  final WindowsInstallerLauncher launchInstaller;

  /// Writes the record the next launch reads back.
  final PendingUpdateRecorder recordPending;

  /// Drops that record again when the hand-off never started.
  final PendingUpdateClearer clearPending;

  /// Persists playback, tears the window down and exits the process.
  final Future<void> Function() shutdown;
}

/// [planWindowsUpdate] behind a seam.
typedef WindowsUpdatePlanner = Future<WindowsUpdatePlan> Function({
  required bool portable,
  required File package,
  required String exeDir,
});

/// [launchPortableSelfUpdate] behind a seam.
typedef PortableUpdateLauncher = Future<void> Function({
  required String scriptPath,
  required File zip,
  required String? logPath,
});

/// [launchWindowsInstaller] behind a seam.
typedef WindowsInstallerLauncher = Future<void> Function(File installer);

/// [recordPendingUpdate] behind a seam.
typedef PendingUpdateRecorder = Future<void> Function({
  required String workDir,
  required String fromVersion,
  required String toVersion,
  required String packagePath,
});

/// [clearPendingUpdate] behind a seam.
typedef PendingUpdateClearer = Future<void> Function({
  required String workDir,
});

/// Downloads [asset] and hands control to the platform installer.
///
/// The two steps are separated by an explicit confirmation because both are
/// destructive: the app is about to close, and on Windows the installer or the
/// updater takes over the window. Playback position is saved by the shutdown
/// chain that runs right after (desktop) or by the lifecycle pause the
/// installer triggers (Android), so the confirmation says so rather than
/// promising it.
Future<void> runUpdateInstallFlow(
  BuildContext context,
  UpdateAvailable result,
  ReleaseAsset asset, {
  WindowsUpdateEnvironment windows = const WindowsUpdateEnvironment(),
}) async {
  final t = getLocalizations(context);

  final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.update_install_confirm_title),
          // The portable edition promises a relaunch, the installer does not:
          // one overwrites its own folder and starts the app again, the other
          // asks the user to drive a wizard.
          content: Text(
            result.portable
                ? t.update_install_confirm_body_portable
                : t.update_install_confirm_body,
          ),
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

  await handOffUpdatePackage(
    context,
    result,
    package.package,
    expectedSize: package.expectedSize,
    expectedSha256: package.expectedSha256,
    windows: windows,
  );
}

/// Hands a verified package to whatever applies it.
///
/// Split from [runUpdateInstallFlow] at the point the transfer ends, so the
/// ordered contract that follows — pre-flight, the hand-off record, the
/// shutdown — is exercisable without a network and without a running installer.
///
/// [expectedSize] / [expectedSha256] are what the download was verified against
/// (`_downloadWithProgress` passes them); the package is re-checked against them
/// here because an installer/updater runs later and a swapped file must be
/// refused, not applied. Defaults are the unverifiable case (a caller that has
/// no release metadata), which keeps the hand-off itself usable without them.
Future<void> handOffUpdatePackage(
  BuildContext context,
  UpdateAvailable result,
  File package, {
  int expectedSize = 0,
  String? expectedSha256,
  WindowsUpdateEnvironment windows = const WindowsUpdateEnvironment(),
}) async {
  final mismatch = await verifyDownloadedPackage(
    package: package,
    expectedSize: expectedSize,
    expectedSha256: expectedSha256,
  );
  if (mismatch != null) {
    _log.w('refusing hand-off: ${package.path} no longer matches '
        '(${mismatch.name})');
    await discardDownload(package);
    if (context.mounted) await _showHandoffIntegrityDialog(context);
    return;
  }
  // The re-verification awaited file I/O; the hosting route may be gone.
  if (!context.mounted) return;

  if (result.platform == UpdatePlatform.android) {
    await _installAndroidPackage(context, package);
    return;
  }
  await _installWindowsPackage(context, result, package, windows);
}

Future<({File package, int expectedSize, String? expectedSha256})?>
    _downloadWithProgress(
  BuildContext context,
  UpdateAvailable result,
  ReleaseAsset asset,
) async {
  // Fetched before the transfer so a wrong digest is discovered up front rather
  // than after a long download.
  final checksums = await fetchPublishedChecksums(tag: result.tag);
  if (!context.mounted) return null;

  final expectedSha256 = checksums.checksumFor(asset.name);
  final verdict = classifyPublishedChecksum(
    checksums,
    asset.name,
    advertisedSize: asset.size,
  );
  if (!checksumVerdictAllowsDownload(verdict)) {
    // Either the release published an index that omits this asset, or there is
    // no index and no advertised size either: nothing is left to verify the
    // transfer against, so nothing is downloaded (and therefore nothing can
    // ever be handed to an installer).
    await _showChecksumRefusalDialog(context, verdict, asset.name);
    return null;
  }
  if (verdict == ChecksumVerdict.noIndex) {
    // No usable index, but the release did advertise a size: the transfer goes
    // ahead on the byte count alone, which the reader is told about rather than
    // left to assume.
    _log.w('no checksum index for ${result.tag}: verifying by size only');
  }
  // Re-checked because the refusal path above awaited a dialog: the caller's
  // surface can be gone by the time this function resumes.
  if (!context.mounted) return null;

  // The window and the transfer share one owner, so a success, a failure and a
  // cancel all end up closing it and none of them can install anything.
  final download = GatedUpdateDownload(
    asset: asset,
    expectedSha256: expectedSha256,
    notice: expectedSha256 == null
        ? getLocalizations(context).update_checksum_unavailable
        : null,
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
  if (package == null) return null;
  // The same anchors the transfer was verified against, carried to the hand-off
  // so the package can be re-checked for a swap before anything runs it.
  return (
    package: package,
    expectedSize: advertisedDownloadSize(
      assetSize: asset.size,
      contentLength: -1,
    ),
    expectedSha256: expectedSha256,
  );
}

/// Refuses a package the refusal policy rejected.
///
/// Two verdicts land here and they do not want the same words: an asset the
/// release's own index does not account for reads differently from a release
/// that offers no verification anchor at all.
Future<void> _showChecksumRefusalDialog(
  BuildContext context,
  ChecksumVerdict verdict,
  String assetName,
) async {
  final t = getLocalizations(context);
  final String message = verdict == ChecksumVerdict.unlisted
      ? t.update_checksum_unlisted(assetName)
      : t.update_verification_unavailable(assetName);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(t.ok),
        ),
      ],
    ),
  );
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
  WindowsUpdateEnvironment windows,
) async {
  final plan = await windows.plan(
    portable: result.portable,
    package: package,
    exeDir: p.dirname(Platform.resolvedExecutable),
  );
  if (!context.mounted) return;

  switch (plan) {
    case BlockedUpdate(:final blocker):
      // The app stays OPEN. Everything that could have been checked without
      // applying the update has been, and something the user can fix is wrong;
      // closing here is what turned "cannot update" into "it just closed".
      if (blocker == WindowsUpdateBlocker.packageUnusable) {
        await discardDownload(package);
      }
      if (context.mounted) await _showBlockedDialog(context, result, blocker);
    case InstallerUpdate(:final packagePath):
      try {
        await windows.launchInstaller(File(packagePath));
      } on UpdateInstallException {
        if (context.mounted) await _showInstallFailed(context);
        return;
      }
      // The installer is up; step aside so it can take the window and the files.
      await windows.shutdown();
    case PortableSelfUpdate(
        :final scriptPath,
        :final packagePath,
        :final logPath,
        :final workDir,
      ):
      // Recorded BEFORE the hand-off: the app is about to be replaced by the
      // very process it is starting, so a note written afterwards would never
      // exist, and the next launch would have nothing to report.
      await windows.recordPending(
        workDir: workDir,
        fromVersion: await currentAppVersion(),
        toVersion: result.version,
        packagePath: packagePath,
      );
      try {
        await windows.launchPortable(
          scriptPath: scriptPath,
          zip: File(packagePath),
          logPath: logPath,
        );
      } on UpdateInstallException catch (error) {
        // The hand-off never started, so the record written above must go: left
        // in place it makes the NEXT launch report "the last update did not
        // finish, run it by hand" for a run that never began, immediately after
        // this dialog already said it could not start.
        await windows.clearPending(workDir: workDir);
        if (!context.mounted) return;
        // A refused PATH is not a broken launch: say which one it is, and point
        // at the package so the user can run the updater themselves.
        if (error.reason == InstallFailure.pathUnsupported) {
          await _showPathUnsupportedDialog(context, packagePath);
        } else {
          await _showInstallFailed(context);
        }
        return;
      }
      // The updater waits for this process to disappear before touching a
      // single file, so the shutdown must complete rather than be abandoned.
      await windows.shutdown();
  }
}

/// Reports a portable hand-off refused because the paths cannot survive
/// `cmd.exe`, and tells the user how to apply the update by hand.
Future<void> _showPathUnsupportedDialog(
  BuildContext context,
  String packagePath,
) async {
  final t = getLocalizations(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.update_install_failed),
      content: Text(t.update_install_path_unsupported(packagePath)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(t.ok),
        ),
      ],
    ),
  );
}

/// Reports a hand-off that cannot happen, and points at the release page.
Future<void> _showBlockedDialog(
  BuildContext context,
  UpdateAvailable result,
  WindowsUpdateBlocker blocker,
) async {
  final t = getLocalizations(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.update_portable_blocked_title),
      content: Text(switch (blocker) {
        WindowsUpdateBlocker.updaterMissing =>
          t.update_portable_blocked_updater_missing,
        WindowsUpdateBlocker.packageUnusable =>
          t.update_portable_blocked_package_unusable,
        WindowsUpdateBlocker.installDirNotWritable =>
          t.update_portable_blocked_not_writable,
      }),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(t.cancel),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            unawaited(launchURL(result.pageUrl));
          },
          child: Text(t.releasePage),
        ),
      ],
    ),
  );
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

/// Reports a package that no longer matches what the transfer verified — a swap
/// between download and hand-off. The app stays open; the file is discarded.
Future<void> _showHandoffIntegrityDialog(BuildContext context) async {
  final t = getLocalizations(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.update_install_failed),
      content: Text(t.update_handoff_integrity_failed),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(t.ok),
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
Future<void> shutdownForUpdate() async {
  await AppShutdown.run();
  exit(0);
}
