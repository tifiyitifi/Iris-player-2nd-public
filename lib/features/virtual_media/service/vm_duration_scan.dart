import 'package:flutter/material.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/service/vm_preflight_coordinator.dart'
    show kVmPreflightBudget;
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/l10n/app_localizations_en.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

final _log = AreaKeyLog(LogKeys.mediaProbe);

/// Outcome of a duration backfill scan over one virtual group's segments.
class VmScanOutcome {
  /// True when every probed segment got a usable duration.
  final bool ok;
  final bool cancelled;
  final bool timedOut;
  final int scanned;
  final int skipped;

  /// Canonical mediaKeys that got a usable duration and were written back.
  final List<String> succeededKeys;

  /// Every key that did not produce a usable duration (probe-empty OR a
  /// successful probe whose write-back found no row).
  final List<String> failedKeys;

  /// The subset of [failedKeys] whose probe genuinely returned no duration
  /// (VT_EMPTY). Only these may be fast-skipped for the rest of the session;
  /// a write-back no-op can succeed on a later scan once the row exists.
  final List<String> shellEmptyKeys;
  final Duration elapsed;
  final String? report;

  const VmScanOutcome({
    required this.ok,
    required this.scanned,
    required this.skipped,
    required this.succeededKeys,
    required this.failedKeys,
    required this.elapsed,
    this.shellEmptyKeys = const [],
    this.cancelled = false,
    this.timedOut = false,
    this.report,
  });

  /// One-line human-readable summary for logs and dialogs.
  String summary(AppLocalizations t) {
    final parts = <String>[t.vm_scan_part_ok(scanned)];
    if (skipped > 0) parts.add(t.vm_scan_part_skipped(skipped));
    if (failedKeys.isNotEmpty) {
      parts.add(t.vm_scan_part_failed(failedKeys.length));
    }
    if (cancelled) parts.add(t.vm_scan_part_cancelled);
    if (timedOut) parts.add(t.vm_scan_part_timeout);
    final secs = (elapsed.inMilliseconds / 1000).toStringAsFixed(1);
    return t.vm_scan_summary(parts.join(t.vm_scan_part_sep), secs);
  }
}

/// Write-back seam (defaults to the drift repository).
///
/// Returns `true` when a media_nodes row was actually written; `false` when
/// the file has no row (a silent no-op that must NOT be reported as a
/// successful scan).
typedef VmWriteBack = Future<bool> Function({
  required String storageId,
  required String path,
  int? durationMs,
  int? width,
  int? height,
});

/// Storage-type seam (defaults to the storage store lookup).
typedef VmStorageTypeOf = StorageType Function(String storageId);

/// Shared drift write-back seam used by the Shell scan and the
/// pseudo-play harvest alike (single choke point for duration persistence).
Future<bool> defaultVmWriteBack({
  required String storageId,
  required String path,
  int? durationMs,
  int? width,
  int? height,
}) async {
  final rows = await DbModule.mediaNodeRepo.updateFileMediaInfo(
    storageId: storageId,
    path: path,
    durationMs: durationMs,
    width: width,
    height: height,
  );
  return rows > 0;
}

/// Single-file probe that never throws: failures degrade to an empty result
/// so one poison file cannot fail its whole batch (see the retry path in
/// [scanVmGroupDurations]).
Future<ProbeResult> _probeSingle(
    MediaProbeService probe, VirtualSegment s) async {
  try {
    return await probe.probeFile(nodePlayableUri(s.path, uri: s.uri));
  } catch (_) {
    return ProbeResult.empty;
  }
}

