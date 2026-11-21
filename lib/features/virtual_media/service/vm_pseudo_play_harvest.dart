import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_stream/media_stream.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/service/vm_duration_scan.dart'
    show VmScanOutcome, VmWriteBack, defaultVmWriteBack;
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/l10n/app_localizations_en.dart';
import 'package:iris/models/storages/ftp.dart' show getFTPAuth;
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/storages/webdav.dart' show getWebDAVAuth;
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/utils/path_conv.dart';

final _log = AreaKeyLog(LogKeys.mediaProbe);

/// One harvested file's media info (null = unobtainable).
typedef HarvestedMedia = ({int durationMs, int? width, int? height});

/// Opens [seg] in a background player and resolves its media info.
///
/// Returns null when unobtainable. Never throws (failures degrade to null):
/// the harvest loop additionally guards with a per-file timeout, so a
/// hanging opener can only cost its budget, never the run.
typedef VmHarvestOpener = Future<HarvestedMedia?> Function(VirtualSegment seg);

/// Background duration harvest over EXACTLY [segments].
///
/// Scope-strict: the caller passes only the failed virtual group's segments
/// (never the library) — the last resort of the efficiency cascade, after
/// the Shell scan, for files whose property handler returns nothing usable
/// (A/B-pinned: VT_EMPTY duration, garbage height) and for FTP, which has
/// no scan-time probing at all.
///
/// - Write-back is incremental (same drift seam as the Shell scan), so
///   cancellation/timeout keeps partial results.
/// - Never touches the play queue or any player-facing store — only the
///   media_nodes columns. The main player is undisturbed (separate Player
///   instance owned by the opener).
/// - Never throws: opener errors degrade to per-segment failures.
Future<VmScanOutcome> harvestVmDurations(
  List<VirtualSegment> segments, {
  required VmHarvestOpener opener,
  VmWriteBack? writeBack,
  bool Function()? shouldCancel,
  void Function(int done, int total, String name)? onProgress,
  Duration perFileTimeout = const Duration(seconds: 20),
  Duration totalBudget = const Duration(minutes: 1),
  AppLocalizations? l10n,
}) async {
  final stopwatch = Stopwatch()..start();
  final persist = writeBack ?? defaultVmWriteBack;

  final failedKeys = <String>[];
  final succeededKeys = <String>[];
  var scanned = 0;
  var done = 0;

  VmScanOutcome finish({bool cancelled = false, bool timedOut = false}) {
    stopwatch.stop();
    final outcome = VmScanOutcome(
      ok: failedKeys.isEmpty && !cancelled && !timedOut,
      scanned: scanned,
      skipped: 0,
      succeededKeys: List.unmodifiable(succeededKeys),
      failedKeys: List.unmodifiable(failedKeys),
      elapsed: stopwatch.elapsed,
      cancelled: cancelled,
      timedOut: timedOut,
    );
    _log.i('[vm-harvest] done ${outcome.summary(l10n ?? AppLocalizationsEn())} total=${segments.length}');
    if (failedKeys.isNotEmpty) {
      _log.w('[vm-harvest] failed sample: ${failedKeys.take(3).join(',')}');
    }
    return outcome;
  }

  // Global ceiling mirrors the preflight budget: 100 files x 20s would
  // otherwise block for ~33min. Cancellation is honored BETWEEN files only.
  // Budget expiry reports timedOut (partial results kept) — distinct from a
  // user cancel, which aborts the whole playback.
  for (final s in segments) {
    if (shouldCancel?.call() == true) {
      return finish(cancelled: true);
    }
    if (stopwatch.elapsed > totalBudget) {
      return finish(timedOut: true);
    }
    HarvestedMedia? got;
    try {
      got = await opener(s).timeout(perFileTimeout);
    } on TimeoutException {
      got = null;
    } catch (_) {
      got = null;
    }
    if (got != null) {
      // Sanitize every opener's output (not just production): malformed
      // w/h would otherwise pollute resolution sorting downstream.
      final sane = sanitizeProbeResult(ProbeResult(
        durationMs: got.durationMs,
        width: got.width,
        height: got.height,
      ));
      if (sane.durationMs == null || sane.durationMs! <= 0) {
        got = null;
      } else {
        got = (
          durationMs: sane.durationMs!,
          width: sane.width,
          height: sane.height
        );
      }
    }
    if (got != null && got.durationMs > 0) {
      try {
        final written = await persist(
          storageId: s.storageId,
          path: canonicalDbPath(s.path.join('/')),
          durationMs: got.durationMs,
          width: got.width,
          height: got.height,
        );
        if (written) {
          scanned++;
          succeededKeys.add(s.mediaKey);
        } else {
          _log.w('[vm-harvest] write-back no-op (no media_nodes row) ${s.mediaKey}');
          failedKeys.add(s.mediaKey);
        }
      } catch (e) {
        _log.w('[vm-harvest] write-back failed ${s.mediaKey}: $e');
        failedKeys.add(s.mediaKey);
      }
    } else {
      failedKeys.add(s.mediaKey);
    }
    done++;
    onProgress?.call(done, segments.length, s.name);
    if (shouldCancel?.call() == true) {
      return finish(cancelled: true);
    }
  }
  return finish();
}

