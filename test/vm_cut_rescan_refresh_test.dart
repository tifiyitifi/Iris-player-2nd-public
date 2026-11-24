import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/services/fake_cut_project_index.dart';
import 'package:iris/features/media_library/scan/service/recursive_scan_service.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:path/path.dart' as p;

/// A media rescan is the automatic moment a `.llc` sibling can appear or
/// disappear, so it must drop the 虚拟剪播 project index (ADR 0033). The user
/// accepted "新建虚拟剪播后需刷新", but a rescan IS that refresh — pressing the
/// 虚拟剪播 tab's button must not be the only way a new cut starts merging.
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
    FakeCutProjectIndex.debugReadDirectory = null;
    db.close();
  });

  String project(String mediaFileName) => '''
{
  version: 2,
  mediaFileName: '$mediaFileName',
  cutSegments: [{ start: 1, end: 20, name: '', selected: true }],
}
''';

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

  /// One local storage rooted at a fresh temp directory holding `ep01.mp4`.
  Future<({Storage storage, String dir, FileItem video})> setUpStorage(
    String id,
  ) async {
    final Directory dir = await Directory.systemTemp.createTemp('iris_cut_rescan');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final Storage storage = Storage.local(
      id: id,
      type: StorageType.internal,
      name: 'cuts',
      basePath: pathConv(dir.path),
    );
    StoragePathCodec.baseResolver = (sid) => sid == id ? storage.basePath : null;
    final String videoPath = p.join(dir.path, 'ep01.mp4');
    await File(videoPath).writeAsBytes(const <int>[0]);
    return (
      storage: storage,
      dir: dir.path,
      video: FileItem(
        storageId: id,
        name: 'ep01.mp4',
        uri: videoPath,
        path: const <String>['ep01.mp4'],
        size: 1,
      ),
    );
  }

  Future<void> rescan(
    WidgetTester tester,
    BuildContext ctx,
    Storage storage,
    FileItem video,
  ) async {
    final scanStore = RecursiveScanStore();
    await scanStore.initialized;
    final service = RecursiveScanService(
      storage: storage,
      scanStore: scanStore,
      nodesDao: DbModule.mediaNodesDao,
      sourcesDao: DbModule.mediaLibSourcesDao,
      probeService: null,
      listDir: (Storage _, List<String> __) async =>
          FileListResult(<FileItem>[video]),
    );
    await service.scanRecursively(
      rootPaths: [storage.basePath.join('/')],
      context: ctx,
    );
  }

  testWidgets(
      'a media rescan drops the cut project cache so a new plan binds',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'cut-rescan';
      final env = await setUpStorage(id);
      final query = (
        mediaKey: '$id:ep01.mp4',
        name: 'ep01.mp4',
        uri: env.video.uri,
      );

      // Prime the cache while the directory still has no project: the merge
      // resolves this video as its source.
      FakeCutProjectIndex.instance.invalidate();
      expect(await FakeCutProjectIndex.instance.hasProjectFor(query), isFalse);

      // The user authors a plan while the app is running.
      await File(p.join(env.dir, 'ep01.llc')).writeAsString(project('ep01.mp4'));

      await rescan(tester, ctx, env.storage, env.video);

      expect(
        await FakeCutProjectIndex.instance.hasProjectFor(query),
        isTrue,
        reason: 'a completed rescan must re-read directories for new plans',
      );
    });
  });

  testWidgets('a media rescan keeps the per-session scan bookkeeping',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      const id = 'cut-rescan-bookkeeping';
      final env = await setUpStorage(id);
      await File(p.join(env.dir, 'ep01.llc')).writeAsString(project('ep01.mp4'));
      final service = VirtualMediaService.instance;
      service.markShellUnsupported(<String>['$id:ep01.mp4']);
      service.dismissScanScope('scope-$id');

      await rescan(tester, ctx, env.storage, env.video);

      // A rescan re-listed the files, it did not re-identify them: fast-scan
      // and dismissed-prompt bookkeeping must survive, or every scan re-arms
      // the Shell probe / the scan dialog for files already known.
      expect(service.isShellUnsupported('$id:ep01.mp4'), isTrue);
      expect(service.isScanDismissed('scope-$id'), isTrue);
    });
  });
}
