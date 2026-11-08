import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:iris/features/media_library/scan/probe/local_header_probe.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.mediaProbe);

/// Persistent worker pool for header-only container probes (MP4 / MKV / AVI).
///
/// WHY a pool: the previous strategy shipped one `Isolate.run` per 32-file
/// batch, so a 30k-file scan paid ~940 isolate spawns (~5–20 ms each) on top
/// of the actual work, and ran the batches strictly serially. Duration probing
/// is pure file IO + a few hundred byte compares per file, so N warm workers
/// turn the "wait for metadata" tier from tens of seconds into a few.
///
/// Results are exchanged as plain int lists (`[durationMs, width, height]`) so
/// no user-defined object has to cross an isolate boundary.
class LocalHeaderProbePool {
  LocalHeaderProbePool({this.size = 4});

  /// Worker count. Four is deliberate: local header reads are mostly syscall /
  /// AV-filter latency, so more workers stop helping quickly, and each one
  /// costs an isolate on the scan path.
  final int size;

  final ReceivePort _receive = ReceivePort();
  final List<Isolate> _isolates = [];
  final List<SendPort> _workers = [];
  final Map<int, ({Completer<List<ProbeResult>> completer, int length})>
      _pending = {};
  Future<void>? _ready;
  int _nextId = 0;
  int _roundRobin = 0;
  bool _disposed = false;

  /// Batch ceiling: a worker handles one message at a time, so oversized
  /// batches only delay the first result without improving throughput.
  static const int batchSize = 32;

  Future<void> _start() {
    return _ready ??= () async {
      _receive.listen((message) {
        if (message is SendPort) {
          _workers.add(message);
          return;
        }
        if (message is List) {
          final id = message[0] as int;
          final raw = message[1] as List;
          final results = <ProbeResult>[
            for (final r in raw)
              ProbeResult(
                durationMs: (r as List)[0] as int?,
                width: r[1] as int?,
                height: r[2] as int?,
              ),
          ];
          final pending = _pending.remove(id);
          if (pending != null && !pending.completer.isCompleted) {
            pending.completer.complete(results);
          }
        }
      });
      for (var i = 0; i < size; i++) {
        _isolates.add(await Isolate.spawn(_workerMain, _receive.sendPort));
      }
    }();
  }

  /// Probes [paths] across the worker pool, preserving input order.
  ///
  /// Never throws: an unusable worker (spawn failure, timeout) degrades to
  /// `ProbeResult.empty`, which the caller treats as "not resolved" and hands
  /// to the platform fallback.
  Future<List<ProbeResult>> probeBatch(List<String> paths) async {
    if (paths.isEmpty) return const [];
    if (_disposed || size <= 0) return _probeInline(paths);
    try {
      await _start();
    } catch (e) {
      _log.w('LocalHeaderProbePool start failed: $e');
      return _probeInline(paths);
    }
    if (_workers.isEmpty) return _probeInline(paths);

    final id = _nextId++;
    final completer = Completer<List<ProbeResult>>();
    _pending[id] = (completer: completer, length: paths.length);
    final worker = _workers[_roundRobin % _workers.length];
    _roundRobin++;
    worker.send([id, paths]);
    try {
      return await completer.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      _pending.remove(id);
      _log.w('LocalHeaderProbePool batch timed out (${paths.length} files)');
      return List<ProbeResult>.filled(paths.length, ProbeResult.empty);
    } catch (e) {
      _pending.remove(id);
      _log.w('LocalHeaderProbePool batch failed: $e');
      return List<ProbeResult>.filled(paths.length, ProbeResult.empty);
    }
  }

  Future<List<ProbeResult>> _probeInline(List<String> paths) async => [
        for (final p in paths)
          LocalHeaderProbe.tryReadSync(p) ?? ProbeResult.empty,
      ];

  /// Batches currently dispatched by [probeAll] (test seam).
  @visibleForTesting
  int debugInFlightBatches = 0;

  /// High-water mark of [debugInFlightBatches] (test seam).
  @visibleForTesting
  int debugMaxInFlightBatches = 0;

