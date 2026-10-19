import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/migration/v32_migration.dart';
import 'package:iris/models/db/migration/v33_migration.dart';
import 'package:iris/models/db/migration/v34_migration.dart';
import 'package:iris/models/db/migration/v35_migration.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import 'helpers/sqlite3_loader.dart';

/// Drift only rolls the schema version back when `onUpgrade` THROWS. A migration
/// that catches its own failure therefore stamps the new version over a
/// half-applied schema, and no later open ever retries — the feature is
/// permanently broken with no self-heal.
///
/// These tests pin the contract:
///
///  * a version-gated migration must let a real failure escape;
///  * index creation alone tolerates an object a hand-built/partial legacy
///    database never had (an index is a pure performance artifact);
///  * the static guard at the bottom keeps future migrations from
///    re-introducing the swallow.
void main() {
  ensureSqlite3Loaded();

  const String segments = 'bg_mapping_segments_table';

  test('a failed v34 backfill escapes instead of stamping the version',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    // The BEFORE UPDATE trigger fires per row, so the table needs one row.
    await db.customStatement(
      "INSERT INTO $segments (id, mapping_id, action, fg_start_ms, fg_end_ms) "
      "VALUES (7, 1, 'playMedia', 0, 1000)",
    );
    await db.customStatement(
      'CREATE TRIGGER v34_abort BEFORE UPDATE ON $segments '
      "BEGIN SELECT RAISE(ABORT, 'v34 backfill aborted'); END",
    );

    await expectLater(
      MigrationV34(db).run(db.createMigrator()),
      throwsA(anything),
    );
  });

  test('a failed v32 add-column escapes instead of stamping the version',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    // The probe matches the column name case-sensitively while SQLite
    // identifiers are case-insensitive: the column looks absent to the probe
    // but already exists to ALTER, so the ADD fails with "duplicate column".
    await db.customStatement('DROP TABLE $segments');
    await db.customStatement(
      'CREATE TABLE $segments ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, COLOR_ARGB INTEGER)',
    );

    await expectLater(
      MigrationV32(db).run(db.createMigrator()),
      throwsA(anything),
    );
  });

  test('an index on a table this database never had is tolerated', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    // A hand-built/partial legacy database can lack a feature table. The index
    // is a pure performance artifact, so its absence must not abort the
    // upgrade (this is the case the settings migration tests exercise too).
    await db.customStatement('DROP TABLE vm_progress');

    await expectLater(
      MigrationV33(db).run(db.createMigrator()),
      completes,
    );
  });

  test('a real v35 index failure still escapes instead of stamping the version',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    // A view is not a missing table: SQLite rejects indexing it, and that is a
    // real failure that must abort the migration rather than fall into the
    // tolerated "no such table" case.
    await db.customStatement('DROP TABLE $segments');
    await db.customStatement(
      'CREATE VIEW $segments AS SELECT 1 AS mapping_id',
    );

    await expectLater(
      MigrationV35(db).run(db.createMigrator()),
      throwsA(anything),
    );
  });

  test(
      'an interrupted upgrade rolls the version back and the next open retries',
      () async {
    final dir = Directory.systemTemp.createTempSync('iris_migration_abort');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}iris.db');

    // ── A real schema-v45 database, then pretend the file is still at v33 so
    //    the next open runs v34..v45.
    final seeded = AppDatabase(NativeDatabase(file));
    await seeded.customStatement(
      "INSERT INTO $segments (id, mapping_id, action, fg_start_ms, fg_end_ms) "
      "VALUES (7, 1, 'playMedia', 0, 1000)",
    );
    await seeded.customStatement(
      'CREATE TRIGGER v34_abort BEFORE UPDATE ON $segments '
      "BEGIN SELECT RAISE(ABORT, 'v34 backfill aborted'); END",
    );
    await seeded.customStatement('PRAGMA user_version = 33');
    await seeded.close();

    // ── v34's backfill hits the trigger. The failure must abort the open.
    final failing = AppDatabase(NativeDatabase(file));
    await expectLater(
      failing.customSelect('SELECT 1').get(),
      throwsA(anything),
    );
    try {
      await failing.close();
    } catch (_) {
      // The open never completed; closing is best-effort cleanup only.
    }

    // Drift only advances user_version when the whole migration succeeds.
    final raw = sql.sqlite3.open(file.path);
    expect(raw.select('PRAGMA user_version').first['user_version'], 33);
    raw.execute('DROP TRIGGER v34_abort');
    raw.dispose();

    // ── The next open retries the migration and completes cleanly.
    final healed = AppDatabase(NativeDatabase(file));
    addTearDown(healed.close);
    final row = await healed.customSelect('PRAGMA user_version').getSingle();
    expect(row.read<int>('user_version'), healed.schemaVersion);
  });

  group('migration catch guard', () {
    // Catches allowed NOT to rethrow, keyed by file:
    //  - v31: backfillNullScopes runs from `beforeOpen` on EVERY open, so a
    //    transient failure heals on the next launch (unlike a version-gated
    //    migration, which never retries).
    //  - v38: _canonicalBase parses one legacy row; malformed data only means
    //    that row keeps its absolute path, so schema state is unaffected.
    //  - v49: the tag-source DELETE runs first and unconditionally; only the
    //    best-effort `DROP COLUMN tag_id` is guarded (SQLite < 3.35 cannot drop
    //    a column, and the app no longer reads or writes it, so advancing the
    //    schema version is safe).
    const allowedSwallows = <String, int>{
      'v31_migration.dart': 1,
      'v38_migration.dart': 1,
      'v49_migration.dart': 1,
    };

    test('every version-gated migration rethrows on failure', () {
      final dir = Directory('lib/models/db/migration');
      expect(dir.existsSync(), isTrue, reason: 'migration dir must exist');
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(files, isNotEmpty);

      final catchRe = RegExp(r'catch\s*\(');
      final rethrowRe = RegExp(r'rethrow\s*;');

      for (final name in allowedSwallows.keys) {
        expect(
          files.any((f) => f.uri.pathSegments.last == name),
          isTrue,
          reason: 'allowlisted $name no longer exists — update the allowlist',
        );
      }

      for (final file in files) {
        final name = file.uri.pathSegments.last;
        final src = file.readAsStringSync();
        final catches = catchRe.allMatches(src).length;
        final rethrows = rethrowRe.allMatches(src).length;
        final allowed = allowedSwallows[name] ?? 0;
        expect(
          rethrows,
          greaterThanOrEqualTo(catches - allowed),
          reason: '$name has $catches catch block(s) but only $rethrows '
              'rethrow(s). A swallowed migration failure stamps the schema '
              'version without applying the change, and no later open retries. '
              'Rethrow, or add the catch to the allowlist with a comment.',
        );
      }
    });
  });
}
