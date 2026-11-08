import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/store/kv/secure_kv.dart';
import 'package:iris/store/kv/use_kv_store.dart';

/// The scan's percentage must describe the TREE, not the part already walked.
///
/// A depth-first walk discovers a directory immediately before scanning it, so
/// `scannedDirs / discoveredDirs` reads ~99% almost immediately. Measured on a
/// 34,005-directory phone volume: 97.7% at 32% of the elapsed time (panel said
/// "3 s left" for 3 more minutes), 99.9% for the last minute. The stored
/// snapshot's directory count is the only honest denominator, and an unknown
/// total must render as "discovering" rather than a fabricated fraction.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  /// 'music', 'music/a', 'music/a/b' 鈥?a three-directory snapshot.
  ///
  /// The root row is stamped scan-done, which is what makes the count
  /// trustworthy: a snapshot left by an interrupted scan (or a partial backup
  /// restore) must NOT become a denominator.
  Future<void> seedDirs(String storageId) async {
    for (final entry in <(String, String?, int)>[
      ('', null, 0),
      ('music', null, 1),
      ('music/a', 'music', 2),
      ('music/a/b', 'music/a', 3),
    ]) {
      await DbModule.mediaNodesDao.upsertNode(MediaNode.directory(
        id: '$storageId:${entry.$1}',
        storageId: storageId,
        path: entry.$1.isEmpty ? const [] : entry.$1.split('/'),
        parentPath: entry.$2,
        pathDepth: entry.$3,
        name: entry.$1.isEmpty ? storageId : entry.$1.split('/').last,
      ));
    }
    await DbModule.mediaNodesDao.markDirScanDone(storageId, '');
  }

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });

  tearDownAll(() async {
    resetKvStoreForTest();
    await db.close();
  });

  group('countDirsUnder', () {
    setUp(() async {
      await db.delete(db.mediaNodesTable).go();
      await seedDirs('s1');
    });

    test('the whole scope counts every stored directory', () async {
      expect(await DbModule.mediaNodesDao.countDirsUnder('s1', ['']), 4);
    });

    test('a partial scan counts only its own subtree', () async {
      expect(await DbModule.mediaNodesDao.countDirsUnder('s1', ['music/a']), 2,
          reason: 'the root folder itself belongs to the denominator');
      expect(await DbModule.mediaNodesDao.countDirsUnder('s1', ['music']), 3);
    });

    test('a never-scanned root answers zero, not "everything"', () async {
      expect(await DbModule.mediaNodesDao.countDirsUnder('s1', ['nope']), 0);
      expect(await DbModule.mediaNodesDao.countDirsUnder('other', ['']), 0);
    });

    test('a SAF scope gates on its own base row, not the empty container',
        () async {
      // SAF scopes never create the `''` container row: their root row
      // carries the full `content://...` URI (document-form base, as
      // `pickDirectory` returns it). The estimate must not read 0 forever.
      const base =
          'content://com.android.externalstorage.documents/tree/primary%3Aa_all/document/primary%3Aa_all';
      const vision = '$base/vision';
      const music = '$vision/music';
      for (final entry in <(String, String?, int)>[
        (base, null, 3),
        (vision, base, 4),
        (music, vision, 5),
      ]) {
        await DbModule.mediaNodesDao.upsertNode(MediaNode.directory(
          id: 'saf1:${entry.$1}',
          storageId: 'saf1',
          path: safSegmentsOf(entry.$1),
          parentPath: entry.$2,
          pathDepth: entry.$3,
          name: entry.$1.split('/').last,
        ));
      }
      expect(await DbModule.mediaNodesDao.countDirsUnder('saf1', [base]), 0,
          reason: 'no completed snapshot yet: no estimate, not zero-as-size');
      await DbModule.mediaNodesDao.markDirScanDone('saf1', base);
      expect(await DbModule.mediaNodesDao.countDirsUnder('saf1', [base]), 3);
    });

    test('a snapshot left by an unfinished scan is not a denominator',
        () async {
      // The row set exists but no scan completed over it: this is exactly the
      // shape a partial backup restore or a killed scan leaves behind, and
      // trusting it made the bar sit at 99% for half the run.
      await db.update(db.mediaNodesTable).write(
            const MediaNodesTableCompanion(isScanDone: Value(false)),
          );
      expect(await DbModule.mediaNodesDao.countDirsUnder('s1', ['']), 0);
    });
  });

  group('scan progress denominator', () {
    late MemoryKvStore kv;
    late RecursiveScanStore store;

    setUp(() async {
      await db.delete(db.mediaNodesTable).go();
      await db.delete(db.scanQueueTable).go();
      kv = MemoryKvStore();
      setKvStoreForTest(kv);
      store = RecursiveScanStore();
      await store.initialized;
    });

    tearDown(() async {
      await store.dispose();
      resetKvStoreForTest();
    });

    test('a rescan starts at the stored size instead of 1/1', () async {
      await seedDirs('s1');
      await store.startScan(storageId: 's1', depthPaths: {
        0: [''],
      });
      expect(store.state.totalDirs, 4,
          reason: 'the previous snapshot knows how big this tree is');
      expect(store.state.progressFraction, 0,
          reason: 'nothing has been scanned yet');

      await store.updateDepth(depth: 1, paths: ['music', 'music/a']);
      expect(store.state.totalDirs, 4,
          reason: 'discovering a directory must not move the denominator');

      await store.updateDepth(depth: 2, paths: ['x', 'y', 'z', 'w']);
      expect(store.state.totalDirs, 7,
          reason: 'a tree that grew past the snapshot raises the floor');
    });

    test('a first-ever scan reports an unknown total, not a fake fraction',
        () async {
      // No rows for this storage: nobody knows the tree's size.
      await store.startScan(storageId: 's2', depthPaths: {
        0: [''],
      });
      expect(store.state.totalDirs, 0);
      await store.updateDepth(depth: 1, paths: ['a', 'b', 'c']);
      expect(store.state.totalDirs, 0,
          reason: 'scanned/discovered would sit at 100% for the whole walk');
      expect(store.state.progressFraction, 0);
    });

    test('a stopped scan keeps every directory it discovered', () async {
      await seedDirs('s1');
      await store.startScan(storageId: 's1', depthPaths: {
        0: ['music'],
      });
      await store.updateDepth(depth: 1, paths: ['music/a', 'music/b']);
      // Buffered on purpose: one insert per directory was one transaction per
      // directory on a phone.
      expect(await DbModule.scanQueueDao.countAll('s1'), 1,
          reason: 'the discovery rows are buffered, not lost');

      await store.stopScan();
      expect(await DbModule.scanQueueDao.countAll('s1'), 3,
          reason: 'a resume must find every directory this run discovered');
    });
  });
}
