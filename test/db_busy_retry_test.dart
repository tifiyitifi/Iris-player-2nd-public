import 'dart:io';

import 'package:drift/native.dart' show NativeDatabase, SqliteException;
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_busy_retry.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import 'helpers/sqlite3_loader.dart';

/// Two IRIS windows share one SQLite file, so a write can lose the race for the
/// write lock. `busy_timeout` waits it out, but the loser of a long transaction
/// still surfaces SQLITE_BUSY; a bounded retry must absorb that instead of
/// dropping the write silently (and must NOT retry a real constraint error).
SqliteException _sqlite(int code, String message) =>
    SqliteException(code, message);

void main() {
  test('a transient SQLITE_BUSY is retried and the later result wins',
      () async {
    var calls = 0;
    final retries = <int>[];

    final value = await retryOnDbBusy<int>(
      () async {
        calls++;
        if (calls < 3) throw _sqlite(5, 'database is locked');
        return 42;
      },
      initialDelay: Duration.zero,
      onRetry: (attempt, _) => retries.add(attempt),
    );

    expect(value, 42);
    expect(calls, 3);
    expect(retries, <int>[1, 2], reason: 'one report per failed attempt');
  });

  test('exhausted retries rethrow the last busy error', () async {
    var calls = 0;

    await expectLater(
      retryOnDbBusy<void>(
        () async {
          calls++;
          throw _sqlite(5, 'database is locked');
        },
        initialDelay: Duration.zero,
      ),
      throwsA(isA<SqliteException>()),
    );

    expect(calls, 3, reason: 'bounded: never retries forever');
  });

  test('SQLITE_LOCKED is transient too', () async {
    var calls = 0;

    final value = await retryOnDbBusy<String>(
      () async {
        calls++;
        if (calls == 1) throw _sqlite(6, 'database table is locked');
        return 'ok';
      },
      initialDelay: Duration.zero,
    );

    expect(value, 'ok');
    expect(calls, 2);
  });

  test('a non-busy failure is not retried', () async {
    var calls = 0;

    await expectLater(
      retryOnDbBusy<void>(
        () async {
          calls++;
          throw _sqlite(19, 'UNIQUE constraint failed');
        },
        initialDelay: Duration.zero,
      ),
      throwsA(isA<SqliteException>()),
    );

    expect(calls, 1, reason: 'a constraint violation can never succeed again');
  });

  test('extended busy/locked codes are transient too', () async {
    // `resultCode` already folds the extended code (`& 0xFF` in sqlite3), so
    // SQLITE_BUSY_SNAPSHOT (517) and SQLITE_LOCKED_VTAB (262) retry. This pins
    // the contract: constructing with an extended code must still classify.
    expect(isDbBusyError(_sqlite(517, 'database is locked')), isTrue);
    expect(isDbBusyError(_sqlite(262, 'database table is locked')), isTrue);

    var calls = 0;
    final value = await retryOnDbBusy<String>(
      () async {
        calls++;
        if (calls == 1) throw _sqlite(517, 'database is locked');
        return 'ok';
      },
      initialDelay: Duration.zero,
    );

    expect(value, 'ok');
    expect(calls, 2);
  });

  test('a non-SQLite error is not retried either', () async {
    var calls = 0;

    await expectLater(
      retryOnDbBusy<void>(
        () async {
          calls++;
          throw StateError('boom');
        },
        initialDelay: Duration.zero,
      ),
      throwsA(isA<StateError>()),
    );

    expect(calls, 1);
  });

  test(
      'withShortDbBusyTimeout fails fast under a held write lock and restores the default',
      () async {
    ensureSqlite3Loaded();
    final dir = Directory.systemTemp.createTempSync('iris_busy_timeout');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}busy.db');

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    await db.customStatement('CREATE TABLE t (id INTEGER PRIMARY KEY)');

    // A second connection holds the write lock (RESERVED, uncommitted).
    final holder = sql.sqlite3.open(file.path);
    addTearDown(holder.dispose);
    holder.execute('BEGIN IMMEDIATE');
    holder.execute('INSERT INTO t (id) VALUES (1)');

    final sw = Stopwatch()..start();
    Object? busyError;
    try {
      await withShortDbBusyTimeout(
        db,
        250,
        () => db.customStatement('INSERT INTO t (id) VALUES (2)'),
      );
    } catch (e) {
      busyError = e;
    }
    sw.stop();
    expect(busyError, isA<SqliteException>());
    expect(isDbBusyError(busyError!), isTrue);
    // The connection default is 5s: without the fail-fast window this would
    // take at least that long (and freeze the UI isolate with it).
    expect(sw.elapsedMilliseconds, lessThan(4000));
    holder.execute('ROLLBACK');

    final row = await db.customSelect('PRAGMA busy_timeout').getSingle();
    expect(row.data.values.single as int, kDbBusyTimeoutMs,
        reason: 'the connection default must be restored for other writers');
  });
}
