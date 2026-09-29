import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';
import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = AreaKeyLog(LogKeys.appUpdate);

/// Progress of one download, reported as it happens so the dialog can move
/// without polling the file.
typedef DownloadProgress = ({int received, int total});

/// Receives the means to stop a transfer, as soon as there is one.
///
/// Registered before the response headers, so a cancel during a slow connect
/// ends the exchange instead of waiting on a body nobody is going to read. The
/// supplied callback is idempotent and may be called after the transfer has
/// already finished, where it does nothing.
typedef DownloadAbortRegistrar = void Function(void Function() abort);

/// Raised when a download cannot be completed. [reason] maps to a message the
/// user can act on; [UpdateFetchException] is deliberately not reused because
/// these failures are about bytes, not about reachability.
class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.reason, {this.detail});

  final DownloadFailure reason;
  final String? detail;

  @override
  String toString() => 'UpdateDownloadException($reason, $detail)';
}

enum DownloadFailure {
  /// The transfer ended before the promised byte count.
  interrupted,

  /// The file on disk is not the size the release advertised.
  sizeMismatch,

  /// The digest does not match the published checksum.
  hashMismatch,

  /// The host answered, but not with the package: 404 for an asset the release
  /// no longer publishes, 403 (refused as a bot), 429 (the anonymous rate
  /// limit), 5xx (GitHub or its gateway is down) or a proxy's own error page.
  /// [UpdateDownloadException.detail] carries the status, which is what decides
  /// the sentence the reader gets.
  http,

  /// The bytes arrived but the file could not be written: no space left on the
  /// device, or a directory the app may not write. Nothing left the network.
  storage,

  /// The host could not be reached at all.
  network,

  /// The caller stopped the transfer on purpose. Never surfaced as a problem:
  /// the user is the one who asked, and the partial file is already gone.
  cancelled,
}

/// Downloads a release asset to a local file, verifying it.
///
/// Verification is what makes an unsigned download trustworthy: the byte count
/// comes from the release payload, and the digest from the checksum file the
/// release publishes alongside the packages. A download that fails either check
/// is deleted rather than left for an installer to run.
///
/// [onAbort] is the way out for a caller that is no longer interested; without
/// it the transfer simply runs to completion, as it did before.
Future<File> downloadAsset({
  required ReleaseAsset asset,
  String? expectedSha256,
  void Function(DownloadProgress)? onProgress,
  HttpClient? client,
  DownloadAbortRegistrar? onAbort,
  String? directory,
}) async {
  final ownsClient = client == null;
  final http = client ?? HttpClient();
  if (ownsClient) http.connectionTimeout = const Duration(seconds: 10);

  final target = File(
    p.join(directory ?? await _downloadDirectory(), asset.name),
  );
  // Prepared before the transfer so the sink handle is in reach of the cleanup
  // below, and classified here: a directory that cannot be created is the disk's
  // answer, and reporting it as a network problem sends the user to check a
  // connection that was never the reason.
  final IOSink sink;
  try {
    await target.parent.create(recursive: true);
    sink = target.openWrite();
  } on FileSystemException catch (error) {
    throw UpdateDownloadException(DownloadFailure.storage, detail: '$error');
  }
  final digest = AccumulatorSink<Digest>();
  final hashing = sha256.startChunkedConversion(digest);

  var received = 0;
  var completed = false;
  var sinkOpen = true;
  var stopped = false;
  StreamSubscription<List<int>>? subscription;
  // Completed by the body being exhausted OR by a stop, so awaiting it can never
  // outlive the caller's decision to walk away.
  final drained = Completer<void>();
  try {
    final request = await http.getUrl(Uri.parse(asset.downloadUrl));
    request.headers.set(HttpHeaders.userAgentHeader, 'IRIS-Update');
    // Handed over before the headers are awaited: a cancel during a slow dial
    // has to end the exchange, not queue up behind a body nobody will read.
    onAbort?.call(() {
      if (stopped) return;
      stopped = true;
      // Safe at any point and idempotent — it tears the connection down while
      // the headers are still pending, and closes the body stream afterwards.
      request.abort();
      unawaited(subscription?.cancel());
      if (!drained.isCompleted) drained.complete();
    });

    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      // A refusal is not a transfer that stopped early, and being throttled,
      // being turned away and GitHub being broken do not want the same words.
      // The status decides the sentence, so it has to survive to the dialog.
      throw UpdateDownloadException(
        DownloadFailure.http,
        detail: '${response.statusCode}',
      );
    }
    final total = asset.size > 0
        ? asset.size
        : response.contentLength >= 0
            ? response.contentLength
            : 0;

    // Subscribed by hand rather than with `await for`, so a stop can cut the
    // transfer instead of only unsubscribing the progress reader: without a
    // subscription in reach, a cancelled download keeps pulling ~186 MB out of
    // the network behind a window the user already closed.
    subscription = response.listen(
      (chunk) {
        if (stopped) return;
        sink.add(chunk);
        hashing.add(chunk);
        received += chunk.length;
        onProgress?.call((received: received, total: total));
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!drained.isCompleted) drained.completeError(error, stackTrace);
      },
      onDone: () {
        if (!drained.isCompleted) drained.complete();
      },
      cancelOnError: true,
    );
    await drained.future;
    if (stopped) {
      throw const UpdateDownloadException(DownloadFailure.cancelled);
    }
    await sink.flush();
    await sink.close();
    sinkOpen = false;
    hashing.close();

    final written = await target.length();
    if (asset.size > 0 && written != asset.size) {
      throw UpdateDownloadException(
        DownloadFailure.sizeMismatch,
        detail: '$written != ${asset.size}',
      );
    }
    if (expectedSha256 != null && expectedSha256.isNotEmpty) {
      final actual = digest.events.single.toString();
      if (actual.toLowerCase() != expectedSha256.toLowerCase()) {
        throw UpdateDownloadException(
          DownloadFailure.hashMismatch,
          detail: actual,
        );
      }
    }
    completed = true;
    return target;
  } catch (error) {
    // A stop is not a network problem, whatever the torn-down exchange threw on
    // its way out. Reporting it as one would offer the user a retry for a
    // transfer they deliberately ended.
    if (stopped) {
      throw const UpdateDownloadException(DownloadFailure.cancelled);
    }
    if (error is SocketException) {
      throw UpdateDownloadException(DownloadFailure.network, detail: '$error');
    }
    if (error is HttpException) {
      throw UpdateDownloadException(DownloadFailure.network, detail: '$error');
    }
    // Reached through flush/close, because an IOSink reports a failed write on
    // the future its next flush or close returns rather than at the add: the
    // bytes arrived and the disk refused them.
    if (error is FileSystemException) {
      throw UpdateDownloadException(DownloadFailure.storage, detail: '$error');
    }
    if (error is TimeoutException) {
      throw const UpdateDownloadException(DownloadFailure.interrupted);
    }
    rethrow;
  } finally {
    if (ownsClient) http.close(force: true);
    // Self-cleaning: a truncated, unverified or abandoned package must not
    // outlive the attempt, or a later run (or the user) could install it.
    if (!completed) {
      // Windows refuses to delete a file that is still open, and a cancelled
      // transfer is a routine way to land here with the sink holding it.
      if (sinkOpen) {
        try {
          await sink.close();
        } catch (error) {
          _log.w('could not close the abandoned download: $error');
        }
      }
      await discardDownload(target);
    }
  }
}

