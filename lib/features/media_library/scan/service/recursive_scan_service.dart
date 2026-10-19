import 'package:flutter/material.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/db/dao/media_lib_sources_dao.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyDb);

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

class RecursiveScanService {
  final Storage storage;
  final RecursiveScanStore scanStore;
  final MediaNodesDao nodesDao;
  final MediaLibSourcesDao sourcesDao;

  /// When non-null, every playable file is deep-probed (duration /
  /// resolution) before being written. Null = plain scan.
  final MediaProbeService? probeService;

  /// Directory-listing seam.
  ///
  /// Defaults to the storage's *detailed* listing so a failed remote listing is
  /// classified (`FileListResult.hasError`) instead of collapsing to an empty
  /// directory. Overridable in tests to simulate WebDAV/FTP failures without
  /// touching the network.
  final Future<FileListResult> Function(Storage storage, List<String> path)
      listDir;

  static Future<FileListResult> _defaultListDir(
          Storage storage, List<String> path) =>
      storage.getFilesDetailed(path);

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

  RecursiveScanService({
    required this.storage,
    required this.scanStore,
    required this.nodesDao,
    required this.sourcesDao,
    this.probeService,
    Future<FileListResult> Function(Storage storage, List<String> path)?
        listDir,
  }) : listDir = listDir ?? _defaultListDir;

  /// Entry point for recursive scanning.
  ///
  /// The service itself decides whether to resume a previous interrupted scan
  /// or start fresh, based on the current [RecursiveScanState.phase]. This
  /// decouples the caller (toolbar) from scan lifecycle concerns — the toolbar
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
    // Roots stamped `scanning` by this run — settled in the `finally` below.
    List<String>? stampedRoots;
    // Observability: whether this run even attempts duration probing is
    // the first branch of every "scanned but no durations" diagnosis.
    // WARNING level: the legacyDb channel silences INFO in all builds.
    areaKeyLog.w('RecursiveScan start storage=$storageId '
        'roots=${rootPaths.length} probe=${probeService == null ? 'off(plain)' : 'on'}');
    try {
      final phase = scanStore.state.phase;

      if (phase == ScanPhase.error) {
        // Scan was interrupted accidentally. Ask user whether to resume.
        final action = await _showIncompleteScanDialog(context);
        if (action == null) return; // dismissed
        if (action == _IncompleteScanAction.resume) {
          await _resumeScan(storageId, rootPaths);
          if (scanStore.state.phase != ScanPhase.scanning) return;
        } else {
          // Start new scan — reset state and proceed.
          final depthPaths = <int, List<String>>{0: rootPaths};
          await scanStore.startScan(
            storageId: storageId,
            depthPaths: depthPaths,
          );
        }
      } else {
        // done / stopped / idle — start fresh with new rootPaths.
        final depthPaths = <int, List<String>>{0: rootPaths};
        await scanStore.startScan(
          storageId: storageId,
          depthPaths: depthPaths,
        );
      }

      // DFS each root path with weight = 1.0 / rootCount.
      final activeRoots = scanStore.state.depthPaths[0] ?? rootPaths;
      final rootWeight = activeRoots.isEmpty ? 1.0 : 1.0 / activeRoots.length;

      // Mark each scanned root as "scanning" in the DB before walking it, so
      // the play gate sees the in-progress state ("从选定目录起扫描就标记").
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
        if (!scanStore.isScanning) return;
        await _scanDirDFS(storageId, rootPath, rootWeight);
      }

      if (!scanStore.isScanning) return;

