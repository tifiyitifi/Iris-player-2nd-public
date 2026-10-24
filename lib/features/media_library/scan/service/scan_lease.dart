import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:iris/utils/app_instance.dart';
import 'package:iris/utils/logger.dart';
import 'package:path/path.dart' as p;

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Cross-window lease for recursive scans.
///
/// WHY: two IRIS windows scanning the same storage duplicate the directory IO
/// and fight over the same `scan_queue`/`media_nodes` rows. The first window to
/// start a scan holds `<instances>/scan.lock` for the duration; another window's
/// scan request is refused (the UI explains it) instead of running in parallel.
///
/// The lease is an OS file lock: a crashed scan releases it automatically, so a
/// dead window can never block scanning forever. Disabled by default (Android /
/// tests) — `main()` installs the desktop lease after `AppPaths.init()`.
class ScanLease extends AppLease {
  ScanLease({required super.lockPath});

  ScanLease.disabled() : super.disabled();

  static ScanLease instance = ScanLease.disabled();

  /// Desktop policy: the lease lives next to the instance slot/claim locks.
  /// Degrades to the no-op lease when the directory cannot be resolved.
  static Future<ScanLease> createFileBacked() async {
    try {
      final String dir = await AppInstance.instancesDirPath();
      return ScanLease(lockPath: p.join(dir, 'scan.lock'));
    } catch (e) {
      _log.w('scan lease disabled (no usable dir): $e');
      return ScanLease.disabled();
    }
  }

  @visibleForTesting
  static void debugSetInstance(ScanLease lease) {
    instance = lease;
  }

  @visibleForTesting
  static void debugReset() {
    instance = ScanLease.disabled();
  }
}