/// One segment's persist outcome: usable probes write back, failures degrade
/// to a failed key — never throws, so a batch [Future.wait] always settles.
Future<({bool ok, bool shellEmpty, String mediaKey})> _persistOne(
  VmWriteBack persist,
  VirtualSegment s,
  ProbeResult raw,
) async {
  final r = sanitizeProbeResult(raw);
  if (r.durationMs == null || r.durationMs! <= 0) {
    return (ok: false, shellEmpty: true, mediaKey: s.mediaKey);
  }
  try {
    final written = await persist(
      storageId: s.storageId,
      path: canonicalDbPath(s.path.join('/')),
      durationMs: r.durationMs,
      width: r.width,
      height: r.height,
    );
    if (!written) {
      // The probe succeeded but there is no media_nodes row to land on:
      // report a failure (truthful summary + leftover), not a phantom OK.
      // NOT shell-empty: a later scan can succeed once the row exists.
      _log.w('[vm-scan] write-back no-op (no media_nodes row) ${s.mediaKey}');
      return (ok: false, shellEmpty: false, mediaKey: s.mediaKey);
    }
    return (ok: true, shellEmpty: false, mediaKey: s.mediaKey);
  } catch (e) {
    _log.w('[vm-scan] write-back failed ${s.mediaKey}: $e');
    return (ok: false, shellEmpty: false, mediaKey: s.mediaKey);
  }
}

