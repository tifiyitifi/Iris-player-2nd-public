import 'package:iris/features/app_update/model/release_info.dart';

/// Asset-name construction and selection.
///
/// Every published name embeds the version, so selection is a set-membership
/// question with exactly one answer, never a scan-and-take-first. The legacy
/// check did `assets.where((a) => a.name.contains('android')).first`, which
/// matched all four Android packages and handed out an arbitrary one — a
/// desktop x86_64 build to an arm64 phone, or the installer to a portable
/// Windows build, which then failed to unpack.

const String androidAssetPrefix = 'IRIS-android-';
const String androidAssetSuffix = '.apk';

/// Published names carry a `v` before the version on every platform:
/// `IRIS-android-<abi>-v2.0.4.apk`, `IRIS-windows-v2.0.4.zip`,
/// `IRIS-windows-installer-v2.0.4.exe`. The prefixes below therefore include it.
const String windowsZipAssetPrefix = 'IRIS-windows-v';
const String windowsZipAssetSuffix = '.zip';
const String windowsInstallerAssetPrefix = 'IRIS-windows-installer-v';
const String windowsInstallerAssetSuffix = '.exe';

/// The ABI-specific Android package for [abi], or null.
ReleaseAsset? androidAssetForAbi({
  required List<ReleaseAsset> assets,
  required String version,
  required String abi,
}) =>
    _findByName(
      assets,
      '$androidAssetPrefix$abi-v$version$androidAssetSuffix',
    );

/// The universal (all-ABI) Android package, or null.
ReleaseAsset? universalAndroidAsset({
  required List<ReleaseAsset> assets,
  required String version,
}) =>
    _findByName(
      assets,
      '${androidAssetPrefix}universal-v$version$androidAssetSuffix',
    );

/// Picks the Android package this device can actually run.
///
/// [supportedAbis] is the device's best-first preference list. The first entry
/// with a matching package wins, so a 64-bit device gets the 64-bit build and a
/// 32-bit-only device gets the 32-bit one. Never returns a package for an ABI
/// the device did not report, because an APK built for an unsupported
/// architecture will not install. Falls back to the universal package, which
/// carries every ABI — heavier, but always installable.
ReleaseAsset? pickAndroidAsset({
  required List<ReleaseAsset> assets,
  required String version,
  required List<String> supportedAbis,
}) {
  for (final abi in supportedAbis) {
    final hit = androidAssetForAbi(
      assets: assets,
      version: version,
      abi: abi,
    );
    if (hit != null) return hit;
  }
  return universalAndroidAsset(assets: assets, version: version);
}

/// The portable edition's self-overwriting ZIP, or null.
ReleaseAsset? windowsPortableAsset({
  required List<ReleaseAsset> assets,
  required String version,
}) =>
    _findByName(
      assets,
      '$windowsZipAssetPrefix$version$windowsZipAssetSuffix',
    );

/// The Inno Setup installer, or null.
ReleaseAsset? windowsInstallerAsset({
  required List<ReleaseAsset> assets,
  required String version,
}) =>
    _findByName(
      assets,
      '$windowsInstallerAssetPrefix$version$windowsInstallerAssetSuffix',
    );

/// Picks the Windows package for the running edition.
///
/// The two editions are installed differently and must not be swapped: the
/// portable build is updated by overwriting its own folder, the installed build
/// by running the installer (which owns the uninstall registry entries). The
/// asset name is the only reliable discriminator — the zip is
/// `IRIS-windows-v<version>.zip` and the installer
/// `IRIS-windows-installer-v<version>.exe`, so an exact match never confuses
/// them the way a `contains('windows')` filter did.
ReleaseAsset? pickWindowsAsset({
  required List<ReleaseAsset> assets,
  required String version,
  required bool portable,
}) =>
    portable
        ? windowsPortableAsset(assets: assets, version: version)
        : windowsInstallerAsset(assets: assets, version: version);

ReleaseAsset? _findByName(List<ReleaseAsset> assets, String name) {
  for (final asset in assets) {
    if (asset.name == name) return asset;
  }
  return null;
}
