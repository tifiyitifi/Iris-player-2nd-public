import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.mediaProbe);

/// Result of one metadata backfill pass.
class MetadataBackfillOutcome {
  const MetadataBackfillOutcome({
    required this.visited,
    required this.written,
    required this.resolved,
    required this.failed,
    required this.cancelled,
    required this.timedOut,
    this.stalled = false,
  });

  static const MetadataBackfillOutcome none = MetadataBackfillOutcome(
    visited: 0,
    written: 0,
    resolved: 0,
    failed: 0,
    cancelled: false,
    timedOut: false,
  );

  /// Rows examined (including ones the probe could not read).
  final int visited;

  /// Rows whose `media_nodes` row was actually updated.
  ///
  /// A verification pass visits rows whose stored values already agree with the
  /// probe; rewriting those would churn the DB for nothing, so they count as
  /// visited + [resolved] but NOT written.
  final int written;

  /// Rows whose probe produced a usable duration (whether or not it changed
  /// anything). This is the "usable" figure a scan summary reports; [written]
  /// alone would read as 0%-usable on a rescan that found everything correct.
  final int resolved;

  /// Rows the probe could not resolve (unknown container, damaged header) or
  /// whose write hit no row.
  final int failed;

  final bool cancelled;
  final bool timedOut;

  /// The probe resolved NOTHING over a full [stallSample] window.
  ///
  /// Not the same as "not finished": this pass has proven it cannot read the
  /// content at all, so repeating it on the next batch (or in the background)
  /// would only spend the same budget again.
  final bool stalled;

  bool get isEmpty => visited == 0;

  @override
  String toString() => 'MetadataBackfill(visited=$visited written=$written '
      'resolved=$resolved failed=$failed cancelled=$cancelled '
      'timedOut=$timedOut stalled=$stalled)';
}

/// Fills `media_nodes.duration_ms` / dimensions for rows that do not have them.
///
/// WHY DB-driven: the work list is a query, not an in-memory queue. That makes
/// the pass idempotent, resumable across restarts, and safe to run while the
/// user plays — a 500k row list never has to be materialized in memory, and a
/// killed run simply continues from the next row on the next pass.
///
/// WHY batched ancestor recompute: `MediaNodeRepository.updateFileMediaInfo`
/// recomputes the duration aggregates up the whole path for EVERY file. That is
/// correct for a single playback write-back but quadratic-ish for a bulk pass
/// (500k files × path depth). Here each batch dedupes the affected parent
/// directories and recomputes each of them once.
class MetadataBackfillService {
  const MetadataBackfillService({
    this.dao,
    this.batchSize = 32,
  });

  /// Injectable DAO for tests; defaults to the wired instance at call time.
  final MediaNodesDao? dao;

  /// Probe batch size handed to [MediaProbeService.probeFiles].
  final int batchSize;