  /// Probes [paths] in [batchSize] chunks, keeping up to [size] chunks in
  /// flight, and returns one result per input path IN INPUT ORDER.
  ///
  /// WHY: dispatching the chunks serially (await one [probeBatch] after the
  /// other) left all but one worker idle, so a "wait for metadata" pass over a
  /// few thousand local files burned its time budget instead of finishing, and
  /// playback started before the duration order was complete.
  ///
  /// Concurrency is bounded by [size] because a worker handles one message at a
  /// time — sending more batches than workers only queues them. Results are
  /// placed by batch index, never by completion order.
  Future<List<ProbeResult>> probeAll(List<String> paths) async {
    if (paths.isEmpty) return const [];
    final batches = <List<String>>[];
    for (var start = 0; start < paths.length; start += batchSize) {
      batches.add(
        paths.sublist(start, (start + batchSize).clamp(0, paths.length)),
      );
    }

    final results = List<List<ProbeResult>?>.filled(batches.length, null);
    final limit = size <= 0 ? 1 : size;
    var next = 0;

    Future<void> drain() async {
      while (next < batches.length) {
        final index = next++;
        debugInFlightBatches++;
        if (debugInFlightBatches > debugMaxInFlightBatches) {
          debugMaxInFlightBatches = debugInFlightBatches;
        }
        try {
          results[index] = await probeBatch(batches[index]);
        } finally {
          debugInFlightBatches--;
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < limit && i < batches.length; i++) drain(),
    ]);

    return [for (final batch in results) ...?batch];
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final isolate in _isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    _isolates.clear();
    _workers.clear();
    for (final pending in _pending.values) {
      // Keep `probeBatch`'s contract: one result per requested file. A shorter
      // list would shift every result of the caller's batch.
      if (!pending.completer.isCompleted) {
        pending.completer.complete(
          List<ProbeResult>.filled(pending.length, ProbeResult.empty),
        );
      }
    }
    _pending.clear();
    _receive.close();
  }
}

void _workerMain(SendPort main) {
  final receive = ReceivePort();
  main.send(receive.sendPort);
  receive.listen((message) {
    if (message is! List) return;
    final id = message[0] as int;
    final paths = (message[1] as List).cast<String>();
    final out = <List<int?>>[];
    for (final path in paths) {
      final result = LocalHeaderProbe.tryReadSync(path);
      out.add([result?.durationMs, result?.width, result?.height]);
    }
    main.send([id, out]);
  });
}

/// Probe strategy that answers duration + dimensions from a local container
/// header (MP4/MOV, MKV/WebM, AVI) and delegates everything else to [fallback].
///
/// Ordering matters for the product, not just for speed: the fast path is what
/// makes "wait for metadata, then play in correct duration order" feasible for
/// a few thousand local files. Anything it cannot read (fragmented MP4, live
/// Matroska without a duration, `content://` URIs, unreadable headers) still
/// gets the platform probe, so no file loses metadata it had before.
class FastLocalProbeService implements MediaProbeService {
  FastLocalProbeService({
    required this.fallback,
    LocalHeaderProbePool? pool,
  }) : pool = pool ?? LocalHeaderProbePool();

  final MediaProbeService fallback;
  final LocalHeaderProbePool pool;

  @override
  Future<ProbeResult> probeFile(String target) async {
    final results = await probeFiles([target]);
    return results.isEmpty ? ProbeResult.empty : results.first;
  }

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async {
    if (targets.isEmpty) return const [];
    final out = List<ProbeResult?>.filled(targets.length, null);
    final fallbackIndexes = <int>[];
    final fastIndexes = <int>[];
    for (var i = 0; i < targets.length; i++) {
      if (_isLocalHeaderTarget(targets[i])) {
        fastIndexes.add(i);
      } else {
        fallbackIndexes.add(i);
      }
    }

    if (fastIndexes.isNotEmpty) {
      // One dispatch for the whole list: `probeAll` chunks it and keeps up to
      // `size` chunks in flight, so the workers actually run in parallel.
      final results = await pool.probeAll(
        [for (final i in fastIndexes) targets[i]],
      );
      for (var j = 0; j < fastIndexes.length; j++) {
        final result = j < results.length ? results[j] : ProbeResult.empty;
        if (result.durationMs != null) {
          out[fastIndexes[j]] = result;
        } else {
          // Unresolved (fragmented / truncated / weird): the platform probe may
          // still know it, so it must not be dropped.
          fallbackIndexes.add(fastIndexes[j]);
        }
      }
    }

    if (fallbackIndexes.isNotEmpty) {
      final fallbackResults = await fallback.probeFiles(
        [for (final i in fallbackIndexes) targets[i]],
      );
      for (var j = 0; j < fallbackIndexes.length; j++) {
        out[fallbackIndexes[j]] =
            j < fallbackResults.length ? fallbackResults[j] : ProbeResult.empty;
      }
    }

    return [for (final r in out) r ?? ProbeResult.empty];
  }

  Future<void> dispose() => pool.dispose();

  static bool _isLocalHeaderTarget(String target) {
    if (target.isEmpty) return false;
    // Android SAF documents and remote URLs never reach the filesystem parser.
    final lower = target.toLowerCase();
    if (lower.startsWith('content://') ||
        lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('ftp://')) {
      return false;
    }
    return LocalHeaderProbe.supportsPath(target);
  }
}
