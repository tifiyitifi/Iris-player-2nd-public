import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/features/app_update/services/github_release_source.dart';

/// A trimmed copy of a real `releases/tags` payload for this project's public
/// repository, including the asset set the release workflow publishes.
String releasePayload({
  String tag = 'v2.0.4',
  String? body = '## v2.0.4\n\n### Changelog\n\n* Desktop control bar rebuilt\n\n### 更新日志\n\n* 桌面控制栏重构',
  List<Map<String, Object?>>? assets,
}) {
  return jsonEncode({
    'tag_name': tag,
    'name': 'IRIS-$tag',
    'html_url': 'https://github.com/tifiyiti/Iris-player-2nd-public/releases/tag/$tag',
    'published_at': '2026-09-26T14:54:44Z',
    'body': body,
    'assets': assets ??
        [
          {
            'name': 'IRIS-android-universal-v2.0.4.apk',
            'browser_download_url':
                'https://github.com/tifiyiti/Iris-player-2nd-public/releases/download/v2.0.4/IRIS-android-universal-v2.0.4.apk',
            'size': 195649251,
          },
          {
            'name': 'IRIS-windows-v2.0.4.zip',
            'browser_download_url':
                'https://github.com/tifiyiti/Iris-player-2nd-public/releases/download/v2.0.4/IRIS-windows-v2.0.4.zip',
            'size': 49235146,
          },
        ],
  });
}

void main() {
  group('parseReleaseInfo', () {
    test('reads tag, version, page, notes and timestamp', () {
      final release = parseReleaseInfo(releasePayload());
      expect(release.tag, 'v2.0.4');
      expect(release.version, '2.0.4');
      expect(release.pageUrl,
          'https://github.com/tifiyiti/Iris-player-2nd-public/releases/tag/v2.0.4');
      expect(release.notes, contains('### Changelog'));
      expect(release.publishedAt,
          DateTime.utc(2026, 9, 26, 14, 54, 44));
    });

    test('keeps a tag with no v prefix intact', () {
      final release = parseReleaseInfo(releasePayload(tag: '2.0.5'));
      expect(release.tag, '2.0.5');
      expect(release.version, '2.0.5');
    });

    test('survives a release with no assets, no body and no date', () {
      final release = parseReleaseInfo(jsonEncode({'tag_name': 'v2.0.0'}));
      expect(release.tag, 'v2.0.0');
      expect(release.assets, isEmpty);
      expect(release.notes, isEmpty);
      expect(release.publishedAt, isNull);
    });

    test('falls back to the requested tag when the payload omits one', () {
      final release =
          parseReleaseInfo(jsonEncode({'body': 'x'}), fallbackTag: 'v9.9.9');
      expect(release.tag, 'v9.9.9');
    });

    test('skips assets without a name or a download URL', () {
      final release = parseReleaseInfo(releasePayload(assets: [
        // No name: nothing to match an expected file name against.
        {'browser_download_url': 'https://example/a', 'size': 1},
        // No download URL: nothing to fetch.
        {'name': 'IRIS-android-universal-v2.0.4.apk', 'size': 1},
        {
          'name': 'IRIS-android-arm64-v8a-v2.0.4.apk',
          'browser_download_url': 'https://example/b',
          'size': 7,
        },
      ]));
      expect(release.assets.map((a) => a.name), [
        'IRIS-android-arm64-v8a-v2.0.4.apk',
      ]);
    });

    test('treats a non-numeric size as unknown rather than failing', () {
      final release = parseReleaseInfo(releasePayload(assets: [
        {
          'name': 'IRIS-android-universal-v2.0.4.apk',
          'browser_download_url': 'https://example/a',
          'size': 'big',
        },
      ]));
      expect(release.assets.single.size, 0);
    });
  });

  group('isUsableReleaseTag', () {
    test('accepts version tags', () {
      expect(isUsableReleaseTag('v2.0.4'), isTrue);
      expect(isUsableReleaseTag('2.0.4'), isTrue);
    });

    test('rejects the leftover local-build tag', () {
      // `2.0.0.local` is neither draft nor prerelease on the public repository,
      // so `releases/latest` can return it. It must not pass for a version.
      expect(isUsableReleaseTag('2.0.0.local'), isFalse);
    });
  });

  group('stripTagPrefix', () {
    test('removes only a leading v', () {
      expect(stripTagPrefix('v2.0.4'), '2.0.4');
      expect(stripTagPrefix('2.0.4'), '2.0.4');
      expect(stripTagPrefix('  v2.0.4 '), '2.0.4');
      expect(stripTagPrefix('2.0.0.local'), '2.0.0.local');
    });
  });

  group('latestTagFromResponse', () {
    const repo = 'https://github.com/tifiyiti/Iris-player-2nd-public';

    Matcher unreadablePage() => throwsA(
          isA<UpdateFetchException>().having(
            (e) => e.reason,
            'reason',
            UpdateFailure.unreadableReleasePage,
          ),
        );

    Matcher httpFailure(int status) => throwsA(
          isA<UpdateFetchException>()
              .having((e) => e.reason, 'reason', UpdateFailure.http)
              .having((e) => e.detail, 'detail', '$status'),
        );

    test('reads the tag out of the release redirect', () {
      expect(
        latestTagFromResponse(
          status: 302,
          location: '$repo/releases/tag/v2.0.4',
        ),
        'v2.0.4',
      );
    });

    test('a repository that never published is the only null', () {
      // 404 specifically, and not "no answer": GitHub 301s a renamed or
      // transferred repository to its new home, so a 404 is never a moved
      // repository in disguise and never has to be reported as a failure.
      expect(latestTagFromResponse(status: 404), isNull);
      expect(latestTagFromResponse(status: 404, location: ''), isNull);
    });

    test('a 200 carrying no redirect target is a failure, not an absence', () {
      // Either GitHub served the page itself, or something on the network
      // answered in its place. Both used to read as "nothing published", which
      // is how a blocked network reached the user as "you are up to date".
      expect(() => latestTagFromResponse(status: 200), unreadablePage());
    });

    test('a redirect pointing away from a tag is a failure', () {
      // GitHub's sign-in challenge and the repository root both land here, as
      // does a redirect with no target at all.
      const away = [
        'https://github.com/login?return_to=%2Ftifiyiti%2FIris-player-2nd-public',
        'https://github.com/login/oauth/authorize?client_id=x',
        repo,
        '',
      ];
      for (final location in away) {
        expect(
          () => latestTagFromResponse(status: 302, location: location),
          unreadablePage(),
          reason: 'location: "$location"',
        );
        expect(
          () => latestTagFromResponse(status: 301, location: location),
          unreadablePage(),
          reason: 'location: "$location"',
        );
      }
    });

    test('a refusal, a throttle and an outage each keep their status', () {
      for (final status in [403, 429, 500, 502, 503, 504]) {
        expect(
          () => latestTagFromResponse(status: status),
          httpFailure(status),
          reason: 'status: $status',
        );
      }
    });

    test('a 2xx that is not a plain page read is still a failure', () {
      // 204 and friends carry no release information either; they must not be
      // mistaken for the 200 that would have carried a redirect.
      for (final status in [201, 204]) {
        expect(
          () => latestTagFromResponse(status: status),
          httpFailure(status),
          reason: 'status: $status',
        );
      }
    });
  });
}
