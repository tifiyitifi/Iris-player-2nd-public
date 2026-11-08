import 'dart:async';
import 'dart:io' show Directory;

import 'package:flutter/material.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/db/dao/media_lib_sources_dao.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/media_library/scan/service/metadata_backfill_service.dart';
import 'package:iris/features/media_library/scan/service/metadata_wait_policy.dart';
import 'package:iris/features/media_library/scan/service/scan_lease.dart';
import 'package:iris/features/media_library/scan/service/scan_profiler.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/features/scenario_playback/actions/media_revision_actions.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/saf_document_uri_index.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/cooperative_yield.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:path/path.dart' as p;

final areaKeyLog = AreaKeyLog(LogKeys.legacyDb);

/// Ancestor `directory` rows that [rel] still needs, given the directories this
/// run has already visited.
///
/// A depth-first walk visits ancestors BEFORE their descendants and every
/// visited directory writes its own row, so on a full-volume scan this list is
/// empty for every directory. The backfill still matters for a scan that
/// STARTS mid-tree (a dropped folder, a resumed segment), where the chain above
/// the root was never walked.
///
/// WHY the pre-check: the backfill used to issue `INSERT OR IGNORE` for every
/// ancestor of every directory regardless. Measured on a 34,005-directory phone
/// volume (AOT profile), that was 221,757 inserts costing 44.6 s — every one of
/// them a no-op, because the rows already existed.
///
/// Paths are storage-relative and compared exactly as the scan stores them in
/// its visited set (see `_visitedDirs`).
@visibleForTesting
List<MediaNode> missingAncestorNodes({
  required String storageId,
  required String rel,
  required Set<String> visited,
}) {
  if (rel.isEmpty) return const <MediaNode>[];
  final segments = rel.split('/');
  final ancestors = <MediaNode>[];
  var parent = '';
  for (var i = 1; i < segments.length; i++) {
    final name = segments[i - 1];
    final path = parent.isEmpty ? name : '$parent/$name';
    if (!visited.contains(path)) {
      ancestors.add(MediaNode.directory(
        id: '$storageId:$path',
        storageId: storageId,
        path: path.split('/'),
        parentPath: parent.isEmpty ? null : parent,
        pathDepth: i,
        name: name,
      ));
    }
    parent = path;
  }
  return ancestors;
}

/// Above this many playable files a scan stops WAITING for the metadata pass.
///
/// 30k local files are ~5 s warm / ~30鈥?0 s cold even with the header probe, and
/// the accepted wait is "a few seconds to a dozen"; beyond that the play gate is
/// released after the enumeration and metadata fills in behind playback.
const int kFastMetadataFileLimit = 30000;

/// Upper bound on simultaneously in-flight directory LISTINGS for one run.
///
/// Each listing is one provider round trip (SAF `content://` costs tens of ms
/// even for an empty folder), so overlapping a few hides that latency. The cap
/// is applied by [RecursiveScanService] as a run-wide semaphore around the
/// listing call — NOT per directory level: nested child workers all compete for
/// the same slots, otherwise a deep tree would open `3^depth` listings at once.
const int kScanMaxConcurrency = 3;

/// How the metadata pass the caller WAITED for ended.
enum MetadataPassOutcome {
  /// The whole work list was probed.
  complete,

  /// Stopped while still productive: the budget ran out, or the measured
  /// throughput showed the rest cannot finish inside it. Playback is released
  /// now and a background pass keeps filling.
  releasedEarly,

  /// The probe resolved nothing across a full sample: repeating it (here or in
  /// the background) would only re-read rows it cannot parse.
  stalled,

  /// A newer run took the storage over, or the scan was stopped. The caller must
  /// not touch the store.
  abandoned,
}

/// Merges a probe result into a media file node.
///
/// Existing values win over "probe could not read this one" (null), so
/// repeated scans / partial probes never downgrade information.
MediaNode applyProbeResult(MediaNode node, ProbeResult result) {
  if (node is! MediaFile) return node;
  return node.copyWith(
    durationMs: result.durationMs ?? node.durationMs,
    width: result.width ?? node.width,
    height: result.height ?? node.height,
  );
}

/// Whether the probe triple stored on a `media_nodes` row agrees with the one a
/// rescan just read.
///
/// This is the ONLY thing standing between "the user asked for a rescan with
/// the probe on" and a corrected row, so the direction matters:
/// - a NON-NULL fresh value that differs from the stored one forces the upsert
///   (`false`): that is how a rescan repairs a duration/resolution poisoned by
///   an older cross-file write-back, and how a re-encoded file converges;
/// - a NULL fresh value means "this run could not read it" (probe disabled, or
///   the Shell property handler has no value for that key) and never downgrades
///   the stored value 鈥?a player-derived duration must survive a plain rescan.
bool probeTripleUnchanged({
  required int? rowDurationMs,
  required int? freshDurationMs,
  required int? rowWidth,
  required int? freshWidth,
  required int? rowHeight,
  required int? freshHeight,
}) =>
    (freshDurationMs == null || rowDurationMs == freshDurationMs) &&
    (freshWidth == null || rowWidth == freshWidth) &&
    (freshHeight == null || rowHeight == freshHeight);

class RecursiveScanService {
  final Storage storage;
  final RecursiveScanStore scanStore;
  final MediaNodesDao nodesDao;
  final MediaLibSourcesDao sourcesDao;

  /// Frame-interval yield gate for the walk (see [CooperativeYield]).
  final CooperativeYield _yieldGate = CooperativeYield();

  /// When non-null, playable files without media info are deep-probed
  /// (duration / resolution) and written back. Null = plain scan.
  ///
  /// The probe is NO LONGER part of the per-directory write path: rows land
  /// first (that is what makes a folder listable in seconds), then
  /// [MetadataBackfillService] fills them in. [backgroundProbe] decides whether
  /// that pass finishes before the scan reports `done`.
  final MediaProbeService? probeService;

  /// When true the metadata pass runs AFTER `completeScan`, so scan waiters
  /// (the play gate, the source-refresh batch) are released as soon as the
  /// tree is listed. False keeps the pass inside the run 鈥?the "wait a few
  /// seconds, then the list is fully ordered by duration" tier.
  final bool backgroundProbe;

  /// True when this run exists only because a play action needed its rows
  /// (drag-drop auto-play, the silent gate increment).
  ///
  /// The progress panel then explains a WAIT rather than reporting a task the
  /// user asked for: it appears only if the run is slow, never counts down, and
  /// is dismissed by whoever started the batch (see
  /// [RecursiveScanStore.quietCompletion]).
  final bool playbackOriginated;

  /// Fired once this run has registered with [scanStore] (i.e. the store is
  /// scanning this run's roots). Callers use it to capture
  /// [RecursiveScanStore.playableSettled] at exactly the right moment.
  final void Function()? onScanStarted;

  /// Directory-listing seam.
  ///
  /// Defaults to the storage's *detailed* listing so a failed remote listing is
  /// classified (`FileListResult.hasError`) instead of collapsing to an empty
  /// directory. Overridable in tests to simulate WebDAV/FTP failures without
  /// touching the network.
  final Future<FileListResult> Function(Storage storage, List<String> path)
      listDir;

  /// True when [listDir] is the real storage listing (no test seam injected).
  /// The empty-listing disambiguation stats the filesystem, which only makes
  /// sense when the same listing actually came from it.
  final bool _usesDefaultListDir;

  static Future<FileListResult> _defaultListDir(
          Storage storage, List<String> path) =>
      // The scanner drops every entry that is neither a directory nor a
      // playable file, so it must not pay a stat() for the rest. On a 2019
      // phone that was ~180k image stats per full-volume scan (68% of the
      // run) for rows that were thrown away one line later.
      storage.getFilesDetailed(path, withEntryFacts: false);

  /// Probe observability accumulated across directories for one scan run:
  /// attempted/usable/empty counts plus the first empty samples. A scan
  /// that built rows but left durations null is attributable from the end
  /// summary instead of invisible (e.g. virtual-merge yellow labels).
  int _probeAttempted = 0;
  int _probeUsable = 0;
  int _probeEmpty = 0;
  final List<String> _probeEmptySamples = [];