      await _computeAllAggregates(storageId);
      await _recomputeAncestors(storageId, rootPaths);
      await _propagateAggregatesToSources(storageId, rootPaths);
      if (probeService != null) {
        areaKeyLog.w('RecursiveScan probe done storage=$storageId '
            'attempted=$_probeAttempted usable=$_probeUsable empty=$_probeEmpty'
            '${_probeEmptySamples.isEmpty ? '' : ' sample=${_probeEmptySamples.take(3).join(',')}'}');
      }
      await scanStore.completeScan();
    } catch (e, st) {
      areaKeyLog.e('RecursiveScanService error: $e\n$st');
      await scanStore.failScan(e.toString());
      // Mark the scan roots as errored so the play gate reports it.
      for (final rootPath in (scanStore.state.depthPaths[0] ?? const <String>[])) {
        try {
          await nodesDao.markDirScanError(storageId, rootPath);
        } catch (_) {}
      }
    } finally {
      // Runs on every exit path — success, failure, stop, or a run superseded
      // by a newer one. The successful completion pass only stamps `scanDone`
      // for directories it can prove complete; anything else must not be left
      // claiming "being scanned".
      if (stampedRoots != null) {
        await _settleScanStates(storageId, stampedRoots);
      }
    }
  }

  /// Converges the roots this run stamped `scanning`.
  ///
  /// The completion pass only stamps `scanDone` for a directory it can prove
  /// complete: a failed child listing, a stopped run, or a run superseded by a
  /// newer one leaves the root stamped `scanning` while the scan still reports
  /// `done`. The play gate reads that stamp as LIVE state ("目录正在扫描中") and
  /// hides the rescan button for it, so the directory could never be repaired
  /// from the gate. Fully scanned roots become `scanDone`, everything else
  /// `error` — the gate then offers a full rescan. (Descendants are never
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

  /// Splits a DFS directory path into path segments, keeping a SAF
  /// `content://` tree prefix as a single first segment (reversible).
  List<String> _pathSegments(String dirPath) {
    if (dirPath.isEmpty) return const [];
    return isSafPath(dirPath) ? safSegmentsOf(dirPath) : dirPath.split('/');
  }

  /// Cooperative yield: lets the raster / player thread pump a frame.
  Future<void> _yieldToUi() async {
    // 0-duration still yields to the event loop; 1ms gives the engine a
    // chance to composite. Keep it minimal to preserve throughput.
    await Future<void>.delayed(Duration.zero);
  }

  Future<bool> _waitIfPaused() async {
    while (scanStore.state.paused && scanStore.isScanning) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return scanStore.isScanning;
  }

  /// Records a directory listing failure for resume/play-gate bookkeeping.
  ///
  /// Best-effort: a secondary failure here must not abort the whole scan. No
  /// existing `media_nodes` rows are touched, so the snapshot is preserved.
  Future<void> _markDirListingError(String storageId, String dirPath) async {
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
  Future<void> _scanDirDFS(
    String storageId,
    String dirPath,
    double weight,
  ) async {
    if (!scanStore.isScanning) return;
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
    // New directory — clear any previous dir's probe counters so the overlay
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
    // right after a full scan). Above-base prefixes are simply dropped —
    // the storage root itself needs no ancestor row.
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
    // batchUpsert uses ON CONFLICT("id") but the table has
    // UNIQUE(storage_id, path) — existing ancestor nodes from a prior scan
    // have different auto-increment IDs, so we must delete them first.
    if (dirPath.isNotEmpty && !_isSafDir(dirPath)) {
      final rel =
          StoragePathCodec.relativize(storageId, canonicalDbPath(dirPath));
      final segments = rel.isEmpty ? const <String>[] : rel.split('/');
      final ancestors = <MediaNode>[];
      for (int i = 1; i < segments.length; i++) {
        final ancestorPath = segments.sublist(0, i).join('/');
        ancestors.add(
          MediaNode.directory(
            id: '$storageId:$ancestorPath',
            storageId: storageId,
            path: segments.sublist(0, i),
            parentPath:
                i == 1 ? null : segments.sublist(0, i - 1).join('/'),
            pathDepth: i,
            name: segments[i - 1],
          ),
        );
      }
      if (ancestors.isNotEmpty) {
        final toCreate = <MediaNodesTableCompanion>[];
        for (final a in ancestors) {
          final canon = canonicalDbPath(a.path.join('/'));
          final MediaNodesTableData? exists =
              await nodesDao.getByPath(storageId, canon);
          if (exists == null) toCreate.add(a.toCompanion());
        }
        if (toCreate.isNotEmpty) await nodesDao.batchUpsert(toCreate);
      }
    }

    List<FileItem> items;
    try {
      final pathList = _pathSegments(dirPath);
      final isNet = storage.type == StorageType.ftp ||
          storage.type == StorageType.webdav ||
          storage.type == StorageType.network;
      final timeout = Duration(seconds: isNet ? 15 : 30);
      final result = await listDir(storage, pathList).timeout(timeout);
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
    } catch (e) {
      areaKeyLog.e('Scan error at $dirPath: $e');
      // Network error: mark queue error for resume, skip subtree.
      await _markDirListingError(storageId, dirPath);
      return;
    }

    final subdirs = <String>[];
    final mediaNodes = <MediaNode>[];
    // Index-aligned with the playable-file entries inside [mediaNodes].
    final playableItems = <FileItem>[];
    final playableNodeIndexes = <int>[];

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

        playableItems.add(item);
        playableNodeIndexes.add(mediaNodes.length);

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

    // Optional deep probe: fill duration/dimensions from the platform's
    // media metadata source before persisting. Runs in an isolate on
    // Windows (never blocks UI), concurrency-limited to 2 and yields
    // between chunks so playback never janks.
    if (probeService != null && playableItems.isNotEmpty) {
      await _probePlayableNodes(
          dirPath, mediaNodes, playableItems, playableNodeIndexes);
    }

    await _syncDirIncremental(storageId, dirPath, mediaNodes);

    await _ensureSelfDirNode(storageId, dirPath);

    // Mark queue entry done for 50w resume (best-effort, survives kill).
    try {
      await scanStore.markQueueDone(dirPath);
    } catch (_) {}

    // Track discovered subdirs in depthPaths for resume.
    if (subdirs.isNotEmpty) {
      final childDepth =
          dirPath.isEmpty ? 0 : _pathSegments(dirPath).length;
      final childPaths = subdirs
          .map((s) => dirPath.isEmpty ? s : '$dirPath/$s')
          .toList();
      await scanStore.updateDepth(
        depth: childDepth,
        paths: childPaths,
      );
    }

    if (!scanStore.isScanning) return;

    // Count-based progress: this dir's frame is complete (contents written,
    // subdirs discovered). The parent's "done" DB marking happens bottom-up
    // in the aggregate pass, never here (a parent is only done once every
    // child is done — "从下到上回归标记").
    await scanStore.updateProgress(
      scannedDirs: scanStore.state.scannedDirs + 1,
    );

    if (subdirs.isEmpty) {
      // Leaf dir — contribute weight (kept for resume heuristics).
      await scanStore.addProgress(weight);
      await _yieldToUi();
    } else {
      // Has children — recurse DFS, yielding between subtrees so a huge
      // directory tree cannot starve the player raster thread.
      final childWeight = weight / subdirs.length;
      for (final sub in subdirs) {
        if (!scanStore.isScanning) return;
        if (!await _waitIfPaused()) return;
        final childPath = dirPath.isEmpty ? sub : '$dirPath/$sub';
        await _scanDirDFS(storageId, childPath, childWeight);
        await _yieldToUi();
      }
      // All children done — contribute this dir's weight.
      if (scanStore.isScanning) {
        await scanStore.addProgress(weight);
      }
      await _yieldToUi();
    }
  }

  /// Probes playable files in batches (32/批) via batched isolate.
  ///
  /// 50w scale: per-file Isolate.run → per-batch Isolate.run (32× reduction).
  /// Network storages skip probe entirely. Yields between batches keep UI smooth.
  /// Progress note: directory progress stays at the parent dir while a big
  /// batch probes, so the current path carries a per-batch probe counter
  /// (the overlay would otherwise sit at 0% for the whole probe stall).
  Future<void> _probePlayableNodes(
    String dirPath,
    List<MediaNode> mediaNodes,
    List<FileItem> playableItems,
    List<int> playableNodeIndexes,
  ) async {
    if (probeService == null) return;
    // Network storages (FTP/WebDAV) never probe — high latency + no Shell.
    final isNetwork = storage.type == StorageType.ftp ||
        storage.type == StorageType.webdav ||
        storage.type == StorageType.network;
    if (isNetwork) return;

    const batchSize = 32;
    var probed = 0;
    for (var start = 0; start < playableItems.length; start += batchSize) {
      if (!scanStore.isScanning) break;
      if (!await _waitIfPaused()) break;
      final end = (start + batchSize).clamp(0, playableItems.length);
      final uris = playableItems.sublist(start, end).map((e) => e.uri).toList();
      final indexes = playableNodeIndexes.sublist(start, end);
      try {
        final results = await probeService!.probeFiles(uris);
        for (var i = 0; i < results.length && i < indexes.length; i++) {
          final nodeIndex = indexes[i];
          // Sanity gate: handlers for exotic containers return
          // present-but-absurd dimensions (A/B-pinned: height 667040 for
          // 720p); null those before they reach the DB.
          final sane = sanitizeProbeResult(results[i]);
          mediaNodes[nodeIndex] = applyProbeResult(mediaNodes[nodeIndex], sane);
          // Observability: count usable vs empty so a no-duration scan
          // is attributable; keep the first empty samples only.
          _probeAttempted++;
          if (results[i].durationMs != null && results[i].durationMs! > 0) {
            _probeUsable++;
          } else {
            _probeEmpty++;
            if (_probeEmptySamples.length < 3) {
              _probeEmptySamples.add(uris[i]);
            }
          }
        }
      } catch (_) {
        // Batch failure is non-fatal; keep unprobed nodes.
        _probeAttempted += indexes.length;
        _probeEmpty += indexes.length;
      }
      probed += indexes.length;
      // File-level probe progress: the directory counter cannot move until
      // the whole dir persists, so carry the probe position in the transient
      // timing readout (best-effort; never fails the scan). The overlay
      // localizes it — the service must not build display text.
      try {
        scanStore.setProbeProgress(probed, playableItems.length);
      } catch (_) {}
      // Yield only for large batches.
      if (uris.length >= 16) await _yieldToUi();
    }
  }

  Future<void> _syncDirIncremental(
    String storageId,
    String dirPath,
    List<MediaNode> freshNodes,
  ) async {
    final canonicalDir = canonicalDbPath(dirPath);
    final List<MediaNodesTableData> existing = canonicalDir.isEmpty
        ? await nodesDao.getRootLevelNodes(storageId)
        : await nodesDao.getDirectChildren(storageId, canonicalDir);
    // Case is identity on a case-sensitive filesystem. Folding unconditionally
    // merged `photo.JPG` and `photo.jpg` into one existence key there (the
    // stale row of a deleted twin was never removed and each file was compared
    // against the wrong row). On NTFS/SMB a case-only rename is the SAME file,
    // so folding stays deliberate.
    final bool foldCase =
        pathRidesCaseInsensitiveFs(storage.basePath.join('/'));
    String nameKeyOf(String name) => foldCase ? name.toLowerCase() : name;
    final existingByName = <String, MediaNodesTableData>{};
    for (final MediaNodesTableData row in existing) {
      existingByName[nameKeyOf(row.name)] = row;
    }
    final freshByName = <String, MediaNode>{};
    for (final MediaNode n in freshNodes) {
      freshByName[nameKeyOf(n.name)] = n;
    }

    final toDeleteFiles = <String>[];
    final toDeleteDirPrefixes = <String>[];
    for (final MediaNodesTableData row in existing) {
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
      final MediaNodesTableData? row = existingByName[nameKeyOf(node.name)];
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
        final probeSame = (node.durationMs == null || row.durationMs == node.durationMs) &&
            (node.width == null || row.width == node.width) &&
            (node.height == null || row.height == node.height);
        // The association set is part of "unchanged": adding or deleting a
        // subtitle in the same directory does NOT touch the video's size or
        // mtime, so a size/mtime-only predicate would serve the stale set
        // forever — a deleted track offered (and failing to load) on every
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
    // row with an above-base parent the adapter cannot relativize back —
    // the phantom that permanently blocked the root scanDone stamp.
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

  Future<void> _computeAllAggregates(String storageId) async {
    var depthPaths = scanStore.state.depthPaths;
    // 50w: depthPaths may be capped at 20k; hydrate full map from queue table.
    if (scanStore.state.totalDirs >= 20000) {
      try {
        final qMap = await DbModule.scanQueueDao.loadDepthPaths(storageId);
        if (qMap.isNotEmpty) depthPaths = qMap;
      } catch (_) {}
    }

    int maxDepth = 0;
    for (final entry in depthPaths.entries) {
      if (entry.key > maxDepth) maxDepth = entry.key;
    }

    int processed = 0;
    for (var depth = maxDepth; depth >= 0; depth--) {
      final paths = depthPaths[depth] ?? [];
      for (final dirPath in paths) {
        if (!scanStore.isScanning) return;
        final normalized = dirPath.replaceAll(RegExp(r'^/|/$'), '');
        try {
          await _computeDirAggregates(storageId, normalized);
          await _markDirDoneWhenChildrenDone(storageId, normalized);
        } catch (e) {
          areaKeyLog.e('Aggregate error at $normalized: $e');
        }
        if (++processed % 20 == 0) await _yieldToUi();
      }
    }
  }

  /// Marks [dirPath] as `scanDone` when it has no direct child directory left
  /// in a non-done state (leaf dirs trivially qualify). Parent dirs are only
  /// stamped after all their children — this is the "从下到上回归标记" rule.
  Future<void> _markDirDoneWhenChildrenDone(
      String storageId, String dirPath) async {
    // A dir that failed to list this run — or whose direct child dir did — is
    // not "fully scanned": keep its `error` stamp so the play gate warns.
    // `_erroredDirs` is keyed by the ABSOLUTE canonical path; raw DB rows are
    // relative, so absolutize before comparing.
    if (_erroredDirs
        .contains(StoragePathCodec.absolutize(storageId, canonicalDbPath(dirPath)))) {
      return;
    }
    try {
      final children = await nodesDao.getChildDirs(storageId, dirPath);
      if (children.any((c) => _erroredDirs
          .contains(StoragePathCodec.absolutize(storageId, c.path)))) {
        return;
      }
      final allDone = await nodesDao.allChildDirsScanned(storageId, dirPath);
      if (children.isEmpty || allDone) {
        await nodesDao.markDirScanDone(storageId, dirPath);
      }
    } catch (e) {
      areaKeyLog.e('Scan-done marking error at $dirPath: $e');
    }
  }

  /// Walk up from each scan root path, recomputing aggregates for every
  /// ancestor directory until reaching the storage root (parentPath == null).
  /// This ensures partial rescans correctly update parent totals.
  Future<void> _recomputeAncestors(
    String storageId,
    List<String> rootPaths,
  ) async {
    final visited = <String>{};
    final queue = <String>[
      for (final p in rootPaths) p.replaceAll(RegExp(r'^/|/$'), ''),
    ];

    while (queue.isNotEmpty) {
      if (!scanStore.isScanning) return;
      final dirPath = queue.removeAt(0);
      if (!visited.add(dirPath)) continue;

      final node = await nodesDao.getByPath(storageId, dirPath);
      if (node == null) continue;

      // Reached the storage root — compute its aggregates from its
      // children and stop walking up (nothing above the root).
      if (node.parentPath == null) {
        try {
          await _computeDirAggregates(storageId, dirPath);
          await _markDirDoneWhenChildrenDone(storageId, dirPath);
        } catch (e) {
          areaKeyLog.e('Root aggregate error at $dirPath: $e');
        }
        await _yieldToUi();
        continue;
      }

      try {
        await _computeDirAggregates(storageId, node.parentPath!);
        await _markDirDoneWhenChildrenDone(storageId, node.parentPath!);
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
  /// top-level nodes, not just one — the storage root is a virtual
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
          // Source covers the entire storage — sum ALL top-level nodes.
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
    List<String> rootPaths,
  ) async {
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
              onPressed: () => Navigator.pop(context),
              child: Text(t.cancel),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, _IncompleteScanAction.startNew),
              child: Text(t.scan_incomplete_new),
            ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.pop(context, _IncompleteScanAction.resume),
              child: Text(t.scan_incomplete_resume),
            ),
          ],
        );
      },
    );
  }
}

enum _IncompleteScanAction { resume, startNew }
