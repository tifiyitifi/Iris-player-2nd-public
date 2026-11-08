import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/migration/v53_migration.dart';
import 'package:iris/utils/natural_sort_key.dart';

/// Schema v53 stores the natural sort key in `media_nodes.natural_name`.
///
/// The column is added by `onUpgrade`, but the BACKFILL runs from `beforeOpen`
/// (chunked, so the WAL cannot grow to the table size) and the index's existence
/// is the "backfill finished" marker. These tests pin every step, including the
/// interrupted-upgrade resume.
void main() {
  Future<bool> hasColumn(AppDatabase db, String table, String column) async {
    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    return rows.any((r) => r.read<String>('name') == column);
  }

  Future<bool> hasIndex(AppDatabase db, String name) async {
    final rows = await db.customSelect(
      "SELECT 1 FROM sqlite_master WHERE type='index' AND name=?",
      variables: [Variable.withString(name)],
    ).get();
    return rows.isNotEmpty;
  }

  Future<List<(String, String)>> keysByName(AppDatabase db) async {
    final rows = await db
        .customSelect('SELECT name, natural_name FROM media_nodes ORDER BY id')
        .get();
    return [
      for (final r in rows) (r.read<String>('name'), r.read<String>('natural_name')),
    ];
  }

  Future<void> seedRows(AppDatabase db, List<String> names) async {
    for (var i = 0; i < names.length; i++) {
      await db.customStatement(
        "INSERT INTO media_nodes "
        "(storage_id, data_scope_id, path, parent_path, path_depth, name, "
        "normalized_name, node_kind, media_type, is_present) "
        "VALUES ('st', 'st', ?, 'dir', 2, ?, ?, 'file', 'video', 1)",
        ['dir/${names[i]}', names[i], names[i].toLowerCase()],
      );
    }
  }

  test('a fresh install has the column, both indexes, and no legacy index',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    expect(await hasColumn(db, 'media_nodes', 'natural_name'), isTrue);
    expect(await hasIndex(db, MigrationV53.naturalIndex), isTrue);
    expect(await hasIndex(db, MigrationV53.parentNaturalIndex), isTrue);
    expect(await hasIndex(db, MigrationV53.legacyNameSortIndex), isFalse);
  });

  test('a v52 database upgrades: column added, keys backfilled, indexes built',
      () async {
    final dir = Directory.systemTemp.createTempSync('iris_v53_probe');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/iris_storages.db');

    final db = AppDatabase(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();

    // Recreate the v52 shape: no key column, no natural indexes, the legacy
    // sort index still present.
    await db.customStatement('DROP INDEX IF EXISTS ${MigrationV53.naturalIndex}');
    await db.customStatement(
        'DROP INDEX IF EXISTS ${MigrationV53.parentNaturalIndex}');
    await db.customStatement(
        'CREATE INDEX IF NOT EXISTS ${MigrationV53.legacyNameSortIndex} '
        'ON media_nodes(data_scope_id, parent_path, normalized_name)');
    await db.customStatement(
        'ALTER TABLE media_nodes DROP COLUMN natural_name');
    await seedRows(db, ['ep10.mkv', 'ep2.mkv', 'ep1.mkv', 'A.mkv']);
    await db.customStatement('PRAGMA user_version = 52');
    await db.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    await upgraded.customSelect('SELECT 1').get();

    expect(await hasColumn(upgraded, 'media_nodes', 'natural_name'), isTrue);
    expect(await hasIndex(upgraded, MigrationV53.naturalIndex), isTrue);
    expect(await hasIndex(upgraded, MigrationV53.parentNaturalIndex), isTrue);
    expect(await hasIndex(upgraded, MigrationV53.legacyNameSortIndex), isFalse);

    final keys = await keysByName(upgraded);
    expect(keys.length, 4);
    for (final (name, key) in keys) {
      expect(key, naturalSortKey(name), reason: 'key of "$name" was not backfilled');
    }

    // The upgraded order is the natural one: ep1, ep2, ep10, A.mkv.
    final ordered = await upgraded.customSelect(
      "SELECT name FROM media_nodes WHERE data_scope_id='st' "
      'ORDER BY natural_name, path',
    ).get();
    expect(
      ordered.map((r) => r.read<String>('name')).toList(),
      ['A.mkv', 'ep1.mkv', 'ep2.mkv', 'ep10.mkv'],
    );
  });

  test('an interrupted upgrade resumes and never doubles work', () async {
    final dir = Directory.systemTemp.createTempSync('iris_v53_resume');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/iris_storages.db');

    final db = AppDatabase(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    await seedRows(db, ['10.mkv', '2.mkv', '1.mkv']);
    // Simulate a crash right after the column was added but before the
    // backfill completed: no keys, no natural index.
    await db.customStatement("UPDATE media_nodes SET natural_name = ''");
    await db.customStatement('DROP INDEX IF EXISTS ${MigrationV53.naturalIndex}');
    await db.customStatement(
        'DROP INDEX IF EXISTS ${MigrationV53.parentNaturalIndex}');
    await db.customStatement('PRAGMA user_version = 52');
    await db.close();

    final reopened = AppDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    await reopened.customSelect('SELECT 1').get();

    final keys = await keysByName(reopened);
    for (final (name, key) in keys) {
      expect(key, naturalSortKey(name));
    }

    // Running the backfill again is a no-op (index marker present).
    await MigrationV53.ensureNaturalOrder(reopened);
    final again = await keysByName(reopened);
    expect(again, keys);
  });

  test('a crash between the two CREATE INDEX statements is repaired', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    // The backfill finished (keys present, first index exists) and the process
    // died before the parent index was built / the legacy drop. Keying the
    // resume on the FIRST index alone left that state forever.
    await db.customStatement(
        'DROP INDEX IF EXISTS ${MigrationV53.parentNaturalIndex}');
    await db.customStatement(
        'CREATE INDEX IF NOT EXISTS ${MigrationV53.legacyNameSortIndex} '
        'ON media_nodes(data_scope_id, parent_path, normalized_name)');
    expect(await hasIndex(db, MigrationV53.naturalIndex), isTrue);
    expect(await hasIndex(db, MigrationV53.parentNaturalIndex), isFalse);

    await MigrationV53.ensureNaturalOrder(db);

    expect(await hasIndex(db, MigrationV53.parentNaturalIndex), isTrue);
    expect(await hasIndex(db, MigrationV53.legacyNameSortIndex), isFalse);
  });

  test('the legacy sort index is dropped even when v53 ran on a fresh schema',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    // Recreate the v31 index, then let the idempotent creator clean it up.
    await db.customStatement(
        'CREATE INDEX IF NOT EXISTS ${MigrationV53.legacyNameSortIndex} '
        'ON media_nodes(data_scope_id, parent_path, normalized_name)');
    expect(await hasIndex(db, MigrationV53.legacyNameSortIndex), isTrue);

    await MigrationV53.createNaturalNameIndexes(db);
    expect(await hasIndex(db, MigrationV53.legacyNameSortIndex), isFalse);
  });
}