  /// Runs until the storage/root has no more missing metadata rows.
  ///
  /// [rootPath] limits the pass to one scanned source (canonical or rooted
  /// path; null/empty = whole storage). [maxFiles] caps a single pass (0 =
  /// unlimited). [budget] stops between batches — partial results are kept.
  /// [isCancelled] is polled between batches.
  ///
  /// [stallSample] ends the pass once that many rows were examined without a
  /// single usable duration (0 = never). The pass the user WAITS for uses it so
  /// an unreadable folder cannot spend the whole budget; a background pass
  /// leaves it off, where an early stop would only leave rows empty.
  ///
  /// [includeExisting] widens the work list from "rows without a duration" to
  /// EVERY playable row in scope (see
  /// [MediaNodesDao.listFilesForMetadata]). A rescan uses it: only a probe can
  /// repair a duration that a re-encode changed or an older cross-file
  /// write-back poisoned, because the listing carries no duration at all and the
  /// gap-filling list would never look at the row again.
  ///
  /// Never throws: a failed batch is logged and counted, and the pass moves on.
  Future<MetadataBackfillOutcome> run({
    required String storageId,
    required MediaProbeService probe,
    String? rootPath,
    int maxFiles = 0,
    Duration? budget,
    bool includeExisting = false,
    int stallSample = 0,
    bool Function()? isCancelled,
    void Function(int done, int total)? onProgress,
  }) async {
    final nodesDao = dao ?? (DbModule.isReady ? DbModule.mediaNodesDao : null);
    if (nodesDao == null) {
      // Unwired DB (tests / CLI): nothing to page over.
      return MetadataBackfillOutcome.none;
    }
    final stopwatch = Stopwatch()..start();
    var total = 0;
    try {
      total = await nodesDao.countFilesForMetadata(
        storageId,
        pathPrefix: rootPath,
        includeExisting: includeExisting,
      );
    } catch (e) {
      _log.w('[backfill] count failed: $e');
    }

    var visited = 0;
    var written = 0;
    var resolved = 0;
    var failed = 0;
    var afterId = 0;
    var cancelled = false;
    var timedOut = false;
    var stalled = false;
    // Directories that gained a duration during this pass. Recomputed ONCE, at
    // the end: doing it per batch walked the ancestor chain of every touched
    // directory every time, which on a phone volume was ~100k aggregate
    // recomputes (~9 minutes) for 20k files.
    final touchedDirs = <String>{};
    onProgress?.call(0, total);

    while (true) {
      if (isCancelled?.call() == true) {
        cancelled = true;
        break;
      }
      if (budget != null && stopwatch.elapsed >= budget) {
        timedOut = true;
        break;
      }
      if (maxFiles > 0 && visited >= maxFiles) break;

      List<
          ({
            int id,
            String path,
            String? uri,
            String name,
            int? sizeInBytes,
            int? durationMs,
            int? width,
            int? height,
          })> rows;
      try {
        rows = await nodesDao.listFilesForMetadata(
          storageId,
          pathPrefix: rootPath,
          afterId: afterId,
          limit: batchSize,
          includeExisting: includeExisting,
        );
      } catch (e) {
        _log.w('[backfill] page failed at id>$afterId: $e');
        break;
      }
      if (rows.isEmpty) break;
      afterId = rows.last.id;

      final uris = [
        for (final row in rows)
          // Row paths are stored relative to the storage base, so the probe
          // target must restore it (see
          // [StoragePathCodec.playableUriForStored]); without that every target
          // loses its drive letter and the whole pass resolves nothing.
          StoragePathCodec.playableUriForStored(
            storageId,
            row.path,
            uri: row.uri,
          ),
      ];
      List<ProbeResult> results;
      // One batch is one `probeFiles` round trip, and the isolate pool's own
      // ceiling is 30 s (a worker stuck on a cold or odd file). The pass the
      // user is WAITING on only promised [budget], so this batch is bounded by
      // what is left of it — otherwise "starts in a few seconds" becomes
      // "starts in 30 s". Background passes carry no budget and keep the pool's
      // ceiling (a late result there is still useful, just not worth waiting).
      final Duration? batchBudget =
          budget == null ? null : budget - stopwatch.elapsed;
      try {
        final Future<List<ProbeResult>> pending = probe.probeFiles(uris);
        results = batchBudget == null
            ? await pending
            : await pending.timeout(
                batchBudget.isNegative ? Duration.zero : batchBudget,
                onTimeout: () =>
                    List<ProbeResult>.filled(uris.length, ProbeResult.empty),
              );
      } catch (e) {
        // One poison file must not fail its batch: retry as guarded singles.
        _log.w('[backfill] batch failed, retrying as singles: $e');
        results = [
          for (final uri in uris)
            await _probeSingle(probe, uri),
        ];
      }

      final touchedBatchDirs = <String>{};
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        final sane = sanitizeProbeResult(
          i < results.length ? results[i] : ProbeResult.empty,
        );
        final durationMs = sane.durationMs;
        if (durationMs == null || durationMs <= 0) {
          failed++;
          continue;
        }
        resolved++;
        // A verification pass re-probes rows that already carry values. Writing
        // them back unchanged would be one UPDATE per file per rescan for
        // nothing, and the ancestors would be recomputed for no reason either.
        final bool sameDuration = row.durationMs == durationMs;
        final bool sameWidth = sane.width == null || sane.width == row.width;
        final bool sameHeight = sane.height == null || sane.height == row.height;
        if (sameDuration && sameWidth && sameHeight) continue;
        try {
          final updated = await nodesDao.updateFileMediaInfo(
            storageId: storageId,
            path: row.path,
            durationMs: durationMs,
            width: sane.width,
            height: sane.height,
            pixelCount: sane.pixelCount,
          );
          if (updated <= 0) {
            failed++;
            continue;
          }
          written++;
          final slash = row.path.lastIndexOf('/');
          if (slash > 0) touchedBatchDirs.add(row.path.substring(0, slash));
        } catch (e) {
          _log.w('[backfill] write failed ${row.path}: $e');
          failed++;
        }
      }

      // One ancestor recompute per affected directory, not per file.
      touchedDirs.addAll(touchedBatchDirs);

      visited += rows.length;
      onProgress?.call(visited, total > 0 ? total : visited);
      // A probe that resolved nothing across a full sample is broken, not slow:
      // stop instead of spending the rest of the budget (and a background pass)
      // on rows it provably cannot read.
      if (stallSample > 0 && visited >= stallSample && resolved == 0) {
        stalled = true;
        break;
      }
      // Cooperative yield: this runs on the UI isolate next to playback.
      await Future<void>.delayed(Duration.zero);
    }

