import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/scan/service/recursive_scan_service.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:path/path.dart' as p;

/// A missing/unreadable local directory is reported as an error-free EMPTY
/// listing. The incremental sync must never read that as "every child was
/// deleted": it used to purge the directory's whole DB snapshot, which then
/// looked like "the dropped file is not in the database".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
  });

  tearDownAll(() {
    StoragePathCodec.baseResolver = (_) => null;
    db.close();
  });

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

  Future<void> seedFile(String storageId, String path) async {
    await DbModule.mediaNodesDao.batchUpsert([
      MediaNode.file(
        id: '$storageId:$path',
        storageId: storageId,
        path: path.split('/'),
        name: path.split('/').last,
        mediaType: MediaType.video,
        sizeInBytes: 10,
      ).toCompanion(),
    ]);
  }

  testWidgets('scanning a MISSING local root keeps its existing rows',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'missing-root';
      final storage = Storage.local(
        id: id,
        type: StorageType.internal,
        name: 'gone',
        basePath: const ['C:/iris-definitely-missing-root'],
      );
      StoragePathCodec.baseResolver = (sid) => sid == id ? storage.basePath : null;
      await seedFile(id, 'movies/keep.mp4');

      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: storage,
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        probeService: null,
      );

      // Real filesystem lister: a missing directory yields an error-free empty
      // result on desktop, which is exactly the ambiguous case under guard.
      await service.scanRecursively(
        rootPaths: [storage.basePath.join('/')],
        context: ctx,
      );

      expect(
        await DbModule.mediaNodesDao.getByPath(id, 'movies/keep.mp4'),
        isNotNull,
        reason: 'an empty listing for a missing dir must not purge rows',
      );
    });
  });

  testWidgets('a superseded run stops walking, never completes the newer run',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'supersede-run';
      final storage = Storage.local(
        id: id,
        type: StorageType.internal,
        name: 'sup',
        basePath: const ['C:/iris-supersede'],
      );
      StoragePathCodec.baseResolver = (sid) => sid == id ? storage.basePath : null;

      final scanStore = RecursiveScanStore();
      await scanStore.initialized;

      final firstListing = Completer<void>();
      final releaseFirst = Completer<void>();
      var listings = 0;
      Future<FileListResult> lister(Storage s, List<String> path) async {
        listings++;
        if (listings == 1) {
          firstListing.complete();
          await releaseFirst.future;
        }
        return FileListResult(const <FileItem>[]);
      }

      final first = RecursiveScanService(
        storage: storage,
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        probeService: null,
        listDir: lister,
      );
      final firstRun = first.scanRecursively(
        rootPaths: ['C:/iris-supersede'],
        context: ctx,
      );
      await firstListing.future;

      // A second run takes the store over while the first is still listing. The
      // scan lease is re-entrant inside one window, so this is reachable (scan
      // again, or drop a folder while a manual scan runs).
      final newerOwner = Object();
      await scanStore.startScan(
        storageId: id,
        depthPaths: {
          0: ['C:/iris-supersede']
        },
        owner: newerOwner,
      );

      releaseFirst.complete();
      await firstRun;

      expect(scanStore.isScanning, isTrue,
          reason: 'the superseded run must not complete the newer run');
      expect(scanStore.ownsRun(newerOwner), isTrue);
      expect(listings, 1,
          reason: 'the superseded walk stops after its in-flight listing');

      await scanStore.stopScan();
    });
  });

  testWidgets('scanning a REAL empty local root still purges stale children',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'empty-root';
      final tempDir = await Directory.systemTemp.createTemp('iris_empty_scan');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final storage = Storage.local(
        id: id,
        type: StorageType.internal,
        name: 'empty',
        basePath: pathConv(tempDir.path),
      );
      StoragePathCodec.baseResolver = (sid) => sid == id ? storage.basePath : null;
      await seedFile(id, 'gone.mp4');

      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: storage,
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        probeService: null,
      );

      await service.scanRecursively(
        rootPaths: [storage.basePath.join('/')],
        context: ctx,
      );

      expect(
        await DbModule.mediaNodesDao.getByPath(id, 'gone.mp4'),
        isNull,
        reason: 'an existing-but-empty dir must still reconcile its snapshot',
      );
      expect(p.isAbsolute(p.joinAll(storage.basePath)), isTrue);
    });
  });
}
