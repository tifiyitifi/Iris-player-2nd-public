import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';
import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/features/app_update/services/github_release_source.dart';
import 'package:iris/utils/app_paths.dart';
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
  Duration bodyTimeout = kUpdateDownloadBodyTimeout,
}) async {
  final ownsClient = client == null;
  final http = client ?? HttpClient();
  if (ownsClient) http.connectionTimeout = const Duration(seconds: 10);

  final finalTarget = File(
    p.join(directory ?? await updatePackageDirectory(), asset.name),
  );
  // Each attempt writes its OWN temp file and only a fully verified package is
  // renamed onto [finalTarget]. The path used to be exactly `asset.name`, so
  // two attempts (a double-tapped install) wrote one file: a failing attempt's
  // cleanup deleted the other's bytes, and a truncated file could land on the
  // final name. The temp suffix sits outside `*.zip`, so a manual updater run
  // never mistakes a half-written file for a package.
  final target = File('${finalTarget.path}.part-${_partSuffix()}');
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
        // Overrun fuse: a peer that keeps streaming past the advertised byte
        // count is not the package that was verified for. Cut it now — the
        // end-of-transfer size check only runs once the body ENDS, which an
        // endless stream never does. Completing the drained future with the
        // failure (without setting `stopped`, so it is not reclassified as a
        // cancel) aborts the wait and the `finally` disposes the sink.
        if (total > 0 && received + chunk.length > total) {
          if (!drained.isCompleted) {
            drained.completeError(UpdateDownloadException(
              DownloadFailure.sizeMismatch,
              detail: 'overrun ${received + chunk.length} > $total',
            ));
          }
          unawaited(subscription?.cancel());
          return;
        }
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
    // A body with no bytes at all still has a deadline; the header timeout above
    // does not cover it.
    await drained.future.timeout(bodyTimeout);
    if (stopped) {
      throw const UpdateDownloadException(DownloadFailure.cancelled);
    }
    await sink.flush();
    await sink.close();
    sinkOpen = false;
    hashing.close();

    final written = await target.length();
    // The release's size when it carried one, else the transport's own count:
    // `asset.size > 0` alone meant a size-less asset skipped the byte check
    // entirely and was trusted on the digest — or, with no index either, on
    // nothing at all.
    final expectedBytes = advertisedDownloadSize(
      assetSize: asset.size,
      contentLength: response.contentLength,
    );
    if (expectedBytes > 0 && written != expectedBytes) {
      throw UpdateDownloadException(
        DownloadFailure.sizeMismatch,
        detail: '$written != $expectedBytes',
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
    // Publish atomically: every consumer keys off the final name (the pending
    // record, the updater's own directory scan, the manual-retry hint), so the
    // verified bytes must be moved into place before the caller sees them.
    await _publishDownload(target, finalTarget);
    completed = true;
    return finalTarget;
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

/// A per-attempt suffix that keeps two concurrent transfers off one path.
///
/// Microseconds make two attempts in the same millisecond distinct; the random
/// tail covers two attempts starting on the same microsecond (a re-entrant
/// tap). Neither piece is security-relevant: the temp is always deleted or
/// renamed within the same call.
String _partSuffix() =>
    '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 30)}';

/// Moves a fully verified temp download onto its final name.
///
/// Windows refuses `rename` onto an existing file, so a stale package (a
/// previous attempt, or a manual run) is removed first. Last-write-wins is
/// correct here: both names denote the same release asset.
Future<void> _publishDownload(File temp, File finalTarget) async {
  try {
    if (await finalTarget.exists()) await finalTarget.delete();
    await temp.rename(finalTarget.path);
  } on FileSystemException catch (error) {
    throw UpdateDownloadException(DownloadFailure.storage, detail: '$error');
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

/// The checksum index a release publishes, plus whether it could be read at all.
///
/// The two questions are different and the caller has to be able to tell them
/// apart:
///
///  * [fetched] is false when there was no index to read — the release does not
///    publish one, the host answered 404/403/429, the body never ended, or the
///    network was down. The byte count is then the only check, which is
///    fail-OPEN by design (a hard requirement would make every release without
///    the file uninstallable) but must be SAID OUT LOUD rather than silently
///    skipped;
///  * [authoritative] is true only when an index was read AND it names at least
///    one asset. An asset MISSING from an authoritative index is an
///    inconsistency in the release, and a byte count is no substitute for a
///    digest: that is fail-CLOSED.
class PublishedChecksums {
  const PublishedChecksums({required this.sums, required this.fetched});

  /// The index was not readable at all.
  const PublishedChecksums.unavailable()
      : sums = const <String, String>{},
        fetched = false;

  /// `{fileName: sha256}` as published.
  final Map<String, String> sums;

  /// Whether an index was read.
  final bool fetched;

  /// Whether this index may be used as the authority on which assets the
  /// release legitimately publishes. An index that was read but names nothing
  /// (an empty or unparsable body) says nothing about this asset, so it is
  /// treated as unavailable rather than as "every asset was withdrawn".
  bool get authoritative => fetched && sums.isNotEmpty;

  /// The published digest for [assetName], or null when the index does not
  /// name it (or was never read).
  String? checksumFor(String assetName) => sums[assetName];
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

/// What the published index implies for one asset.
enum ChecksumVerdict {
  /// The index names this asset: the digest is checked.
  verified,

  /// The index was read, is usable, and does NOT name this asset. The release is
  /// inconsistent, and a byte count cannot stand in for a digest: refuse.
  unlisted,

  /// There is no usable index at all (not published, unreadable, or names
  /// nothing), but the release DID advertise a byte count. The byte count is the
  /// only check, which must be SAID OUT LOUD.
  noIndex,

  /// There is no usable index AND the release advertised no size either: nothing
  /// about the transfer can be verified, and the only thing left is the `PK`
  /// magic number in the archive header (see `planWindowsUpdate`). Refuse — that
  /// is a shape a proxy can substitute.
  unverifiable,
}

/// The checksum policy, as one expression, so the flow cannot drift from it.
///
/// [advertisedSize] is the byte count the release payload carried for this asset
/// (0 when it carried none). It only decides whether the fail-open [noIndex]
/// path is available at all: with no digest and no byte count there is no
/// verification anchor left, which is [unverifiable].
ChecksumVerdict classifyPublishedChecksum(
  PublishedChecksums index,
  String assetName, {
  int advertisedSize = 0,
}) {
  if (index.checksumFor(assetName) != null) return ChecksumVerdict.verified;
  if (index.authoritative) return ChecksumVerdict.unlisted;
  return advertisedSize > 0
      ? ChecksumVerdict.noIndex
      : ChecksumVerdict.unverifiable;
}

/// Whether a package classified as [verdict] may be DOWNLOADED at all.
///
/// The one place the refusal policy is expressed, so the flow cannot drift from
/// it. Only two shapes may proceed:
///
///  * [ChecksumVerdict.verified] — a published digest pins the bytes;
///  * [ChecksumVerdict.noIndex] — no usable index, but the release advertised a
///    size, so the transfer is still pinned to a byte count.
///
/// [ChecksumVerdict.unlisted] (the index is authoritative and silent about this
/// asset) and [ChecksumVerdict.unverifiable] (nothing to verify against) must
/// never reach a download — let alone an installer. Any NEW verdict is refused
/// by default until it is deliberately allowed here.
bool checksumVerdictAllowsDownload(ChecksumVerdict verdict) =>
    verdict == ChecksumVerdict.verified || verdict == ChecksumVerdict.noIndex;

/// The byte count a finished download must end up with.
///
/// The release's own `size` when it has one, else the transport's
/// `Content-Length` — a size-less payload must still be pinned to something, or
/// the byte check silently disappears (`contentLength` is -1 when the response
/// is framed by connection close alone, and then nothing is known: 0).
int advertisedDownloadSize({
  required int assetSize,
  required int contentLength,
}) =>
    assetSize > 0 ? assetSize : (contentLength >= 0 ? contentLength : 0);

/// Hard ceiling on one response BODY, i.e. the time from the first byte to the
/// last. The header has its own 30s deadline; a body had none, so a slow drip
/// that trickled forever (or a peer that held the socket open without ever
/// sending the final byte) stranded the progress window until the user
/// cancelled by hand. Generous on purpose: a large package over a slow link is
/// the normal case, an endless one is the bug.
const Duration kUpdateDownloadBodyTimeout = Duration(minutes: 30);

/// Re-checks a package that was verified at download time but may since have
/// been replaced before the hand-off.
///
/// The downloader verifies the digest and byte count and then names the file;
/// between that and the moment an installer or updater is started there is a
/// window in which the file could be swapped (a hostile local process, a
/// half-written manual retry). Re-reading it here closes that window: a
/// mismatch must refuse the hand-off, not install.
///
/// Returns null when the package still matches, else the reason it does not.
/// [digestOf] exists so the digest step is exercisable without a real 186 MB
/// package; production hashes the file.
Future<DownloadFailure?> verifyDownloadedPackage({
  required File package,
  required int expectedSize,
  String? expectedSha256,
  Future<String> Function(File file)? digestOf,
}) async {
  try {
    if (!await package.exists()) return DownloadFailure.storage;
    final length = await package.length();
    if (expectedSize > 0 && length != expectedSize) {
      return DownloadFailure.sizeMismatch;
    }
    if (expectedSha256 != null && expectedSha256.isNotEmpty) {
      final actual = await (digestOf ?? _sha256OfFile)(package);
      if (actual.toLowerCase() != expectedSha256.toLowerCase()) {
        return DownloadFailure.hashMismatch;
      }
    }
  } catch (error) {
    _log.w('could not re-verify ${package.path} before hand-off: $error');
    return DownloadFailure.storage;
  }
  return null;
}

/// Streams [file] through SHA-256 without holding it in memory.
Future<String> _sha256OfFile(File file) async {
  final digest = AccumulatorSink<Digest>();
  final hashing = sha256.startChunkedConversion(digest);
  await for (final chunk in file.openRead()) {
    hashing.add(chunk);
  }
  hashing.close();
  return digest.events.single.toString();
}

/// Fetches the published checksum index.
///
/// Never throws and never returns null: an index that cannot be read comes back
/// as [PublishedChecksums.unavailable], which the caller is expected to ACT on
/// (tell the reader the digest check is not happening) instead of swallowing —
/// the previous "empty map" shape made an absent index indistinguishable from
/// "this asset is not listed", and both ended in a silently unverified install.
///
/// The URL is built from [UpdateSource.repoSlug], so a repository rename cannot
/// leave the digest check pointing at the old one.
///
/// Both deadlines matter, because the flow reads this before it opens its
/// progress window: a body that stops mid-answer without either of them leaves
/// the user on a dead interface, with no dialog to close and no transfer to
/// cancel. [url] and [readTimeout] exist so that deadline is exercisable
/// against a loopback origin; production always asks for the published one.
Future<PublishedChecksums> fetchPublishedChecksums({
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
      Uri.parse(url ?? UpdateSource.checksumUrl(tag)),
    );
    request.headers.set(HttpHeaders.userAgentHeader, 'IRIS-Update');
    final response = await request.close().timeout(readTimeout);
    // Asked before the body is read: a refusal carries an error page (or no
    // body at all), and reading one is how a dead answer turns into a dead read.
    if (response.statusCode != 200) {
      // Drained so the connection can be released, under the same deadline: an
      // error page that never ends must not become the wait either.
      await response.drain<void>().timeout(readTimeout);
      return const PublishedChecksums.unavailable();
    }
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(readTimeout);
    return PublishedChecksums(sums: parseSha256Sums(body), fetched: true);
  } catch (error) {
    _log.w('checksum index unavailable: $error');
    return const PublishedChecksums.unavailable();
  } finally {
    if (ownsClient) http.close(force: true);
  }
}

/// Where downloaded update packages land.
///
/// Portable mode keeps them inside `<userdata>/updates`, for the same reason
/// everything else lives there: the directory is writable by definition (it was
/// write-probed at startup), it travels with the folder, and the user can find
/// the package to run `portable_update_by_zip.bat` by hand when an automatic
/// hand-off did not go through.
///
/// Everywhere else it is the app's support directory: guaranteed writable
/// (unlike the install directory on Android, and unlike `Program Files` on
/// Windows) and the place the Android file provider is already allowed to hand
/// to the system installer.
Future<String> updatePackageDirectory() async {
  if (isAndroid) {
    return (await getTemporaryDirectory()).path;
  }
  final layout = AppPaths.layout;
  if (AppPaths.isPortable && layout != null) {
    return p.join(layout.rootPath, 'updates');
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
