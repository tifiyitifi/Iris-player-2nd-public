import 'package:drift/drift.dart';
import 'package:drift_db_viewer/drift_db_viewer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/app_instance.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:path/path.dart' as p;
final areaKeyLog = AreaKeyLog(LogKeys.legacyDb);

/// Runs [body] while holding a cross-process "database open" lease.
///
/// WHY: schema migrations run as plain statements inside drift's `beforeOpen`
/// (`GeneratedDatabase.beforeOpen` — no transaction, and drift does not guard
/// against other processes). Every IRIS window opens the same file, so a second
/// window starting while the first one migrates would read the OLD
/// `user_version`, replay the same `ALTER`/`CREATE` steps and fail with
/// "duplicate column" / "table already exists" — leaving that window's database
/// unusable. Serializing open+migrate makes the loser open an already-upgraded
/// file (drift then runs no migration at all).
///
/// Contention is waited out (migrations are short); a lease that never arrives
/// only logs and proceeds, because startup must never hang on a broken lock
/// directory.
@visibleForTesting
Future<T> withDbOpenLease<T>({
  required String dirPath,
  required Future<T> Function() body,
  int attempts = 150,
  Duration delay = const Duration(milliseconds: 200),
}) async {
  final lease = AppLease(lockPath: p.join(dirPath, 'db-open.lock'));
  var acquired = await lease.acquire();
  for (var i = 0; i < attempts && !acquired; i++) {
    await Future<void>.delayed(delay);
    acquired = await lease.acquire();
  }
  if (!acquired) {
    areaKeyLog.w('db-open lease not acquired after '
        '${attempts * delay.inMilliseconds}ms; opening without it');
  }
  try {
    return await body();
  } finally {
    await lease.release();
  }
}

/// Singleton holder for the app's Drift database.
///
/// Ensures only one `AppDatabase` instance exists, preventing
/// multiple connections and resource conflicts. Call `init()` once
/// at startup to open the database; access it anywhere via `instance`.
///
/// The `SELECT 1` query is a minimal query that just returns the number 1.
/// It forces the database to open immediately without loading any real data.
class AppDatabaseHolder {
  static late final AppDatabase _instance;
  static const int debugDbLimitNum = 100;

  static AppDatabase get instance => _instance;

  static Future<void> init() async {
    Future<void> openAndStore() async {
      final db = AppDatabase();
      // Force the database to open (runs onCreate/onUpgrade on first use).
      await db.customSelect('SELECT 1 ').get();
      _instance = db;
    }

    if (isDesktop) {
      // Multi-window: only one window may migrate the shared file at a time.
      await withDbOpenLease(
        dirPath: await AppInstance.instancesDirPath(),
        body: openAndStore,
      );
    } else {
      await openAndStore();
    }

    await _debugDump(_instance);
  }

  /// Instead of manually querying every table,
  ///
  /// let Drift tell you what tables exist and automatically dump them.
  static Future<void> _debugDump(AppDatabase db) async {
    if (!kDebugMode) return;

    areaKeyLog.i('================ DB SNAPSHOT ================');

    // Get all user tables
    final tables = await db.customSelect('''
      SELECT name
      FROM sqlite_master
      WHERE type='table'
      AND name NOT LIKE 'sqlite_%'
      ORDER BY name
    ''').get();

    for (final tableRow in tables) {
      final tableName = tableRow.data['name'] as String;

      // ---- Row count ----
      final countResult =
          await db.customSelect('SELECT COUNT(*) AS cnt FROM $tableName').getSingle();

      final rowCount = countResult.data['cnt'];

      areaKeyLog.i('Table: $tableName  (rows: $rowCount)');

      // ---- Preview rows ----
      final rows = await db.customSelect(
        'SELECT * FROM $tableName ORDER BY rowid DESC LIMIT ?',
        variables: [Variable.withInt(debugDbLimitNum)],
      ).get();

      if (rows.isEmpty) {
        areaKeyLog.i('  <empty>');
      } else {
        for (final row in rows) {
          areaKeyLog.i('  ${row.data}');
        }
      }

      areaKeyLog.i('---------------------------------------------');
    }

    final indexes = await db.customSelect('''
  SELECT name, tbl_name
  FROM sqlite_master
  WHERE type='index'
  ORDER BY name
''').get();

    for (final row in indexes) {
      areaKeyLog.i('Index: ${row.data}');
    }

    areaKeyLog.i('=============================================');
  }

  static void openInspector(BuildContext context) {
    // We use the internal _instance.
    // The UI doesn't need to know DriftDbViewer exists.
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => DriftDbViewer(_instance)),
    );
  }
}
