import 'package:iris/features/app_update/model/app_version.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/features/app_update/services/update_check_service.dart';
import 'package:iris/utils/app_paths.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:package_info_plus/package_info_plus.dart';

final areaKeyLog = AreaKeyLog(LogKeys.legacyUtil);

/// Legacy view of a published release.
///
/// Kept only for the compatibility branch in the About page (see
/// `kShowUpstreamAboutEntries`), which predates the app_update module and must
/// keep compiling. This is a projection of the module's own result, not a
/// second implementation: the tag lookup, the version comparison and the asset
/// selection all live under `features/app_update`. The About page itself uses
/// the app_update flow, which reports "up to date", "ahead of the public
/// release" and each failure separately — none of which this null-returning
/// signature can express.
class Release {
  final String version;
  final String url;
  final String downloadUrl;
  final int size;
  final String changeLog;

  Release({
    required this.version,
    required this.url,
    required this.downloadUrl,
    required this.size,
    required this.changeLog,
  });
}

/// Returns the newest release this build could install, or null.
Future<Release?> getLatestRelease() async {
  if (currentUpdatePlatform() == UpdatePlatform.unsupported) {
    areaKeyLog.i('Unsupported platform');
    return null;
  }

  final String currentVersion;
  try {
    currentVersion = (await PackageInfo.fromPlatform()).version;
  } catch (e) {
    areaKeyLog.e('Could not read the app version: $e');
    return null;
  }

  final result = await checkForUpdate(currentVersion: currentVersion);
  if (result is! UpdateAvailable) return null;

  return Release(
    version: result.version,
    url: result.pageUrl,
    downloadUrl: result.asset.downloadUrl,
    size: result.asset.size,
    changeLog: result.notes,
  );
}

/// Whether [latestVersion] is newer than [currentVersion].
///
/// An unparseable version on either side answers false rather than throwing:
/// the compatibility branch treats false as "nothing to show".
bool isVersionUpdated(String currentVersion, String latestVersion) {
  final comparison = compareVersions(currentVersion, latestVersion);
  return comparison != null && comparison < 0;
}

/// Whether the running build ships the portable self-updater next to its
/// executable, i.e. whether an in-place update is possible at all.
bool isPortableRelease() => isWindows && AppPaths.isPortable;
