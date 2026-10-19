import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/services/media_node_sync_service.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/path_conv.dart';

/// `MediaNodeSyncService.syncDirectory` must report whether it actually wrote
/// `media_nodes`, so callers only announce a media change (and invalidate the
/// scenario queue index) on a real mutation — never on a no-op re-browse.
void main() {
  late AppDatabase db;

  setUpAll(() {
    db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
  });

  tearDownAll(() => db.close());

  setUp(() async {
    await DbModule.mediaNodesDao.deleteByStorage('s1');
  });

  Storage storage() => Storage.local(
        id: 's1',
        type: StorageType.internal,
        name: 't',
        basePath: const ['/tmp'],
      );

  FileItem video(String name) => FileItem(
        storageId: 's1',
        storageType: StorageType.internal,
        name: name,
        uri: '/tmp/$name',
        path: ['/tmp', name],
        type: ContentType.video,
      );

  test('changed=true when a new file is written; false on an identical resync',
      () async {
    final first = await MediaNodeSyncService().syncDirectory(
      storage: storage(),
      items: [video('a.mp4')],
      dirPath: const ['/tmp'],
    );
    expect(first.changed, isTrue, reason: 'a new row was inserted');

    final second = await MediaNodeSyncService().syncDirectory(
      storage: storage(),
      items: [video('a.mp4')],
      dirPath: const ['/tmp'],
    );
    expect(second.changed, isFalse, reason: 'nothing changed on the resync');
  });

  test('changed=true when a vanished file is deleted', () async {
    await MediaNodeSyncService().syncDirectory(
      storage: storage(),
      items: [video('a.mp4')],
      dirPath: const ['/tmp'],
    );

    final removed = await MediaNodeSyncService().syncDirectory(
      storage: storage(),
      items: const [],
      dirPath: const ['/tmp'],
    );
    expect(removed.changed, isTrue, reason: 'the stale row was deleted');
  });

  test('a case-only rename keeps the row (and its progress)', () async {
    Storage windowsStorage() => Storage.local(
          id: 's1',
          type: StorageType.internal,
          name: 't',
          basePath: const ['C:', 'tmp'],
        );
    const dir = ['C:', 'tmp'];

    await MediaNodeSyncService().syncDirectory(
      storage: windowsStorage(),
      items: [video('photo.JPG')],
      dirPath: dir,
    );
    final row = (await DbModule.mediaNodesDao.getDirectChildren(
      's1',
      canonicalDbPath('C:/tmp'),
    ))
        .single;
    await DbModule.mediaNodesDao.attachedDatabase.customStatement(
      'UPDATE media_nodes SET playback_position_ms = 1234 WHERE id = ?',
      [row.id],
    );

    final renamed = await MediaNodeSyncService().syncDirectory(
      storage: windowsStorage(),
      items: [video('Photo.JPG')],
      dirPath: dir,
    );

    final rows = await DbModule.mediaNodesDao.getDirectChildren(
      's1',
      canonicalDbPath('C:/tmp'),
    );
    expect(rows, hasLength(1), reason: 'a case-only rename is the same file');
    expect(rows.single.path, 'C:/tmp/Photo.JPG');
    expect(rows.single.playbackPositionMs, 1234,
        reason: 'the rename must not delete and recreate the row');
    expect(renamed.changed, isTrue);
  });

  test('case-sensitive storage keeps case-variant files distinct', () async {
    Storage posixStorage() => Storage.local(
          id: 's1',
          type: StorageType.internal,
          name: 't',
          basePath: const ['/tmp'],
        );

    await MediaNodeSyncService().syncDirectory(
      storage: posixStorage(),
      items: [video('photo.JPG'), video('photo.jpg')],
      dirPath: const ['/tmp'],
    );
    expect(
      (await DbModule.mediaNodesDao.getDirectChildren('s1', 'tmp')).length,
      2,
      reason: 'both case-variant files exist on a case-sensitive filesystem',
    );

    final removed = await MediaNodeSyncService().syncDirectory(
      storage: posixStorage(),
      items: [video('photo.JPG')],
      dirPath: const ['/tmp'],
    );

    final rows = await DbModule.mediaNodesDao.getDirectChildren('s1', 'tmp');
    expect(rows, hasLength(1),
        reason: 'the deleted case-variant file must not be kept by a folded key');
    expect(rows.single.name, 'photo.JPG');
    expect(removed.changed, isTrue);
  });
}