/// Removes a partially, unverified or abandoned download.
///
/// Called on every non-success path, and by a caller whose transfer finished
/// after the user gave up: a truncated or unwanted APK must not survive as
/// something the installer could later pick up.
Future<void> discardDownload(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (error) {
    _log.w('could not delete the failed download: $error');
  }
}

/// Parses a `SHA256SUMS.txt` body into `{fileName: digest}`.
///
/// Accepts both `sha256sum` output shapes (`<digest>  <name>` and
/// `<digest> *<name>`) and ignores comment lines, so the artifact the release
/// publishes can be consumed verbatim.
Map<String, String> parseSha256Sums(String body) {
  final result = <String, String>{};
  for (final rawLine in const LineSplitter().convert(body)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final digest = parts[0].toLowerCase();
    if (digest.length != 64) continue;
    var name = parts.sublist(1).join(' ');
    if (name.startsWith('*')) name = name.substring(1);
    if (name.startsWith('./')) name = name.substring(2);
    if (name.isEmpty) continue;
    result[name] = digest;
  }
  return result;
}

/// Fetches the published checksum index, or an empty map when it is absent.
///
/// A missing index is not a failure: the byte-count check still applies, and a
/// hard requirement would make every release without the file uninstallable.
///
/// Both deadlines matter, because the flow reads this before it opens its
/// progress window: a body that stops mid-answer without either of them leaves
/// the user on a dead interface, with no dialog to close and no transfer to
/// cancel. [url] and [readTimeout] exist so that deadline is exercisable
/// against a loopback origin; production always asks for the published one.
Future<Map<String, String>> fetchPublishedChecksums({
  required String tag,
  HttpClient? client,
  Duration readTimeout = const Duration(seconds: 15),
  String? url,
}) async {
  final ownsClient = client == null;
  final http = client ?? HttpClient();
  if (ownsClient) http.connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await http.getUrl(
      Uri.parse(
        url ??
            'https://github.com/tifiyitifi/Iris-player-2nd-public/releases/download/'
                '$tag/SHA256SUMS.txt',
      ),
    );
    request.headers.set(HttpHeaders.userAgentHeader, 'IRIS-Update');
    final response = await request.close().timeout(readTimeout);
    // Asked before the body is read: a refusal carries an error page (or no
    // body at all), and reading one is how a dead answer turns into a dead read.
    if (response.statusCode != 200) {
      // Drained so the connection can be released, under the same deadline: an
      // error page that never ends must not become the wait either.
      await response.drain<void>().timeout(readTimeout);
      return const <String, String>{};
    }
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(readTimeout);
    return parseSha256Sums(body);
  } catch (error) {
    _log.w('checksum index unavailable: $error');
    return const <String, String>{};
  } finally {
    if (ownsClient) http.close(force: true);
  }
}

/// Where downloads land.
///
/// Inside the app cache on both platforms: it is guaranteed writable (unlike
/// the install directory on Android, and unlike `Program Files` on Windows)
/// and it is where the Android file provider is already allowed to hand a path
/// to the system installer.
Future<String> _downloadDirectory() async {
  if (isAndroid) {
    return (await getTemporaryDirectory()).path;
  }
  return p.join((await getApplicationSupportDirectory()).path, 'updates');
}

/// Human-readable byte count for the progress dialog.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  final index = math.min(
    (math.log(bytes) / math.log(1024)).floor(),
    units.length - 1,
  );
  final value = bytes / math.pow(1024, index);
  return '${value.toStringAsFixed(index == 0 ? 0 : 1)} ${units[index]}';
}
