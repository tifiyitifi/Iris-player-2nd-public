import 'package:iris/features/app_update/model/app_version.dart';
import 'package:iris/features/app_update/model/asset_picker.dart';
import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/features/app_update/services/github_release_source.dart';
import 'package:iris/utils/app_paths.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:package_info_plus/package_info_plus.dart';

final _log = AreaKeyLog(LogKeys.appUpdate);

/// Reads the newest published tag. Injected so tests need no network.
typedef LatestTagLoader = Future<String?> Function();

/// Reads one release payload. Injected so tests need no network.
typedef ReleaseLoader = Future<ReleaseInfo> Function(String tag);

/// Runs one update check and classifies the outcome.
///
/// Both loaders are parameters rather than direct calls, so the whole decision
/// tree — up to date, ahead, available, and every failure mode — is exercisable
/// without a network. The single API call is made only after a newer version is
/// confirmed, so an up-to-date install costs no API quota at all.
Future<UpdateCheckResult> checkForUpdate({
  required String currentVersion,
  LatestTagLoader? loadLatestTag,
  ReleaseLoader? loadRelease,
  UpdatePlatform? platform,
  List<String>? supportedAbis,
  bool? portable,
}) async {
  final targetPlatform = platform ?? currentUpdatePlatform();
  if (targetPlatform == UpdatePlatform.unsupported) {
    return const CheckFailed(UpdateFailure.unsupportedPlatform);
  }

  final loadTag = loadLatestTag ?? fetchLatestReleaseTag;
  final load = loadRelease ?? fetchReleaseInfo;

  String? tag;
  try {
    tag = await loadTag();
  } on UpdateFetchException catch (error) {
    return CheckFailed(error.reason, detail: error.detail);
  } catch (error) {
    _log.w('update check failed while reading the latest tag: $error');
    return const CheckFailed(UpdateFailure.network);
  }

  if (tag == null || tag.isEmpty) {
    // Nothing published yet: there is no update, and nothing went wrong either.
    return UpToDate(version: currentVersion);
  }

  if (!isUsableReleaseTag(tag)) {
    // A tag that is not a version — a leftover local-build tag is neither draft
    // nor prerelease, so GitHub may hand it back as "latest". Comparing it
    // would throw or coerce it into a nonsense number, so it is reported as its
    // own failure instead of silently reading as "up to date".
    _log.w('latest release tag is not a version: $tag');
    return CheckFailed(UpdateFailure.malformedTag, detail: tag);
  }

  final latestVersion = stripTagPrefix(tag);
  final comparison = compareVersions(currentVersion, latestVersion);
  if (comparison == null) {
    // The running build carries a version this parser cannot read (a locally
    // edited pubspec, typically). Do not guess in either direction.
    return CheckFailed(UpdateFailure.malformedTag, detail: currentVersion);
  }
  if (comparison == 0) {
    return UpToDate(version: latestVersion);
  }
  if (comparison > 0) {
    return AheadOfPublic(current: currentVersion, latest: latestVersion);
  }

  final ReleaseInfo release;
  try {
    release = await load(tag);
  } on UpdateFetchException catch (error) {
    return CheckFailed(error.reason, detail: error.detail);
  } catch (error) {
    _log.w('update check failed while reading release $tag: $error');
    return const CheckFailed(UpdateFailure.network);
  }

  final isPortable = portable ?? _isPortableEdition();
  final abis = supportedAbis ?? await resolveSupportedAbis();

  final asset = targetPlatform == UpdatePlatform.android
      ? pickAndroidAsset(
          assets: release.assets,
          version: release.version,
          supportedAbis: abis,
        )
      : pickWindowsAsset(
          assets: release.assets,
          version: release.version,
          portable: isPortable,
        );

  if (asset == null) {
    // The release exists but ships nothing installable for this platform. The
    // failure dialog still offers the release page, which is the only route
    // left for such a build.
    _log.i('release $tag has no ${targetPlatform.name} package');
    return const CheckFailed(UpdateFailure.noAsset);
  }

  final universal = targetPlatform == UpdatePlatform.android
      ? universalAndroidAsset(assets: release.assets, version: release.version)
      : null;

  return UpdateAvailable(
    tag: release.tag.isEmpty ? tag : release.tag,
    version: release.version,
    pageUrl: release.pageUrl,
    notes: release.notes,
    platform: targetPlatform,
    asset: asset,
    universalAsset:
        (universal == null || universal.name == asset.name) ? null : universal,
    publishedAt: release.publishedAt,
    portable: isPortable,
  );
}

/// The portable edition ships `portable.flag` next to its executable and
/// updates by overwriting its own folder; the installed edition is updated by
/// running the installer. [AppPaths] already decided which one this is.
bool _isPortableEdition() => isWindows && AppPaths.isPortable;

/// The running build's version, without the build number: a release tag
/// carries no build component, so comparing one against the other would always
/// report a difference.
Future<String> currentAppVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    setUpdateUserAgentVersion(info.version);
    return info.version;
  } catch (error) {
    _log.w('could not read the app version: $error');
    return '0.0.0';
  }
}
