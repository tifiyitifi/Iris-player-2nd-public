import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/features/app_update/services/github_release_source.dart';
import 'package:iris/features/app_update/services/update_check_service.dart';

ReleaseInfo releaseFor(String tag, {List<ReleaseAsset>? assets}) => ReleaseInfo(
      tag: tag,
      version: stripTagPrefix(tag),
      pageUrl: 'https://example/releases/tag/$tag',
      notes: '* notes',
      publishedAt: DateTime.utc(2026, 9, 26),
      assets: assets ??
          [
            ReleaseAsset(
              name: 'IRIS-android-arm64-v8a-v2.0.5.apk',
              downloadUrl: 'https://example/arm64',
              size: 75646479,
            ),
            ReleaseAsset(
              name: 'IRIS-android-universal-v2.0.5.apk',
              downloadUrl: 'https://example/universal',
              size: 195649251,
            ),
          ],
    );

void main() {
  group('checkForUpdate', () {
    test('reports an available update with the package chosen for the device',
        () async {
      var apiCalls = 0;
      final result = await checkForUpdate(
        currentVersion: '2.0.4',
        platform: UpdatePlatform.android,
        supportedAbis: ['arm64-v8a', 'armeabi-v7a'],
        loadLatestTag: () async => 'v2.0.5',
        loadRelease: (tag) async {
          apiCalls++;
          return releaseFor(tag);
        },
      );

      expect(result, isA<UpdateAvailable>());
      final available = result as UpdateAvailable;
      expect(available.version, '2.0.5');
      expect(available.tag, 'v2.0.5');
      expect(available.asset.name, 'IRIS-android-arm64-v8a-v2.0.5.apk');
      expect(available.universalAsset?.name, 'IRIS-android-universal-v2.0.5.apk');
      expect(apiCalls, 1);
    });

    test('up to date costs no API call at all', () async {
      // The tag comparison is enough; spending an API request to re-confirm
      // would burn the anonymous hourly quota for nothing.
      var apiCalls = 0;
      final result = await checkForUpdate(
        currentVersion: '2.0.4',
        platform: UpdatePlatform.android,
        supportedAbis: const ['arm64-v8a'],
        loadLatestTag: () async => 'v2.0.4',
        loadRelease: (tag) async {
          apiCalls++;
          return releaseFor(tag);
        },
      );

      expect(result, isA<UpToDate>());
      expect((result as UpToDate).version, '2.0.4');
      expect(apiCalls, 0);
    });

    test('a newer local build is reported as ahead, not as up to date', () async {
      final result = await checkForUpdate(
        currentVersion: '2.1.0',
        platform: UpdatePlatform.android,
        supportedAbis: const ['arm64-v8a'],
        loadLatestTag: () async => 'v2.0.4',
        loadRelease: (tag) async => releaseFor(tag),
      );

      expect(result, isA<AheadOfPublic>());
      expect((result as AheadOfPublic).current, '2.1.0');
      expect(result.latest, '2.0.4');
    });

    test('a leftover non-version tag is its own failure, not "up to date"', () {
      // `2.0.0.local` is neither draft nor prerelease, so the public repository
      // can report it as the latest release. Reading it as "up to date" would
      // silently disable updates.
      expect(
        checkForUpdate(
          currentVersion: '2.0.4',
          platform: UpdatePlatform.android,
          supportedAbis: const ['arm64-v8a'],
          loadLatestTag: () async => '2.0.0.local',
          loadRelease: (tag) async => releaseFor(tag),
        ),
        completion(isA<CheckFailed>()
            .having((f) => f.reason, 'reason', UpdateFailure.malformedTag)
            .having((f) => f.detail, 'detail', '2.0.0.local')),
      );
    });

    test('an unreachable host is a network failure, never "up to date"', () {
      expect(
        checkForUpdate(
          currentVersion: '2.0.4',
          platform: UpdatePlatform.android,
          loadLatestTag: () async =>
              throw const UpdateFetchException(UpdateFailure.network),
          loadRelease: (tag) async => releaseFor(tag),
        ),
        completion(
            isA<CheckFailed>()
                .having((f) => f.reason, 'reason', UpdateFailure.network)),
      );
    });

    test('a timeout keeps its own reason', () {
      expect(
        checkForUpdate(
          currentVersion: '2.0.4',
          platform: UpdatePlatform.android,
          loadLatestTag: () async =>
              throw const UpdateFetchException(UpdateFailure.timeout),
          loadRelease: (tag) async => releaseFor(tag),
        ),
        completion(isA<CheckFailed>()
            .having((f) => f.reason, 'reason', UpdateFailure.timeout)),
      );
    });

    test('an unexpected status keeps the status for the message', () {
      expect(
        checkForUpdate(
          currentVersion: '2.0.4',
          platform: UpdatePlatform.android,
          loadLatestTag: () async =>
              throw const UpdateFetchException(UpdateFailure.http, detail: '403'),
          loadRelease: (tag) async => releaseFor(tag),
        ),
        completion(isA<CheckFailed>()
            .having((f) => f.reason, 'reason', UpdateFailure.http)
            .having((f) => f.detail, 'detail', '403')),
      );
    });

    test('a repository with no release yet is up to date, not an error', () {
      expect(
        checkForUpdate(
          currentVersion: '2.0.4',
          platform: UpdatePlatform.android,
          loadLatestTag: () async => null,
          loadRelease: (tag) async => releaseFor(tag),
        ),
        completion(isA<UpToDate>()),
      );
    });

    test('an answer with no version in it is a failure, not "up to date"', () {
      // The regression this pins: the tag loader used to answer null here too,
      // and null means "nothing was ever published" to the line below — so a
      // sign-in wall or a page injected by the network reached the user as
      // "you are on the latest version".
      expect(
        checkForUpdate(
          currentVersion: '2.0.4',
          platform: UpdatePlatform.android,
          loadLatestTag: () async => throw const UpdateFetchException(
            UpdateFailure.unreadableReleasePage,
            detail: 'https://github.com/login?return_to=x',
          ),
          loadRelease: (tag) async => releaseFor(tag),
        ),
        completion(isA<CheckFailed>().having(
          (f) => f.reason,
          'reason',
          UpdateFailure.unreadableReleasePage,
        )),
      );
    });

    test('a release with no package for this platform points at the page', () {
      expect(
        checkForUpdate(
          currentVersion: '2.0.4',
          platform: UpdatePlatform.windows,
          portable: true,
          loadLatestTag: () async => 'v2.0.5',
          loadRelease: (tag) async => ReleaseInfo(
            tag: tag,
            version: '2.0.5',
            pageUrl: 'https://example',
            notes: '',
            assets: const [
              ReleaseAsset(
                name: 'IRIS-android-universal-v2.0.5.apk',
                downloadUrl: 'https://example/a',
                size: 1,
              ),
            ],
          ),
        ),
        completion(
            isA<CheckFailed>().having((f) => f.reason, 'reason', UpdateFailure.noAsset)),
      );
    });

    test('an unsupported platform is refused before any request', () {
      expect(
        checkForUpdate(
          currentVersion: '2.0.4',
          platform: UpdatePlatform.unsupported,
          loadLatestTag: () async => fail('must not reach the network'),
          loadRelease: (tag) async => releaseFor(tag),
        ),
        completion(isA<CheckFailed>()
            .having((f) => f.reason, 'reason', UpdateFailure.unsupportedPlatform)),
      );
    });

    test('the portable Windows edition gets the ZIP', () async {
      final result = await checkForUpdate(
        currentVersion: '2.0.4',
        platform: UpdatePlatform.windows,
        portable: true,
        loadLatestTag: () async => 'v2.0.5',
        loadRelease: (tag) async => ReleaseInfo(
          tag: tag,
          version: '2.0.5',
          pageUrl: 'https://example',
          notes: '',
          assets: const [
            ReleaseAsset(
              name: 'IRIS-windows-installer-v2.0.5.exe',
              downloadUrl: 'https://example/installer',
              size: 2,
            ),
            ReleaseAsset(
              name: 'IRIS-windows-v2.0.5.zip',
              downloadUrl: 'https://example/zip',
              size: 3,
            ),
          ],
        ),
      );

      final available = result as UpdateAvailable;
      expect(available.asset.name, 'IRIS-windows-v2.0.5.zip');
      expect(available.portable, isTrue);
      expect(available.universalAsset, isNull);
    });
  });
}
