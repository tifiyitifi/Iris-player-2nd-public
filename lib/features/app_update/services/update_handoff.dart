import 'dart:convert';
import 'dart:io';

import 'package:iris/features/app_update/model/app_version.dart';
import 'package:iris/utils/logger.dart';
import 'package:path/path.dart' as p;

final _log = AreaKeyLog(LogKeys.appUpdate);

/// The record the app leaves behind before it hands its files to the portable
/// updater, and that the next launch reads back.
///
/// Why it exists: handing over is the one update step that cannot be undone or
/// watched. The app closes, a script it does not control either overwrites the
/// program files or does not, and the user is left to tell the two apart. With
/// this record the next launch can say which of the two happened instead of
/// showing nothing at all.
const String pendingUpdateFileName = 'pending.json';

/// A hand-off that has been started but not yet accounted for.
class PendingUpdate {
  const PendingUpdate({
    required this.fromVersion,
    required this.toVersion,
    required this.packagePath,
    required this.startedAt,
  });

  final String fromVersion;
  final String toVersion;
  final String packagePath;
  final DateTime startedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'from': fromVersion,
        'to': toVersion,
        'package': packagePath,
        'startedAt': startedAt.toIso8601String(),
      };

  /// Parses one record, or null when the payload is not one.
  ///
  /// A corrupt record must never take the launch down with it: it is a note to
  /// self, not state the app depends on.
  static PendingUpdate? fromJson(Object? json) {
    if (json is! Map) return null;
    final from = json['from'];
    final to = json['to'];
    if (from is! String || to is! String || to.isEmpty) return null;
    final packagePath = json['package'];
    final startedAt = json['startedAt'];
    return PendingUpdate(
      fromVersion: from,
      toVersion: to,
      packagePath: packagePath is String ? packagePath : '',
      startedAt: startedAt is String
          ? (DateTime.tryParse(startedAt) ?? DateTime.now())
          : DateTime.now(),
    );
  }
}

/// What became of the last hand-off, once the app is running again.
class PreviousUpdateReport {
  const PreviousUpdateReport({
    required this.pending,
    required this.applied,
  });

  final PendingUpdate pending;

  /// Whether the running build is the version that was handed over. False means
  /// the updater did not finish — the app came back on the old files.
  final bool applied;

  /// The version that was being installed.
  String get toVersion => pending.toVersion;

  /// The package that was handed over (kept for a manual retry when the
  /// updater did not land).
  String get packagePath => pending.packagePath;
}

/// Records a hand-off that is about to be started.
///
/// Written BEFORE the updater is launched, because the whole point is to
/// survive the app being replaced: a record written afterwards would never
/// exist.
Future<void> recordPendingUpdate({
  required String workDir,
  required String fromVersion,
  required String toVersion,
  required String packagePath,
}) async {
  final record = PendingUpdate(
    fromVersion: fromVersion,
    toVersion: toVersion,
    packagePath: packagePath,
    startedAt: DateTime.now(),
  );
  try {
    await File(p.join(workDir, pendingUpdateFileName))
        .writeAsString(jsonEncode(record.toJson()), flush: true);
  } catch (error) {
    // Not fatal: the update itself can still succeed. The app only loses the
    // ability to report on it afterwards.
    _log.w('could not record the pending update: $error');
  }
}

/// Reads the hand-off record, if there is one.
///
/// A payload this build cannot read as a record (a corrupt or foreign file —
/// only this app ever writes it) is DELETED rather than left in place: nothing
/// could ever report it, and the alternative is re-reading a broken file on
/// every launch forever.
Future<PendingUpdate?> readPendingUpdate(String workDir) async {
  final file = File(p.join(workDir, pendingUpdateFileName));
  final String raw;
  try {
    if (!await file.exists()) return null;
    raw = await file.readAsString();
  } catch (error) {
    // A transient read failure (a lock, a permission hiccup) must not destroy
    // the record: the launch simply loses this run's report.
    _log.w('could not read the pending update record: $error');
    return null;
  }

  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (error) {
    _log.w('the pending update record is not JSON; dropping it: $error');
    await _discardPending(file);
    return null;
  }
  final record = PendingUpdate.fromJson(decoded);
  if (record == null) {
    _log.w('the pending update record is not a record; dropping it');
    await _discardPending(file);
    return null;
  }
  return record;
}

Future<void> _discardPending(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (error) {
    _log.w('could not drop the unreadable pending update record: $error');
  }
}

/// Removes the hand-off record.
///
/// For a hand-off that never actually started. The record is a promise that the
/// NEXT launch will be told what became of an update; when the updater could
/// not even be launched, that promise turns into a false report — "the last
/// update did not finish, run the .bat by hand" — on the very next start, right
/// after the user was already told it could not start. Nothing was handed over,
/// so there is nothing to account for.
Future<void> clearPendingUpdate({required String workDir}) async {
  try {
    final file = File(p.join(workDir, pendingUpdateFileName));
    if (await file.exists()) await file.delete();
  } catch (error) {
    _log.w('could not clear the pending update record: $error');
  }
}

/// Consumes the hand-off record and reports what happened to it.
///
/// One-shot by construction: the record is deleted here whatever the outcome,
/// so the report is shown exactly once and a stale note can never greet the
/// user again. Returns null when there was no hand-off to report.
///
/// The downloaded package is deleted once it has landed; when it has NOT, it is
/// kept on purpose — it is what a manual run of `portable_update_by_zip.bat`
/// still needs.
Future<PreviousUpdateReport?> takePreviousUpdateReport({
  required String workDir,
  required String runningVersion,
}) async {
  final pending = await readPendingUpdate(workDir);
  if (pending == null) return null;

  try {
    await File(p.join(workDir, pendingUpdateFileName)).delete();
  } catch (error) {
    _log.w('could not clear the pending update record: $error');
  }

  // Semantic comparison, not string equality: `2.1` and `2.1.0` are the same
  // release, and a trailing-segment difference must not report a FINISHED
  // update as "did not finish" forever. An unparseable version cannot be
  // confirmed as applied, so it reads as not-applied (`null` != 0).
  final applied = compareVersions(runningVersion.trim(), pending.toVersion.trim()) == 0;
  if (applied && pending.packagePath.isNotEmpty) {
    // The record is a plain JSON file next to the download, so the path in it
    // is INPUT, not a fact: only a package that actually lives in this run's
    // work directory may be deleted. Without the containment check a tampered
    // record (`"package": "C:\\..."`) turned the next launch into an arbitrary
    // file delete under the user's account.
    if (_isInsideDirectory(pending.packagePath, workDir)) {
      try {
        final package = File(pending.packagePath);
        if (await package.exists()) await package.delete();
      } catch (error) {
        _log.w('could not delete the applied update package: $error');
      }
    } else {
      _log.w('refusing to delete an update package outside $workDir: '
          '${pending.packagePath}');
    }
  }

  return PreviousUpdateReport(pending: pending, applied: applied);
}

/// Whether [filePath] resolves to a location strictly inside [directory].
///
/// Both sides are canonicalized (so `..` cannot escape) and, on a
/// case-insensitive filesystem, compared case-insensitively — the package name
/// comes from the same directory listing that produced the record.
bool _isInsideDirectory(String filePath, String directory) {
  try {
    final dir = p.canonicalize(Directory(directory).absolute.path);
    final file = p.canonicalize(File(filePath).absolute.path);
    if (Platform.isWindows) {
      return p.isWithin(dir.toLowerCase(), file.toLowerCase());
    }
    return p.isWithin(dir, file);
  } catch (_) {
    return false;
  }
}