/// Batch-probes durations for [segments] and writes usable results back to
/// the database so the group can merge on the next resolve.
///
/// - Mirrors `RecursiveScanService._probePlayableNodes`: 32/batch via
///   `probeFiles`, network storages (FTP/WebDAV) skipped (never probed —
///   high latency, no shell).
/// - Incremental write-back: every usable probe is persisted immediately, so
///   cancellation/timeout keeps partial results.
/// - [skipKeys]: mediaKeys whose Shell handler is already known empty this
///   session (MP4s whose property handler returns VT_EMPTY for duration —
///   only demux can read them). They fail fast without a probe round-trip so
///   repeat scans route straight to the harvest confirm.
/// - Never throws: batch errors degrade to per-segment failures.
Future<VmScanOutcome> scanVmGroupDurations(
  List<VirtualSegment> segments, {
  void Function(int done, int total, String name)? onProgress,
  MediaProbeService? probeService,
  VmWriteBack? writeBack,
  VmStorageTypeOf? storageTypeOf,
  bool Function()? shouldCancel,
  int batchSize = 32,
  Duration budget = kVmPreflightBudget,
  Set<String>? skipKeys,
  AppLocalizations? l10n,
}) async {
  final stopwatch = Stopwatch()..start();
  final probe = probeService ?? createMediaProbeService();
  final persist = writeBack ?? defaultVmWriteBack;
  final typeOf =
      storageTypeOf ?? ((id) => useStorageStore().findById(id)?.type ?? StorageType.none);
  final typeCache = <String, StorageType>{};

  bool isNetwork(VirtualSegment s) {
    final t = typeCache.putIfAbsent(s.storageId, () => typeOf(s.storageId));
    return t == StorageType.ftp ||
        t == StorageType.webdav ||
        t == StorageType.network;
  }

  final failedKeys = <String>[];
  final succeededKeys = <String>[];
  final shellEmptyKeys = <String>[];
  var scanned = 0;
  var skipped = 0;
  var done = 0;
  // Remaining work is over `local` ONLY. `done` also counts known rows and
  // skipKeys, so `local.length - done` can go negative in a mixed group.
  var localDone = 0;

  VmScanOutcome finish(
      {bool cancelled = false, bool timedOut = false, String? report}) {
    stopwatch.stop();
    // Terminal progress sample: network/unknown leftovers are never probed, so
    // without this the caller's bar could freeze below 100% (e.g. 7/10) even
    // though the scan is done. Reports the full caller-visible total once.
    if (segments.isNotEmpty) {
      onProgress?.call(segments.length, segments.length, segments.last.name);
    }
    final outcome = VmScanOutcome(
      ok: failedKeys.isEmpty && !cancelled && !timedOut,
      scanned: scanned,
      skipped: skipped,
      succeededKeys: List.unmodifiable(succeededKeys),
      failedKeys: List.unmodifiable(failedKeys),
      shellEmptyKeys: List.unmodifiable(shellEmptyKeys),
      elapsed: stopwatch.elapsed,
      cancelled: cancelled,
      timedOut: timedOut,
      report: report,
    );
    // Observability: every scan leaves one summary line so a "no data"
    // outcome is attributable (probe-empty vs write-back miss vs skip).
    // Pure-log line: locale comes from the caller when available, otherwise
    // the compiled-in English strings (same as other release logs).
    _log.i('[vm-scan] done ${outcome.summary(l10n ?? AppLocalizationsEn())} '
        'total=${segments.length}');
    if (failedKeys.isNotEmpty) {
      _log.w('[vm-scan] failed sample: ${failedKeys.take(3).join(',')}');
    }
    return outcome;
  }

  final skippedKeys = skipKeys ?? const <String>{};

  // Session-known Shell-empty files fail fast before batching (no probe
  // round-trip); they still advance progress so the bar stays truthful.
  // Only UNKNOWN-duration skips are counted here: a skip key that already
  // carries a positive duration is counted by [knownCount] instead, so the
  // two accounting paths can never double-count the same segment (which used
  // to push `done` past the total).
  if (skippedKeys.isNotEmpty) {
    for (final s in segments) {
      if (skippedKeys.contains(s.mediaKey) &&
          !isNetwork(s) &&
          (s.durationMs ?? 0) <= 0) {
        failedKeys.add(s.mediaKey);
        done++;
      }
    }
    if (done > 0) {
      onProgress?.call(done, segments.length, segments.last.name);
    }
  }

  // Never re-probe segments that already carry a positive duration (the
  // caller may pass a whole group; only unknowns need shell time).
  final knownCount =
      segments.where((s) => (s.durationMs ?? 0) > 0).length;
  final local = segments
      .where((s) =>
          (s.durationMs ?? 0) <= 0 &&
          !isNetwork(s) &&
          !skippedKeys.contains(s.mediaKey))
      .toList(growable: false);
  // Progress denominator is the caller-visible total; known-duration rows
  // count as already done so bars with mixed groups still reach 100%.
  done += knownCount;
  skipped = segments.length - local.length - done;
  if (skipped > 0) {
    _log.w('[vm-scan] skipped $skipped network segment(s), '
        'probing ${local.length} local');
  }

  final size = batchSize <= 0 ? 32 : batchSize;
  for (var start = 0; start < local.length; start += size) {
    if (shouldCancel?.call() == true) {
      return finish(cancelled: true);
    }
    if (stopwatch.elapsed > budget) {
      final t = l10n ?? AppLocalizationsEn();
      final report = t.vm_scan_timeout(budget.inSeconds, scanned,
          local.length, local.length - localDone);
      _log.e('[vm-scan] TIMEOUT $report');
      return finish(timedOut: true, report: report);
    }
    final end = (start + size).clamp(0, local.length);
    final batch = local.sublist(start, end);
    List<ProbeResult> results;
    try {
      // SAF segments carry their real content:// document uri — probe that
      // (native MMR accepts content://) instead of a rebuilt path.
      results = await probe.probeFiles(
        [for (final s in batch) nodePlayableUri(s.path, uri: s.uri)],
      );
    } catch (e) {
      // One poison file (isolate spawn failure, channel error) must not fail
      // the other 31: retry as singles — each guarded, successes persist.
      _log.w('[vm-scan] batch failed, retrying as singles: $e');
      results = [for (final s in batch) await _probeSingle(probe, s)];
    }
    // Post-probe gate: a slow batch may have blown the budget while probing
    // (the loop-top check only sees batch boundaries). Persist what's in hand
    // below (incremental contract), then stop instead of starting new work.
    final overBudget = stopwatch.elapsed > budget;
    // Overlapped write-back: each segment's persist is two self-contained DB
    // round trips (drift serializes them safely), so awaiting them together
    // overlaps Dart-side gaps instead of summing 32 sequential latencies.
    // Results fold in batch order (Future.wait preserves it), keeping
    // succeeded/failed key order deterministic.
    final outcomes = await Future.wait([
      for (var i = 0; i < batch.length; i++)
        _persistOne(
          persist,
          batch[i],
          i < results.length ? results[i] : ProbeResult.empty,
        ),
    ]);
    for (final o in outcomes) {
      if (o.ok) {
        scanned++;
        succeededKeys.add(o.mediaKey);
      } else {
        failedKeys.add(o.mediaKey);
        if (o.shellEmpty) shellEmptyKeys.add(o.mediaKey);
      }
    }
    done += batch.length;
    localDone += batch.length;
    onProgress?.call(done, segments.length, batch.last.name);
    if (overBudget) {
      final t = l10n ?? AppLocalizationsEn();
      final report = t.vm_scan_timeout(
          budget.inSeconds, scanned, local.length, local.length - localDone);
      _log.e('[vm-scan] TIMEOUT $report');
      return finish(timedOut: true, report: report);
    }
  }
  return finish();
}