/// Production opener: one background media_kit [Player] REUSED for the whole
/// scan (no video controller, no rendering surface). It opens each segment
/// with `play: false` purely to read `duration` (+ video dims when available).
///
/// One Player per scan (current scheme): creating and disposing a Player per
/// file hits media_kit's disposal race (a late wakeup after
/// `mpv_terminate_destroy` aborts the process). `stop()` clears the previous
/// file's playlist/state before the next open; the duration stream is
/// broadcast with no replay, so a value from the previous file cannot be
/// replayed to the next wait. The trade-off is that a late event that arrives
/// after the next open depends on that stop/broadcast guarantee — the stub
/// opener test does not exercise the production sequence.
///
/// URI/header construction mirrors the player hooks exactly
/// (`use_media_kit_player` open block): FTP goes through the local
/// `MediaStream` proxy with FTP auth, WebDAV uses its direct URL with WebDAV
/// auth, local files use the sanitized playable path. Volume is forced to 0
/// as a belt-and-braces measure (nothing should audible-play with
/// `play: false` regardless).
class MediaKitHarvestOpener {
  MediaKitHarvestOpener({Duration perFileTimeout = const Duration(seconds: 20)})
      : _perFileTimeout = perFileTimeout;

  final Duration _perFileTimeout;

  /// ONE Player per scan opener, reused for every file and disposed ONCE when
  /// the scan ends.
  ///
  /// Creating and disposing a Player per file hits media_kit's disposal race:
  /// it closes the mpv wakeup `NativeCallable` before `mpv_terminate_destroy`
  /// joins the core thread, and a late wakeup then aborts the process (SIGABRT
  /// "Callback invoked after it has been deleted") — observed while a video was
  /// already playing. Reusing one instance cuts that risk from once per file to
  /// once per scan; `stop()` clears each file's playlist/state before the next
  /// open.
  Player? _player;

  Player _ensurePlayer() => _player ??= Player();

  Future<HarvestedMedia?> call(VirtualSegment seg) async {
    final player = _ensurePlayer();
    try {
      final target = _openTarget(seg);
      if (target == null) return null;
      // Clear the previous file first. The duration stream is broadcast (no
      // replay), so a stale value cannot satisfy the wait below.
      try {
        await player.stop();
      } catch (_) {}
      try {
        await player.setVolume(0);
      } catch (_) {}
      await player.open(
        Media(target.uri, httpHeaders: target.headers),
        play: false,
      );
      // Duration arrives via demux on open (proven by durationArrived on
      // ordinary opens); dims are best-effort with a short budget.
      final dur = await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(_durationBudget());
      int? w;
      int? h;
      try {
        final vp = await player.stream.videoParams
            .firstWhere((v) => (v.w ?? 0) > 0 && (v.h ?? 0) > 0)
            .timeout(const Duration(seconds: 2));
        w = vp.w;
        h = vp.h;
      } on TimeoutException {
        // Dims optional; duration is the must-have.
      }
      final sane = sanitizeProbeResult(ProbeResult(
          durationMs: dur.inMilliseconds, width: w, height: h));
      if (sane.durationMs == null || sane.durationMs! <= 0) return null;
      return (
        durationMs: sane.durationMs!,
        width: sane.width,
        height: sane.height
      );
    } catch (_) {
      return null;
    } finally {
      // Leave the reused Player idle; [dispose] releases it once per scan.
      try {
        await player.stop();
      } catch (_) {}
    }
  }

  Duration _durationBudget() {
    final budget = _perFileTimeout - const Duration(seconds: 3);
    return budget < const Duration(seconds: 5)
        ? const Duration(seconds: 5)
        : budget;
  }

  /// Releases the reused Player once the scan is over. Kept as a single
  /// deliberate disposal (not per file) so the media_kit disposal race is hit at
  /// most once per scan, while the app is normally still active.
  Future<void> dispose() async {
    final player = _player;
    _player = null;
    if (player == null) return;
    try {
      await player.stop();
    } catch (_) {}
    try {
      await player.dispose();
    } catch (_) {}
  }


  /// Builds the exact open target the player hooks would use for [seg].
  /// Null when unresolvable (FTP proxy down). The storage lookup is
  /// defensive: without a store entry the segment is treated as local
  /// (same graceful-degradation posture as the player hooks' fallbacks).
  ({String uri, Map<String, String> headers})? _openTarget(
      VirtualSegment seg) {
    Storage? storage;
    try {
      storage = useStorageStore().findById(seg.storageId);
    } catch (_) {
      storage = null;
    }
    final type = storage?.type ?? StorageType.none;
    if (type == StorageType.ftp && storage is FTPStorage) {
      // This is a direct Media() consumer, so it prepends the proxy itself;
      // the relative part is shared with every other producer.
      final proxy = MediaStream().url;
      if (proxy == null || proxy.isEmpty) return null;
      return (
        uri: '$proxy/${ftpPlayableUri(storage, seg.path)}',
        headers: {'authorization': getFTPAuth(storage)}
      );
    }
    if (type == StorageType.webdav && storage is WebDAVStorage) {
      // Derived from the storage record (scheme/port + the CURRENT host), the
      // same way every MediaNode→FileItem producer builds it — a wildcard entry
      // must never be dialled as `192.168.*.*`.
      return (
        uri: webdavPlayableUri(storage, seg.path),
        headers: {'authorization': getWebDAVAuth(storage)}
      );
    }
    return (
      // SAF rows carry their real content:// document uri; plain rows fall
      // back to the rebuilt playable path.
      uri: sanitizePlayableUri(nodePlayableUri(seg.path, uri: seg.uri)),
      headers: const <String, String>{}
    );
  }
}
