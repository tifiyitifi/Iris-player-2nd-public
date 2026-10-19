import 'dart:io';

import 'package:iris/utils/logger.dart';
import 'package:open_filex/open_filex.dart';

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

  /// The hand-off would have to pass a path through `cmd.exe`, which expands
  /// `%VAR%`, `!`, `&`, `^` and re-reads `( )`/quotes: a directory the user
  /// controls (a Windows profile with `&` in the name, an archive extracted
  /// under one) made the command ambiguous. Refused with instructions to run the
  /// updater by hand instead of launching something unintended.
  pathUnsupported,
}

/// The portable edition's updater, shipped next to the executable.
///
/// Its presence is what makes an in-place update possible: the script waits for
/// the running process to exit, preserves `userdata`, overwrites the program
/// files and relaunches. Without it the portable edition can only be updated by
/// hand.
const String portableUpdaterScriptName = 'portable_update_by_zip.ps1';

/// Console title of the updater window the hand-off opens.
///
/// Also the `start` title argument, which is not decoration: `start` reads its
/// first quoted token as the window title, so passing one keeps the command
/// itself unambiguous.
const String portableUpdaterTitle = 'IRIS Portable Update';

/// One prepared updater launch, split out so it can be asserted without
/// spawning a process.
class PortableUpdaterCommand {
  const PortableUpdaterCommand({
    required this.executable,
    required this.arguments,
  });

  final String executable;
  final List<String> arguments;
}

/// Characters `cmd.exe` re-interprets inside a command line.
///
/// `%VAR%` expands, `!` expands under delayed expansion, `&`/`|`/`<`/`>`/`( )`
/// separate or group commands, `^` is the escape character and `"` toggles
/// quoting. `start`'s own argument parsing makes it worse: the first quoted
/// token is read as a window title.
const String cmdUnsafePathChars = r'%!^&|<>()"';

/// Whether [path] can survive the `cmd.exe /c start` hand-off untouched.
bool isCmdSafePortableUpdaterPath(String path) =>
    path.isNotEmpty && !path.split('').any(cmdUnsafePathChars.contains);

/// The command that hands a downloaded ZIP to the portable updater.
///
/// Routed through `cmd.exe /c start` rather than launching `powershell.exe`
/// directly, and that is the whole point of this function:
///
///  * `ProcessStartMode.detached` is Win32 `DETACHED_PROCESS`, which gives the
///    child **no console at all**. This process is a GUI-subsystem executable
///    with no console of its own to hand over, and in that state
///    `powershell.exe` exits immediately **without executing a single line of
///    the script** (measured: exit 0 in ~0.1 s, no file touched, five runs out
///    of five). The hand-off was therefore a silent no-op, and the app then went
///    on to shut itself down — which is exactly what "it just closes" was.
///  * `cmd.exe /c start` allocates a console for the script, so the update runs
///    and the user can watch it (and read the error, on the rare path where
///    there is one). The console is the script's own; the app exits either way.
///
/// `-LogPath` is passed alongside so the run leaves a file behind even if no
/// console could be created.
///
/// Returns NULL when either path contains a character `cmd.exe` would expand or
/// re-parse (see [isCmdSafePortableUpdaterPath]): the caller must fall back to
/// telling the user to run the updater by hand rather than hand the console an
/// ambiguous command line.
PortableUpdaterCommand? portableUpdaterCommand({
  required String scriptPath,
  required String zipPath,
  required String? logPath,
}) {
  if (!isCmdSafePortableUpdaterPath(scriptPath) ||
      !isCmdSafePortableUpdaterPath(zipPath) ||
      (logPath != null && !isCmdSafePortableUpdaterPath(logPath))) {
    _log.w('portable updater paths cannot be passed through cmd.exe safely');
    return null;
  }
  return PortableUpdaterCommand(
    executable: 'cmd.exe',
    arguments: [
      '/c',
      'start',
      portableUpdaterTitle,
      'powershell.exe',
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptPath,
      '-ZipPath',
      zipPath,
      if (logPath != null) ...['-LogPath', logPath],
      '-NonInteractive',
    ],
  );
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
/// The updater is launched detached and takes over from here — it waits for this
/// process to disappear before touching anything, so the caller must shut the
/// app down right after. The console it opens belongs to the script, so it
/// outlives this process.
Future<void> launchPortableSelfUpdate({
  required String scriptPath,
  required File zip,
  required String? logPath,
}) async {
  final command = portableUpdaterCommand(
    scriptPath: scriptPath,
    zipPath: zip.path,
    logPath: logPath,
  );
  if (command == null) {
    // A path `cmd.exe` would expand or re-parse: refuse rather than launch a
    // command line whose meaning depends on the user's directory name.
    throw const UpdateInstallException(InstallFailure.pathUnsupported);
  }
  try {
    await Process.start(
      command.executable,
      command.arguments,
      mode: ProcessStartMode.detached,
    );
  } catch (error) {
    _log.w('could not start the portable updater: $error');
    throw const UpdateInstallException(InstallFailure.cannotLaunch);
  }
}
