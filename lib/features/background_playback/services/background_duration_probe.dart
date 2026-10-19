import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart' show StorageType;
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

final _log = AreaKeyLog(LogKeys.mediaProbe);

/// Result of one 副音 duration probe pass over a queue page.
class BgDurationProbeOutcome {
  const BgDurationProbeOutcome({
    required this.resolvedKeys,
    required this.failedKeys,
    required this.skippedNetworkKeys,
  });

  static const BgDurationProbeOutcome none = BgDurationProbeOutcome(
    resolvedKeys: <String>[],
    failedKeys: <String>[],
    skippedNetworkKeys: <String>[],
  );

  /// Media keys whose duration was probed AND written back to `media_nodes`.
  final List<String> resolvedKeys;

  /// Media keys the probe could not resolve, or whose write-back hit no
  /// `media_nodes` row. The queue list flags them and the alignment refuses to
  /// map against them.
  final List<String> failedKeys;

  /// Media keys on a NETWORK storage. Probing those mid-playback stalls the
  /// session (the same rule the VM duration scan follows), so they stay unknown
  /// WITHOUT being reported as an error.
  final List<String> skippedNetworkKeys;

  bool get isEmpty =>
      resolvedKeys.isEmpty && failedKeys.isEmpty && skippedNetworkKeys.isEmpty;

  @override
  String toString() => 'BgDurationProbe(resolved=${resolvedKeys.length} '
      'failed=${failedKeys.length} network=${skippedNetworkKeys.length})';
}

/// Whether a storage type is one the probe deliberately skips (see
/// [BgDurationProbeOutcome.skippedNetworkKeys]).
bool isNetworkStorageType(StorageType t) =>
    t == StorageType.ftp || t == StorageType.webdav || t == StorageType.network;

/// Durations of [queue] resolved from `media_nodes`, keyed by
/// [backgroundMediaKey]. A missing/vanished row, or a non-positive duration, is
/// simply absent — never a fabricated `0` (see [BgQueueTimeline]).
///
/// A SAF single-picked file has an EMPTY segment path and carries its identity
/// in its document `uri`, so a path-keyed lookup cannot see its row; the queue's
/// uris are resolved too, and the result re-keyed with [canonicalProgressKey]
/// (NOT `canonicalKey(storageId, occurrencePath)`) so a uri-keyed row round-trips
/// to the live file's [backgroundMediaKey] even when the uri is not tree-shaped.
///
/// The ONE read used by both the resolved-key set below and the 副音 timeline
/// reader in `background_runtime_scope` — keep them on this single reader so the
/// two halves can never disagree about which file is "known".
Future<Map<String, int>> resolvedBgDurationsByKey(List<FileItem> queue) async {
  if (queue.isEmpty || !DbModule.isReady) return const <String, int>{};
  try {
    final keys = <String>{for (final f in queue) backgroundMediaKey(f)};
    final uris = <String>{
      for (final f in queue)
        if (f.path.isEmpty && f.uri.isNotEmpty) f.uri,
    };
    final nodes = await DbModule.mediaNodeRepo
        .nodesByMediaKeysOrUris(keys, alsoByUris: uris);
    final out = <String, int>{};
    for (final n in nodes) {
      final f = n.maybeMap(file: (v) => v, orElse: () => null);
      final d = f?.durationMs;
      if (f == null || d == null || d <= 0) continue;
      out[canonicalProgressKey(f.storageId, f.path, uri: f.uri)] = d;
    }
    return out;
  } catch (_) {
    return const <String, int>{};
  }
}

/// Media keys of [queue] that already carry a usable duration in `media_nodes`.
///
/// Keys are the SAME space [backgroundMediaKey] uses (so a SAF single-picked
/// file is keyed by its document uri, exactly like `MediaNode.occurrencePath`).
Future<Set<String>> resolvedBgDurationKeys(List<FileItem> queue) async {
  if (queue.isEmpty || !DbModule.isReady) return const <String>{};
  return (await resolvedBgDurationsByKey(queue)).keys.toSet();
}

/// Default write-back: the single choke point for duration persistence
/// (`media_nodes`), shared with the VM duration scan.
Future<int> _defaultWriteBack({
  required String storageId,
  required String path,
  required int durationMs,
}) =>
    DbModule.mediaNodeRepo.updateFileMediaInfo(
      storageId: storageId,
      path: path,
      durationMs: durationMs,
    );