  /// Directories whose listing failed during THIS run (canonical paths).
  ///
  /// The aggregate pass must not stamp them (or their ancestors) `scanDone`:
  /// doing so would report a partial scan as complete and hide the failure from
  /// the play gate. Run-scoped, so a later successful rescan can mark them done.
  final Set<String> _erroredDirs = {};

  /// Directories this run actually walked, in the stored (base-relative) form.
  ///
  /// The settle pass ([_settleScanStates]) may only trust a root it reached —
  /// a run that stopped beforehand knows nothing about that root's
  /// completeness. Run-scoped by design.
  final Set<String> _visitedDirs = {};

  /// Run-wide slots bounding concurrent directory listings.
  ///
  /// Deliberately a semaphore around the LISTING only, never the whole DFS: a
  /// parent worker holding a slot while awaiting its children would deadlock
  /// as soon as the tree is deeper than the slot count.
  int _listingSlots = kScanMaxConcurrency;
  final List<Completer<void>> _listingWaiters = <Completer<void>>[];

  /// Runs [body] while holding one listing slot (see [kScanMaxConcurrency]).
  Future<T> _withListingSlot<T>(Future<T> Function() body) async {
    if (_listingSlots > 0) {
      _listingSlots--;
    } else {
      final waiter = Completer<void>();
      _listingWaiters.add(waiter);
      await waiter.future;
    }
    try {
      return await body();
    } finally {
      // Hand the slot straight to the next waiter, so a queued listing never
      // races a brand-new one for it.
      if (_listingWaiters.isNotEmpty) {
        _listingWaiters.removeAt(0).complete();
      } else {
        _listingSlots++;
      }
    }
  }

  /// Identity of the run THIS service instance started.
  ///
  /// A superseded walk must stop writing into the store. `isScanning` cannot
  /// express that: a new run re-arms the phase, so the OLD walk kept listing
  /// directories, then `completeScan()`-ed the NEW run's state (and released the
  /// shared scan lease) — the new run looked finished before it had walked
  /// anything. Identity also survives the interleaving case, where a slow run
  /// reads `runToken` after the newer run already bumped it.
  final Object _runOwner = Object();

  /// Whether THIS run still owns the store.
  bool get _runIsLive => scanStore.isScanning && scanStore.ownsRun(_runOwner);

  /// Phase timings for this run (see [ScanProfiler]).
  ///
  /// Measured on a 2019 Android 10 phone: 34k directories / 558 videos, and the
  /// whole volume lists in ~6 s 鈥?yet the scan took minutes. The cost was
  /// per-directory statements plus the encrypted scan-state blob, which no
  /// desktop-shaped tuning would have found. This is the seam that turns that
  /// from a guess into a log line, per device.
  final ScanProfiler profiler = ScanProfiler();

  RecursiveScanService({
    required this.storage,
    required this.scanStore,
    required this.nodesDao,
    required this.sourcesDao,
    this.probeService,
    this.backgroundProbe = false,
    this.playbackOriginated = false,
    this.onScanStarted,
    Future<FileListResult> Function(Storage storage, List<String> path)?
        listDir,
  })  : listDir = listDir ?? _defaultListDir,
        _usesDefaultListDir = listDir == null;

  /// Entry point for recursive scanning.
  ///
  /// The service itself decides whether to resume a previous interrupted scan
  /// or start fresh, based on the current [RecursiveScanState.phase]. This
  /// decouples the caller (toolbar) from scan lifecycle concerns 鈥?the toolbar
  /// only needs to pass the desired root paths.
  Future<void> scanRecursively({
    required List<String> rootPaths,
    required BuildContext context,
  }) async {
    final storageId = storage.id;
    // An empty root means "the storage base": listing the empty path makes the
    // platform answer an empty (non-error) listing, which the incremental sync
    // then reads as "the root has no entries" and prunes the whole snapshot.
    rootPaths = [
      for (final p in rootPaths)
        p.isEmpty ? storage.basePath.join('/') : p,
    ];
    // Roots stamped `scanning` by this run 鈥?settled in the `finally` below.
    List<String>? stampedRoots;
    final runStopwatch = Stopwatch()..start();
    try {
      // The interrupted-scan prompt is arbitrary user think-time. Decide BEFORE
      // taking the cross-window lease: holding it while the prompt is open made
      // every other window answer "another window is scanning" until the user
      // clicked, even though nothing was scanning yet.
      final phase = scanStore.state.phase;
      _IncompleteScanAction? action;
      if (phase == ScanPhase.error) {
        // Scan was interrupted accidentally. Ask user whether to resume.
        if (!context.mounted) return;
        action = await _showIncompleteScanDialog(context);
        if (action == null) return; // dismissed
      }

      // Cross-window lease: only one window scans at a time (duplicate directory
      // IO and scan_queue row fights otherwise). Denied = another live window is
      // scanning; explain instead of silently doing nothing.
      if (!await ScanLease.instance.acquire()) {
        areaKeyLog.w('RecursiveScan skipped: another window holds the scan lease');
        if (context.mounted) {
          await _showScanBusyDialog(context);
        }
        return;
      }
      // Observability: whether this run even attempts duration probing is
      // the first branch of every "scanned but no durations" diagnosis.
      // WARNING level: the legacyDb channel silences INFO in all builds.
      areaKeyLog.w('RecursiveScan start storage=$storageId '
          'roots=${rootPaths.length} probe=${probeService == null ? 'off(plain)' : 'on'}');

      // The store writes the snapshot during this run; attribute those writes to
      // this run's breakdown. Cleared in `finally` so a later run cannot report
      // into a finished one's numbers.
      scanStore.profiler = profiler;

      // A SAF descent hint is only valid for the tree as it was listed: a
      // rename/move since the last run would otherwise list the wrong folder.
      // Clearing costs at most one provider query per directory.
      SafDocumentUriIndex.instance.clear();

      final wantsMetadataWait = !backgroundProbe && !_isNetworkStorage;
      if (action == _IncompleteScanAction.resume) {
        await _resumeScan(storageId, rootPaths,
            waitForMetadata: wantsMetadataWait);
        if (scanStore.state.phase != ScanPhase.scanning) return;
      } else {
        // done / stopped / idle 鈥?or an explicit "start new" after an
        // interrupted run 鈥?start fresh with the new rootPaths.
        final depthPaths = <int, List<String>>{0: rootPaths};
        await scanStore.startScan(
          storageId: storageId,
          depthPaths: depthPaths,
          waitForMetadata: wantsMetadataWait,
          quietCompletion: playbackOriginated,
          owner: _runOwner,
        );
      }
      // A run that lost the store between the prompt/lease and this point must
      // not walk anything: its roots may already belong to the newer run.
      if (!scanStore.ownsRun(_runOwner)) return;
      onScanStarted?.call();

      // DFS each root path with weight = 1.0 / rootCount.
      final activeRoots = scanStore.state.depthPaths[0] ?? rootPaths;
      final rootWeight = activeRoots.isEmpty ? 1.0 : 1.0 / activeRoots.length;

      // Mark each scanned root as "scanning" in the DB before walking it, so
      // the play gate sees the in-progress state ("浠庨€夊畾鐩綍璧锋壂鎻忓氨鏍囪").
      // Heal first: pre-fix scans leaked above-base phantoms (`F:`, `F:/dl`)
      // whose NULL parent permanently blocks the root scanDone stamp.
      // Ensure second: on a never-scanned root the stamp UPDATE would hit
      // zero rows, leaving the settle pass nothing to converge.
      try {
        await nodesDao.deleteAboveBaseAncestors(storageId);
      } catch (e) {
        areaKeyLog.w('Phantom cleanup skipped: $e');
      }
      for (final rootPath in activeRoots) {
        await _ensureSelfDirNode(storageId, rootPath);
        await nodesDao.markDirScanning(storageId, rootPath);
      }
      stampedRoots = activeRoots;

      for (final rootPath in activeRoots) {
        if (!_runIsLive) return;
        await _scanDirDFS(storageId, rootPath, rootWeight);
      }

      if (!_runIsLive) return;

      // The tree is listed: every row the gate needs to build a playable,
      // sortable scope is in `media_nodes` now. Releasing this BEFORE the
      // metadata pass is what turns "drop a folder" from probe-bound into
      // enumeration-bound for large scopes.
      if (wantsMetadataWait &&
          scanStore.filesSeen > kFastMetadataFileLimit) {
        areaKeyLog.w('Scan listing ${scanStore.filesSeen} files exceeds '
            '$kFastMetadataFileLimit; playing before metadata completes');
        scanStore.disableMetadataWait();
      }
      scanStore.markEnumerationComplete();

      // Network shares never block on metadata (one SMB open+header read
      // measured ~45 ms/file, so even a 1.7k-file share is ~30 s of waiting).
      final background =
          !wantsMetadataWait || scanStore.filesSeen > kFastMetadataFileLimit;

      if (probeService != null && !background) {
        final outcome = await _runMetadataPass(
          storageId,
          activeRoots,
          background,
          // Adaptive ceiling on the pre-play wait, not a fixed one: a pass that
          // provably cannot finish in time releases as soon as the projection
          // says so (see [shouldReleaseMetadataWait]), so a cold 1.3k-file
          // folder plays in ~a second instead of sitting ~10 s 鈥?and an
          // unreadable one does not spend the budget at all.
          budget: kMetadataWaitBudget,
        );
        // A superseded run must not touch the store: the completers below belong
        // to the run that owns it now.
        if (!_runIsLive) return;
        switch (outcome) {
          case MetadataPassOutcome.complete:
            scanStore.markPlayableReady();
          case MetadataPassOutcome.releasedEarly:
            // Release the play gate now and let the DB-driven pass continue in
            // the background 鈥?it resumes at the first row still missing data.
            scanStore.disableMetadataWait();
            unawaited(_runBackgroundPassAndAnnounce(
              storageId,
              activeRoots,
              true,
            ));
          case MetadataPassOutcome.stalled:
            // Nothing to gain from a background repeat: the probe cannot read
            // this content at all. Play now and leave the durations unknown
            // (they sort last, and a later playback still fills them in).
            areaKeyLog.w('Metadata pass stalled after $_probeAttempted rows '
                'with no usable result; releasing playback');
            scanStore.disableMetadataWait();
          case MetadataPassOutcome.abandoned:
            return;
        }
      }

      // A run superseded while it was probing must not write aggregates or
      // completion for roots the newer run now owns: that state is its own.
      if (!_runIsLive) return;
      await profiler.time('db.agg', () => _computeAllAggregates(storageId));
      await profiler.time(
        'db.aggAncestors',
        () => _recomputeAncestors(storageId, rootPaths),
      );
      await profiler.time(
        'db.aggSources',
        () => _propagateAggregatesToSources(storageId, rootPaths),
      );
      if (probeService != null) {
        areaKeyLog.w('RecursiveScan probe done storage=$storageId '
            'attempted=$_probeAttempted usable=$_probeUsable empty=$_probeEmpty'
            '${_probeEmptySamples.isEmpty ? '' : ' sample=${_probeEmptySamples.take(3).join(',')}'}');
      }
      // Last gate before the terminal write: the aggregate pass awaits, so a
      // newer run can claim the store while it is running.
      if (!_runIsLive) return;
      await scanStore.completeScan();

      if (probeService != null && background) {
        // Post-settle: play is already running; this only fills metadata.
        unawaited(_runBackgroundPassAndAnnounce(
          storageId,
          activeRoots,
          background,
        ));
      }
    } catch (e, st) {
      areaKeyLog.e('RecursiveScanService error: $e\n$st');
      // Only the owning run may fail "the" scan: a superseded run that throws
      // on its way out (a listing aborted by its own token check) must not mark
      // the newer run's store as errored.
      if (scanStore.ownsRun(_runOwner)) {
        await scanStore.failScan(e.toString());
        // Mark the scan roots as errored so the play gate reports it.
        for (final rootPath
            in (scanStore.state.depthPaths[0] ?? const <String>[])) {
          try {
            await nodesDao.markDirScanError(storageId, rootPath);
          } catch (_) {}
        }
      }
    } finally {
      // Runs on every exit path 鈥?success, failure, stop, or a run superseded
      // by a newer one. The successful completion pass only stamps `scanDone`
      // for directories it can prove complete; anything else must not be left
      // claiming "being scanned".
      //
      // A SUPERSEDED run settles nothing and releases nothing: its roots now
      // belong to the newer run (settling them would stamp `error`/`done` under
      // it) and the shared lease must outlive it.
      if (scanStore.ownsRun(_runOwner)) {
        if (stampedRoots != null) {
          await _settleScanStates(storageId, stampedRoots);
        }
        scanStore.profiler = null;
        profiler.record('run.total', runStopwatch.elapsed);
        // One line per run, biggest phase first: this is the number that decides
        // whether the next fix is IO, statements, the probe, or the snapshot blob.
        final probeState = probeService == null ? 'off' : 'on';
        areaKeyLog.w('[scan-prof] storage=$storageId '
            'dirs=${_visitedDirs.length} files=${scanStore.filesSeen} '
            'probe=$probeState ${profiler.summary()}');
        // Hand the scan lease to whichever window scans next.
        await ScanLease.instance.release();
      }
    }
  }

