import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:iris/utils/app_instance.dart';
import 'package:iris/utils/logger.dart';
import 'package:path/path.dart' as p;

final _log = AreaKeyLog(LogKeys.appUpdate);

/// Cross-window lease for downloading/applying an update.
///
/// WHY: both windows write the SAME package file (`<updates>/<asset name>`) and
/// can start the same installer/updater. Two concurrent downloads interleave
/// into a file whose digest can never match, and two installers fight over the
/// executable. The window that starts the download owns `<instances>/update.lock`
/// until it hands off; the other window says so instead of racing.
///
/// OS file lock: a window that dies mid-download releases it automatically.
/// Disabled by default (Android / tests) — `main()` installs the desktop lease.
class UpdateLease extends AppLease {
  UpdateLease({required super.lockPath});

  UpdateLease.disabled() : super.disabled();

  static UpdateLease instance = UpdateLease.disabled();

  static Future<UpdateLease> createFileBacked() async {
    try {
      final String dir = await AppInstance.instancesDirPath();
      return UpdateLease(lockPath: p.join(dir, 'update.lock'));
    } catch (e) {
      _log.w('update lease disabled (no usable dir): $e');
      return UpdateLease.disabled();
    }
  }

  @visibleForTesting
  static void debugSetInstance(UpdateLease lease) {
    instance = lease;
  }

  @visibleForTesting
  static void debugReset() {
    instance = UpdateLease.disabled();
  }
}