/// Probes every entry of [queue] whose duration `media_nodes` does not carry and
/// writes the result back.
///
/// WHY: the 副音 queue's virtual timeline is built from these durations. A
/// missing one used to be recorded as 0, which silently collapsed 副音's
/// position onto its head and — through the 连续锁步 drift correction — dragged
/// the video there (「开启副音把播放进度归 0」). Unresolved entries are now
/// REPORTED instead of faked (the queue list flags them in red).
///
/// Mirrors the VM duration scan: 32/batch, network storages skipped, a missing
/// `media_nodes` row counts as a FAILURE (never a phantom OK), and one poison
/// file cannot fail its batch (a failed batch retries as singles).
Future<BgDurationProbeOutcome> probeMissingBgDurations(
  List<FileItem> queue, {
  MediaProbeService? probeService,
  bool Function(String storageId)? isNetwork,
  Future<int> Function({
    required String storageId,
    required String path,
    required int durationMs,
  })? writeBack,
  int batchSize = 32,
}) async {
  if (queue.isEmpty) return BgDurationProbeOutcome.none;
  // A queue only exists once the DB is wired; a store-free caller (tests) may
  // still run a pass when it injects its own write-back.
  if (!DbModule.isReady && writeBack == null)
    return BgDurationProbeOutcome.none;
  final resolved = await resolvedBgDurationKeys(queue);
  final probe = probeService ?? createMediaProbeService();
  final net = isNetwork ??
      ((id) => isNetworkStorageType(
            useStorageStore().findById(id)?.type ?? StorageType.none,
          ));
  final persist = writeBack ?? _defaultWriteBack;

  final failed = <String>[];
  final network = <String>[];
  final written = <String>[];
  final todo = <FileItem>[];
  for (final f in queue) {
    final key = backgroundMediaKey(f);
    if (resolved.contains(key)) continue;
    if (net(f.storageId)) {
      network.add(key);
      continue;
    }
    todo.add(f);
  }
  if (todo.isEmpty) {
    return BgDurationProbeOutcome(
      resolvedKeys: const <String>[],
      failedKeys: const <String>[],
      skippedNetworkKeys: network,
    );
  }

  final size = batchSize <= 0 ? 32 : batchSize;
  for (var start = 0; start < todo.length; start += size) {
    final end = (start + size).clamp(0, todo.length);
    final batch = todo.sublist(start, end);
    List<ProbeResult> results;
    try {
      results = await probe.probeFiles(
        [for (final f in batch) nodePlayableUri(f.path, uri: f.uri)],
      );
    } catch (e) {
      // One poison file (isolate spawn failure, channel error) must not fail the
      // rest: retry as singles, each guarded.
      _log.w('[bg-duration] batch failed, retrying as singles: $e');
      results = [];
      for (final f in batch) {
        try {
          results.add(
            await probe.probeFile(nodePlayableUri(f.path, uri: f.uri)),
          );
        } catch (_) {
          results.add(ProbeResult.empty);
        }
      }
    }
    for (var i = 0; i < batch.length; i++) {
      final f = batch[i];
      final key = backgroundMediaKey(f);
      final r = sanitizeProbeResult(
        i < results.length ? results[i] : ProbeResult.empty,
      );
      final int? d = r.durationMs;
      if (d == null || d <= 0) {
        failed.add(key);
        continue;
      }
      try {
        final rows = await persist(
          storageId: f.storageId,
          // The row's canonical path: the storage-relative path, or the SAF
          // document uri for a single-pick whose path is empty (that row stores
          // the uri as its path — see [backgroundOccurrencePath]). Writing
          // `f.path.join('/')` here addressed the empty path and could only ever
          // hit whichever single pick happened to own it.
          path: backgroundOccurrencePath(f),
          durationMs: d,
        );
        if (rows <= 0) {
          // Probed fine but there is no row to land on: report a failure
          // (truthful flag + red row), never a phantom success.
          _log.w('[bg-duration] write-back no-op (no media_nodes row) $key');
          failed.add(key);
          continue;
        }
        written.add(key);
      } catch (e) {
        _log.w('[bg-duration] write-back failed $key: $e');
        failed.add(key);
      }
    }
  }

  final outcome = BgDurationProbeOutcome(
    resolvedKeys: List.unmodifiable(written),
    failedKeys: List.unmodifiable(failed),
    skippedNetworkKeys: List.unmodifiable(network),
  );
  _log.i('[bg-duration] $outcome (queue=${queue.length})');
  return outcome;
}

/// Persists the live duration the 副音 engine reported for the file it just
/// opened — the cheapest probe there is (the file is already demuxed), and the
/// same lazy backfill the foreground hook performs.
///
/// [path] must be the file's `media_nodes` canonical path
/// ([backgroundOccurrencePath]) — the SAF document uri for a path-less
/// single-pick — or the write lands on the wrong row.
///
/// Returns true when a `media_nodes` row was actually written.
Future<bool> writeBackBgLiveDuration({
  required String storageId,
  required String path,
  required int durationMs,
}) async {
  if (!DbModule.isReady || durationMs <= 0) return false;
  try {
    final rows = await _defaultWriteBack(
      storageId: storageId,
      path: path,
      durationMs: durationMs,
    );
    if (rows <= 0) return false;
    _log.i('[bg-duration] live backfill ${canonicalKey(storageId, path)} '
        'dur=${durationMs}ms');
    return true;
  } catch (e) {
    _log.w('[bg-duration] live backfill failed: $e');
    return false;
  }
}