  /// Runs a background metadata pass and announces the storage when it wrote
  /// something.
  ///
  /// The scan's callers announce at `completeScan`, which by design happens
  /// BEFORE this pass finishes ("play first, fill later"). Without the second
  /// announce the refreshed durations / resolutions stay invisible: the derived
  /// queue index keeps its old signature, so an open duration-sorted queue (and
  /// a `sourceScanRevision`-driven re-fetch) keeps serving "all durations
  /// unknown" until something unrelated bumps the revision.
  Future<void> _runBackgroundPassAndAnnounce(
    String storageId,
    List<String> roots,
    bool background, {
    Duration? budget,
  }) async {
    final outcome = await _runMetadataPass(
      storageId,
      roots,
      background,
      budget: budget,
    );
    if (outcome == MetadataPassOutcome.abandoned) return;
    if (!scanStore.ownsRun(_runOwner)) return;
    try {
      await MediaRevisionActions.mediaNodesChanged([storageId]);
    } catch (e) {
      // The announce is a UI/index concern and must never fail the scan.
      areaKeyLog.w('Scan metadata announce skipped: $e');
    }
  }

  /// Converges the roots this run stamped `scanning`.
  ///
  /// The completion pass only stamps `scanDone` for a directory it can prove
  /// complete: a failed child listing, a stopped run, or a run superseded by a
  /// newer one leaves the root stamped `scanning` while the scan still reports
  /// `done`. The play gate reads that stamp as LIVE state ("鐩綍姝ｅ湪鎵弿涓?) and
  /// hides the rescan button for it, so the directory could never be repaired
  /// from the gate. Fully scanned roots become `scanDone`, everything else
  /// `error` 鈥?the gate then offers a full rescan. (Descendants are never
  /// stamped by a run, and the normal bottom-up pass owns them.)
  Future<void> _settleScanStates(
    String storageId,
    List<String> rootPaths,
  ) async {
    try {
      for (final rootPath in rootPaths) {
        final status = await nodesDao.dirScanStatus(storageId, rootPath);
        if (status?.state != 'scanning') continue;
        final row = await nodesDao.getByPath(storageId, rootPath);
        if (row == null) continue;
        final dirPath = row.path;
        final selfErrored = _erroredDirs
            .contains(StoragePathCodec.absolutize(storageId, dirPath));
        final children = await nodesDao.getChildDirs(storageId, dirPath);
        final childErrored = children.any((c) => _erroredDirs
            .contains(StoragePathCodec.absolutize(storageId, c.path)));
        // The walk must actually have reached the root: a run that stopped
        // before descending into it knows nothing about its completeness.
        // Its children must have been reached too: a stale `scanDone` stamp
        // from a previous successful run is not proof this run verified them
        // (a run stopped inside the first child would otherwise converge the
        // root to done on the strength of never-visited children).
        if (_visitedDirs.contains(dirPath) &&
            !selfErrored &&
            !childErrored &&
            children.every((c) => _visitedDirs.contains(c.path))) {
          final allDone = await nodesDao.allChildDirsScanned(storageId, dirPath);
          if (children.isEmpty || allDone) {
            await nodesDao.markDirScanDone(storageId, dirPath);
            continue;
          }
        }
        await nodesDao.markDirScanError(storageId, dirPath);
      }
    } catch (e) {
      areaKeyLog.e('Scan-state settle error: $e');
    }
  }

  /// True when the current DFS path lives under an Android SAF storage
  /// (segment 0 is a full `content://.../tree/...` prefix).
  bool _isSafDir(String dirPath) => isSafPath(dirPath);

