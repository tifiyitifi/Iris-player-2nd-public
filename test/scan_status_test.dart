import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/models/db/app_database.dart';

/// Scan-state enum marking + count-based progress contracts.
void main() {
  late AppDatabase db;
  late MediaNodesDao dao;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = MediaNodesDao(db);
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedDir(String path, {String? parent}) async {
    final segments = path.split('/').where((e) => e.isNotEmpty).toList();
    await dao.batchUpsert([
      MediaNode.directory(
        id: 'st1:$path',
        storageId: 'st1',
        path: segments,
        parentPath: (parent == null || parent.isEmpty) ? null : parent,
        pathDepth: segments.length,
        name: segments.last,
      ).toCompanion(),
    ]);
  }

  group('DAO scan-state marking', () {
    test('markDirScanning sets scanState=scanning, keeps isScanDone false', () async {
      await seedDir('A');
      await dao.markDirScanning('st1', 'A');

      final status = await dao.dirScanStatus('st1', 'A');
      expect(status?.state, 'scanning');

      final row = await db.customSelect(
        'SELECT is_scan_done FROM media_nodes WHERE storage_id = ? AND path = ?',
        variables: [Variable.withString('st1'), Variable.withString('A')],
      ).getSingle();
      expect(row.data['is_scan_done'], 0);
    });

    test('markDirScanDone sets scanState=scanDone + isScanDone + lastScanAt', () async {
      await seedDir('A');
      await dao.markDirScanDone('st1', 'A');

      final status = await dao.dirScanStatus('st1', 'A');
      expect(status?.state, 'scanDone');
      expect(status?.lastScanAt, isNotNull);

      final row = await db.customSelect(
        'SELECT is_scan_done, last_scan_at FROM media_nodes '
        'WHERE storage_id = ? AND path = ?',
        variables: [Variable.withString('st1'), Variable.withString('A')],
      ).getSingle();
      expect(row.data['is_scan_done'], 1);
      expect(row.data['last_scan_at'], isNotNull);
    });

    test('markDirScanError sets scanState=error', () async {
      await seedDir('A');
      await dao.markDirScanError('st1', 'A');
      expect((await dao.dirScanStatus('st1', 'A'))?.state, 'error');
    });

    test('dirScanStatus for a missing row reports notScan', () async {
      final status = await dao.dirScanStatus('st1', 'missing');
      expect(status?.state, 'notScan');
      expect(status?.lastScanAt, isNull);
    });

    test('root path "" resolves the parentPath IS NULL row', () async {
      // Root dir node: path '' is stored as a node with empty path list.
      await dao.batchUpsert([
        MediaNode.directory(
          id: 'st1:',
          storageId: 'st1',
          path: const [],
          parentPath: null,
          pathDepth: 0,
          name: 'st1',
        ).toCompanion(),
      ]);
      await dao.markDirScanning('st1', '');
      expect((await dao.dirScanStatus('st1', ''))?.state, 'scanning');
    });
  });

  group('progress fraction', () {
    test('progressFraction = scannedDirs / totalDirs, clamped', () {
      // Pure model contract: the STORE supplies the total (the stored tree
      // size), the fraction itself is count-based, so 100% can only appear once
      // every directory is done.
      expect(
        const RecursiveScanState(totalDirs: 5, scannedDirs: 2).progressFraction,
        closeTo(0.4, 0.001),
      );
      expect(
        const RecursiveScanState(totalDirs: 5, scannedDirs: 5)
            .progressFraction,
        1.0,
      );
      expect(
        const RecursiveScanState(totalDirs: 5, scannedDirs: 99)
            .progressFraction,
        1.0,
        reason: 'clamped',
      );
      // Unknown total (never scanned): 0, never "done".
      expect(const RecursiveScanState(scannedDirs: 7).progressFraction, 0.0);
    });

    test('completeScan sets progress to 1.0 (the only 100% source)', () async {
      final store = RecursiveScanStore();
      store.updateProgress(scannedDirs: 2);
      expect(store.state.progress, 0.0); // weight field untouched

      await store.completeScan();
      expect(store.state.phase, ScanPhase.done);
      expect(store.state.progress, 1.0);
      await store.dispose();
    });
  });
}
