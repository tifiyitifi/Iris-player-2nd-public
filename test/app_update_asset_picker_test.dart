import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/model/asset_picker.dart';
import 'package:iris/features/app_update/model/release_info.dart';

/// The six files a public release publishes, in the order the API happens to
/// list them. Deliberately NOT in a friendly order: the legacy picker took
/// `.first` of a filtered list, so any ordering that happened to be favourable
/// would hide the bug.
List<ReleaseAsset> releaseAssets({String version = '2.0.4'}) => [
      ReleaseAsset(
        name: 'IRIS-android-arm64-v8a-v$version.apk',
        downloadUrl: 'https://example/arm64',
        size: 75646479,
      ),
      ReleaseAsset(
        name: 'IRIS-android-universal-v$version.apk',
        downloadUrl: 'https://example/universal',
        size: 195649251,
      ),
      ReleaseAsset(
        name: 'IRIS-android-armeabi-v7a-v$version.apk',
        downloadUrl: 'https://example/armv7',
        size: 71880335,
      ),
      ReleaseAsset(
        name: 'IRIS-android-x86_64-v$version.apk',
        downloadUrl: 'https://example/x86_64',
        size: 81860899,
      ),
      ReleaseAsset(
        name: 'IRIS-windows-installer-v$version.exe',
        downloadUrl: 'https://example/installer',
        size: 36344485,
      ),
      ReleaseAsset(
        name: 'IRIS-windows-v$version.zip',
        downloadUrl: 'https://example/zip',
        size: 49235146,
      ),
    ];

void main() {
  group('pickAndroidAsset', () {
    test('gives a 64-bit device the 64-bit package', () {
      final picked = pickAndroidAsset(
        assets: releaseAssets(),
        version: '2.0.4',
        supportedAbis: ['arm64-v8a', 'armeabi-v7a'],
      );
      expect(picked?.name, 'IRIS-android-arm64-v8a-v2.0.4.apk');
    });

    test('gives a 32-bit-only device the 32-bit package', () {
      final picked = pickAndroidAsset(
        assets: releaseAssets(),
        version: '2.0.4',
        supportedAbis: ['armeabi-v7a'],
      );
      expect(picked?.name, 'IRIS-android-armeabi-v7a-v2.0.4.apk');
    });

    test('follows the device preference order, not the asset order', () {
      final picked = pickAndroidAsset(
        assets: releaseAssets(),
        version: '2.0.4',
        // An emulator that prefers the 32-bit x86 build.
        supportedAbis: ['x86', 'x86_64'],
      );
      expect(picked?.name, 'IRIS-android-x86_64-v2.0.4.apk');
    });

    test('never offers an ABI the device did not report', () {
      // The release publishes no x86 package, so a device that only reports x86
      // must get the universal build rather than an arm one.
      final picked = pickAndroidAsset(
        assets: releaseAssets(),
        version: '2.0.4',
        supportedAbis: ['x86'],
      );
      expect(picked?.name, 'IRIS-android-universal-v2.0.4.apk');
    });

    test('falls back to universal when the ABI list is unknown', () {
      final picked = pickAndroidAsset(
        assets: releaseAssets(),
        version: '2.0.4',
        supportedAbis: const [],
      );
      expect(picked?.name, 'IRIS-android-universal-v2.0.4.apk');
    });

    test('matches the release version, so a stale package is never reused', () {
      final picked = pickAndroidAsset(
        assets: releaseAssets(),
        version: '2.0.5',
        supportedAbis: ['arm64-v8a'],
      );
      expect(picked, isNull);
    });
  });

  group('pickWindowsAsset', () {
    test('portable gets the ZIP, never the installer', () {
      // The legacy `contains('windows')` filter matched both files and returned
      // whichever came first, which handed the installer to a portable build.
      final picked = pickWindowsAsset(
        assets: releaseAssets(),
        version: '2.0.4',
        portable: true,
      );
      expect(picked?.name, 'IRIS-windows-v2.0.4.zip');
    });

    test('installed gets the installer, never the ZIP', () {
      final picked = pickWindowsAsset(
        assets: releaseAssets(),
        version: '2.0.4',
        portable: false,
      );
      expect(picked?.name, 'IRIS-windows-installer-v2.0.4.exe');
    });

    test('a release without the installer yields null, not the ZIP', () {
      // This is the shape of a release built before the installer existed: the
      // installed build must not silently overwrite itself from a portable ZIP.
      final assets = releaseAssets()
          .where((a) => !a.name.contains('installer'))
          .toList();
      expect(
        pickWindowsAsset(assets: assets, version: '2.0.4', portable: false),
        isNull,
      );
    });
  });

  group('universalAndroidAsset', () {
    test('finds the universal package by exact name', () {
      final universal = universalAndroidAsset(
        assets: releaseAssets(),
        version: '2.0.4',
      );
      expect(universal?.name, 'IRIS-android-universal-v2.0.4.apk');
    });

    test('returns null when the release has none', () {
      final assets = releaseAssets()
          .where((a) => !a.name.contains('universal'))
          .toList();
      expect(universalAndroidAsset(assets: assets, version: '2.0.4'), isNull);
    });
  });
}
