import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/migration/v46_migration.dart';

/// Schema v46: `media_nodes.modified_at` moves from epoch SECONDS to epoch
/// MILLISECONDS.
///
/// What has to hold:
/// - a fresh install is at 46 and stores milliseconds;
/// - an existing v45 database is rescaled once, so the read side lands on the
///   real instant;
/// - the step is re-entrant (a second run must not multiply again);
/// - NULL timestamps stay NULL.
void main() {
  /// 2025-01-01T00:00:00Z — unambiguous in both units.
  const seconds = 1735689600;
  const millis = 1735689600000;

  Future<void> insert(
    AppDatabase db,
    String path, {
    DateTime? modifiedAt,
  }) async {
    final segments = path.split('/');
    await MediaNodesDao(db).insertNode(MediaNode.file(
      id: path,
      storageId: 'st1',
      path: segments,
      name: segments.last,
      mediaType: MediaType.video,
      modifiedAt: modifiedAt,
    ));
  }

  Future<DateTime?> read(AppDatabase db, String path) async {
    final node = await MediaNodeRepository(MediaNodesDao(db))
        .getNodeByPath(storageId: 'st1', path: path.split('/'));
    return node?.modifiedAt;
  }

  test('a fresh install is at v46 (>=) and stores milliseconds', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    expect(db.schemaVersion, greaterThanOrEqualTo(46));
    await insert(db, 'A/new.mp4',
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(1234));
    expect((await read(db, 'A/new.mp4'))!.millisecondsSinceEpoch, 1234);
  });

  test('a v45 database is rescaled to milliseconds on reopen', () async {
    final dir = Directory.systemTemp.createTempSync('iris_v46_probe');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/iris_storages.db');

    // ── A v45-shaped database: seconds, stamped back to 45.
    final db = AppDatabase(NativeDatabase(file));
    await insert(db, 'A/old.mp4', modifiedAt: DateTime.fromMillisecondsSinceEpoch(0));
    await insert(db, 'A/never.mp4'); // NULL mtime
    await db.customStatement(
        'UPDATE media_nodes SET modified_at = $seconds '
        'WHERE modified_at IS NOT NULL');
    // A shared order persisted under the OLD order-key format.
    await db.customStatement(
        "INSERT INTO media_orders (order_key, media_rev, n, ids) "
        "VALUES ('v1|st1|name|asc|f|video,audio', 0, 0, X'')");
    await db.customStatement('PRAGMA user_version = 45');
    await db.close();

    // ── Reopen at the new version: Drift runs MigrationV46 on the way in.
    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);

    final row = await upgraded.customSelect('PRAGMA user_version').getSingle();
    expect(row.read<int>('user_version'), greaterThanOrEqualTo(46));
    expect(
      (await read(upgraded, 'A/old.mp4'))!.millisecondsSinceEpoch,
      millis,
    );
    // A NULL timestamp must not be invented.
    expect(await read(upgraded, 'A/never.mp4'), isNull);
    // The unreachable old-format orders are dropped.
    final orders = await upgraded
        .customSelect('SELECT COUNT(*) AS c FROM media_orders')
        .getSingle();
    expect(orders.read<int>('c'), 0);
  });

  test('MigrationV46 is re-entrant and leaves an already-scaled row alone',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await insert(db, 'A/old.mp4', modifiedAt: DateTime.fromMillisecondsSinceEpoch(0));
    await db.customStatement(
        "UPDATE media_nodes SET modified_at = $seconds WHERE path IS NOT NULL");

    await MigrationV46(db).run(db.createMigrator());
    expect((await read(db, 'A/old.mp4'))!.millisecondsSinceEpoch, millis);

    // Second run: the guard sees milliseconds and must not touch them.
    await MigrationV46(db).run(db.createMigrator());
    expect((await read(db, 'A/old.mp4'))!.millisecondsSinceEpoch, millis);
  });
}
