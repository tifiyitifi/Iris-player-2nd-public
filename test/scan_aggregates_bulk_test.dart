import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
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

/// The aggregate pass runs on every scanned directory, so its shape decides
/// whether a phone-sized library takes seconds or minutes. It used to be ~4
/// statements per folder (materialize all children, materialize the child dirs
/// again, probe for an unscanned child, update). It is now two flat reads plus a
/// batched write, restricted to the directories this run actually walked.
///
/// These tests pin the OBSERVABLE behaviour those statements produced, because
/// the play gate reads it: totals per directory, and the bottom-up `scanDone`
/// rule ("从下到上回归标记").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;
  late MediaNodesDao dao;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
    dao = DbModule.mediaNodesDao;
  });

  tearDownAll(() async {
    await db.close();
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

  FileItem file(String name, int size) =>
      FileItem(name: name, uri: name, size: size);

  testWidgets('totals and the done stamp roll up a nested tree', (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'agg-tree';
      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: ftp(id),
        scanStore: scanStore,
        nodesDao: dao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        listDir: (s, p) async => switch (p.join('/')) {
          'a' => FileListResult([
              FileItem(name: 'b', uri: 'a/b', isDir: true),
              FileItem(name: 'c', uri: 'a/c', isDir: true),
              file('top.mp4', 50),
            ]),
          'a/b' => FileListResult([
              file('x.mp4', 100),
              file('y.mp4', 200),
            ]),
          'a/c' => FileListResult([file('z.mp4', 300)]),
          _ => const FileListResult(<FileItem>[]),
        },
        probeService: null,
      );

      await service.scanRecursively(rootPaths: const ['a'], context: ctx);

      expect(scanStore.state.phase, ScanPhase.done,
          reason: scanStore.state.error);

      final a = (await dao.getByPath(id, 'a'))!;
      expect(a.directDirCount, 2);
      expect(a.directMediaCount, 1);
      expect(a.directItemCount, 3);
      expect(a.totalDirCount, 2);
      expect(a.totalMediaCount, 4);
      expect(a.totalItemCount, 6);
      expect(a.totalSizeInBytes, 650);
      expect(a.scanState, 'scanDone');

      final b = (await dao.getByPath(id, 'a/b'))!;
      expect(b.directMediaCount, 2);
      expect(b.totalItemCount, 2);
      expect(b.totalSizeInBytes, 300);
      expect(b.scanState, 'scanDone', reason: 'a leaf is complete once listed');
    });
  });

  testWidgets('a failed child keeps its parent out of scanDone', (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'agg-fail';
      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: ftp(id),
        scanStore: scanStore,
        nodesDao: dao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        listDir: (s, p) async => switch (p.join('/')) {
          'r' => FileListResult([
              FileItem(name: 'ok', uri: 'r/ok', isDir: true),
              FileItem(name: 'bad', uri: 'r/bad', isDir: true),
            ]),
          'r/ok' => FileListResult([file('v.mp4', 10)]),
          _ => const FileListResult(
              <FileItem>[],
              errorKind: StorageListErrorKind.unreachable,
              errorDetail: 'boom',
            ),
        },
      );

      await service.scanRecursively(rootPaths: const ['r'], context: ctx);

      expect((await dao.getByPath(id, 'r/ok'))!.scanState, 'scanDone');
      expect((await dao.getByPath(id, 'r/bad'))!.scanState, isNot('scanDone'));
      expect((await dao.getByPath(id, 'r'))!.scanState, isNot('scanDone'),
          reason: 'an unreachable child means the parent is not fully scanned');
    });
  });

  testWidgets('a partial rescan leaves an unrelated sibling row untouched',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'agg-partial';
      // A directory outside this run's scope, with aggregates from a previous
      // scan. The bulk pass reads the whole scope but must only write what it
      // walked.
      await dao.batchUpsert([
        MediaNode.directory(
          id: '$id:other',
          storageId: id,
          path: const ['other'],
          pathDepth: 1,
          name: 'other',
        ).toCompanion(),
      ]);
      await dao.updateAggregates(
        storageId: id,
        path: 'other',
        directMediaCount: 42,
        directDirCount: 0,
        directItemCount: 42,
        totalMediaCount: 42,
        totalDirCount: 0,
        totalItemCount: 42,
        totalSizeInBytes: 4200,
        totalDurationMs: 42000,
      );

      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: ftp(id),
        scanStore: scanStore,
        nodesDao: dao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        // Only `a` is scanned; `other` is a root-level sibling this run never
        // lists, so its row must keep both its aggregates and its absent stamp.
        listDir: (s, p) async => p.join('/') == 'a'
            ? FileListResult([file('only.mp4', 7)])
            : const FileListResult(<FileItem>[]),
      );

      await service.scanRecursively(rootPaths: const ['a'], context: ctx);

      final other = (await dao.getByPath(id, 'other'))!;
      expect(other.totalMediaCount, 42,
          reason: 'a subtree the run never walked must keep its aggregates');
      expect(other.totalSizeInBytes, 4200);
      expect(other.scanState, isNot('scanDone'),
          reason: 'and must never be stamped complete by someone else\'s scan');
    });
  });
}
