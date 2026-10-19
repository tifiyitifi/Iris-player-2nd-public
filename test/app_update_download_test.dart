import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/features/app_update/services/github_release_source.dart';
import 'package:iris/features/app_update/services/update_downloader.dart';
import 'package:path/path.dart' as p;

/// A loopback origin that answers [status] and then stops mid-body: the headers
/// arrive, and the answer never does. A server that says nothing at all only
/// proves the header deadline, so this is the one shape that can hang a read.
Future<HttpServer> _stallingOrigin(int status) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.statusCode = status;
    request.response.add(utf8.encode('half an answer'));
    await request.response.flush();
    // Never completes, and the response is never closed.
    await Completer<void>().future;
  });
  return server;
}

/// A loopback origin that answers [status] with [body] and closes.
Future<HttpServer> _answeringOrigin(int status, String body) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response
      ..statusCode = status
      ..add(utf8.encode(body));
    await request.response.close();
  });
  return server;
}

String _urlOf(HttpServer server) => 'http://127.0.0.1:${server.port}/SHA256SUMS.txt';

Matcher _thrownFailure(DownloadFailure reason) => throwsA(
      isA<UpdateDownloadException>()
          .having((error) => error.reason, 'reason', reason),
    );

void main() {
  group('checksum policy', () {
    const asset = 'IRIS-windows-v2.0.7.zip';
    const digest =
        '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

    test('an index that names the asset verifies it', () {
      expect(
        classifyPublishedChecksum(
          const PublishedChecksums(sums: {asset: digest}, fetched: true),
          asset,
        ),
        ChecksumVerdict.verified,
      );
    });

    test('an authoritative index that omits the asset refuses it', () {
      // Fail-CLOSED: the release says which packages it published, and this one
      // is not among them. The advertised size is not a substitute for a digest.
      expect(
        classifyPublishedChecksum(
          const PublishedChecksums(
            sums: {'IRIS-android-universal-v2.0.7.apk': digest},
            fetched: true,
          ),
          asset,
        ),
        ChecksumVerdict.unlisted,
      );
    });

    test('no index at all fails open on the advertised size alone', () {
      // Read, but names nothing: not an authority over this asset, so it takes
      // the fail-open path rather than refusing every install. The download is
      // still pinned to a byte count, which is why this is allowed.
      expect(
        classifyPublishedChecksum(
          const PublishedChecksums.unavailable(),
          asset,
          advertisedSize: 42,
        ),
        ChecksumVerdict.noIndex,
      );
      expect(
        classifyPublishedChecksum(
          const PublishedChecksums(sums: {}, fetched: true),
          asset,
          advertisedSize: 42,
        ),
        ChecksumVerdict.noIndex,
      );
    });

    test('no index AND no advertised size cannot be verified: refused', () {
      // Neither a digest nor a byte count: nothing about the transfer can be
      // checked, and a `PK` header is a magic number, not an integrity signal.
      // Fail CLOSED instead of installing whatever the network handed back.
      expect(
        classifyPublishedChecksum(const PublishedChecksums.unavailable(), asset),
        ChecksumVerdict.unverifiable,
      );
      expect(
        classifyPublishedChecksum(
          const PublishedChecksums.unavailable(),
          asset,
          advertisedSize: 0,
        ),
        ChecksumVerdict.unverifiable,
      );
      // A digest is still the strongest answer, size or no size.
      expect(
        classifyPublishedChecksum(
          const PublishedChecksums(sums: {asset: digest}, fetched: true),
          asset,
          advertisedSize: 0,
        ),
        ChecksumVerdict.verified,
      );
    });
  });

  group('checksumVerdictAllowsDownload (the refusal gate)', () {
    // The flow gates the download on this predicate, so an installer can never
    // be reached for a package nothing verified. Pinned exhaustively: a NEW
    // verdict refuses by default until it is deliberately added here.
    test('only verified and size-only may proceed', () {
      const allowed = {ChecksumVerdict.verified, ChecksumVerdict.noIndex};
      for (final verdict in ChecksumVerdict.values) {
        expect(
          checksumVerdictAllowsDownload(verdict),
          allowed.contains(verdict),
          reason: '$verdict',
        );
      }
      expect(checksumVerdictAllowsDownload(ChecksumVerdict.unlisted), isFalse);
      expect(
          checksumVerdictAllowsDownload(ChecksumVerdict.unverifiable), isFalse);
    });
  });

  group('advertisedDownloadSize', () {
    test('the release size wins when the payload carries one', () {
      expect(advertisedDownloadSize(assetSize: 7, contentLength: 999), 7);
    });

    test('a size-less payload falls back to the transport length', () {
      // The byte check used to be skipped entirely when the release omitted
      // `size`; the transport's own Content-Length is still a real anchor.
      expect(advertisedDownloadSize(assetSize: 0, contentLength: 5000), 5000);
    });

    test('neither present means unknown (0), never a passing check', () {
      expect(advertisedDownloadSize(assetSize: 0, contentLength: -1), 0);
    });
  });

  group('parseSha256Sums', () {
    test('reads the sha256sum format the release publishes', () {
      const body = '''
a3f1b2c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f80  IRIS-android-universal-v2.0.5.apk
00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff  IRIS-windows-v2.0.5.zip
''';
      final sums = parseSha256Sums(body);
      expect(sums.length, 2);
      expect(sums['IRIS-android-universal-v2.0.5.apk'],
          'a3f1b2c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f80');
      expect(sums['IRIS-windows-v2.0.5.zip'],
          '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff');
    });

    test('accepts the binary-mode star marker', () {
      const body =
          '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff *IRIS-windows-v2.0.5.zip';
      expect(parseSha256Sums(body).containsKey('IRIS-windows-v2.0.5.zip'), isTrue);
    });

    test('strips a leading ./ so names match the asset names', () {
      const body =
          '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff  ./IRIS-windows-v2.0.5.zip';
      expect(parseSha256Sums(body).containsKey('IRIS-windows-v2.0.5.zip'), isTrue);
    });

    test('ignores comments, blanks and short digests', () {
      const body = '''
# generated by CI

deadbeef  IRIS-broken.apk
''';
      expect(parseSha256Sums(body), isEmpty);
    });

    test('lower-cases digests so comparison is case-insensitive', () {
      const body =
          'AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899  IRIS-windows-v2.0.5.zip';
      expect(parseSha256Sums(body)['IRIS-windows-v2.0.5.zip'],
          'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899');
    });
  });

  group('formatBytes', () {
    test('scales to a readable unit', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(75646479), '72.1 MB');
      expect(formatBytes(195649251), '186.6 MB');
    });
  });

  group('fetchPublishedChecksums', () {
    test('reads the index the release published', () async {
      const digest =
          '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
      final server = await _answeringOrigin(
        200,
        '# generated by CI\n\n$digest  IRIS-windows-v2.0.7.zip\n',
      );
      addTearDown(() => server.close(force: true));

      final index = await fetchPublishedChecksums(
        tag: 'v2.0.7',
        url: _urlOf(server),
        readTimeout: const Duration(seconds: 5),
      );
      expect(index.fetched, isTrue);
      expect(index.authoritative, isTrue);
      expect(index.sums, {'IRIS-windows-v2.0.7.zip': digest});
      expect(index.checksumFor('IRIS-windows-v2.0.7.zip'), digest);
      // A different asset is NOT in the index, and because the index itself is
      // usable that is a refusal (see the flow), not a silent pass.
      expect(index.checksumFor('IRIS-android-universal-v2.0.7.apk'), isNull);
    });

    test('a body that never ends is abandoned instead of waited on', () async {
      // The flow reads this index before it opens the progress window, so a read
      // with no deadline leaves the user on a dead interface: no dialog, no
      // progress, no way out. A missing index is not a failure, so the deadline
      // has to land on the one answer the caller can survive.
      final server = await _stallingOrigin(200);
      addTearDown(() => server.close(force: true));

      final index = await fetchPublishedChecksums(
        tag: 'v2.0.7',
        url: _urlOf(server),
        readTimeout: const Duration(milliseconds: 200),
      ).timeout(const Duration(seconds: 10));
      expect(index.fetched, isFalse);
      expect(index.authoritative, isFalse);
      expect(index.sums, isEmpty);
    });

    test('a refusal is unavailable too, and does not read the body', () async {
      final server = await _stallingOrigin(429);
      addTearDown(() => server.close(force: true));

      final index = await fetchPublishedChecksums(
        tag: 'v2.0.7',
        url: _urlOf(server),
        readTimeout: const Duration(milliseconds: 200),
      ).timeout(const Duration(seconds: 10));
      expect(index.fetched, isFalse);
      expect(index.authoritative, isFalse);
    });

    test('a 404 stays unavailable', () async {
      // Not every release publishes an index, and a hard requirement would make
      // all of them uninstallable — so this one is fail-OPEN, but the caller can
      // now say so instead of skipping the digest check in silence.
      final server = await _answeringOrigin(404, 'Not Found');
      addTearDown(() => server.close(force: true));

      final index = await fetchPublishedChecksums(
        tag: 'v2.0.7',
        url: _urlOf(server),
        readTimeout: const Duration(seconds: 5),
      );
      expect(index.fetched, isFalse);
      expect(index.authoritative, isFalse);
      expect(index.checksumFor('IRIS-windows-v2.0.7.zip'), isNull);
    });

    test('an index that names nothing is NOT authoritative', () async {
      // A 200 with an empty or unparsable body says nothing about any asset. It
      // must not be read as "every asset was withdrawn" (which would refuse
      // every install), yet it also cannot be an authority, so it degrades to
      // the same fail-open path as a missing index.
      final server = await _answeringOrigin(200, '# generated by CI\n');
      addTearDown(() => server.close(force: true));

      final index = await fetchPublishedChecksums(
        tag: 'v2.0.7',
        url: _urlOf(server),
        readTimeout: const Duration(seconds: 5),
      );
      expect(index.fetched, isTrue);
      expect(index.authoritative, isFalse);
    });

    test('the production URL comes from the release source', () {
      // One slug, used by the check, the release page and the digest file: the
      // downloader used to spell the repository out itself, so a rename would
      // have left the digest check pointing at the old one.
      expect(
        UpdateSource.checksumUrl('v2.0.7'),
        'https://github.com/${UpdateSource.repoSlug}/releases/download/'
        'v2.0.7/SHA256SUMS.txt',
      );
    });
  });

  group('downloadAsset failures', () {
    test('a refused transfer keeps the status, not "interrupted"', () async {
      // 403 is a bot challenge, 429 is the anonymous rate limit and 5xx is
      // GitHub being down. They do not want the same words, and none of them is
      // a transfer that stopped early, so the status has to survive the trip.
      for (final status in [403, 429, 500, 503]) {
        final server = await _answeringOrigin(status, 'no package here');
        final directory = await Directory.systemTemp.createTemp('iris-refused');
        addTearDown(() async {
          await server.close(force: true);
          await directory.delete(recursive: true);
        });

        await expectLater(
          downloadAsset(
            asset: ReleaseAsset(
              name: 'package.zip',
              downloadUrl: 'http://127.0.0.1:${server.port}/package.zip',
              size: 4,
            ),
            directory: directory.path,
          ),
          allOf(
            _thrownFailure(DownloadFailure.http),
            throwsA(isA<UpdateDownloadException>()
                .having((e) => e.detail, 'detail', '$status')),
          ),
          reason: 'status: $status',
        );
      }
    });

    test('a failed attempt leaves an existing verified package alone', () async {
      // Two attempts with one asset name share the final path. The second
      // (truncated -> sizeMismatch) must delete only its OWN temp, never the
      // package the first attempt already verified and published.
      final good = await _answeringOrigin(200, 'package-bytes');
      final bad = await _answeringOrigin(200, 'short');
      final directory = await Directory.systemTemp.createTemp('iris-republish');
      addTearDown(() async {
        await good.close(force: true);
        await bad.close(force: true);
        await directory.delete(recursive: true);
      });

      final published = await downloadAsset(
        asset: ReleaseAsset(
          name: 'package.zip',
          downloadUrl: 'http://127.0.0.1:${good.port}/package.zip',
          size: 'package-bytes'.length,
        ),
        directory: directory.path,
      );
      expect(published.path, p.join(directory.path, 'package.zip'));
      expect(await published.readAsString(), 'package-bytes');

      await expectLater(
        downloadAsset(
          asset: ReleaseAsset(
            name: 'package.zip',
            downloadUrl: 'http://127.0.0.1:${bad.port}/package.zip',
            size: 1000,
          ),
          directory: directory.path,
        ),
        _thrownFailure(DownloadFailure.sizeMismatch),
      );

      // The verified package survives, byte-for-byte...
      expect(published.existsSync(), isTrue);
      expect(await published.readAsString(), 'package-bytes');
      // ...and the failed attempt left no temp behind.
      expect(
        directory.listSync().where((e) => e.path.contains('.part-')),
        isEmpty,
      );
    });

    test('a package that cannot be written is not a network failure', () async {
      // The download directory is a file, so the package can never be opened
      // for writing. That is the disk's answer, and it has to be reported as
      // such: a full volume is not something any amount of retrying fixes.
      final root = await Directory.systemTemp.createTemp('iris-nospace');
      addTearDown(() => root.delete(recursive: true));
      final blocker = File(p.join(root.path, 'not-a-directory'))
        ..writeAsStringSync('in the way');

      await expectLater(
        downloadAsset(
          asset: const ReleaseAsset(
            name: 'package.zip',
            downloadUrl: 'http://127.0.0.1:1/package.zip',
            size: 4,
          ),
          // Never resolves: the package has to fail before the network is
          // touched, which is exactly what "no space" means.
          directory: blocker.path,
        ),
        _thrownFailure(DownloadFailure.storage),
      );
    });

    test('a body that never ends is abandoned instead of waited on', () async {
      // The header deadline covers the connect, not the body. A peer that stops
      // mid-answer without closing used to hang the progress window until the
      // user cancelled by hand.
      final server = await _stallingOrigin(200);
      final directory = await Directory.systemTemp.createTemp('iris-body-stall');
      addTearDown(() async {
        await server.close(force: true);
        await directory.delete(recursive: true);
      });

      await expectLater(
        downloadAsset(
          asset: ReleaseAsset(
            name: 'package.zip',
            downloadUrl: 'http://127.0.0.1:${server.port}/package.zip',
            size: 1000,
          ),
          directory: directory.path,
          bodyTimeout: const Duration(milliseconds: 200),
        ).timeout(const Duration(seconds: 10)),
        _thrownFailure(DownloadFailure.interrupted),
      );
    });

    test('a body that streams past the advertised size is cut off', () async {
      // An endless overrun never reaches the end-of-transfer size check, so the
      // byte count has to be enforced DURING the transfer.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response
          ..statusCode = 200
          // Chunked responses are buffered by default; without this the bytes
          // only reach the client when the response closes, which is exactly
          // the case this test must NOT be in.
          ..bufferOutput = false
          ..add(List<int>.filled(64, 0x41));
        await request.response.flush();
        await Completer<void>().future; // never closes
      });
      final directory = await Directory.systemTemp.createTemp('iris-overrun');
      addTearDown(() async {
        await server.close(force: true);
        await directory.delete(recursive: true);
      });

      await expectLater(
        downloadAsset(
          asset: ReleaseAsset(
            name: 'package.zip',
            downloadUrl: 'http://127.0.0.1:${server.port}/package.zip',
            size: 10,
          ),
          directory: directory.path,
        ).timeout(const Duration(seconds: 10)),
        _thrownFailure(DownloadFailure.sizeMismatch),
      );
    });
  });

  group('verifyDownloadedPackage', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('iris-verify');
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test('a size mismatch is refused', () async {
      final file = File(p.join(root.path, 'package.zip'))
        ..writeAsBytesSync(List<int>.filled(3, 0));
      expect(
        await verifyDownloadedPackage(package: file, expectedSize: 10),
        DownloadFailure.sizeMismatch,
      );
    });

    test('a digest mismatch is refused, a match passes', () async {
      final file = File(p.join(root.path, 'package.zip'))
        ..writeAsStringSync('package');
      expect(
        await verifyDownloadedPackage(
          package: file,
          expectedSize: 'package'.length,
          expectedSha256: 'aaaa',
          digestOf: (_) async => 'bbbb',
        ),
        DownloadFailure.hashMismatch,
      );
      expect(
        await verifyDownloadedPackage(
          package: file,
          expectedSize: 'package'.length,
          expectedSha256: 'AAAA',
          digestOf: (_) async => 'aaaa',
        ),
        isNull,
      );
    });

    test('a missing package is refused', () async {
      expect(
        await verifyDownloadedPackage(
          package: File(p.join(root.path, 'gone.zip')),
          expectedSize: 10,
        ),
        DownloadFailure.storage,
      );
    });
  });
}
