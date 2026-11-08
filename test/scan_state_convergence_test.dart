import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/service/recursive_scan_service.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/enums/storage_list_error.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/storage.dart';

/// Scan-state convergence: a run must never end with a directory still stamped
/// `scanning`, because the play gate reads that stamp as LIVE state ("目录正在
/// 扫描中") and offers no rescan for it. A failed child listing, a stopped run
/// and an empty root path all used to leave it behind forever.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  Storage ftp(String id) => Storage.ftp(
        id: id,
        name: 'FTP',
        host: '10.0.0.2',
        basePath: const [''],
        port: '21',
        username: 'u',
        password: 'p',
      );

  Future<BuildContext> contextOf(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ));
    return ctx;
  }

  testWidgets('a failed child listing converges the parent, never scans forever',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'conv-fail';
      await DbModule.mediaNodesDao.batchUpsert([
        MediaNode.directory(
          id: '$id:a',
          storageId: id,
          path: const ['a'],
          pathDepth: 1,
          name: 'a',
        ).toCompanion(),
        MediaNode.directory(
          id: '$id:a/b',
          storageId: id,
          path: const ['a', 'b'],
          parentPath: 'a',
          pathDepth: 2,
          name: 'b',
        ).toCompanion(),
      ]);

      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: ftp(id),
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        listDir: (s, p) async => p.join('/') == 'a'
            ? FileListResult([
                FileItem(name: 'b', uri: 'a/b', isDir: true),
              ])
            : const FileListResult(
                <FileItem>[],
                errorKind: StorageListErrorKind.unreachable,
                errorDetail: 'boom',
              ),
      );

      await service.scanRecursively(rootPaths: const ['a'], context: ctx);

      // The overlay reports a finished scan...
      expect(scanStore.state.phase, ScanPhase.done);
      // ...so no ancestor may be left claiming it is still being scanned.
      final parent = await DbModule.mediaNodesDao.dirScanStatus(id, 'a');
      expect(parent?.state, isNot('scanning'));
      expect(parent?.state, 'error');
      expect((await DbModule.mediaNodesDao.dirScanStatus(id, 'a/b'))?.state,
          'error');
    });
  });

  testWidgets('a stopped scan converges its stamped root', (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'conv-stop';
      await DbModule.mediaNodesDao.batchUpsert([
        MediaNode.directory(
          id: '$id:s',
          storageId: id,
          path: const ['s'],
          pathDepth: 1,
          name: 's',
        ).toCompanion(),
      ]);

      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: ftp(id),
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        listDir: (s, p) async {
          // The user stops the scan while it is walking.
          await scanStore.stopScan();
          return const FileListResult(<FileItem>[]);
        },
      );

      await service.scanRecursively(rootPaths: const ['s'], context: ctx);

      expect(scanStore.state.phase, ScanPhase.stopped);
      expect((await DbModule.mediaNodesDao.dirScanStatus(id, 's'))?.state,
          isNot('scanning'));
    });
  });

  testWidgets('a stopped scan never marks unvisited stale children done',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'conv-stop-stale';
      final dao = DbModule.mediaNodesDao;
      await dao.batchUpsert([
        MediaNode.directory(
          id: '$id:s',
          storageId: id,
          path: const ['s'],
          pathDepth: 1,
          name: 's',
        ).toCompanion(),
        MediaNode.directory(
          id: '$id:s/kidA',
          storageId: id,
          path: const ['s', 'kidA'],
          parentPath: 's',
          pathDepth: 2,
          name: 'kidA',
        ).toCompanion(),
        MediaNode.directory(
          id: '$id:s/kidB',
          storageId: id,
          path: const ['s', 'kidB'],
          parentPath: 's',
          pathDepth: 2,
          name: 'kidB',
        ).toCompanion(),
      ]);
      // A previous successful scan: every stamp reads done ...
      await dao.markDirScanDone(id, 's');
      await dao.markDirScanDone(id, 's/kidA');
      await dao.markDirScanDone(id, 's/kidB');

      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: ftp(id),
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        listDir: (s, p) async {
          if (p.join('/') == 's') {
            // The user stops the scan while the root is listing, so neither
            // child is ever walked by this run and their old `scanDone`
            // stamps are stale evidence, not proof of completeness.
            // (Stopping inside one child is racy under bounded child
            // concurrency — a sibling worker may already have claimed the
            // next child — so the stop is issued here, deterministically
            // before any child starts.)
            await scanStore.stopScan();
            return FileListResult([
              FileItem(name: 'kidA', uri: 's/kidA', isDir: true),
              FileItem(name: 'kidB', uri: 's/kidB', isDir: true),
            ]);
          }
          return const FileListResult(<FileItem>[]);
        },
      );

      await service.scanRecursively(rootPaths: const ['s'], context: ctx);

      expect(scanStore.state.phase, ScanPhase.stopped);
      final root = await dao.dirScanStatus(id, 's');
      expect(root?.state, isNot('scanning'));
      // `kidB` was never visited, so the root must NOT converge to done on
      // the strength of stale child stamps — the gate must offer a rescan.
      expect(root?.state, 'error');
    });
  });

  testWidgets('an empty root path scans the storage base, not an empty listing',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'conv-root';
      final storage = Storage.local(
        id: id,
        type: StorageType.internal,
        name: 't',
        basePath: const ['/data', 'lib'],
      );
      final requested = <String>[];
      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: storage,
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        listDir: (s, p) async {
          requested.add(p.join('/'));
          return const FileListResult(<FileItem>[]);
        },
      );

      // '' = the paged browser's root scope; listing it as an empty path made
      // the platform answer "empty" and the incremental sync prune the storage.
      await service.scanRecursively(rootPaths: const [''], context: ctx);

      expect(requested, isNotEmpty);
      expect(requested.first, 'data/lib');
    });
  });
}
