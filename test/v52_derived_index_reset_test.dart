import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/model/db/dao/media_order_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_shared_index_dao.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/migration/v52_migration.dart';

/// Schema v52 must (a) add the two new columns, (b) drop the derived blobs and
/// the shared orders — they encode the previous base order and the previous
/// ORDER BY semantics — and (c) be re-entrant.
void main() {
  Future<bool> hasColumn(AppDatabase db, String table, String column) async {
    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    return rows.any((r) => r.read<String>('name') == column);
  }

  Future<int> countOf(AppDatabase db, String table) async {
    final row =
        await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
    return row.read<int>('c');
  }

  Future<void> seedDerived(AppDatabase db) async {
    await MediaOrderDao(db).write(
      'v3|st|sizeInBytes|asc|f|video,audio',
      mediaRev: 3,
      ids: Int32List.fromList([1, 2, 3]),
    );
    await ScenarioSharedIndexDao(db).write(
      42,
      baseCount: 3,
      slices: Uint8List.fromList([1]),
      accepted: Uint8List.fromList([1]),
      absorbed: Uint8List.fromList([1]),
      groupRows: Uint8List.fromList([1]),
      placeholders: Uint8List.fromList([1]),
      occurrence: Uint8List.fromList([1]),
      flags: Uint8List.fromList([1]),
    );
    await db.customStatement(
      'INSERT INTO scenario_queue_builds '
      '(scenario_id, build_id, base_count, entry_count, built_at) '
      'VALUES (?, ?, ?, ?, ?)',
      ['sc', 42, 3, 3, 0],
    );
  }

  test('a v51 database upgrades to v52 and rebuilds nothing stale', () async {
    final dir = Directory.systemTemp.createTempSync('iris_v52_probe');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/iris_storages.db');

    final db = AppDatabase(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    await seedDerived(db);

    // Recreate the v51 shape: the columns did not exist yet.
    await db.customStatement(
        'ALTER TABLE ${MigrationV52.mediaOrdersTable} '
        'DROP COLUMN ${MigrationV52.lastUsedAtColumn}');
    await db.customStatement(
        'ALTER TABLE ${MigrationV52.sharedIndexTable} '
        'DROP COLUMN ${MigrationV52.elementOrderColumn}');
    await db.customStatement('PRAGMA user_version = 51');
    await db.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);

    final version =
        (await upgraded.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version');
    expect(version, greaterThanOrEqualTo(52));

    expect(
      await hasColumn(
          upgraded, MigrationV52.mediaOrdersTable, MigrationV52.lastUsedAtColumn),
      isTrue,
    );
    expect(
      await hasColumn(upgraded, MigrationV52.sharedIndexTable,
          MigrationV52.elementOrderColumn),
      isTrue,
    );

    expect(await countOf(upgraded, MigrationV52.mediaOrdersTable), 0,
        reason: 'every stored order used the old ORDER BY');
    expect(await countOf(upgraded, MigrationV52.sharedIndexTable), 0,
        reason: 'the old blob encodes the old base order');
    expect(await countOf(upgraded, MigrationV52.queueBuildsTable), 0);
  });

  test('MigrationV52 is re-entrant', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await seedDerived(db);

    await MigrationV52(db).run(db.createMigrator());
    await MigrationV52(db).run(db.createMigrator());

    expect(
      await hasColumn(
          db, MigrationV52.mediaOrdersTable, MigrationV52.lastUsedAtColumn),
      isTrue,
    );
    expect(
      await hasColumn(
          db, MigrationV52.sharedIndexTable, MigrationV52.elementOrderColumn),
      isTrue,
    );
    expect(await countOf(db, MigrationV52.mediaOrdersTable), 0);
    expect(await countOf(db, MigrationV52.sharedIndexTable), 0);
  });

  test('a fresh install already has both columns', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect(
      await hasColumn(
          db, MigrationV52.mediaOrdersTable, MigrationV52.lastUsedAtColumn),
      isTrue,
    );
    expect(
      await hasColumn(
          db, MigrationV52.sharedIndexTable, MigrationV52.elementOrderColumn),
      isTrue,
    );
  });
}
