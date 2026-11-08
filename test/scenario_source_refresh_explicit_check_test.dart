import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_explicit_item.dart';
import 'package:iris/features/scenario_playback/scan/service/scenario_source_refresh_service.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/enums/storage_list_error.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/storage.dart';

// The explicit-file existence check must delete a media node ONLY when the
// parent listing succeeded and the file is genuinely absent. A failed listing
// (offline/unreachable) must never delete — the same offline-safe contract as
// the recursive scanner.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  Storage storage() => Storage.local(
        id: 's1',
        type: StorageType.internal,
        name: 'Local',
        basePath: const ['root'],
      );

  ScenarioSourceRefreshUnitSpec unitWith(List<ScenarioExplicitItem> items) =>
      ScenarioSourceRefreshUnitSpec(
        storage: storage(),
        rootPaths: const [],
        directories: const [],
        explicitItems: items,
        explicitProbeTargets: items,
        weight: 1,
      );

  ScenarioExplicitItem explicit(String path) => ScenarioExplicitItem(
        id: 1,
        scenarioId: 'scn',
        storageId: 's1',
        path: path,
      );

  Future<void> seedFile(String path) async {
    final segs = path.split('/');
    await DbModule.mediaNodesDao.batchUpsert([
      MediaNode.file(
        id: 's1:$path',
        storageId: 's1',
        path: segs,
        parentPath: segs.length > 1 ? segs.sublist(0, segs.length - 1).join('/') : null,
        pathDepth: segs.length,
        name: segs.last,
        mediaType: MediaType.video,
        sizeInBytes: 10,
      ).toCompanion(),
    ]);
  }

  test('does NOT delete on an EMPTY listing: a missing directory is '
      'indistinguishable from an empty one', () async {
    await seedFile('movies/gone.mp4');

    final service = ScenarioSourceRefreshService(
      listDir: (Storage s, List<String> p) async =>
          const FileListResult(<FileItem>[]),
    );

    // Desktop reports an absent/unreadable directory as an error-free empty
    // result, so an empty listing must never be read as "the file is gone".
    final check = await service.checkExplicitFiles(
      unitWith([explicit('movies/gone.mp4')]),
    );

    expect(check.missing, 0);
    expect(check.presentPaths, isEmpty);
    expect(await DbModule.mediaNodeRepo.getNodeByPath(
      storageId: 's1',
      path: const ['movies', 'gone.mp4'],
    ), isNotNull);
  });

  test('deletes a node when the listing succeeds, is NON-empty, and omits the '
      'file', () async {
    await seedFile('movies/gone.mp4');

    final service = ScenarioSourceRefreshService(
      listDir: (Storage s, List<String> p) async => FileListResult([
        FileItem(
          name: 'other.mp4',
          path: const ['movies', 'other.mp4'],
          uri: 'other.mp4',
          isDir: false,
          type: ContentType.video,
          size: 10,
        ),
      ]),
    );

    // A successful listing with real entries is proof the directory exists and
    // the explicit file is not in it → remove the stale node.
    final check = await service.checkExplicitFiles(
      unitWith([explicit('movies/gone.mp4')]),
    );

    expect(check.missing, 1);
    expect(check.presentPaths, isEmpty);
    expect(await DbModule.mediaNodeRepo.getNodeByPath(
      storageId: 's1',
      path: const ['movies', 'gone.mp4'],
    ), isNull);
  });

  test('lists a UNC parent WITHOUT collapsing its leading //', () async {
    await seedFile('movies/unc.mp4');

    List<String>? seen;
    final service = ScenarioSourceRefreshService(
      listDir: (Storage s, List<String> p) async {
        seen = p;
        return FileListResult([
          FileItem(
            name: 'unc.mp4',
            path: const ['movies', 'unc.mp4'],
            uri: 'unc.mp4',
            isDir: false,
            type: ContentType.video,
            size: 10,
          ),
        ]);
      },
    );

    // Raw UNC path: the stored explicit-item path keeps the `\\server` marker,
    // which the old `canonicalDbPath(...).split('/')` collapsed away.
    final check = await service.checkExplicitFiles(
      unitWith([explicit('\\\\server/share/movies/unc.mp4')]),
    );

    expect(seen, const ['\\\\server', 'share', 'movies']);
    expect(check.missing, 0);
    expect(check.presentPaths, {'server/share/movies/unc.mp4'});
  });

  test('keeps the node when the file is present in the listing', () async {
    await seedFile('movies/kept.mp4');

    final service = ScenarioSourceRefreshService(
      listDir: (Storage s, List<String> p) async => FileListResult([
        FileItem(
          name: 'kept.mp4',
          path: const ['movies', 'kept.mp4'],
          uri: 'kept.mp4',
          isDir: false,
          type: ContentType.video,
          size: 10,
        ),
      ]),
    );

    final check = await service.checkExplicitFiles(
      unitWith([explicit('movies/kept.mp4')]),
    );

    expect(check.missing, 0);
    // Confirmed present → this is the set the targeted probe may refresh.
    expect(check.presentPaths, {'movies/kept.mp4'});
    expect(await DbModule.mediaNodeRepo.getNodeByPath(
      storageId: 's1',
      path: const ['movies', 'kept.mp4'],
    ), isNotNull);
  });

  test('does NOT delete when the listing failed (offline-safe)', () async {
    await seedFile('movies/keep.mp4');

    final service = ScenarioSourceRefreshService(
      listDir: (Storage s, List<String> p) async => const FileListResult(
        <FileItem>[],
        errorKind: StorageListErrorKind.unreachable,
      ),
    );

    final check = await service.checkExplicitFiles(
      unitWith([explicit('movies/keep.mp4')]),
    );

    // A failed listing proves nothing: neither a delete NOR a probe target.
    expect(check.missing, 0);
    expect(check.presentPaths, isEmpty);
    expect(await DbModule.mediaNodeRepo.getNodeByPath(
      storageId: 's1',
      path: const ['movies', 'keep.mp4'],
    ), isNotNull);
  });
}
