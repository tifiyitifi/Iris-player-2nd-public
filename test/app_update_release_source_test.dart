import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    'html_url': 'https://github.com/tifiyitifi/Iris-player-2nd-public/releases/tag/$tag',
    'published_at': '2026-09-26T14:54:44Z',
    'body': body,
    'assets': assets ??
        [
          {
            'name': 'IRIS-android-universal-v2.0.4.apk',
            'browser_download_url':
                'https://github.com/tifiyitifi/Iris-player-2nd-public/releases/download/v2.0.4/IRIS-android-universal-v2.0.4.apk',
            'size': 195649251,
          },
          {
            'name': 'IRIS-windows-v2.0.4.zip',
            'browser_download_url':
                'https://github.com/tifiyitifi/Iris-player-2nd-public/releases/download/v2.0.4/IRIS-windows-v2.0.4.zip',
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
          'https://github.com/tifiyitifi/Iris-player-2nd-public/releases/tag/v2.0.4');
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
    const repo = 'https://github.com/tifiyitifi/Iris-player-2nd-public';

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
        'https://github.com/login?return_to=%2Ftifiyitifi%2FIris-player-2nd-public',
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

  group('latestProbeTarget', () {
    final asked = Uri.parse('https://github.com/old-owner/iris/releases/latest');

    test('a rename hop is the same question at another address', () {
      expect(
        latestProbeTarget(
          location: 'https://github.com/new-owner/iris/releases/latest',
          asked: asked,
        ),
        Uri.parse('https://github.com/new-owner/iris/releases/latest'),
      );
    });

    test('the address a rename points at is itself a question worth asking', () {
      // Two renames in a row only resolve if the moved address stays a valid
      // starting point for the next hop.
      final moved = Uri.parse('https://github.com/other/iris/releases/latest');
      expect(latestProbeTarget(location: '$moved', asked: asked), moved);
      expect(latestProbeTarget(location: '$moved', asked: moved), moved);
    });

    test('the hop that names the tag is an answer, not a question to re-ask', () {
      expect(
        latestProbeTarget(
          location: 'https://github.com/new-owner/iris/releases/tag/v2.0.5',
          asked: asked,
        ),
        isNull,
      );
    });

    test('anything that is not that question again is refused', () {
      // A sign-in challenge, the repository root and a network's own page all
      // end somewhere else entirely. Re-asking those is a hang, not a rename.
      const elsewhere = [
        'https://github.com/login?return_to=%2Fold-owner%2Fire',
        'https://github.com/old-owner/iris',
        'https://github.com/old-owner/iris/',
        'https://github.com/old-owner/iris/releases',
        'https://github.com/old-owner/iris/releases/latest/extra',
        'https://github.com/old-owner/iris/latest',
        'https://elsewhere.example/old-owner/iris/releases/latest',
      ];
      for (final location in elsewhere) {
        expect(
          latestProbeTarget(location: location, asked: asked),
          isNull,
          reason: 'location: "$location"',
        );
      }
    });

    test('a relative, empty or unreadable target is not a question to re-ask', () {
      for (final location in [
        null,
        '',
        '   ',
        '/old-owner/iris/releases/latest',
      ]) {
        expect(
          latestProbeTarget(location: location, asked: asked),
          isNull,
          reason: 'location: "$location"',
        );
      }
    });
  });

  group('fetchLatestReleaseTag', () {
    Matcher unreadablePage() => throwsA(
          isA<UpdateFetchException>().having(
            (e) => e.reason,
            'reason',
            UpdateFailure.unreadableReleasePage,
          ),
        );

    /// A loopback origin answering each request with the next entry of
    /// [answers], repeating the last, so a rename hop can be followed by the
    /// payload hop the way GitHub answers one. `$origin` in a location is
    /// replaced by this origin's own address.
    Future<(HttpServer, int Function())> redirectingOrigin(
        List<(int, String?)> answers) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      var served = 0;
      server.listen((request) async {
        final index = served < answers.length ? served : answers.length - 1;
        final answer = answers[index];
        served++;
        request.response.statusCode = answer.$1;
        final location = answer.$2;
        if (location != null) {
          request.response.headers.set(HttpHeaders.locationHeader,
              location.replaceAll(r'$origin', base));
        }
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      return (server, () => served);
    }

    Future<String?> probe(HttpServer server) => fetchLatestReleaseTag(
          url: 'http://127.0.0.1:${server.port}/old-owner/iris/releases/latest',
        );

    test('the payload hop on the first answer is the whole answer', () async {
      final (server, _) = await redirectingOrigin([
        (302, r'$origin/old-owner/iris/releases/tag/v2.0.5'),
      ]);
      expect(await probe(server), 'v2.0.5');
    });

    test('a rename hop is the same question asked again, not a failure', () async {
      // The slug this build was compiled with now answers 301 with the same
      // `latest` probe at the new name, and that probe carries the tag.
      final (server, served) = await redirectingOrigin([
        (301, r'$origin/new-owner/iris/releases/latest'),
        (302, r'$origin/new-owner/iris/releases/tag/v2.0.5'),
      ]);
      expect(await probe(server), 'v2.0.5');
      expect(served(), 2,
          reason: 'one hop spent on the rename, one on the answer');
    });

    test('two renames in a row still find the tag', () async {
      final (server, served) = await redirectingOrigin([
        (301, r'$origin/second/iris/releases/latest'),
        (301, r'$origin/third/iris/releases/latest'),
        (302, r'$origin/third/iris/releases/tag/v2.0.6'),
      ]);
      expect(await probe(server), 'v2.0.6');
      expect(served(), 3);
    });

    test('a sign-in challenge is not a rename and is not retried', () async {
      final (server, served) = await redirectingOrigin([
        (302, r'$origin/login?return_to=%2Fold-owner%2Fire'),
      ]);
      await expectLater(probe(server), unreadablePage());
      expect(served(), 1, reason: 'one question, one refused answer');
    });

    test('a body that never ends is abandoned instead of waited on', () async {
      // The `Location` is the payload; the body is only drained so the
      // connection can be released. A captive portal that sends the status and
      // then stalls left the version check hanging with no dialog to close —
      // `readTimeout` only ever covered the headers.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 302;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${server.port}/owner/iris/releases/tag/v2.0.5',
        );
        request.response.add(utf8.encode('half an answer'));
        await request.response.flush();
        // Never completes, and the response is never closed.
        await Completer<void>().future;
      });
      addTearDown(() => server.close(force: true));

      await expectLater(
        fetchLatestReleaseTag(
          url: 'http://127.0.0.1:${server.port}/owner/iris/releases/latest',
          readTimeout: const Duration(milliseconds: 200),
        ).timeout(const Duration(seconds: 10)),
        throwsA(isA<UpdateFetchException>()
            .having((e) => e.reason, 'reason', UpdateFailure.timeout)),
      );
    });

    test('a redirect loop costs a bounded number of hops, not a hang', () async {
      // A name that keeps pointing at itself, or a captive portal that keeps
      // redirecting, must not turn a version check into an endless walk.
      final (server, served) = await redirectingOrigin([
        (301, r'$origin/loop/iris/releases/latest'),
      ]);
      await expectLater(probe(server), unreadablePage());
      expect(served(), lessThanOrEqualTo(4));
    });

    test('a repository that never published stays an absence', () async {
      final (server, _) = await redirectingOrigin([(404, null)]);
      expect(await probe(server), isNull);
    });

    test('a refusal keeps its own status instead of being walked', () async {
      final (server, served) = await redirectingOrigin([(403, null)]);
      await expectLater(
        probe(server),
        throwsA(isA<UpdateFetchException>()
            .having((e) => e.reason, 'reason', UpdateFailure.http)
            .having((e) => e.detail, 'detail', '403')),
      );
      expect(served(), 1);
    });
  });
}
