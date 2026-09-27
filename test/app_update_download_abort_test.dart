import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/features/app_update/services/update_downloader.dart';
import 'package:path/path.dart' as p;

/// Bytes the slow origin promises, and therefore promises to check.
const _total = 4 << 20;

/// A loopback origin that streams [_total] bytes slowly enough to be caught
/// mid-flight — the only window in which a stop can act at all.
Future<HttpServer> _slowOrigin() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.statusCode = 200;
    request.response.contentLength = _total;
    var sent = 0;
    while (sent < _total) {
      final size = math.min(8192, _total - sent);
      request.response.add(List<int>.filled(size, sent % 256));
      sent += size;
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await request.response.close();
  });
  return server;
}

/// A loopback origin that accepts the connection and never answers, so the
/// transfer is still waiting for headers when the caller gives up.
Future<HttpServer> _silentOrigin() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await Completer<void>().future;
  });
  return server;
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 500; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for the transfer to reach the awaited state');
}

Matcher _thrownFailure(DownloadFailure reason) => throwsA(
      isA<UpdateDownloadException>()
          .having((error) => error.reason, 'reason', reason),
    );

/// The stop has to be a real one: cancelling used to only close the window, so
/// the body kept arriving and the caller was handed a package anyway.
void main() {
  test('a stopped transfer reports cancelled, not a network failure', () async {
    final server = await _slowOrigin();
    addTearDown(() => server.close(force: true));
    final directory = await Directory.systemTemp.createTemp('iris-abort');
    addTearDown(() => directory.delete(recursive: true));

    final reported = <DownloadProgress>[];
    void Function()? abort;
    final transfer = downloadAsset(
      asset: ReleaseAsset(
        name: 'package.bin',
        downloadUrl: 'http://127.0.0.1:${server.port}/package.bin',
        size: _total,
      ),
      onProgress: reported.add,
      onAbort: (handle) => abort = handle,
      directory: directory.path,
    );

    await _waitFor(() => abort != null && reported.isNotEmpty);
    abort!();

    await expectLater(transfer, _thrownFailure(DownloadFailure.cancelled));

    // Nothing keeps arriving behind the stop.
    final seen = reported.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(reported.length, seen);
  });

  test('a stopped transfer leaves no package behind', () async {
    final server = await _slowOrigin();
    addTearDown(() => server.close(force: true));
    final directory = await Directory.systemTemp.createTemp('iris-abort');
    addTearDown(() => directory.delete(recursive: true));

    void Function()? abort;
    final transfer = downloadAsset(
      asset: ReleaseAsset(
        name: 'package.bin',
        downloadUrl: 'http://127.0.0.1:${server.port}/package.bin',
        size: _total,
      ),
      onAbort: (handle) => abort = handle,
      directory: directory.path,
    );

    await _waitFor(() => abort != null);
    abort!();
    await expectLater(transfer, _thrownFailure(DownloadFailure.cancelled));

    // Self-cleaning covers a stop as well: a truncated APK must not survive as
    // something an installer could later pick up.
    expect(File(p.join(directory.path, 'package.bin')).existsSync(), isFalse);
  });

  test('a stop while the headers are still pending ends the exchange',
      () async {
    final server = await _silentOrigin();
    addTearDown(() => server.close(force: true));
    final directory = await Directory.systemTemp.createTemp('iris-abort');
    addTearDown(() => directory.delete(recursive: true));

    void Function()? abort;
    final transfer = downloadAsset(
      asset: ReleaseAsset(
        name: 'package.bin',
        downloadUrl: 'http://127.0.0.1:${server.port}/package.bin',
        size: _total,
      ),
      onAbort: (handle) => abort = handle,
      directory: directory.path,
    );

    // The handle exists before the body does, so a cancel during a slow dial
    // does not have to wait out a 30 s header timeout.
    await _waitFor(() => abort != null);
    abort!();

    await expectLater(transfer, _thrownFailure(DownloadFailure.cancelled));
  });

  test('a transfer nobody stops still verifies and keeps the package',
      () async {
    final server = await _slowOrigin();
    addTearDown(() => server.close(force: true));
    final directory = await Directory.systemTemp.createTemp('iris-abort');
    addTearDown(() => directory.delete(recursive: true));

    final reported = <DownloadProgress>[];
    void Function()? abort;
    final file = await downloadAsset(
      asset: ReleaseAsset(
        name: 'package.bin',
        downloadUrl: 'http://127.0.0.1:${server.port}/package.bin',
        size: _total,
      ),
      onProgress: reported.add,
      onAbort: (handle) => abort = handle,
      directory: directory.path,
    );

    expect(await file.length(), _total);
    expect(reported.last, (received: _total, total: _total));

    // A stop that arrives after the package landed is a no-op, not a deletion
    // of the file the caller is about to install.
    abort!();
    expect(file.existsSync(), isTrue);
    expect(await file.length(), _total);
  });
}