    await _recomputeTouchedAggregates(nodesDao, storageId, touchedDirs);

    final outcome = MetadataBackfillOutcome(
      visited: visited,
      written: written,
      resolved: resolved,
      failed: failed,
      cancelled: cancelled,
      timedOut: timedOut,
      stalled: stalled,
    );
    if (visited > 0) {
      _log.i('[backfill] $outcome storage=$storageId root=${rootPath ?? ''}');
    }
    return outcome;
  }

  /// Recomputes the duration aggregate of every touched directory and its
  /// ancestors, each exactly ONCE and deepest-first.
  ///
  /// WHY the set algebra: a parent's total must include its children's updated
  /// totals, so parents have to run after children; and a directory shared by
  /// many files (every file in a folder touches the same parent chain) must not
  /// be recomputed once per file. Doing it per batch instead cost ~100k
  /// full-row aggregate queries for a 20k-file library.
  static Future<void> _recomputeTouchedAggregates(
    MediaNodesDao nodesDao,
    String storageId,
    Set<String> touchedDirs,
  ) async {
    if (touchedDirs.isEmpty) return;
    final closure = <String>{};
    for (final dir in touchedDirs) {
      var current = dir;
      while (current.isNotEmpty) {
        closure.add(current);
        final slash = current.lastIndexOf('/');
        current = slash > 0 ? current.substring(0, slash) : '';
      }
    }
    final ordered = closure.toList()
      ..sort((a, b) => _depthOf(b).compareTo(_depthOf(a)));
    for (final dir in ordered) {
      try {
        await nodesDao.recomputeDurationAggregate(storageId, dir);
      } catch (e) {
        _log.w('[backfill] aggregate recompute failed at $dir: $e');
      }
    }
  }

  static int _depthOf(String path) {
    var depth = 1;
    for (var i = 0; i < path.length; i++) {
      if (path.codeUnitAt(i) == 0x2F) depth++;
    }
    return depth;
  }

  Future<ProbeResult> _probeSingle(
      MediaProbeService probe, String uri) async {
    try {
      return await probe.probeFile(uri);
    } catch (_) {
      return ProbeResult.empty;
    }
  }
}
