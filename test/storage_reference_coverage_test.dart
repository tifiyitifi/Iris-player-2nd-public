import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/services/storage_duplicate_repair.dart';
import 'package:iris/models/db/app_database.dart';

/// Schema-coverage guard for the duplicate-entry merge.
///
/// The merge rewrites every column that names a storage entry. A future table
/// added without updating [storageReferenceColumns] would silently keep pointing
/// at the merged-away entry (invisible rows, dead playback), so this test reads
/// the live schema and fails on any uncovered `*storage_id*` column.
void main() {
  late AppDatabase db;

  setUpAll(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDownAll(() async {
    await db.close();
  });

  /// Columns handled by the node/scan merge itself (not a plain id rewrite).
  const structurallyHandled = <String>{
    'media_nodes.storage_id', // rows are merged/moved by scope
    'scan_states.storage_id', // dropped (rebuilt by the next scan)
    'scan_queue.storage_id', // dropped (rebuilt by the next scan)
  };

  test('every storage-id column is covered by the merge', () async {
    final tables = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();
    final covered = <String>{
      for (final (table, column) in storageReferenceColumns) '$table.$column',
      ...structurallyHandled,
    };

    final uncovered = <String>[];
    for (final table in tables) {
      final name = table.read<String>('name');
      if (name.startsWith('sqlite_')) continue;
      final columns = await db.customSelect('PRAGMA table_info("$name")').get();
      for (final column in columns) {
        final columnName = column.read<String>('name');
        if (!columnName.contains('storage_id')) continue;
        final key = '$name.$columnName';
        if (!covered.contains(key)) uncovered.add(key);
      }
    }

    expect(uncovered, isEmpty,
        reason: 'Add these to storageReferenceColumns and to the merge test');
  });

  test('the reference list has no stale entries', () async {
    final tables = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();
    final names = {for (final t in tables) t.read<String>('name')};
    for (final (table, column) in storageReferenceColumns) {
      expect(names, contains(table));
      final columns = await db.customSelect('PRAGMA table_info("$table")').get();
      expect(
        columns.map((c) => c.read<String>('name')),
        contains(column),
        reason: '$table.$column no longer exists',
      );
    }
  });
}
