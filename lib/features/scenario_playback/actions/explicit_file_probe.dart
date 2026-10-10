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
  });

  final String storageId;

  /// Canonical DB path (base-prefixed form accepted by the write-back).
  final String path;

  /// Playable URI handed to the probe service (SAF `content://` or a path).
  final String uri;
}

/// Storage-type probe seam; defaults to the storage store lookup.
typedef ExplicitProbeIsNetwork = bool Function(String storageId);

/// Silently probes [targets] and writes usable duration/dimensions back to
/// `media_nodes` so dropped/added explicit files show their metadata without
/// waiting for the lazy per-play backfill.
///
/// Mirrors the scan-time probe (`RecursiveScanService._probePlayableNodes`):
/// 32/批 via `probeFiles`, network storages (FTP/WebDAV) skipped, absurd
/// dimensions sanitized. Honors the persisted scan probe preference (unset →
/// default ON). Never throws: a failed batch degrades to unprobed files.
///
/// Returns the set of storage ids that actually received a write, so the
/// caller can announce the change through [MediaRevisionActions] exactly once.
Future<Set<String>> probeExplicitFiles(
  List<ExplicitFileProbeTarget> targets, {
  MediaProbeService? probeService,
  ExplicitProbeIsNetwork? isNetwork,
  int batchSize = 32,
}) async {
  if (targets.isEmpty) return const {};
  // Honor the user's scan-probe choice; never chosen → probe by default
  // (same "默认勾选扫描时间" rule as the scan options dialog).
  final preference = await ScanProbePreference.load();
  if (preference == false) return const {};

  final probe = probeService ?? createMediaProbeService();
  final net = isNetwork ?? _defaultIsNetwork;
  final local = [for (final t in targets) if (!net(t.storageId)) t];
  if (local.isEmpty) return const {};

  final touched = <String>{};
  final size = batchSize <= 0 ? 32 : batchSize;
  for (var start = 0; start < local.length; start += size) {
    final end = (start + size).clamp(0, local.length);
    final batch = local.sublist(start, end);
    List<ProbeResult> results;
    try {
      results = await probe.probeFiles([for (final t in batch) t.uri]);
    } catch (e) {
      // One poison file (isolate spawn failure, channel error) must not fail
      // the whole run; skip the batch and keep going.
      _log.w('[explicit-probe] batch failed at $start: $e');
      continue;
    }
    for (var i = 0; i < batch.length; i++) {
      final sane = sanitizeProbeResult(
        i < results.length ? results[i] : ProbeResult.empty,
      );
      if (sane.durationMs == null || sane.durationMs! <= 0) continue;
      try {
        final rows = await DbModule.mediaNodeRepo.updateFileMediaInfo(
          storageId: batch[i].storageId,
          path: batch[i].path,
          durationMs: sane.durationMs,
          width: sane.width,
          height: sane.height,
        );
        if (rows > 0) touched.add(batch[i].storageId);
      } catch (e) {
        _log.w('[explicit-probe] write-back failed: $e');
      }
    }
    // Keep the UI responsive on a large drop; the probe is background work.
    await Future<void>.delayed(Duration.zero);
  }
  return touched;
}

bool _defaultIsNetwork(String storageId) {
  final type = useStorageStore().findById(storageId)?.type;
  return type == StorageType.ftp ||
      type == StorageType.webdav ||
      type == StorageType.network;
}
