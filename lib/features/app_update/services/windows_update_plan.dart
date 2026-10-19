import 'dart:io';

import 'package:iris/features/app_update/services/update_installer.dart';
import 'package:iris/utils/logger.dart';
import 'package:path/path.dart' as p;

final _log = AreaKeyLog(LogKeys.appUpdate);

/// Why a portable self-update cannot be handed over.
///
/// Each member is something the *user* has to change (move the folder, re-take
/// the download) or something the release has to ship (the updater script), so
/// the report is actionable rather than "the update failed".
enum WindowsUpdateBlocker {
  /// The package shipped without `portable_update_by_zip.ps1` next to the exe.
  /// A portable build cannot overwrite itself without it.
  updaterMissing,

  /// The downloaded package is gone, empty, or not an archive at all. Reached
  /// when the file was truncated by a dead transfer, replaced by a proxy's
  /// error page, or removed between the download and the hand-over.
  packageUnusable,

  /// The folder holding the executable refuses a write, so nothing can be
  /// overwritten. Almost always "extracted into Program Files".
  installDirNotWritable,
}

/// What the app will do with a verified Windows package.
sealed class WindowsUpdatePlan {
  const WindowsUpdatePlan();
}

/// Overwrite this build in place through the shipped updater, then let it
/// relaunch the app.
final class PortableSelfUpdate extends WindowsUpdatePlan {
  const PortableSelfUpdate({
    required this.scriptPath,
    required this.packagePath,
    required this.logPath,
    required this.workDir,
  });

  final String scriptPath;
  final String packagePath;

  /// Where the updater writes its transcript. Next to the package, because the
  /// install directory may be the very thing that is not writable.
  final String logPath;

  /// Directory the hand-off record (`pending.json`) lives in.
  final String workDir;
}

/// Hand the package to the Inno Setup installer; the user drives the wizard.
final class InstallerUpdate extends WindowsUpdatePlan {
  const InstallerUpdate({required this.packagePath});

  final String packagePath;
}

/// Nothing can be applied. The app must stay OPEN and say why — closing on a
/// hand-over that cannot happen is precisely how "it just closes" happened.
final class BlockedUpdate extends WindowsUpdatePlan {
  const BlockedUpdate(this.blocker);

  final WindowsUpdateBlocker blocker;
}

/// Decides how [package] is applied, checking everything that can be checked
/// *before* the app closes itself.
///
/// Pure with respect to the machine it runs on: [exeDir] is the only path it
/// does not derive, which keeps the decision testable against a temporary
/// directory instead of the real installation.
Future<WindowsUpdatePlan> planWindowsUpdate({
  required bool portable,
  required File package,
  required String exeDir,
}) async {
  final workDir = package.parent.path;

  if (!portable) {
    // The installed edition is updated by its own installer, which owns the
    // uninstall registry entries and raises its own UAC prompt.
    return InstallerUpdate(packagePath: package.path);
  }

  final script = File(p.join(exeDir, portableUpdaterScriptName));
  if (!script.existsSync()) {
    _log.w('portable updater script missing next to $exeDir');
    return const BlockedUpdate(WindowsUpdateBlocker.updaterMissing);
  }

  if (!await _looksLikePackage(package)) {
    _log.w('downloaded update package is not usable: ${package.path}');
    return const BlockedUpdate(WindowsUpdateBlocker.packageUnusable);
  }

  if (!await _isWritable(exeDir)) {
    _log.w('install directory refuses a write: $exeDir');
    return const BlockedUpdate(WindowsUpdateBlocker.installDirNotWritable);
  }

  return PortableSelfUpdate(
    scriptPath: script.path,
    packagePath: package.path,
    // A STABLE name, deliberately: one attempt per timestamp left a log behind
    // for every try, in a folder nothing ever cleans. Each line is already
    // timestamped, so one appended file keeps the history readable and bounded
    // to a single file.
    logPath: p.join(workDir, 'portable-update.log'),
    workDir: workDir,
  );
}

/// Whether the file is a non-empty ZIP.
///
/// Deliberately shallow: the updater itself verifies the package properly (it
/// unpacks `iris.exe` and compares versions). This exists only to catch the
/// obviously-wrong file — an error page saved under a `.zip` name, or a
/// truncated transfer — before the app gives up its window for it.
Future<bool> _looksLikePackage(File package) async {
  try {
    if (!await package.exists()) return false;
    final length = await package.length();
    if (length < 4) return false;
    final header = await package.openRead(0, 4).first;
    return header.length >= 4 &&
        header[0] == 0x50 && // P
        header[1] == 0x4B && // K
        header[2] == 0x03 &&
        header[3] == 0x04;
  } catch (error) {
    _log.w('could not read the downloaded package: $error');
    return false;
  }
}

/// Cheap and definitive writability probe of the install directory.
///
/// The updater overwrites the program files in place, so a read-only location
/// (a portable build extracted into `Program Files`) has to be reported while
/// the app is still running, not after it has closed.
Future<bool> _isWritable(String exeDir) async {
  final probe = File(p.join(exeDir, '.iris-update-write-probe'));
  try {
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
    return true;
  } catch (error) {
    _log.w('install directory is not writable: $error');
    try {
      if (await probe.exists()) await probe.delete();
    } catch (_) {
      // The probe is already gone or was never created; nothing to clean.
    }
    return false;
  }
}
