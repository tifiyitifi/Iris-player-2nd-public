import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

import 'helpers/sqlite3_loader.dart';

/// The SAF URI backfill selects "file rows under this tree with no uri" with a
/// `LIKE '<treePrefix>/%'`. The SAF tree id is percent-ENCODED (`primary%3A…`)
/// and may contain `_`, so the prefix must be escaped: unescaped, `%` and `_`
/// are wildcards and the scan can pick up a sibling tree's rows and write a
/// wrong document uri onto them.
void main() {
  ensureSqlite3Loaded();

  late AppDatabase db;
  const scope = 'sid';

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });

  tearDownAll(() async {
    await db.close();
  });

  setUp(() async {
    await db.customStatement('DELETE FROM media_nodes');
  });

  Future<void> insertFile(String path) => db.customInsert(
        'INSERT INTO media_nodes (storage_id, data_scope_id, path, parent_path, '
        'name, node_kind, uri) VALUES (?,?,?,?,?,?,NULL)',
        variables: [
          Variable.withString(scope),
          Variable.withString(scope),
          Variable.withString(path),
          Variable.withString(''),
          Variable.withString(path.split('/').last),
          Variable.withString('file'),
        ],
      );

  const real = 'content://auth/tree/primary%3AMedia_1/a.mp4';
  // `_` is a single-character wildcard: this sibling tree must NOT match.
  const underscoreDecoy = 'content://auth/tree/primary%3AMediaX1/b.mp4';
  // `%` is a multi-character wildcard: this must NOT match either.
  const percentDecoy = 'content://auth/tree/primaryZZZ3AMedia_1/c.mp4';

  test('only rows under the literal prefix are returned', () async {
    await insertFile(real);
    await insertFile(underscoreDecoy);
    await insertFile(percentDecoy);

    final rows = await DbModule.mediaNodesDao.listSafFilesMissingUri(
      scope,
      'content://auth/tree/primary%3AMedia_1',
    );

    expect(rows.map((r) => r.path), [real],
        reason: 'the wildcard characters must be escaped');
  });
}
