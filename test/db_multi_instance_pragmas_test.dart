import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:sqlite3/sqlite3.dart';

import 'helpers/sqlite3_loader.dart';

/// Two IRIS windows share ONE database file. The connection setup must put it
/// in WAL with a busy timeout, otherwise concurrent writers fail immediately
/// with SQLITE_BUSY and progress/settings writes are silently lost.
void main() {
  test('every connection opens in WAL with a busy timeout', () async {
    ensureSqlite3Loaded();
    final dir = await Directory.systemTemp.createTemp('iris_db_wal_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/iris.db';

    final first = sqlite3.open(path);
    addTearDown(first.dispose);
    multiInstancePragmaSetup(first);

    expect(
      first.select('PRAGMA journal_mode').single.values.first,
      'wal',
      reason: 'readers and one writer must coexist across processes',
    );
    expect(
      first.select('PRAGMA busy_timeout').single.values.first,
      5000,
      reason: 'a competing writer waits instead of throwing SQLITE_BUSY',
    );
    expect(
      first.select('PRAGMA synchronous').single.values.first,
      1, // NORMAL
      reason: 'the durable-enough pairing for WAL',
    );

    // journal_mode is a FILE property: the other window sees WAL too.
    final second = sqlite3.open(path);
    addTearDown(second.dispose);
    expect(second.select('PRAGMA journal_mode').single.values.first, 'wal');
  });
}
