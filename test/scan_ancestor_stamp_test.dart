import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/service/recursive_scan_service.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/storage.dart';

/// Regression for "partial scan refreshed the ancestor's `scanDone` stamp".
///
/// Scanning ONE subfolder used to walk up and re-stamp every ancestor with
/// `scanDone` + `now` as soon as that ancestor's children looked done. Those
/// children are only the rows that happen to exist: a sibling this run never
/// listed (never scanned, or stale) is not in the tree, so the parent claimed
/// "fully scanned just now" for a subtree it knows nothing about. The play gate
/// trusts that stamp, so dropping the parent then played an incomplete queue
/// without any scan. Only the directories the run actually reached may be
/// stamped done; ancestors keep their own previous state.
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

  testWidgets('a partial scan never stamps an ancestor that was not walked',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'anc-stamp';
      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: ftp(id),
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        // `a` holds TWO subdirectories; only `a/b` is scanned here. `a/c` has
        // no row at all, so the parent's completeness is unknowable.
        listDir: (s, p) async => p.join('/') == 'a/b'
            ? FileListResult([
                FileItem(name: 'v.mp4', uri: 'a/b/v.mp4'),
              ])
            : const FileListResult(<FileItem>[]),
      );

      await service.scanRecursively(rootPaths: const ['a/b'], context: ctx);

      // The scanned root is done ...
      expect((await DbModule.mediaNodesDao.dirScanStatus(id, 'a/b'))?.state,
          'scanDone');
      // ... but its parent was never walked, so it must NOT claim to be fully
      // scanned (the play gate would accept it and play an incomplete queue).
      expect((await DbModule.mediaNodesDao.dirScanStatus(id, 'a'))?.state,
          isNot('scanDone'));
    });
  });

  testWidgets('scanning the ancestor itself still stamps it done',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'anc-stamp-full';
      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: ftp(id),
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        listDir: (s, p) async => switch (p.join('/')) {
          'a' => FileListResult([
              FileItem(name: 'b', uri: 'a/b', isDir: true),
            ]),
          'a/b' => FileListResult([
              FileItem(name: 'v.mp4', uri: 'a/b/v.mp4'),
            ]),
          _ => const FileListResult(<FileItem>[]),
        },
      );

      await service.scanRecursively(rootPaths: const ['a'], context: ctx);

      expect((await DbModule.mediaNodesDao.dirScanStatus(id, 'a'))?.state,
          'scanDone');
      expect((await DbModule.mediaNodesDao.dirScanStatus(id, 'a/b'))?.state,
          'scanDone');
    });
  });
}
