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
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/storage.dart';

/// The recursive scan captures the external subtitle associations a listing
/// carries and PERSISTS them (schema v50), so DB-resolved playback surfaces
/// (scenario / tag / play queue) offer the same external tracks as a browse.
///
/// The incremental scan skips unchanged files. A row whose associations were
/// never captured (pre-v50) must therefore be re-upserted exactly once; a row
/// that already knows them must keep being skipped.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  final modifiedAt = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  Storage storage(String id) => Storage.ftp(
        id: id,
        name: 'FTP',
        host: '10.0.0.2',
        basePath: const [''],
        port: '21',
        username: 'u',
        password: 'p',
      );

  const subtitle = Subtitle(
    name: 'v.zh-ru.ass',
    uri: 'ftp?host=10.0.0.2&port=21&path=/a/v.zh-ru.ass',
  );

  FileItem listingItem() => FileItem(
        storageId: 'ignored',
        storageType: StorageType.ftp,
        name: 'v.mp4',
        uri: 'ftp?host=10.0.0.2&port=21&path=/a/v.mp4',
        path: const ['a', 'v.mp4'],
        size: 10,
        lastModified: modifiedAt,
        type: ContentType.video,
        subtitles: const [subtitle],
      );

  MediaNode seededFile({
    required String storageId,
    List<Subtitle>? subtitles,
    DateTime? createdAt,
  }) =>
      MediaNode.file(
        id: '$storageId:a/v.mp4',
        storageId: storageId,
        path: const ['a', 'v.mp4'],
        parentPath: 'a',
        pathDepth: 2,
        name: 'v.mp4',
        mediaType: MediaType.video,
        sizeInBytes: 10,
        modifiedAt: modifiedAt,
        createdAt: createdAt,
        subtitles: subtitles,
      );

  Future<List<Subtitle>?> readSubtitles(String storageId) async {
    final row = await DbModule.mediaNodesDao.getByPath(storageId, 'a/v.mp4');
    final node = MediaNodeDriftAdapter.fromDb(row!);
    return node.maybeMap(file: (f) => f.subtitles, orElse: () => null);
  }

  Future<BuildContext> contextOf(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ),
    );
    return ctx;
  }

  Future<void> runScan(
    String storageId,
    BuildContext ctx,
  ) async {
    final scanStore = RecursiveScanStore();
    await scanStore.initialized;
    final service = RecursiveScanService(
      storage: storage(storageId),
      scanStore: scanStore,
      nodesDao: DbModule.mediaNodesDao,
      sourcesDao: DbModule.mediaLibSourcesDao,
      listDir: (_, __) async => FileListResult([listingItem()]),
    );
    await service.scanRecursively(rootPaths: const ['a'], context: ctx);
  }

  testWidgets('scan persists the listing subtitle associations',
      (tester) async {
    final ctx = await contextOf(tester);
    // runAsync: the scanner's cooperative yields use real timers.
    await tester.runAsync(() async {
      await runScan('st-persist', ctx);
      expect(await readSubtitles('st-persist'), const [subtitle]);
    });
  });

  testWidgets('a row with UNKNOWN associations is enriched by the next scan',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      await DbModule.mediaNodesDao
          .batchUpsert([seededFile(storageId: 'st-enrich').toCompanion()]);
      expect(await readSubtitles('st-enrich'), isNull);

      await runScan('st-enrich', ctx);

      expect(await readSubtitles('st-enrich'), const [subtitle]);
    });
  });

  testWidgets(
      'changed associations are refreshed by the next scan (subtitle ADDED)',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      // The video is unchanged (same size/mtime) and its row knew a DIFFERENT
      // set: the listing is the authority, so the row must follow it. The old
      // predicate only asked "was it ever captured?" and served the stale set
      // forever.
      await DbModule.mediaNodesDao.batchUpsert([
        seededFile(storageId: 'st-added', subtitles: const []).toCompanion(),
      ]);
      expect(await readSubtitles('st-added'), isEmpty);

      await runScan('st-added', ctx);

      expect(await readSubtitles('st-added'), const [subtitle]);
    });
  });

  testWidgets(
      'changed associations are refreshed by the next scan (subtitle DELETED)',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      // The subtitle file is gone; the video is byte-identical. Without the set
      // comparison the row keeps offering a track that cannot load, and the
      // player shows "subtitle failed to load" on EVERY open (v50 auto-select).
      await DbModule.mediaNodesDao.batchUpsert([
        seededFile(storageId: 'st-deleted', subtitles: const [subtitle])
            .toCompanion(),
      ]);
      expect(await readSubtitles('st-deleted'), const [subtitle]);

      final scanStore = RecursiveScanStore();
      await scanStore.initialized;
      final service = RecursiveScanService(
        storage: storage('st-deleted'),
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        // Same directory listing, minus the subtitle.
        listDir: (_, __) async => FileListResult([
          FileItem(
            storageId: 'ignored',
            storageType: StorageType.ftp,
            name: 'v.mp4',
            uri: 'ftp?host=10.0.0.2&port=21&path=/a/v.mp4',
            path: const ['a', 'v.mp4'],
            size: 10,
            lastModified: modifiedAt,
            type: ContentType.video,
            subtitles: const [],
          ),
        ]),
      );
      await service.scanRecursively(rootPaths: const ['a'], context: ctx);

      expect(await readSubtitles('st-deleted'), isEmpty);
    });
  });

  testWidgets(
      'an unchanged row whose associations MATCH the listing is not rewritten',
      (tester) async {
    final ctx = await contextOf(tester);
    await tester.runAsync(() async {
      // `createdAt` is written by every node upsert and is NOT part of the
      // skip predicate, so it is the observable that distinguishes "skipped"
      // from "re-upserted with the same values": the listing node carries none,
      // so a write would clear it.
      final created = DateTime.fromMillisecondsSinceEpoch(1600000000000);
      await DbModule.mediaNodesDao.batchUpsert([
        seededFile(storageId: 'st-skip', subtitles: const [subtitle],
                createdAt: created)
            .toCompanion(),
      ]);

      await runScan('st-skip', ctx);

      final row = await DbModule.mediaNodesDao.getByPath('st-skip', 'a/v.mp4');
      expect(row!.createdAt, created,
          reason: 'the row was skipped, not rewritten');
      expect(await readSubtitles('st-skip'), const [subtitle]);
    });
  });
}
