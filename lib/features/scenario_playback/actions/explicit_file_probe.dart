import 'package:flutter/foundation.dart' show immutable;
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/media_library/scan/probe/scan_probe_preference.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.mediaProbe);

/// One explicit file awaiting a silent metadata probe.
@immutable
class ExplicitFileProbeTarget {
  const ExplicitFileProbeTarget({
    required this.storageId,
    required this.path,
    required this.uri,
    this.sizeInBytes,
    this.modifiedAt,
  });

  final String storageId;

  /// Canonical DB path (base-prefixed form accepted by the write-back).
  final String path;

  /// Playable URI handed to the probe service (SAF `content://` or a path).
  final String uri;

  /// Size from the listing that produced this target, when the lane could stat
  /// it. The queue sorts by size, so a dropped/added file must persist it even
  /// when the deep probe cannot open the container.
  final int? sizeInBytes;

  /// mtime from that same listing, when known (the queue sorts by it too).
  final DateTime? modifiedAt;
}

/// Storage-type probe seam; defaults to the storage store lookup.
typedef ExplicitProbeIsNetwork = bool Function(String storageId);

/// Outcome of a targeted explicit-file probe pass.
///
/// [touchedStorages] is the change-announcement set (feeds
/// [MediaRevisionActions]); [written] counts the files whose `media_nodes` row
/// was actually updated, so a summary can report real work instead of attempts.
typedef ExplicitProbeOutcome = ({Set<String> touchedStorages, int written});

/// Silently probes [targets] and writes usable duration/dimensions back to
/// `media_nodes` so dropped/added explicit files show their metadata without
/// waiting for the lazy per-play backfill.
///
/// A target's listing-derived [ExplicitFileProbeTarget.sizeInBytes] /
/// [ExplicitFileProbeTarget.modifiedAt] are written too, even when the probe
/// yields no duration: the queue sorts by them, so "rescan" has to be able to
/// heal a 0/NULL row on its own.
///
/// Mirrors the scan-time probe (`RecursiveScanService._probePlayableNodes`):
/// 32/批 via `probeFiles`, network storages (FTP/WebDAV) skipped, absurd
/// dimensions sanitized. Honors the persisted scan probe preference (unset →
/// default ON). Never throws: a failed batch degrades to unprobed files.
///
/// Returns the storages that actually received a write, so the caller can
/// announce the change through [MediaRevisionActions] exactly once.
Future<Set<String>> probeExplicitFiles(
  List<ExplicitFileProbeTarget> targets, {
  MediaProbeService? probeService,
  ExplicitProbeIsNetwork? isNetwork,
  int batchSize = 32,
  bool? probeEnabled,
}) async =>
    (await probeExplicitFilesDetailed(
      targets,
      probeService: probeService,
      isNetwork: isNetwork,
      batchSize: batchSize,
      probeEnabled: probeEnabled,
    ))
        .touchedStorages;

/// [probeExplicitFiles] with the number of rows actually written.
///
/// The scenario-wide refresh reports "N explicit items refreshed", which must
/// count real writes: a container the probe cannot read, or a file whose
/// `media_nodes` row is gone, is an attempt, not a refresh.
Future<ExplicitProbeOutcome> probeExplicitFilesDetailed(
  List<ExplicitFileProbeTarget> targets, {
  MediaProbeService? probeService,
  ExplicitProbeIsNetwork? isNetwork,
  int batchSize = 32,

  /// Overrides the persisted scan-probe preference; `null` reads it.
  ///
  /// `false` suppresses only the CONTAINER probe — the listing's size/mtime are
  /// still written back, because a probe-less profile must still be able to
  /// heal a 0/NULL size row through "rescan file/source".
  bool? probeEnabled,
}) async {
  if (targets.isEmpty) return (touchedStorages: const <String>{}, written: 0);

  final net = isNetwork ?? _defaultIsNetwork;
  final local = [for (final t in targets) if (!net(t.storageId)) t];
  if (local.isEmpty) return (touchedStorages: const <String>{}, written: 0);

  // Honor the user's scan-probe choice; never chosen → probe by default
  // (same "默认勾选扫描时间" rule as the scan options dialog). Creating the
  // service is skipped when disabled: on desktop it spins up an isolate pool.
  final enabled = probeEnabled ?? ((await ScanProbePreference.load()) != false);
  final probe = enabled ? (probeService ?? createMediaProbeService()) : null;

  final touched = <String>{};
  var written = 0;
  final size = batchSize <= 0 ? 32 : batchSize;
  for (var start = 0; start < local.length; start += size) {
    final end = (start + size).clamp(0, local.length);
    final batch = local.sublist(start, end);
    List<ProbeResult> results = const <ProbeResult>[];
    if (probe != null) {
      try {
        results = await probe.probeFiles([for (final t in batch) t.uri]);
      } catch (e) {
        // One poison file (isolate spawn failure, channel error) must not fail
        // the whole run; skip the batch and keep going.
        _log.w('[explicit-probe] batch failed at $start: $e');
        continue;
      }
    }
    for (var i = 0; i < batch.length; i++) {
      final target = batch[i];
      final sane = sanitizeProbeResult(
        i < results.length ? results[i] : ProbeResult.empty,
      );
      final durationMs = sane.durationMs;
      final hasDuration = durationMs != null && durationMs > 0;
      final hasSize = target.sizeInBytes != null && target.sizeInBytes! > 0;
      final hasMtime = target.modifiedAt != null;
      // The listing's physical facts are worth a write on their own: the queue
      // sorts by size/mtime, and a container the probe cannot open (or a run
      // with probing disabled) must still heal a 0/NULL row. The old
      // "duration-only" gate is exactly why "rescan source" never fixed sizes.
      if (!hasDuration && !hasSize && !hasMtime) continue;
      try {
        final rows = await DbModule.mediaNodeRepo.updateFileMediaInfo(
          storageId: target.storageId,
          path: target.path,
          durationMs: hasDuration ? durationMs : null,
          width: hasDuration ? sane.width : null,
          height: hasDuration ? sane.height : null,
          sizeInBytes: hasSize ? target.sizeInBytes : null,
          modifiedAt: target.modifiedAt,
        );
        if (rows > 0) {
          touched.add(target.storageId);
          written++;
        }
      } catch (e) {
        _log.w('[explicit-probe] write-back failed: $e');
      }
    }
    // Keep the UI responsive on a large drop; the probe is background work.
    await Future<void>.delayed(Duration.zero);
  }
  if (written > 0) {
    _log.i('[explicit-probe] refreshed $written file(s) '
        'across ${touched.length} storage(s)');
  }
  return (touchedStorages: touched, written: written);
}

bool _defaultIsNetwork(String storageId) {
  final type = useStorageStore().findById(storageId)?.type;
  return type == StorageType.ftp ||
      type == StorageType.webdav ||
      type == StorageType.network;
}