/// Scan-or-cancel choice when a would-be virtual group degrades for missing
/// durations.
///
/// Returns true for "scan now", false for "cancel merge (normal playback)".
/// Barrier taps / back button count as cancel (null → false at the call
/// site).
Future<bool?> showVmDurationScanDialog(
  NavigatorState navigator, {
  required String groupName,
  required List<String> unknownNames,
  required int totalSegments,
}) async {
  if (!navigator.mounted) return false;
  return showDialog<bool>(
    context: navigator.context,
    builder: (context) {
      final t = getLocalizations(context);
      final shown = unknownNames.take(3).join(', ');
      final names = unknownNames.length > 3
          ? '$shown, ${t.vm_sheet_more_items(unknownNames.length)}'
          : shown;
      return AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.amber),
        title: Text(t.vm_dscan_title),
        content: Text(
          t.vm_dscan_body(
              groupName, totalSegments, unknownNames.length, names),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.vm_dscan_play_normal),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.vm_dscan_scan_now),
          ),
        ],
      );
    },
  );
}

/// Runs [task] under a blocking progress dialog with a Cancel button.
///
/// [task] receives a progress reporter and a cancellation poll; cancelling
/// pops the dialog and [task] is expected to stop promptly (its partial
/// results are kept by the scan itself).
///
/// [cancelLabel] names the stop action (scan vs harvest phrasing). The caller
/// decides what a cancellation MEANS: for the duration scan/harvest it keeps
/// the partial results and continues normal playback, never aborts the whole
/// session.
Future<VmScanOutcome> scanWithProgressDialog(
  NavigatorState navigator, {
  required String title,
  required int total,
  required Future<VmScanOutcome> Function(
    void Function(int done, int total, String name) onProgress,
    bool Function() isCancelled,
  ) task,
  String? cancelLabel,
}) async {
  final progress = ValueNotifier<({int done, String name})>((done: 0, name: ''));
  var cancelled = false;
  BuildContext? dialogContext;
  var dialogDone = false;
  final dialogFuture = showDialog<void>(
    context: navigator.context,
    barrierDismissible: false,
    builder: (context) {
      dialogContext = context;
      final t = getLocalizations(context);
      return AlertDialog(
        title: Text(title),
        content: ValueListenableBuilder<({int done, String name})>(
          valueListenable: progress,
          builder: (context, p, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: total <= 0 ? null : p.done / total,
              ),
              const SizedBox(height: 12),
              Text('$p.done/$total · ${p.name}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(context);
            },
            child: Text(cancelLabel ?? t.vm_dscan_cancel_scan),
          ),
        ],
      );
    },
  ).then((_) => dialogDone = true);
  VmScanOutcome outcome;
  try {
    outcome = await task(
      (done, _, name) {
        progress.value = (done: done, name: name);
      },
      () => cancelled,
    );
  } finally {
    // The Cancel button already popped the dialog when cancelled==true.
    // Otherwise close via the dialog's own context — never pop blindly
    // (that would dismiss the underlying page). The route push is async,
    // so wait briefly for it to land when the task finished first.
    if (!cancelled && !dialogDone) {
      for (var i = 0; i < 100 && dialogContext == null && !dialogDone; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final ctx = dialogContext;
      if (ctx != null && ctx.mounted) {
        Navigator.of(ctx).pop();
      }
    }
    await dialogFuture;
    // Dispose only after the route is fully gone: the exit animation may
    // still rebuild the ValueListenableBuilder, which re-subscribes.
    progress.dispose();
  }
  return outcome;
}