  /// Storages whose per-file probe is too slow to gate play on: FTP/WebDAV
  /// (protocol) and SMB/UNC shares (`StorageType.network`), where a single
  /// header read costs a network round trip.
  bool get _isNetworkStorage =>
      storage.type == StorageType.ftp ||
      storage.type == StorageType.webdav ||
      storage.type == StorageType.network;

  /// True when an empty LISTING can be disambiguated by a local `exists()`
  /// check: local/SAF-less volumes and mounted SMB shares ride the real
  /// filesystem. WebDAV/FTP have no local path to stat.
  bool get _canStatLocalListing => switch (storage.type) {
        StorageType.internal ||
        StorageType.usb ||
        StorageType.sdcard ||
        StorageType.network =>
          true,
        StorageType.none || StorageType.webdav || StorageType.ftp => false,
      };

  /// Splits a DFS directory path into path segments, keeping a SAF
  /// `content://` tree prefix as a single first segment (reversible).
  List<String> _pathSegments(String dirPath) {
    if (dirPath.isEmpty) return const [];
    return isSafPath(dirPath) ? safSegmentsOf(dirPath) : dirPath.split('/');
  }

  /// Cooperative yield: lets the raster / player thread pump a frame.
  ///
  /// Budgeted at the frame interval (see [CooperativeYield]): the old
  /// unconditional `Future.delayed(Duration.zero)` cost one timer event per
  /// step, ~100k of them per 34k-directory scan (25.8 s measured).
  Future<void> _yieldToUi() => _yieldGate.maybeYield();

  Future<bool> _waitIfPaused() async {
    while (scanStore.state.paused && _runIsLive) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return _runIsLive;
  }

  /// Records a directory listing failure for resume/play-gate bookkeeping.
  ///
  /// Best-effort: a secondary failure here must not abort the whole scan. No
  /// existing `media_nodes` rows are touched, so the snapshot is preserved.
  Future<void> _markDirListingError(String storageId, String dirPath) async {
    // A superseded run no longer speaks for this directory: its failure must
    // not stamp `error` under the run that owns the store now.
    if (!scanStore.ownsRun(_runOwner)) return;
    _erroredDirs.add(canonicalDbPath(dirPath));
    try {
      await scanStore.markQueueError(dirPath);
    } catch (_) {}
    try {
      await nodesDao.markDirScanError(storageId, dirPath);
    } catch (_) {}
  }

  /// DFS scan of a single directory.
  ///
  /// [weight] is this dir's contribution to the overall progress [0..1].
  /// Leaf dirs (no subdirs) add their weight immediately.
  /// Parent dirs add their weight after all children complete.
  /// Cooperative yielding keeps playback smooth even on large trees.
  ///
  /// [rowWrittenByParent] says the caller reached this directory through its
  /// parent's listing, which just wrote/confirmed its row. Only a scan ROOT can
  /// lack that row (nothing listed it in this run), so the self-node check is
  /// skipped here — it was one `SELECT` per directory, ~11 s on a 34k-directory
  /// phone volume, for a row that provably exists.
  Future<void> _scanDirDFS(
    String storageId,
    String dirPath,
    double weight, {
    bool rowWrittenByParent = false,
  }) async {
    if (!_runIsLive) return;
    if (!await _waitIfPaused()) return;
    await _yieldToUi();

    // Normalize dirPath: strip leading/trailing slashes so that all
    // parentPath values stored in the DB are consistent (no leading '/').
    dirPath = dirPath.replaceAll(RegExp(r'^/+|/+$'), '');
    _visitedDirs
        .add(StoragePathCodec.relativize(storageId, canonicalDbPath(dirPath)));

    // Update display.
    await scanStore.updateProgress(
      currentScanningPath: dirPath,
    );
    // New directory 鈥?clear any previous dir's probe counters so the overlay
    // never shows a stale "probing x/y".
    scanStore.setProbeProgress(0, 0);

    // Backfill ancestor directory nodes from the storage root down to
    // dirPath's parent.  Partial scans (rootPaths starting mid-tree) would
    // otherwise leave the path above the scan root absent from the DB,
    // breaking the path-tree browser.
    //
    // Ancestors are built from the STORAGE-RELATIVE form: building them from
    // absolute segments once leaked the base and everything above it
    // (`F:`, `F:/dl`) into the DB, and the topmost phantom's NULL parent
    // permanently blocked the root scanDone stamp (hence "never scanned"
    // right after a full scan). Above-base prefixes are simply dropped 鈥?    // the storage root itself needs no ancestor row.
    //
    // SAF storages are skipped here: their "ancestors above the tree root"
    // would be bogus `content:`/authority segments (the URI is not a real
    // filesystem hierarchy). The tree root directory node is created once by
    // _ensureSelfDirNode with the prefix as its single segment.
    //
    // dirPath may originate from currentPath.join('/') which produces a
    // leading '/' (e.g. "/storage/emulated/0/a_all").  Splitting that
    // directly creates an empty first segment that would produce bogus
    // nodes, so we filter empty segments first.
    //
    // batchUpsert targets UNIQUE(data_scope_id, path); ancestors are created
    // only when absent (INSERT OR IGNORE), so an existing row keeps its scan
    // stamp and aggregates.
    if (dirPath.isNotEmpty && !_isSafDir(dirPath)) {
      final rel =
          StoragePathCodec.relativize(storageId, canonicalDbPath(dirPath));
      // Only the ancestors this run has NOT walked yet. Depth-first order
      // guarantees every ancestor of a directory was visited (and therefore
      // has its row) before it, so a full-volume scan needs no inserts at all
      // — the pre-check keeps the backfill for a scan that starts mid-tree.
      final ancestors = missingAncestorNodes(
        storageId: storageId,
        rel: rel,
        visited: _visitedDirs,
      );
      if (ancestors.isNotEmpty) {
        await profiler.time(
          'db.ancestors',
          () => nodesDao.batchInsertIfAbsent(
            [for (final a in ancestors) a.toCompanion()],
          ),
          items: ancestors.length,
        );
      }
    }

    List<FileItem> items;
    final pathList = _pathSegments(dirPath);
    try {
      final isNet = storage.type == StorageType.ftp ||
          storage.type == StorageType.webdav ||
          storage.type == StorageType.network;
      final timeout = Duration(seconds: isNet ? 15 : 30);
      final result = await profiler.time(
        'list',
        // Slots are held only for the provider round trip: nested child
        // workers share the same run-wide cap, and no worker holds a slot
        // while waiting for its own children (that would deadlock).
        () => _withListingSlot(
          () => listDir(storage, pathList).timeout(timeout),
        ),
      );
      if (result.hasError) {
        // A failed listing (unreachable / unauthorized / timeout) must NEVER be
        // treated as "this directory is empty": the incremental sync below would
        // delete the directory's existing snapshot rows. Skip the subtree and
        // flag the dir as errored instead (the DB snapshot is preserved).
        areaKeyLog.e('Scan listing failed at $dirPath: '
            '${result.errorKind} ${result.errorDetail}');
        await _markDirListingError(storageId, dirPath);
        return;
      }
      items = result.items;
      if (items.isEmpty &&
          _usesDefaultListDir &&
          _canStatLocalListing &&
          !_isSafDir(dirPath)) {
        // A MISSING local directory is reported as an error-free EMPTY result
        // (see getLocalFilesResult), so "empty" alone cannot justify purging
        // the directory's snapshot. Stat the same path the lister just used and
        // only trust a genuinely empty, existing directory.
        final exists = await Directory(p.joinAll(pathList)).exists();
        if (!exists) {
          areaKeyLog.w('Scan listing empty for a missing directory at $dirPath');
          await _markDirListingError(storageId, dirPath);
          return;
        }
      }
    } catch (e) {
      areaKeyLog.e('Scan error at $dirPath: $e');
      // Network error: mark queue error for resume, skip subtree.
      await _markDirListingError(storageId, dirPath);
      return;
    }

    // Superseded while the listing was in flight: the rows below belong to the
    // newer run now (it re-lists this directory), so do not write them into the
    // store it owns.
    if (!_runIsLive) return;

    final subdirs = <String>[];
    final mediaNodes = <MediaNode>[];
    var playableCount = 0;

    for (final item in items) {
      if (item.name.contains('/') ||
          item.name.contains('\\') ||
          item.name == '..' ||
          item.name == '.') {
        areaKeyLog.w('Scan skip traversal name: ${item.name}');
        continue;
      }
      if (item.isDir) {
        subdirs.add(item.name);
        final childPath =
            dirPath.isEmpty ? item.name : '$dirPath/${item.name}';
        final childPathList = _pathSegments(childPath);

        mediaNodes.add(MediaNode.directory(
          id: '$storageId:$childPath',
          storageId: storageId,
          path: childPathList,
          parentPath: dirPath.isEmpty ? null : dirPath,
          pathDepth: childPathList.length,
          name: item.name,
        ));
      } else if (item.isPlayable) {
        final filePath =
            dirPath.isEmpty ? item.name : '$dirPath/${item.name}';
        final filePathList = _pathSegments(filePath);

        playableCount++;

        mediaNodes.add(MediaNode.file(
          id: '$storageId:$filePath',
          storageId: storageId,
          path: filePathList,
          parentPath: dirPath.isEmpty ? null : dirPath,
          pathDepth: filePathList.length,
          name: item.name,
          mediaType: _fileItemMediaType(item),
          sizeInBytes: item.size,
          // SAF rows persist the real content:// document URI so probe /
          // playback / virtual-merge can open the file without rebuilding a
          // mangled path. Plain rows keep null (playableUri fallback).
          uri: isSafPath(item.uri) ? item.uri : null,
          // Subtitle associations come from the listing and are persisted so
          // DB-resolved entries (scenario / tag / queue) can offer them too.
          subtitles: item.subtitles,
          modifiedAt: item.lastModified,
        ));
      }
    }

    // Rows FIRST, metadata later. The old order probed every file of the
    // directory before writing anything, so the folder stayed invisible (and
    // unplayable) for the whole probe 鈥?the exact behaviour that made a
    // 1200-file folder take tens of seconds to appear.
    scanStore.addFilesSeen(playableCount);
    await profiler.time(
      'db.sync',
      () => _syncDirIncremental(storageId, dirPath, mediaNodes),
      items: mediaNodes.length,
    );

    await profiler.time('db.dir', () async {
      // A directory reached through its parent's listing already has a row
      // (the sync above wrote every child, new or changed). Only a scan root
      // can be missing one.
      if (!rowWrittenByParent) {
        await _ensureSelfDirNode(storageId, dirPath);
      }

      // Mark queue entry done for 50w resume (best-effort, survives kill).
      try {
        await scanStore.markQueueDone(dirPath);
      } catch (_) {}
    });

    // Track discovered subdirs in depthPaths for resume.
    if (subdirs.isNotEmpty) {
      final childDepth =
          dirPath.isEmpty ? 0 : _pathSegments(dirPath).length;
      final childPaths = subdirs
          .map((s) => dirPath.isEmpty ? s : '$dirPath/$s')
          .toList();
      await profiler.time(
        'db.queue',
        () => scanStore.updateDepth(
          depth: childDepth,
          paths: childPaths,
        ),
        items: childPaths.length,
      );
    }

    if (!_runIsLive) return;

    // Count-based progress: this dir's frame is complete (contents written,
    // subdirs discovered). The parent's "done" DB marking happens bottom-up
    // in the aggregate pass, never here (a parent is only done once every
    // child is done 鈥?"浠庝笅鍒颁笂鍥炲綊鏍囪").
    await scanStore.incrementScannedDirs();

    if (subdirs.isEmpty) {
      // Leaf dir 鈥?contribute weight (kept for resume heuristics).
      await scanStore.addProgress(weight);
      await _yieldToUi();
    } else {
      // Has children 鈥?recurse DFS, yielding between subtrees so a huge
      // directory tree cannot starve the player raster thread.
      final childWeight = weight / subdirs.length;
      await _scanChildrenConcurrently(storageId, dirPath, subdirs, childWeight);
      // All children done 鈥?contribute this dir's weight.
      if (_runIsLive) {
        await scanStore.addProgress(weight);
      }
      await _yieldToUi();
    }
  }

