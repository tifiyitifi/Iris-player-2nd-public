import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/kv/secure_kv.dart';
import 'package:iris/store/kv/use_kv_store.dart';

/// Persistence contracts for the scan snapshot on a phone-sized library.
///
/// A 34k-directory volume (measured on a real Android 10 device) made the old
/// blob grow to the 20k-path cap — roughly 1.5 MB of JSON re-encrypted and
/// committed every 300 ms. The resume map already has an authoritative home
/// (`scan_queue`), so the blob keeps counters only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late MemoryKvStore kv;
  late RecursiveScanStore store;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });

  tearDownAll(() async {
    resetKvStoreForTest();
    await db.close();
  });

  setUp(() async {
    await db.delete(db.scanQueueTable).go();
    await db.delete(db.mediaNodesTable).go();
    kv = MemoryKvStore();
    setKvStoreForTest(kv);
    store = RecursiveScanStore();
    await store.initialized;
  });

  tearDown(() async {
    await store.dispose();
    resetKvStoreForTest();
  });

  Map<String, dynamic> persistedBlob() {
    final raw = kv.values['recursive_scan_state'];
    expect(raw, isNotNull, reason: 'the scan snapshot must still be persisted');
    return jsonDecode(raw!) as Map<String, dynamic>;
  }

  Future<List<String>> pendingPaths() =>
      DbModule.scanQueueDao.getPendingPaths('s1');

  /// A previously scanned volume: these rows are the progress denominator's
  /// floor. Without them the total is UNKNOWN (0) and the overlay says
  /// "discovering" instead of inventing a fraction — see
  /// `scan_progress_denominator_test.dart`.
  Future<void> seedScannedDirs(String storageId, List<String> paths) async {
    // The storage root must exist AND be stamped scan-done: only a COMPLETED
    // snapshot is trusted as the progress denominator (a partial restore would
    // otherwise report ~99% for half the run).
    await DbModule.mediaNodesDao.upsertNode(MediaNode.directory(
      id: '$storageId:',
      storageId: storageId,
      path: const [],
      parentPath: null,
      pathDepth: 0,
      name: storageId,
    ));
    await DbModule.mediaNodesDao.markDirScanDone(storageId, '');
    for (final path in paths) {
      final parts = path.split('/');
      await DbModule.mediaNodesDao.upsertNode(MediaNode.directory(
        id: '$storageId:$path',
        storageId: storageId,
        path: parts,
        parentPath:
            parts.length == 1 ? null : parts.sublist(0, parts.length - 1).join('/'),
        pathDepth: parts.length,
        name: parts.last,
      ));
    }
  }

  test('the persisted blob carries counters but not the resume map', () async {
    await seedScannedDirs('s1', ['A', 'A/b', 'A/c', 'A/b/x', 'A/b/y']);
    await store.startScan(
      storageId: 's1',
      depthPaths: {
        0: ['A'],
        1: ['A/b', 'A/c'],
      },
    );
    await store.updateDepth(depth: 2, paths: ['A/b/x', 'A/b/y']);

    // Live state keeps the map: the running scan walks it.
    expect(store.state.depthPaths[2], ['A/b/x', 'A/b/y']);
    expect(store.state.totalDirs, 5);

    // A lifecycle save (debounced during the run, immediate on transitions).
    await store.save(store.state);

    final blob = persistedBlob();
    expect(blob['depthPaths'], isEmpty,
        reason: 'the resume map belongs to scan_queue, not the KV blob');
    expect(blob['totalDirs'], 5,
        reason: 'progress denominators must survive a restart');
  });

  test('totalDirs tracks additions without re-summing the whole map', () async {
    await seedScannedDirs('s2', ['A']);
    await store.startScan(storageId: 's2', depthPaths: {0: ['A']});
    expect(store.state.totalDirs, 1);

    await store.updateDepth(depth: 1, paths: ['A/b', 'A/c']);
    expect(store.state.totalDirs, 3);

    await store.updateDepth(depth: 2, paths: ['A/b/x', 'A/c/y']);
    expect(store.state.totalDirs, 5);
  });

  test('queue-done marks are buffered and flushed on a terminal phase',
      () async {
    // 40 pending entries so the 32-entry flush threshold is crossed.
    final roots = [for (var i = 0; i < 40; i++) 'R$i'];
    await store.startScan(storageId: 's1', depthPaths: {0: roots});

    for (final root in roots) {
      await store.markQueueDone(root);
    }

    // 40 appended, so the buffer flushed at 32; the last 8 are still pending.
    expect((await pendingPaths()).length, 8,
        reason: 'buffered marks must not cost one transaction per directory');

    await store.stopScan();
    expect(await pendingPaths(), isEmpty,
        reason: 'a terminal phase must flush what the buffer still holds');
  });

  test('a run left `scanning` by a dead process reloads as interrupted',
      () async {
    await store.startScan(
      storageId: 's1',
      depthPaths: {
        0: ['A'],
        1: ['A/b'],
      },
    );
    await store.pauseScan();

    // What a restarted process sees: the blob (no map) plus the queue table.
    final reloaded = RecursiveScanStore();
    await reloaded.initialized;
    // The work list is recoverable ...
    expect(reloaded.state.depthPaths[1], ['A/b'],
        reason: 'resume must be rebuilt from scan_queue when the blob is bare');
    // ... but the run itself is not: claiming `scanning` from a dead process
    // showed a frozen progress panel with no scan behind it.
    expect(reloaded.state.phase, ScanPhase.error);
    expect(reloaded.hasIncompleteScan, isTrue,
        reason: 'the next scan must offer resume / start-new');
    await reloaded.dispose();
  });

  test('the blob never exceeds the old cap growth on a huge tree', () async {
    // Simulates the shape of a 34k-directory phone volume: the persisted value
    // stays small because only counters are written.
    await seedScannedDirs('s3', ['A']);
    await store.startScan(storageId: 's3', depthPaths: {0: ['A']});
    for (var depth = 1; depth <= 6; depth++) {
      await store.updateDepth(
        depth: depth,
        paths: [for (var i = 0; i < 200; i++) 'd$depth/$i'],
      );
    }

    final raw = kv.values['recursive_scan_state']!;
    expect(raw.length, lessThan(2000),
        reason: 'a growing path list must not be written to secure storage');
    expect(store.state.totalDirs, 1201);
  });
}
