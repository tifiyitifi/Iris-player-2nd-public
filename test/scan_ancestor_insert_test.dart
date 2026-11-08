import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/adapters/media_node_drift_adapter.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

/// The recursive scan's ancestor backfill must create the missing chain without
/// touching directories it already knows: a directory row carries the scan stamp
/// and aggregates of a previous run, and rewriting it would reset them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  MediaNodesTableCompanion dir(String path, {String? parent, int depth = 1}) =>
      MediaNode.directory(
        id: 's:$path',
        storageId: 's',
        path: path.split('/'),
        parentPath: parent,
        pathDepth: depth,
        name: path.split('/').last,
      ).toCompanion();

  test('creates missing ancestors and leaves existing rows untouched', () async {
    // A previously scanned directory: its stamp must survive the backfill.
    await dao.upsertNode(MediaNode.directory(
      id: 's:a',
      storageId: 's',
      path: const ['a'],
      parentPath: null,
      pathDepth: 1,
      name: 'a',
    ));
    await dao.markDirScanDone('s', 'a');

    await dao.batchInsertIfAbsent([
      dir('a', depth: 1),
      dir('a/b', parent: 'a', depth: 2),
      dir('a/b/c', parent: 'a/b', depth: 3),
    ]);

    final a = await dao.getByPath('s', 'a');
    expect(a, isNotNull);
    expect(a!.scanState, 'scanDone',
        reason: 'an existing directory must never be rewritten by the backfill');
    expect(await dao.getByPath('s', 'a/b'), isNotNull);
    expect(await dao.getByPath('s', 'a/b/c'), isNotNull);
  });

  test('is idempotent across repeated calls', () async {
    await dao.batchInsertIfAbsent([dir('z', depth: 1)]);
    await dao.batchInsertIfAbsent([dir('z', depth: 1)]);

    final rows = await dao.getDirectChildren('s', '');
    expect(rows.where((r) => r.path == 'z'), hasLength(1));
  });
}