  /// Scans child directories with bounded concurrency.
  ///
  /// Workers overlap the per-directory provider round trips; the actual cap on
  /// in-flight LISTINGS is the run-wide semaphore ([_withListingSlot]), so a
  /// nested tree cannot multiply them per level. The claim index is taken
  /// synchronously (no await between read and increment), so every child is
  /// visited exactly once. Store mutations stay safe: the store read+set pairs
  /// are synchronous, and the scanned-dir count goes through
  /// `incrementScannedDirs`.
  Future<void> _scanChildrenConcurrently(
    String storageId,
    String dirPath,
    List<String> subdirs,
    double childWeight,
  ) async {
    if (subdirs.isEmpty || !_runIsLive) return;
    if (subdirs.length == 1) {
      if (!_runIsLive) return;
      if (!await _waitIfPaused()) return;
      final single =
          dirPath.isEmpty ? subdirs.first : '$dirPath/${subdirs.first}';
      await _scanDirDFS(storageId, single, childWeight,
          rowWrittenByParent: true);
      await _yieldToUi();
      return;
    }
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (!_runIsLive) return;
        if (next >= subdirs.length) return;
        final sub = subdirs[next];
        next++;
        if (!await _waitIfPaused()) return;
        if (!_runIsLive) return;
        final childPath = dirPath.isEmpty ? sub : '$dirPath/$sub';
        await _scanDirDFS(storageId, childPath, childWeight,
            rowWrittenByParent: true);
        await _yieldToUi();
      }
    }
    final count = subdirs.length < kScanMaxConcurrency
        ? subdirs.length
        : kScanMaxConcurrency;
    await Future.wait([for (var i = 0; i < count; i++) worker()]);
  }

  /// Fills duration/resolution for rows this run just wrote 鈥?DB-driven, so a
  /// resumed/partial scan simply continues from the first row that still lacks
  /// metadata, and an app restart does not lose the work list.
  ///
  /// Runs before `completeScan` (tier A: "wait a few seconds, then the list is
  /// fully ordered") or after it (tier B/C / network: play first, fill later).
  ///
  /// The two modes are deliberately different, and the difference is what makes
  /// a rescan able to REPAIR metadata:
  /// - the pass the caller WAITED for ([background] false) re-verifies every
  ///   playable row in scope. Rows land before probing now, so a listing never
  ///   carries a duration; size/mtime heal from the listing, but a duration a
  ///   re-encode changed (or an older cross-file write-back poisoned) can only
  ///   come back from a probe. Bounded by [budget], so the wait stays "seconds".
  /// - the background/overflow pass (true) only fills gaps ("play first, fill
  ///   later"): re-probing a whole 500k storage behind playback, or over a
  ///   network share, would be endless IO for no new information.
  ///
  /// Returns [MetadataPassOutcome.complete] when the pass reached the end of the
  /// work list. Anything else means the caller releases the play gate; whether a
  /// background pass is worth starting depends on WHICH stop it was.
  ///
  /// Network storages used to be skipped entirely, which left SMB shares with a
  /// permanently empty duration column (and made duration sorting useless
  /// there). They now probe too; the gate is what refuses to WAIT for them.
  Future<MetadataPassOutcome> _runMetadataPass(
    String storageId,
    List<String> roots,
    bool background, {
    Duration? budget,
  }) async {
    final probe = probeService;
    if (probe == null) return MetadataPassOutcome.complete;
    final backfill = MetadataBackfillService(dao: nodesDao);
    final verifyExisting = !background;
    // The projection and the stall cut-off describe a WAIT, so only the pass the
    // caller waits for uses them: a background pass runs behind playback, where
    // stopping early would only leave rows empty for no benefit.
    final waitBudget = background ? null : budget;
    // A newer run on the SAME storage over the same roots supersedes this pass:
    // its own pass re-examines exactly these rows, so continuing only competes
    // for the UI isolate. A run elsewhere (another storage, or a sibling
    // subtree) must NOT cancel it 鈥?those rows are disjoint and no later pass
    // covers them.
    bool superseded() => scanStore.isSupersededByNewerRun(
          owner: _runOwner,
          storageId: storageId,
          roots: roots,
        );
    var releaseByProjection = false;
    final cancel = background
        ? superseded
        : () => superseded() || !scanStore.isScanning || releaseByProjection;
    // Progress belongs to the store's CURRENT run; a superseded pass must not
    // overwrite another run's probe counters on its way out.
    void reportProgress(int done, int total) {
      if (!scanStore.ownsRun(_runOwner)) return;
      scanStore.setProbeProgress(done, total);
    }

    final stopwatch = waitBudget == null ? null : (Stopwatch()..start());

    var total = 0;
    for (final root in roots) {
      if (cancel()) return MetadataPassOutcome.abandoned;
      try {
        total += await nodesDao.countFilesForMetadata(
          storageId,
          pathPrefix: root,
          includeExisting: verifyExisting,
        );
      } catch (_) {}
    }
    reportProgress(0, total);

    var done = 0;
    var completed = true;
    var stalled = false;
    for (final root in roots) {
      if (cancel()) {
        completed = false;
        break;
      }
      Duration? remaining;
      if (waitBudget != null && stopwatch != null) {
        remaining = waitBudget - stopwatch.elapsed;
        if (remaining <= Duration.zero) {
          completed = false;
          break;
        }
      }
      final outcome = await profiler.time(
        'probe',
        () => backfill.run(
          storageId: storageId,
          probe: probe,
          rootPath: root,
          budget: remaining,
          includeExisting: verifyExisting,
          stallSample: background ? 0 : kMetadataStallSample,
          isCancelled: cancel,
          onProgress: (d, t) {
            final denominator = total > 0 ? total : done + t;
            reportProgress(done + d, denominator);
            if (waitBudget == null || stopwatch == null || releaseByProjection) {
              return;
            }
            if (shouldReleaseMetadataWait(
              done: done + d,
              total: denominator,
              elapsed: stopwatch.elapsed,
              budget: waitBudget,
            )) {
              releaseByProjection = true;
            }
          },
        ),
        itemsOf: (outcome) => outcome.visited,
      );
      done += outcome.visited;
      _probeAttempted += outcome.visited;
      _probeUsable += outcome.resolved;
      _probeEmpty += outcome.failed;
      if (outcome.stalled) {
        stalled = true;
        completed = false;
        break;
      }
      if (outcome.cancelled) {
        // An early release is OUR cancel, not a lost race: report it as such so
        // the caller keeps the background continuation.
        if (releaseByProjection) {
          completed = false;
          break;
        }
        return MetadataPassOutcome.abandoned;
      }
      if (outcome.timedOut) {
        completed = false;
        break;
      }
    }
    reportProgress(done, total > 0 ? total : done);
    // Observability: "the scan finished but music has no durations" is answered
    // by this line together with the caller's `probe done` summary.
    areaKeyLog.w('RecursiveScan metadata pass storage=$storageId '
        'background=$background visited=$done total=$total '
        'stalled=$stalled');
    if (stalled) return MetadataPassOutcome.stalled;
    // A projection-triggered stop is only a stop if it actually cut work short:
    // when the last batch finished anyway, the list IS fully ordered and the
    // gate can open without scheduling a (pointless) background continuation.
    return completed
        ? MetadataPassOutcome.complete
        : MetadataPassOutcome.releasedEarly;
  }

  Future<void> _syncDirIncremental(
    String storageId,
    String dirPath,
    List<MediaNode> freshNodes,
  ) async {
    final canonicalDir = canonicalDbPath(dirPath);
    // Slim projection: the diff below reads ten fields, and a `SELECT *` per
    // directory (34k on a phone volume) was measured at 12.2 s on a rescan.
    final List<ScanSyncChildRow> existing =
        await nodesDao.listChildrenForScanSync(storageId, canonicalDir);
    // Case is identity on a case-sensitive filesystem. Folding unconditionally
    // merged `photo.JPG` and `photo.jpg` into one existence key there (the
    // stale row of a deleted twin was never removed and each file was compared
    // against the wrong row). On NTFS/SMB a case-only rename is the SAME file,
    // so folding stays deliberate.
    final bool foldCase =
        pathRidesCaseInsensitiveFs(storage.basePath.join('/'));
    String nameKeyOf(String name) => foldCase ? name.toLowerCase() : name;
    final existingByName = <String, ScanSyncChildRow>{};
    for (final ScanSyncChildRow row in existing) {
      existingByName[nameKeyOf(row.name)] = row;
    }
    final freshByName = <String, MediaNode>{};
    for (final MediaNode n in freshNodes) {
      freshByName[nameKeyOf(n.name)] = n;
    }

    final toDeleteFiles = <String>[];
    final toDeleteDirPrefixes = <String>[];
    for (final ScanSyncChildRow row in existing) {
      if (!freshByName.containsKey(nameKeyOf(row.name))) {
        if (row.nodeKind == MediaNodeKind.directory) {
          toDeleteDirPrefixes.add(row.path);
        } else {
          toDeleteFiles.add(row.path);
        }
      }
    }

    final toUpsert = <MediaNode>[];
    final toDeleteTypeChangeFiles = <String>[];
    final toDeleteTypeChangePrefixes = <String>[];
    for (final MediaNode node in freshNodes) {
      final ScanSyncChildRow? row = existingByName[nameKeyOf(node.name)];
      if (row == null) {
        toUpsert.add(node);
        continue;
      }
      final bool rowIsDir = row.nodeKind == MediaNodeKind.directory;
      final bool nodeIsDir = node.isDir;
      if (rowIsDir != nodeIsDir) {
        if (rowIsDir) {
          toDeleteTypeChangePrefixes.add(row.path);
        } else {
          toDeleteTypeChangeFiles.add(row.path);
        }
        toUpsert.add(node);
        continue;
      }
      if (node is MediaFile) {
        final sameSize = row.sizeInBytes == node.sizeInBytes;
        final sameModified = row.modifiedAt == node.modifiedAt;
        final sameType = row.mediaType == node.mediaType;
        final probeSame = probeTripleUnchanged(
          rowDurationMs: row.durationMs,
          freshDurationMs: node.durationMs,
          rowWidth: row.width,
          freshWidth: node.width,
          rowHeight: row.height,
          freshHeight: node.height,
        );
        // Observable repair: a rescan with the probe enabled is the documented
        // way to fix metadata poisoned by an older cross-file write-back, so an
        // actual value change is named here instead of hiding inside the diff.
        // A null fresh value never logs (it downgrades nothing).
        final bool durationCorrected =
            node.durationMs != null && node.durationMs != row.durationMs;
        final bool dimsCorrected =
            (node.width != null && node.width != row.width) ||
                (node.height != null && node.height != row.height);
        if (durationCorrected || dimsCorrected) {
          areaKeyLog.i('[scan] probe corrects ${node.name}: '
              'dur=${row.durationMs}->${node.durationMs} '
              'res=${row.width}x${row.height}->${node.width}x${node.height}');
        }
        // The association set is part of "unchanged": adding or deleting a
        // subtitle in the same directory does NOT touch the video's size or
        // mtime, so a size/mtime-only predicate would serve the stale set
        // forever 鈥?a deleted track offered (and failing to load) on every
        // open, a new one never appearing. Rows whose associations were never
        // captured (pre-v50) are still re-upserted once, so they gain them.
        if (sameSize &&
            sameModified &&
            sameType &&
            probeSame &&
            MediaNodeDriftAdapter.sameSubtitles(
                row.subtitlesJson, node.subtitles)) {
          continue;
        }
      } else {
        final sameModified = row.modifiedAt == node.modifiedAt;
        if (sameModified) continue;
      }
      toUpsert.add(node);
    }

    // An unchanged rescan reaches here with nothing to do for every directory:
    // opening a transaction anyway was one write transaction per directory
    // (34k of them, ~14 s measured on a phone volume) that committed nothing.
    if (toDeleteDirPrefixes.isEmpty &&
        toDeleteTypeChangePrefixes.isEmpty &&
        toDeleteFiles.isEmpty &&
        toDeleteTypeChangeFiles.isEmpty &&
        toUpsert.isEmpty) {
      return;
    }

    // Per-dir atomic transaction so a crash cannot leave half-deleted state.
    await nodesDao.attachedDatabase.transaction(() async {
      for (final p in toDeleteDirPrefixes) {
        await nodesDao.deleteByPathPrefix(storageId, p);
      }
      for (final p in toDeleteTypeChangePrefixes) {
        await nodesDao.deleteByPathPrefix(storageId, p);
      }
      final allFilesToDelete = <String>[
        ...toDeleteFiles,
        ...toDeleteTypeChangeFiles,
      ];
      if (allFilesToDelete.isNotEmpty) {
        await nodesDao.batchDeleteByPaths(storageId, allFilesToDelete);
      }
      if (toUpsert.isNotEmpty) {
        await nodesDao.batchUpsert(
            toUpsert.map((e) => e.toCompanion()).toList());
      }
    });
  }

  Future<void> _ensureSelfDirNode(String storageId, String dirPath) async {
    if (dirPath.isEmpty) return;
    final canonical = canonicalDbPath(dirPath);
    if (canonical.isEmpty) return;
    final existing = await nodesDao.getByPath(storageId, canonical);
    if (existing != null) return;
    // Build the node from the STORAGE-RELATIVE form. Constructing it from
    // absolute segments once stored the base itself as an `F:/dl/ar`-style
    // row with an above-base parent the adapter cannot relativize back 鈥?    // the phantom that permanently blocked the root scanDone stamp.
    final saf = isSafPath(canonical);
    final rel =
        saf ? canonical : StoragePathCodec.relativize(storageId, canonical);
    if (!saf && rel.isEmpty) {
      // Storage-root self node: the `''` row the play gate reads.
      await nodesDao.batchUpsert([
        MediaNode.directory(
          id: '$storageId:',
          storageId: storageId,
          path: const <String>[],
          parentPath: null,
          pathDepth: 0,
          name: storage.basePath.isNotEmpty
              ? storage.basePath.last
              : storage.name,
        ).toCompanion(),
      ]);
      return;
    }
    // pathConv keeps a SAF `content://` tree prefix as one segment so the
    // root directory node is `[prefix]` (parent null), never `content:`...
    final pathList = saf ? pathConv(canonical) : rel.split('/');
    if (pathList.isEmpty) return;
    await nodesDao.batchUpsert([
      MediaNode.directory(
        id: '$storageId:$canonical',
        storageId: storageId,
        path: pathList,
        parentPath: pathList.length == 1 ? null : pathList.sublist(0, pathList.length - 1).join('/'),
        pathDepth: pathList.length,
        name: pathList.last,
      ).toCompanion(),
    ]);
  }

  /// Recomputes aggregates AND the bottom-up `scanDone` stamp for every
  /// directory this run actually walked.
  ///
  /// WHY a bulk pass: the per-directory version issued ~4 statements per folder
  /// (materialize every child row, materialize the child dirs again, probe for an
  /// unscanned child, then update). On a 34k-directory phone volume that alone
  /// was tens of seconds of pure statement overhead. Here the scope is read with
  /// TWO flat queries and the sums/convergence are computed in Dart; only the
  /// affected directories are written back, batched.
  ///
  /// Scope is the walked set, never the whole scope: a partial rescan must not
  /// rewrite the aggregates (or stamps) of a subtree it never looked at, and a
  /// stopped run must not stamp anything at all. On a resumed run the previous
  /// segment's discovered directories come from the persisted map / queue (the
  /// in-memory map is capped at 20k, which is why [_visitedDirs] is unioned in).
  Future<void> _computeAllAggregates(String storageId) async {
    final affected = <String>{..._visitedDirs};
    var depthPaths = scanStore.state.depthPaths;
    // 50w: the in-memory map is CAPPED (see RecursiveScanStore.updateDepth), so
    // the discovered set may be incomplete — hydrate the full map from the
    // queue. This used to key off `totalDirs >= 20000`, which now means "the
    // tree is big" rather than "the map was capped", and would have paid the
    // queue read on every large library.
    if (scanStore.depthPathsCapped) {
      try {
        final qMap = await DbModule.scanQueueDao.loadDepthPaths(storageId);
        if (qMap.isNotEmpty) depthPaths = qMap;
      } catch (_) {}
    }
    for (final paths in depthPaths.values) {
      for (final dirPath in paths) {
        affected.add(dirPath.replaceAll(RegExp(r'^/|/$'), ''));
      }
    }
    if (affected.isEmpty) return;

    final dirRows = await nodesDao.listDirAggregateRows(storageId);
    final fileAgg = await nodesDao.fileAggregatesByParent(storageId);

    final byPath = <String, ({int depth, int totalMedia, int totalDir, int totalItem, int totalSize, int totalDur, bool isDone})>{};
    final childrenOf = <String, List<String>>{};
    for (final row in dirRows) {
      byPath[row.path] = (
        depth: row.pathDepth,
        totalMedia: row.totalMediaCount,
        totalDir: row.totalDirCount,
        totalItem: row.totalItemCount,
        totalSize: row.totalSizeInBytes,
        totalDur: row.totalDurationMs,
        isDone: row.isScanDone,
      );
      if (row.path.isEmpty) continue; // the container is nobody's child
      (childrenOf[row.parentPath ?? ''] ??= <String>[]).add(row.path);
    }

    // Children before parents: a parent's totals include what this pass just
    // computed for its subtree.
    final ordered = affected.toList()
      ..sort((a, b) =>
          (byPath[b]?.depth ?? 0).compareTo(byPath[a]?.depth ?? 0));

    // Freshly stamped directories, so the parent rule sees this pass's work.
    final donePaths = <String>{
      for (final e in byPath.entries)
        if (e.value.isDone) e.key,
    };

    final updates = <
        ({
          String path,
          int directMediaCount,
          int directDirCount,
          int directItemCount,
          int totalMediaCount,
          int totalDirCount,
          int totalItemCount,
          int totalSizeInBytes,
          int totalDurationMs,
          bool markDone,
        })>[];

    for (final path in ordered) {
      if (!_runIsLive) return;
      final row = byPath[path];
      if (row == null) continue; // removed between the walk and the pass

      final kids = childrenOf[path] ?? const <String>[];
      final files = fileAgg[path] ??
          (mediaCount: 0, fileCount: 0, sizeBytes: 0, durationMs: 0);

      var totalDir = kids.length;
      var totalMedia = files.mediaCount;
      var totalItem = kids.length + files.fileCount;
      var totalSize = files.sizeBytes;
      var totalDur = files.durationMs;
      var childErrored = false;
      var allKidsDone = true;
      for (final kid in kids) {
        final done = byPath[kid];
        totalDir += done?.totalDir ?? 0;
        totalMedia += done?.totalMedia ?? 0;
        totalItem += done?.totalItem ?? 0;
        totalSize += done?.totalSize ?? 0;
        totalDur += done?.totalDur ?? 0;
        if (!donePaths.contains(kid)) allKidsDone = false;
        if (_erroredDirs.contains(
            StoragePathCodec.absolutize(storageId, kid))) {
          childErrored = true;
        }
      }
      // Publish this dir's totals before its parent is processed.
      byPath[path] = (
        depth: row.depth,
        totalMedia: totalMedia,
        totalDir: totalDir,
        totalItem: totalItem,
        totalSize: totalSize,
        totalDur: totalDur,
        isDone: row.isDone,
      );

      // "浠庝笅鍒颁笂鍥炲綊鏍囪": a dir is complete only if it is not errored, no child
      // dir errored, and every child dir is complete. A failed subtree must keep
      // its error stamp so the play gate offers a rescan.
      final selfErrored = _erroredDirs.contains(StoragePathCodec.absolutize(
          storageId, canonicalDbPath(path)));
      final markDone = !selfErrored && !childErrored && allKidsDone;
      if (markDone) donePaths.add(path);

      updates.add((
        path: path,
        directMediaCount: files.mediaCount,
        directDirCount: kids.length,
        directItemCount: kids.length + files.fileCount,
        totalMediaCount: totalMedia,
        totalDirCount: totalDir,
        totalItemCount: totalItem,
        totalSizeInBytes: totalSize,
        totalDurationMs: totalDur,
        markDone: markDone,
      ));
    }

    await nodesDao.batchWriteDirAggregates(
      storageId: storageId,
      rows: updates,
    );
  }

  /// Walk up from each scan root path, recomputing aggregates for every
  /// ancestor directory until reaching the storage root (parentPath == null).
  /// This ensures partial rescans correctly update parent totals.
  ///
  /// Aggregates ONLY 鈥?never the `scanDone` stamp. An ancestor of a partial
  /// root was not walked by this run, so its OTHER children may be stale or
  /// never scanned; stamping it done here would claim "fully scanned just now"
  /// for a subtree this run knows nothing about (dropping the parent then
  /// passed the play gate and played an incomplete queue). Every directory the
  /// run actually reached is in `depthPaths` and already stamped by
  /// [_computeAllAggregates]; anything above the roots keeps its own previous
  /// stamp until a scan (or a browse/doc) covers it.
  Future<void> _recomputeAncestors(
    String storageId,
    List<String> rootPaths,
  ) async {
    final visited = <String>{};
    final queue = <String>[
      for (final p in rootPaths) p.replaceAll(RegExp(r'^/|/$'), ''),
    ];

    while (queue.isNotEmpty) {
      if (!_runIsLive) return;
      final dirPath = queue.removeAt(0);
      if (!visited.add(dirPath)) continue;

      final node = await nodesDao.getByPath(storageId, dirPath);
      if (node == null) continue;

      // Reached the storage root 鈥?compute its aggregates from its
      // children and stop walking up (nothing above the root).
      if (node.parentPath == null) {
        try {
          await _computeDirAggregates(storageId, dirPath);
        } catch (e) {
          areaKeyLog.e('Root aggregate error at $dirPath: $e');
        }
        await _yieldToUi();
        continue;
      }

      try {
        await _computeDirAggregates(storageId, node.parentPath!);
      } catch (e) {
        areaKeyLog.e('Ancestor aggregate error at ${node.parentPath}: $e');
      }
      queue.add(node.parentPath!);
      await _yieldToUi();
    }
  }

  Future<void> _computeDirAggregates(
      String storageId, String dirPath) async {
    final children = await nodesDao.getDirectChildren(storageId, dirPath);

    int directDirCount = 0;
    int directMediaCount = 0;
    int directItemCount = children.length;
    int totalDirCount = 0;
    int totalMediaCount = 0;
    int totalItemCount = children.length;
    int totalSizeInBytes = 0;
    int totalDurationMs = 0;

    for (final child in children) {
      if (child.nodeKind == MediaNodeKind.directory) {
        directDirCount++;
        totalDirCount += 1 + child.totalDirCount;
        totalMediaCount += child.totalMediaCount;
        totalItemCount += child.totalItemCount;
        totalSizeInBytes += child.totalSizeInBytes;
        totalDurationMs += child.totalDurationMs;
      } else {
        if (child.mediaType != null &&
            child.mediaType != MediaType.unknown) {
          directMediaCount++;
          totalMediaCount++;
        }
        totalSizeInBytes += child.sizeInBytes ?? 0;
        totalDurationMs += child.durationMs ?? 0;
      }
    }

    await nodesDao.updateAggregates(
      storageId: storageId,
      path: dirPath,
      directMediaCount: directMediaCount,
      directDirCount: directDirCount,
      directItemCount: directItemCount,
      totalMediaCount: totalMediaCount,
      totalDirCount: totalDirCount,
      totalItemCount: totalItemCount,
      totalSizeInBytes: totalSizeInBytes,
      totalDurationMs: totalDurationMs,
    );
  }

  /// After node-level aggregates are computed, find sources that overlap
  /// with the scanned [rootPaths] and copy the matching node's aggregates
  /// to each affected source row.
  ///
  /// For root sources (path == null) the aggregates are the sum of ALL
  /// top-level nodes, not just one 鈥?the storage root is a virtual
  /// container with no single node in the tree.
  Future<void> _propagateAggregatesToSources(
    String storageId,
    List<String> rootPaths,
  ) async {
    try {
      final sources = await sourcesDao.getOverlappingSources(storageId, rootPaths);
      if (sources.isEmpty) return;

      for (final source in sources) {
        if (source.path != null && source.path!.isNotEmpty) {
          final node = await nodesDao.getByPath(storageId, source.path!);
          if (node == null) continue;

          await sourcesDao.updateSourceAggregates(
            sourceId: source.id,
            totalMediaCount: node.totalMediaCount,
            totalDirCount: node.totalDirCount,
            totalItemCount: node.totalItemCount,
            totalSizeInBytes: node.totalSizeInBytes,
            totalDurationMs: node.totalDurationMs,
          );
        } else {
          // Source covers the entire storage 鈥?sum ALL top-level nodes.
          final rootNodes = await nodesDao.getRootLevelNodes(storageId);
          if (rootNodes.isEmpty) continue;

          int totalMediaCount = 0;
          int totalDirCount = 0;
          int totalItemCount = 0;
          int totalSizeInBytes = 0;
          int totalDurationMs = 0;

          for (final node in rootNodes) {
            totalMediaCount += node.totalMediaCount;
            totalDirCount += node.totalDirCount;
            totalItemCount += node.totalItemCount;
            totalSizeInBytes += node.totalSizeInBytes;
            totalDurationMs += node.totalDurationMs;
          }

          await sourcesDao.updateSourceAggregates(
            sourceId: source.id,
            totalMediaCount: totalMediaCount,
            totalDirCount: totalDirCount,
            totalItemCount: totalItemCount,
            totalSizeInBytes: totalSizeInBytes,
            totalDurationMs: totalDurationMs,
          );
        }
      }
    } catch (e) {
      areaKeyLog.e('Source aggregate propagation error: $e');
    }
  }

  Future<void> _resumeScan(
    String storageId,
    List<String> rootPaths, {
    bool waitForMetadata = true,
  }) async {
    final existingState = scanStore.state;
    final depthPaths = <int, List<String>>{};

    for (final entry in existingState.depthPaths.entries) {
      final incomplete = <String>[];
      for (final dirPath in entry.value) {
        final allScanned =
            await nodesDao.allChildDirsScanned(storageId, dirPath);
        if (!allScanned) {
          incomplete.add(dirPath);
        }
      }
      if (incomplete.isNotEmpty) {
        depthPaths[entry.key] = incomplete;
      }
    }

    if (depthPaths.isEmpty) {
      await scanStore.resetScan();
      return;
    }

    final firstDepth = depthPaths.keys.reduce((a, b) => a < b ? a : b);

    // Recompute progress from already-completed root dirs.
    double completedWeight = 0.0;
    final activeRoots = depthPaths[0] ?? rootPaths;
    final skippedRoots =
        rootPaths.where((r) => !activeRoots.contains(r)).toList();
    if (rootPaths.isNotEmpty) {
      completedWeight += skippedRoots.length / rootPaths.length;
    }

    await scanStore.startScan(
      storageId: storageId,
      depthPaths: depthPaths,
      carryElapsedMs: existingState.elapsedMs,
      waitForMetadata: waitForMetadata,
      quietCompletion: playbackOriginated,
      owner: _runOwner,
    );
    await scanStore.setDepth(firstDepth);

    // Restore accumulated progress from previously completed roots.
    if (completedWeight > 0) {
      await scanStore.updateProgress(
        progress: completedWeight.clamp(0.0, 1.0),
      );
      await scanStore.save(scanStore.state);
    }
  }

  static MediaType _fileItemMediaType(FileItem item) {
    if (item.type == ContentType.video) return MediaType.video;
    if (item.type == ContentType.audio) return MediaType.audio;
    return MediaType.unknown;
  }

  /// Explains that another IRIS window owns the scan lease.
  Future<void> _showScanBusyDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        final t = getLocalizations(dialogCtx);
        return AlertDialog(
          title: Text(t.scan_busy_other_window_title),
          content: Text(t.scan_busy_other_window_body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text(t.ok),
            ),
          ],
        );
      },
    );
  }

  /// Shows a dialog asking whether to resume an interrupted scan or start fresh.
  /// Returns `null` if dismissed.
  Future<_IncompleteScanAction?> _showIncompleteScanDialog(
    BuildContext context,
  ) {
    return showDialog<_IncompleteScanAction>(
      context: context,
      builder: (dialogCtx) {
        final t = getLocalizations(dialogCtx);
        return AlertDialog(
          title: Text(t.scan_incomplete_title),
          content: Text(t.scan_incomplete_body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text(t.cancel),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogCtx, _IncompleteScanAction.startNew),
              child: Text(t.scan_incomplete_new),
            ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.pop(dialogCtx, _IncompleteScanAction.resume),
              child: Text(t.scan_incomplete_resume),
            ),
          ],
        );
      },
    );
  }
}

enum _IncompleteScanAction { resume, startNew }
