import 'dart:io';

import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/utils/logger.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

final _log = AreaKeyLog(LogKeys.appUpdate);

/// Raised when the platform refuses to take over with the downloaded package.
class UpdateInstallException implements Exception {
  const UpdateInstallException(this.reason);

  final InstallFailure reason;

  @override
  String toString() => 'UpdateInstallException($reason)';
}

enum InstallFailure {
  /// The system installer / setup program could not be started.
  cannotLaunch,

  /// Android: the app is not allowed to install packages yet.
  needsPermission,
}

/// The portable edition's updater, shipped next to the executable.
///
/// Its presence is what makes an in-place update possible: the script waits for
/// the running process to exit, preserves `userdata`, overwrites the program
/// files and relaunches. Without it the portable edition can only be updated by
/// hand.
const String portableUpdaterScriptName = 'portable_update_by_zip.ps1';

/// Absolute path of the portable updater next to the executable, or null.
String? findPortableUpdater() {
  final exeDir = p.dirname(Platform.resolvedExecutable);
  final script = File(p.join(exeDir, portableUpdaterScriptName));
  return script.existsSync() ? script.path : null;
}

/// Hands a downloaded Android package to the system installer.
///
/// Uses the file-provider handoff rather than a raw `file://` intent: the
/// package lives in the app's private cache, which no other process may read,
/// so it has to be shared as a content URI with a one-shot read grant. The
/// plugin already declares that provider and maps `.apk` to
/// `application/vnd.android.package-archive`.
///
/// The system installer shows its own confirmation; Android requires a user
/// gesture for every install and offers no way around it. Once the install
/// succeeds Android replaces the package and terminates this process, so
/// nothing needs saving here — the app is already backgrounded by then, which
/// is when the player hooks persist playback position.
Future<void> installAndroidPackage(File apk) async {
  final ResultType type;
  try {
    type = (await OpenFilex.open(apk.path)).type;
  } catch (error) {
    _log.w('could not hand the package to the installer: $error');
    throw const UpdateInstallException(InstallFailure.cannotLaunch);
  }
  if (type == ResultType.done) return;
  _log.w('installer handoff refused: $type');
  throw UpdateInstallException(
    switch (type) {
      ResultType.noAppToOpen || ResultType.permissionDenied =>
        InstallFailure.needsPermission,
      _ => InstallFailure.cannotLaunch,
    },
  );
}

/// Starts the downloaded Inno Setup installer and returns immediately.
///
/// Deliberately not silent: a silent install would raise a UAC prompt on top of
/// an already-running full-screen player, and would terminate playback without
/// asking. The user drives the wizard, exactly as they did when they installed
/// this build in the first place.
///
/// Launched directly rather than through a shell: nothing here needs `cmd.exe`'s
/// help, and going through it would hand the path to a parser that expands `%`
/// and `!` before the installer ever sees them.
Future<void> launchWindowsInstaller(File installer) async {
  try {
    await Process.start(
      installer.path,
      const [],
      mode: ProcessStartMode.detached,
    );
  } catch (error) {
    _log.w('could not start the installer: $error');
    throw const UpdateInstallException(InstallFailure.cannotLaunch);
  }
}

/// Starts the portable self-update for [zip] and returns immediately.
///
/// [scriptPath] must be the copy that ships with the *running* build, not one
/// from the package being downloaded: the new build's own script cannot run
/// until the current files are replaced, and the current build's script knows
/// how to preserve `userdata`.
///
/// The script is launched detached and takes over from here — it waits for this
/// process to disappear before touching anything, so the caller must shut the
/// app down right after.
///
/// Launched directly, like the installer above: `powershell.exe` is an
/// executable, not a batch file, so a shell in front of it would only add a
/// parser that can mangle a user profile path.
Future<void> launchPortableSelfUpdate({
  required String scriptPath,
  required File zip,
}) async {
  try {
    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptPath,
        '-ZipPath',
        zip.path,
        '-NonInteractive',
      ],
      mode: ProcessStartMode.detached,
    );
  } catch (error) {
    _log.w('could not start the portable updater: $error');
    throw const UpdateInstallException(InstallFailure.cannotLaunch);
  }
}

/// Which package [asset] is, for the confirmation copy.
bool isWindowsPortablePackage(ReleaseAsset asset) =>
    asset.name.startsWith('IRIS-windows-') &&
    !asset.name.startsWith('IRIS-windows-installer-');
