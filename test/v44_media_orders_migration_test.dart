import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/model/db/dao/media_order_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_shared_index_dao.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/migration/v44_migration.dart';
import 'package:iris/models/db/migration/v52_migration.dart';

/// v44 adds the shared-order index tables (`media_orders`,
/// `scenario_shared_index`). Like v43, the upgrade path runs hand-written DDL
/// while a fresh install goes through Drift's `createAll()`, so the two must be
/// proven to agree.
void main() {
  const tables = ['media_orders', 'scenario_shared_index'];

  Future<List<String>> tableShape(AppDatabase db, String table) async {
    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    return [
      for (final r in rows)
        '${r.read<String>('name')}|${r.read<String>('type')}|'
            '${r.read<int>('notnull')}|${r.read<String?>('dflt_value')}|'
            '${r.read<int>('pk')}',
    ];
  }

  Future<AppDatabase> freshDb() async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    return db;
  }

  test('the migration produces the same shape a fresh install gets', () async {
    final fresh = await freshDb();
    addTearDown(fresh.close);
    final freshShapes = {
      for (final t in tables) t: await tableShape(fresh, t),
    };
    for (final t in tables) {
      expect(freshShapes[t], isNotEmpty, reason: '$t missing on fresh install');
    }

    // Simulate a pre-v44 database: the tables do not exist yet.
    final db = await freshDb();
    addTearDown(db.close);
    for (final t in tables) {
      await db.customStatement('DROP TABLE IF EXISTS $t');
      await expectLater(
        db.customSelect('SELECT 1 FROM $t').get(),
        throwsA(anything),
      );
    }

    await MigrationV44(db).run(db.createMigrator());
    // Later migrations extend these tables (v52 adds `media_orders.last_used_at`
    // and `scenario_shared_index.element_order`), so a HEAD fresh install can
    // only match after those have run too — the point of this test is that the
    // migration PATH reaches the fresh shape, not that v44 alone did.
    await MigrationV52(db).run(db.createMigrator());

    for (final t in tables) {
      expect(await tableShape(db, t), freshShapes[t], reason: '$t shape');
    }

    // Both DAOs work against the migrated tables.
    final orders = MediaOrderDao(db);
    final ids = Int32List.fromList([4, 5, 6]);
    await orders.write('k', mediaRev: 1, ids: ids);
    expect(await orders.read('k', mediaRev: 1), ids);

    final shared = ScenarioSharedIndexDao(db);
    await shared.write(
      7,
      baseCount: 3,
      slices: Uint8List.fromList([1]),
      accepted: Uint8List.fromList([2]),
      absorbed: Uint8List.fromList([3]),
      groupRows: Uint8List.fromList([4]),
      placeholders: Uint8List.fromList([5]),
      occurrence: Uint8List.fromList([6]),
      flags: Uint8List.fromList([7]),
    );
    final blobs = await shared.read(7);
    expect(blobs, isNotNull);
    expect(blobs!.baseCount, 3);
    expect(blobs.groupRows, Uint8List.fromList([4]));
  });

  test('the migration is re-entrant', () async {
    final db = await freshDb();
    addTearDown(db.close);
    final before = {
      for (final t in tables) t: await tableShape(db, t),
    };

    await MigrationV44(db).run(db.createMigrator());
    await MigrationV44(db).run(db.createMigrator());

    for (final t in tables) {
      expect(await tableShape(db, t), before[t], reason: '$t shape');
    }
  });
}
