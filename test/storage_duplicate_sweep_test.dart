import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/services/storage_duplicate_repair.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:path/path.dart' as p;

/// Ghost-row sweep: mark file rows absent when the file is gone, never delete
/// rows, and refuse to run when the volume is offline (an unplugged drive must
/// not grey out the whole library).
void main() {
  late AppDatabase db;
  late MediaNodesDao dao;
  late Directory temp;

  setUpAll(() {
    db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
  });

  tearDownAll(() async {
    StoragePathCodec.baseResolver = (_) => null;
    await db.close();
  });

  setUp(() async {
    await db.delete(db.mediaNodesTable).go();
    temp = await Directory.systemTemp.createTemp('iris_sweep');
    StoragePathCodec.baseResolver =
        (id) => id == 'sid' ? pathConv(temp.path) : null;
    dao = DbModule.mediaNodesDao;
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> add(String name) => dao.insertNode(MediaNode.file(
        id: 'sid:$name',
        storageId: 'sid',
        path: <String>[name],
        pathDepth: 1,
        name: name,
        mediaType: MediaType.video,
      ));

  LocalStorage entry({List<String>? basePath}) => LocalStorage(
        id: 'sid',
        type: StorageType.internal,
        name: 'temp',
        basePath: basePath ?? pathConv(temp.path),
        volumeId: 'vol:tmp',
      );

  test('marks only the files that are actually gone', () async {
    File(p.join(temp.path, 'kept.mp4')).writeAsStringSync('x');
    await add('kept.mp4');
    await add('ghost.mp4');

    final stats = await sweepMissingFilesForStorage(entry());

    expect(stats.ghostRowsMarked, 1);
    final rows = await dao.rowsInScope('sid');
    final kept = rows.firstWhere((r) => r.path == 'kept.mp4');
    final ghost = rows.firstWhere((r) => r.path == 'ghost.mp4');
    expect(kept.isPresent, isTrue);
    expect(ghost.isPresent, isFalse);
    // Rows are hidden, never deleted: a rescan/reconnect brings them back.
    expect(rows, hasLength(2));
  });

  test('an offline volume is skipped entirely', () async {
    await add('ghost.mp4');
    final stats = await sweepMissingFilesForStorage(
      entry(basePath: pathConv(p.join(temp.path, 'not-mounted'))),
    );

    expect(stats.ghostRowsMarked, 0);
    expect((await dao.rowsInScope('sid')).single.isPresent, isTrue);
  });

  test('directories are never marked by the file sweep', () async {
    await dao.insertNode(MediaNode.directory(
      id: 'sid:dir',
      storageId: 'sid',
      path: const <String>['dir'],
      pathDepth: 1,
      name: 'dir',
    ));
    // The directory exists on disk but is not a file row.
    Directory(p.join(temp.path, 'dir')).createSync();

    final stats = await sweepMissingFilesForStorage(entry());

    expect(stats.ghostRowsMarked, 0);
    final dir = (await dao.rowsInScope('sid'))
        .firstWhere((r) => r.nodeKind == MediaNodeKind.directory);
    expect(dir.isPresent, isTrue);
  });
}
