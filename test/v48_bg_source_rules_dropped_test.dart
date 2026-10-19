import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/migration/v48_migration.dart';
import 'package:iris/models/db/migration/v49_migration.dart';

/// Schema v48 drops the retired `bg_source_rules` table; v49 retires the
/// scenario TAG SOURCE (deletes `source_kind = 'tag'` rows and drops `tag_id`).
void main() {
  Future<bool> tableExists(AppDatabase db, String name) async {
    final rows = await db.customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(name)],
    ).get();
    return rows.isNotEmpty;
  }

  Future<Set<String>> columns(AppDatabase db, String name) async {
    final rows = await db.customSelect('PRAGMA table_info($name)').get();
    return {for (final r in rows) r.read<String>('name')};
  }

  test('a fresh install has no bg_source_rules table and no tag_id column',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    expect(db.schemaVersion, greaterThanOrEqualTo(49));
    expect(await tableExists(db, 'bg_source_rules'), isFalse);
    expect((await columns(db, 'scenario_sources')).contains('tag_id'), isFalse);
  });

  test('MigrationV48 drops a legacy table, re-entrantly', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await db.customStatement(
      'CREATE TABLE bg_source_rules (id TEXT NOT NULL PRIMARY KEY)',
    );
    expect(await tableExists(db, 'bg_source_rules'), isTrue);

    await MigrationV48(db).run(db.createMigrator());
    expect(await tableExists(db, 'bg_source_rules'), isFalse);

    // Re-entrant: DROP IF EXISTS on an absent table is a no-op.
    await MigrationV48(db).run(db.createMigrator());
    expect(await tableExists(db, 'bg_source_rules'), isFalse);
  });

  test('MigrationV49 deletes tag sources and drops tag_id, re-entrantly',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    // Force the schema to be created, then simulate a pre-v49 database: the
    // `tag_id` column exists and a tag-source row lives in the table.
    await columns(db, 'scenario_sources');
    await db.customStatement(
        'ALTER TABLE scenario_sources ADD COLUMN tag_id INTEGER');
    await db.customStatement(
        "INSERT INTO scenario (id, name, type, repeat_mode, created_at, updated_at) "
        "VALUES ('bg', 'Background', 'background', 'all', 0, 0)");
    await db.customStatement(
        "INSERT INTO scenario_sources "
        "(scenario_id, storage_id, path, recursive, source_kind, tag_id, sort_order, created_at) "
        "VALUES ('bg', '', '', 0, 'tag', 42, 0, 0)");
    // A residual row in a non-canonical spelling: `textEnum` would throw on it
    // at read time (`values.byName`), so the migration takes it out too.
    await db.customStatement(
        "INSERT INTO scenario_sources "
        "(scenario_id, storage_id, path, recursive, source_kind, tag_id, sort_order, created_at) "
        "VALUES ('bg', 't7', '', 0, 'TAG', 7, 3, 0)");
    await db.customStatement(
        "INSERT INTO scenario_sources "
        "(scenario_id, storage_id, path, recursive, source_kind, tag_id, sort_order, created_at) "
        "VALUES ('bg', 's1', 'A', 1, 'folder', NULL, 1, 0)");

    await MigrationV49(db).run(db.createMigrator());

    final rows =
        await db.customSelect('SELECT source_kind FROM scenario_sources').get();
    expect(rows.map((r) => r.read<String?>('source_kind')).toSet(), {'folder'},
        reason: 'the tag source row is deleted; the folder source stays');
    expect((await columns(db, 'scenario_sources')).contains('tag_id'), isFalse,
        reason: 'the unused tag_id column is dropped');

    // Re-entrant: no table, no column, and the folder row is untouched.
    await MigrationV49(db).run(db.createMigrator());
    expect((await db.customSelect('SELECT 1 FROM scenario_sources').get()).length,
        1);
  });
}
