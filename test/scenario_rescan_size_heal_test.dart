import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

/// "Rescan" must be able to REPAIR size/mtime, not just duration.
///
/// The row is often written by a lane that cannot stat (size 0 / NULL mtime).
/// A rescan lists the file, so its physical facts are in hand; the write-back
/// has to persist them, keep ancestor aggregates in step, and never let an
/// unknown value erase a known one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
  });

  tearDownAll(() => db.close());

  setUp(() async {
    await DbModule.mediaNodesDao.batchUpsert([
      MediaNode.directory(
        id: 's:movies',
        storageId: 's',
        path: const ['movies'],
        name: 'movies',
      ).toCompanion(),
      MediaNode.file(
        id: 's:movies/a.mkv',
        storageId: 's',
        path: const ['movies', 'a.mkv'],
        name: 'a.mkv',
        mediaType: MediaType.video,
      ).toCompanion(),
    ]);
  });

  Future<MediaNode> nodeAt(List<String> path) async {
    final node = await DbModule.mediaNodeRepo
        .getNodeByPath(storageId: 's', path: path);
    return node!;
  }

  test('a rescan heals size/mtime and the folder total', () async {
    final t = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    final rows = await DbModule.mediaNodeRepo.updateFileMediaInfo(
      storageId: 's',
      path: 'movies/a.mkv',
      sizeInBytes: 8192,
      modifiedAt: t,
    );

    expect(rows, 1);
    final file = (await nodeAt(['movies', 'a.mkv']))
        .maybeMap(file: (f) => f, orElse: () => null)!;
    expect(file.sizeInBytes, 8192);
    expect(file.modifiedAt!.millisecondsSinceEpoch, t.millisecondsSinceEpoch);

    // The folder row the browser and the size sort read must follow.
    final dir = await nodeAt(['movies']);
    final dirFile = dir.maybeMap(
      directory: (d) => d,
      orElse: () => null,
    )!;
    expect(dirFile.totalSizeInBytes, 8192);
  });

  test('an unknown rescan value never erases the healed values', () async {
    final t = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    await DbModule.mediaNodeRepo.updateFileMediaInfo(
      storageId: 's',
      path: 'movies/a.mkv',
      sizeInBytes: 8192,
      modifiedAt: t,
    );

    final rows = await DbModule.mediaNodeRepo.updateFileMediaInfo(
      storageId: 's',
      path: 'movies/a.mkv',
      sizeInBytes: 0,
      modifiedAt: null,
    );

    // Nothing known → nothing written (a no-op, never an erase).
    expect(rows, 0);
    final file = (await nodeAt(['movies', 'a.mkv']))
        .maybeMap(file: (f) => f, orElse: () => null)!;
    expect(file.sizeInBytes, 8192);
    expect(file.modifiedAt!.millisecondsSinceEpoch, t.millisecondsSinceEpoch);
  });
}
