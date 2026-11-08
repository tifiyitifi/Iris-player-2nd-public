// Natural-sort benchmark harness (ad-hoc, NOT part of CI).
//
// ignore_for_file: avoid_print
//
// Run:
//   flutter test tool/bench/natural_key_bench.dart --reporter expanded
//
// Why it lives in tool/ and not test/: it builds a 500k-row database and takes
// minutes. `flutter test` only scans test/, so CI never pays for it.
//
// It creates its own throwaway databases under the system temp dir and never
// touches a user/app database.
//
// Sections (see .opencode/plan/natural-sort-benchmark.md):
//   B0  environment + dataset
//   B1  current ORDER BY (normalized_name) plans + timings
//   B5a write amplification, baseline
//   B2  ALTER + backfill strategies (A/B/C/D)
//   B3  key size
//   B4  candidate index sets, plans + timings (ASC / DESC / DESC-rev)
//   B5b write amplification, with the key column + indexes
//   B6  SharedMediaOrder.build (derived base order) on 500k
//   B7  Dart comparator cost (current / naive natural / decorate-sort)
//   B8  paging-correctness fixtures (SQL order == Dart key order, page seams)
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart'
    show MediaType;
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/resolver/shared_media_order.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/utils/natural_sort_key.dart';

import '../../test/helpers/sqlite3_loader.dart';

const int kFiles = 500000;
const int kDirs = 5000;
const int kInsertBatch = 500;
const int kPage = 200;

// ---------------------------------------------------------------------------
// Retired `vmNaturalCompare` (verbatim copy of the file deleted in
// `feat(sort)`, kept ONLY so B8 can report how the new key differs from the
// algorithm it replaced). Not used by production code.
//
// NB: the trailing `ra.length.compareTo(rb.length)` is load-bearing — it is the
// "fewer leading zeros first" rule the key deliberately keeps (`7` < `007`).
// ---------------------------------------------------------------------------
final _leadZeroRun = RegExp(r'^0+');

int _legacyVmCompare(String a, String b) {
  final al = a.toLowerCase();
  final bl = b.toLowerCase();
  var i = 0, j = 0;
  while (i < a.length && j < b.length) {
    final ad = _isDigit(a.codeUnitAt(i));
    final bd = _isDigit(b.codeUnitAt(j));
    if (ad && bd) {
      var i2 = i;
      while (i2 < a.length && _isDigit(a.codeUnitAt(i2))) {
        i2++;
      }
      var j2 = j;
      while (j2 < b.length && _isDigit(b.codeUnitAt(j2))) {
        j2++;
      }
      final cmp = _legacyNumericRuns(a.substring(i, i2), b.substring(j, j2));
      if (cmp != 0) return cmp;
      i = i2;
      j = j2;
    } else if (ad != bd) {
      return ad ? -1 : 1;
    } else {
      final ca = al.codeUnitAt(i);
      final cb = bl.codeUnitAt(j);
      if (ca != cb) return ca.compareTo(cb);
      i++;
      j++;
    }
  }
  final byLen = (a.length - i).compareTo(b.length - j);
  if (byLen != 0) return byLen;
  return a.compareTo(b);
}

int _legacyNumericRuns(String ra, String rb) {
  final ta = ra.replaceFirst(_leadZeroRun, '');
  final tb = rb.replaceFirst(_leadZeroRun, '');
  if (ta.length != tb.length) return ta.length.compareTo(tb.length);
  final cmp = ta.compareTo(tb); // same length -> lexicographic == numeric
  if (cmp != 0) return cmp;
  return ra.length.compareTo(rb.length); // fewer leading zeros first
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

int _sign(int v) => v < 0 ? -1 : (v > 0 ? 1 : 0);

// ---------------------------------------------------------------------------
// Dataset
// ---------------------------------------------------------------------------
int _nameSlot(int i) => (i * 7919) % kFiles;

String _nameFor(int slot) {
  final dir = slot % kDirs;
  final ep = slot ~/ kDirs + 1;
  final mod = slot % 100;
  if (mod < 60) return 'Show$dir S01E$ep ep$ep [1080p].mkv';
  if (mod < 85) {
    return 'EP${ep.toString().padLeft(7, '0')}_disk0_part'
        '${(slot % 1000).toString().padLeft(3, '0')}.mkv';
  }
  if (slot % 99991 == 0) return 'rec${slot}1234567890123.dat';
  return '进击的巨人 第$ep集 第${slot % 100}话.mkv';
}

String _esc(String s) => s.replaceAll("'", "''");

String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);

void main() {
  test('natural sort benchmark (500k)', () async {
    ensureSqlite3Loaded();
    final root = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}iris-nat-bench');
    if (root.existsSync()) root.deleteSync(recursive: true);
    root.createSync(recursive: true);

    final dbFile = File('${root.path}${Platform.pathSeparator}bench.db');
    final db = AppDatabase(
      NativeDatabase(dbFile, setup: multiInstancePragmaSetup),
    );
    await db.customSelect('SELECT 1').get(); // force open + migrations

    void section(String s) => print('\n=== $s ===');
    void out(String s) => print(s);

    int fileSize(String path) {
      final f = File(path);
      return f.existsSync() ? f.lengthSync() : 0;
    }

    int dbTotalBytes() =>
        fileSize(dbFile.path) +
        fileSize('${dbFile.path}-wal') +
        fileSize('${dbFile.path}-shm');

    Future<void> checkpoint() async {
      await db.customSelect('PRAGMA wal_checkpoint(TRUNCATE)').get();
    }

    // ---------------------------------------------------------------- B0 --
    section('B0 environment + dataset');
    final ver = (await db.customSelect('SELECT sqlite_version() AS v').get())
        .first
        .read<String>('v');
    final pageSize = (await db.customSelect('PRAGMA page_size').get())
        .first
        .read<int>('page_size');
    final journal = (await db.customSelect('PRAGMA journal_mode').get())
        .first
        .read<String>('journal_mode');
    out('sqlite=$ver page_size=$pageSize journal=$journal');
    out('dataset: $kFiles files / $kDirs dirs, single scope "st1"');

    var sw = Stopwatch()..start();

    // Bulk-load fast path. Production inserts row-by-row into the indexed
    // table; that took ~22 min here (2 MB default page cache + random index
    // pages), so we drop the indexes, load in ONE transaction with a large
    // cache, then recreate the EXACT captured DDL. The final schema/index set
    // the ORDER BY benchmarks see is identical to production.
    final idxRows = await db.customSelect(
      "SELECT name, sql FROM sqlite_master WHERE type='index' "
      "AND tbl_name='media_nodes' AND sql IS NOT NULL",
    ).get();
    final idxDdl = [
      for (final r in idxRows) (r.read<String>('name'), r.read<String>('sql')),
    ];
    for (final (name, _) in idxDdl) {
      await db.customStatement('DROP INDEX IF EXISTS "$name"');
    }
    await db.customStatement('PRAGMA cache_size=-262144');

    // Directory rows first (realistic listing shape).
    await db.customStatement('BEGIN');
    for (var batchStart = 0; batchStart < kDirs; batchStart += kInsertBatch) {
      final buf = StringBuffer('INSERT INTO media_nodes (storage_id, '
          'data_scope_id, path, parent_path, path_depth, name, normalized_name, '
          'node_kind, media_type, is_present) VALUES ');
      var first = true;
      for (var d = batchStart; d < min(batchStart + kInsertBatch, kDirs); d++) {
        final name = 'Show$d';
        if (!first) buf.write(',');
        first = false;
        buf.write("('st1','st1','$name',NULL,1,'${_esc(name)}',"
            "'${_esc(name.toLowerCase())}','directory',NULL,1)");
      }
      await db.customStatement(buf.toString());
    }

    // File rows, insertion order deliberately shuffled against name order.
    final names = List<String>.filled(kFiles, '');
    for (var i = 0; i < kFiles; i++) {
      names[i] = _nameFor(_nameSlot(i));
    }
    for (var batchStart = 0; batchStart < kFiles; batchStart += kInsertBatch) {
      final buf = StringBuffer('INSERT INTO media_nodes (storage_id, '
          'data_scope_id, path, parent_path, path_depth, name, normalized_name, '
          'node_kind, media_type, size_in_bytes, duration_ms, modified_at, '
          'is_present) VALUES ');
      var first = true;
      for (var i = batchStart; i < min(batchStart + kInsertBatch, kFiles); i++) {
        final slot = _nameSlot(i);
        final dir = 'Show${slot % kDirs}';
        final name = names[i];
        if (!first) buf.write(',');
        first = false;
        buf.write("('st1','st1','$dir/${_esc(name)}','$dir',2,"
            "'${_esc(name)}','${_esc(name.toLowerCase())}','file','video',"
            '${1024 * (i % 900)},${60000 * (i % 30)},${1700000000000 + i},1)');
      }
      await db.customStatement(buf.toString());
    }
    await db.customStatement('COMMIT');
    out('rows loaded: ${sw.elapsedMilliseconds} ms');
    sw.reset();

    // Back to production defaults for every measurement below.
    await db.customStatement('PRAGMA cache_size=-2000');
    for (final (_, sql) in idxDdl) {
      await db.customStatement(sql);
    }
    out('indexes recreated: ${sw.elapsedMilliseconds} ms (${idxDdl.length} idx)');
    await checkpoint();
    out('insert total: ${sw.elapsedMilliseconds} ms  db=${_mb(dbTotalBytes())} MB');
    sw.reset();

    // ------------------------------------------------------- query helper --
    Future<(int, double)> timedQuery(
      String sql,
      List<Variable> vars, {
      int reps = 3,
    }) async {
      var rows = 0;
      await db.customSelect(sql, variables: vars).get(); // warm-up
      final t = Stopwatch()..start();
      for (var r = 0; r < reps; r++) {
        rows = (await db.customSelect(sql, variables: vars).get()).length;
      }
      t.stop();
      return (rows, t.elapsedMicroseconds / 1000 / reps);
    }

    Future<String> plan(String sql, List<Variable> vars) async {
      final rows = await db.customSelect('EXPLAIN QUERY PLAN $sql',
          variables: vars).get();
      return rows.map((r) => r.read<String>('detail')).join(' | ');
    }

    String ms(double v) => '${v.toStringAsFixed(1)}ms';

    // Baseline SQL (what the app issues today).
    const q1 = "SELECT * FROM media_nodes WHERE data_scope_id=?1 "
        "AND path IS NOT NULL AND node_kind='file' "
        'ORDER BY normalized_name, path LIMIT $kPage OFFSET ?2';
    const q2 = "SELECT * FROM media_nodes WHERE data_scope_id=?1 "
        "AND path IS NOT NULL AND node_kind='file' "
        'ORDER BY parent_path, normalized_name, path LIMIT $kPage OFFSET ?2';
    const q3 = 'SELECT * FROM media_nodes WHERE data_scope_id=?1 '
        'AND parent_path=?2 ORDER BY normalized_name, path LIMIT $kPage';
    const q4 = 'SELECT * FROM media_nodes WHERE data_scope_id=?1 '
        "AND parent_path=?2 AND node_kind='file' "
        'ORDER BY node_kind, normalized_name, path LIMIT $kPage';

    List<Variable> v1(int offset) => [
          Variable.withString('st1'),
          Variable.withInt(offset),
        ];
    List<Variable> v2(String dir) => [
          Variable.withString('st1'),
          Variable.withString(dir),
        ];

    // ---------------------------------------------------------------- B1 --
    section('B1 baseline (normalized_name, legacy index restored)');
    // v53 dropped `idx_scope_parent_name_sort`. Recreate it for this section
    // only, so these "before" numbers stay comparable with the plan document;
    // production no longer orders by normalized_name anywhere.
    sw = Stopwatch()..start();
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_scope_parent_name_sort '
      'ON media_nodes(data_scope_id, parent_path, normalized_name)',
    );
    out('legacy sort index recreated: ${sw.elapsedMilliseconds} ms');
    for (final (label, sql, vars) in [
      ('Q1 all-name asc', q1, v1(0)),
      ('Q2 grouped asc', q2, v1(0)),
      ('Q3 folder', q3, v2('Show42')),
      ('Q4 folder+folderFirst', q4, v2('Show42')),
    ]) {
      out('$label plan: ${await plan(sql, vars)}');
    }
    for (final off in [0, 100000, 250000, 499000]) {
      final (n, t) = await timedQuery(q1, v1(off));
      out('Q1 offset $off: ${ms(t)} (rows=$n)');
    }
    for (final off in [0, 100000, 250000, 499000]) {
      final (n, t) = await timedQuery(q2, v1(off));
      out('Q2 offset $off: ${ms(t)} (rows=$n)');
    }
    {
      final (n, t) = await timedQuery(q3, v2('Show42'));
      out('Q3 folder: ${ms(t)} (rows=$n)');
      final (n4, t4) = await timedQuery(q4, v2('Show42'));
      out('Q4 folder+folderFirst: ${ms(t4)} (rows=$n4)');
    }
    await db.customStatement('DROP INDEX IF EXISTS idx_scope_parent_name_sort');

    // --------------------------------------------------------- upsert SQL --
    Future<void> upsertBatch(int start, int count, {bool withKey = false}) async {
      final cols = 'storage_id, data_scope_id, path, parent_path, path_depth, '
          'name, normalized_name, ${withKey ? 'natural_name, ' : ''}'
          'node_kind, media_type, size_in_bytes, duration_ms, modified_at, '
          'is_present';
      final updates = 'name=excluded.name, '
          'normalized_name=excluded.normalized_name, '
          '${withKey ? 'natural_name=excluded.natural_name, ' : ''}'
          'size_in_bytes=excluded.size_in_bytes, '
          'duration_ms=excluded.duration_ms';
      for (var batchStart = start;
          batchStart < start + count;
          batchStart += kInsertBatch) {
        final buf = StringBuffer('INSERT INTO media_nodes ($cols) VALUES ');
        var first = true;
        for (var i = batchStart;
            i < min(batchStart + kInsertBatch, start + count);
            i++) {
          final slot = _nameSlot(i);
          final dir = 'Show${slot % kDirs}';
          final name = names[i];
          if (!first) buf.write(',');
          first = false;
          buf.write("('st1','st1','$dir/${_esc(name)}','$dir',2,"
              "'${_esc(name)}','${_esc(name.toLowerCase())}',"
              '${withKey ? "'${_esc(naturalSortKey(name))}'," : ''}'
              "'file','video',${2048 + i % 100},${70000 + i % 50},"
              '${1700000000001 + i},1)');
        }
        buf.write(' ON CONFLICT(data_scope_id, path) DO UPDATE SET $updates');
        await db.customStatement(buf.toString());
      }
    }

    // --------------------------------------------------------------- B5a --
    section('B5a write amplification (baseline, no key column)');
    sw = Stopwatch()..start();
    await db.customStatement('BEGIN');
    await upsertBatch(0, 50000);
    await db.customStatement('COMMIT');
    out('50k upsert: ${sw.elapsedMilliseconds} ms');

    // ---------------------------------------------------------------- B2 --
    section('B2 ALTER + backfill strategies');
    sw = Stopwatch()..start();
    final hasKey = (await db.customSelect('PRAGMA table_info(media_nodes)').get())
        .any((r) => r.read<String>('name') == 'natural_name');
    if (hasKey) {
      // Re-running against an already-upgraded schema (post-v53): the column and
      // its indexes exist, so recreate the pre-backfill state instead.
      await db.customStatement('DROP INDEX IF EXISTS idx_scope_natural_path');
      await db.customStatement(
          'DROP INDEX IF EXISTS idx_scope_parent_natural_path');
      out('schema already has natural_name (v53); measuring on the new shape');
    } else {
      await db.customStatement(
          "ALTER TABLE media_nodes ADD COLUMN natural_name TEXT NOT NULL DEFAULT ''");
      out('ALTER ADD COLUMN: ${sw.elapsedMilliseconds} ms');
    }

    // Pull (id, name) once; encode once so every variant writes the same values.
    final ids = <int>[];
    final keys = <String>[];
    for (var off = 0; off < kFiles + kDirs; off += 20000) {
      final rows = await db.customSelect(
        'SELECT id, name FROM media_nodes ORDER BY id LIMIT 20000 OFFSET ?1',
        variables: [Variable.withInt(off)],
      ).get();
      if (rows.isEmpty) break;
      for (final r in rows) {
        ids.add(r.read<int>('id'));
        keys.add(naturalSortKey(r.read<String>('name')));
      }
    }
    out('prepared ${ids.length} keys (encoding done once, excluded from timings)');

    Future<void> resetKeys() async {
      await db.customStatement("UPDATE media_nodes SET natural_name=''");
      await checkpoint();
    }

    Future<int> backfillPerRow() async {
      sw = Stopwatch()..start();
      await db.customStatement('BEGIN');
      for (var i = 0; i < ids.length; i++) {
        await db.customStatement(
          'UPDATE media_nodes SET natural_name=?1 WHERE id=?2',
          [keys[i], ids[i]],
        );
      }
      await db.customStatement('COMMIT');
      return sw.elapsedMilliseconds;
    }

    Future<(int, int, int)> backfillCaseBatch(
        {bool stopAfterChunk = false}) async {
      const chunk = 20000;
      const batch = 500;
      var walPeak = 0;
      sw = Stopwatch()..start();
      var updated = 0;
      for (var base = 0; base < ids.length; base += chunk) {
        final end = min(base + chunk, ids.length);
        await db.customStatement('BEGIN');
        for (var b = base; b < end; b += batch) {
          final stop = min(b + batch, end);
          final cases = StringBuffer();
          final idList = StringBuffer();
          final vars = <Object>[];
          for (var i = b; i < stop; i++) {
            cases.write(' WHEN ${ids[i]} THEN ?${vars.length + 1}');
            if (i > b) idList.write(',');
            idList.write(ids[i]);
            vars.add(keys[i]);
          }
          await db.customStatement(
            'UPDATE media_nodes SET natural_name = CASE id${cases.toString()} END '
            'WHERE id IN (${idList.toString()})',
            vars,
          );
          updated += stop - b;
        }
        await db.customStatement('COMMIT');
        await db.customSelect('PRAGMA wal_checkpoint(PASSIVE)').get();
        walPeak = max(walPeak, fileSize('${dbFile.path}-wal'));
        if (stopAfterChunk && base >= chunk) break;
      }
      return (sw.elapsedMilliseconds, walPeak, updated);
    }

    Future<(int, int)> backfillTempTable() async {
      sw = Stopwatch()..start();
      await db.customStatement(
          'CREATE TEMP TABLE IF NOT EXISTS tmp_key(id INTEGER PRIMARY KEY, k TEXT)');
      await db.customStatement('BEGIN');
      for (var i = 0; i < ids.length; i += 5000) {
        final end = min(i + 5000, ids.length);
        final buf = StringBuffer('INSERT INTO tmp_key(id, k) VALUES ');
        for (var j = i; j < end; j++) {
          if (j > i) buf.write(',');
          buf.write('(${ids[j]},\'${_esc(keys[j])}\')');
        }
        await db.customStatement(buf.toString());
      }
      await db.customStatement('COMMIT');
      await db.customStatement(
          'UPDATE media_nodes SET natural_name = '
          '(SELECT k FROM tmp_key WHERE tmp_key.id = media_nodes.id) '
          'WHERE id IN (SELECT id FROM tmp_key)');
      await db.customStatement('DROP TABLE tmp_key');
      await db.customSelect('PRAGMA wal_checkpoint(PASSIVE)').get();
      final walPeak = fileSize('${dbFile.path}-wal');
      return (sw.elapsedMilliseconds, walPeak);
    }

    await resetKeys();
    final perRowMs = await backfillPerRow();
    out('A per-row UPDATE: $perRowMs ms');

    await resetKeys();
    final (caseMs, caseWal, caseRows) = await backfillCaseBatch();
    out('B CASE-batch 500 / commit 20k: $caseMs ms  rows=$caseRows  '
        'wal_peak=${_mb(caseWal)} MB');

    await resetKeys();
    final (tmpMs, tmpWal) = await backfillTempTable();
    out('C temp-table + subquery: $tmpMs ms  wal_peak=${_mb(tmpWal)} MB');

    // D: index first, then the same batch backfill.
    await db.customStatement(
        'CREATE INDEX IF NOT EXISTS idx_scope_natural ON media_nodes(data_scope_id, natural_name)');
    await resetKeys();
    final (caseIdxMs, _, _) = await backfillCaseBatch();
    out('D index-first + B: $caseIdxMs ms');
    await db.customStatement('DROP INDEX IF EXISTS idx_scope_natural');
    await checkpoint();

    // Ensure full backfill for the rest of the run.
    await resetKeys();
    await backfillCaseBatch();
    await checkpoint();

    // ---------------------------------------------------------------- B3 --
    section('B3 key size');
    final sizeRow = (await db.customSelect(
      'SELECT COUNT(*) n, AVG(LENGTH(name)) an, AVG(LENGTH(natural_name)) ak, '
      'MAX(LENGTH(natural_name)-LENGTH(name)) mx, '
      "SUM(CASE WHEN name GLOB '*[^ -~]*' THEN 1 ELSE 0 END) cjk "
      'FROM media_nodes',
    ).get())
        .first;
    final cjkRow = (await db.customSelect(
      "SELECT COUNT(*) n, AVG(LENGTH(name)) an, AVG(LENGTH(natural_name)) ak "
      "FROM media_nodes WHERE name GLOB '*[^ -~]*'",
    ).get())
        .first;
    out('rows=${sizeRow.read<int>('n')} '
        'name_avg=${(sizeRow.read<double?>('an') ?? 0).toStringAsFixed(1)}B '
        'key_avg=${(sizeRow.read<double?>('ak') ?? 0).toStringAsFixed(1)}B '
        'max_delta=${sizeRow.read<int?>('mx')}B');
    out('cjk rows=${cjkRow.read<int>('n')} '
        'name_avg=${(cjkRow.read<double?>('an') ?? 0).toStringAsFixed(1)}B '
        'key_avg=${(cjkRow.read<double?>('ak') ?? 0).toStringAsFixed(1)}B');

    // ---------------------------------------------------------------- B4 --
    section('B4 candidate index sets');
    const q1n = "SELECT * FROM media_nodes WHERE data_scope_id=?1 "
        "AND path IS NOT NULL AND node_kind='file' "
        'ORDER BY natural_name, path LIMIT $kPage OFFSET ?2';
    const q2n = "SELECT * FROM media_nodes WHERE data_scope_id=?1 "
        "AND path IS NOT NULL AND node_kind='file' "
        'ORDER BY parent_path, natural_name, path LIMIT $kPage OFFSET ?2';
    const q3n = 'SELECT * FROM media_nodes WHERE data_scope_id=?1 '
        'AND parent_path=?2 ORDER BY natural_name, path LIMIT $kPage';
    const q4n = 'SELECT * FROM media_nodes WHERE data_scope_id=?1 '
        "AND parent_path=?2 AND node_kind='file' "
        'ORDER BY node_kind, natural_name, path LIMIT $kPage';
    // Direction variants (tail currently ASC in the DAO; DESC-rev = tail follows).
    const q1d = "SELECT * FROM media_nodes WHERE data_scope_id=?1 "
        "AND path IS NOT NULL AND node_kind='file' "
        'ORDER BY natural_name DESC, path ASC LIMIT $kPage OFFSET ?2';
    const q1dr = "SELECT * FROM media_nodes WHERE data_scope_id=?1 "
        "AND path IS NOT NULL AND node_kind='file' "
        'ORDER BY natural_name DESC, path DESC LIMIT $kPage OFFSET ?2';
    const q2dr = "SELECT * FROM media_nodes WHERE data_scope_id=?1 "
        "AND path IS NOT NULL AND node_kind='file' "
        'ORDER BY parent_path DESC, natural_name DESC, path DESC LIMIT $kPage OFFSET ?2';

    Future<int> sizeNow() async {
      await checkpoint();
      final r = await db.customSelect('PRAGMA page_count').get();
      final n = r.first.read<int>('page_count');
      return n * pageSize;
    }

    final baseSize = await sizeNow();
    out('table size (no natural index yet): ${_mb(baseSize)} MB');

    final sets = <String, List<String>>{
      'S1': [
        'CREATE INDEX IF NOT EXISTS idx_scope_natural_path '
            'ON media_nodes(data_scope_id, natural_name, path)',
      ],
      'S2': [
        'CREATE INDEX IF NOT EXISTS idx_scope_parent_natural_path '
            'ON media_nodes(data_scope_id, parent_path, natural_name, path)',
      ],
      'S3': [
        'DROP INDEX IF EXISTS idx_scope_parent_name_sort',
      ],
    };

    Future<void> reportQueries(String tag) async {
      out('[$tag] Q1n plan: ${await plan(q1n, v1(0))}');
      out('[$tag] Q2n plan: ${await plan(q2n, v1(0))}');
      out('[$tag] Q1d plan: ${await plan(q1d, v1(0))}');
      out('[$tag] Q1dr plan: ${await plan(q1dr, v1(0))}');
      out('[$tag] Q2dr plan: ${await plan(q2dr, v1(0))}');
      out('[$tag] Q3n plan: ${await plan(q3n, v2('Show42'))}');

      for (final off in [0, 250000, 499000]) {
        final (n, t) = await timedQuery(q1n, v1(off));
        out('[$tag] Q1n offset $off: ${ms(t)} (rows=$n)');
      }
      for (final off in [0, 250000]) {
        final (n, t) = await timedQuery(q2n, v1(off));
        out('[$tag] Q2n offset $off: ${ms(t)} (rows=$n)');
      }
      for (final off in [0, 250000]) {
        final (n, t) = await timedQuery(q1d, v1(off));
        out('[$tag] Q1d(desc,tail-asc) offset $off: ${ms(t)} (rows=$n)');
      }
      for (final off in [0, 250000]) {
        final (n, t) = await timedQuery(q1dr, v1(off));
        out('[$tag] Q1dr(desc,tail-desc) offset $off: ${ms(t)} (rows=$n)');
      }
      for (final off in [0, 250000]) {
        final (n, t) = await timedQuery(q2dr, v1(off));
        out('[$tag] Q2dr(desc,tail-desc) offset $off: ${ms(t)} (rows=$n)');
      }
      final (n3, t3) = await timedQuery(q3n, v2('Show42'));
      out('[$tag] Q3n folder: ${ms(t3)} (rows=$n3)');
      final (n4, t4) = await timedQuery(q4n, v2('Show42'));
      out('[$tag] Q4n folder+folderFirst: ${ms(t4)} (rows=$n4)');
      out('[$tag] size: ${_mb(await sizeNow())} MB');
    }

    for (final entry in sets.entries) {
      section('B4/${entry.key}');
      for (final stmt in entry.value) {
        sw = Stopwatch()..start();
        await db.customStatement(stmt);
        out('${stmt.split(' ').take(3).join(' ')}: ${sw.elapsedMilliseconds} ms');
      }
      await reportQueries(entry.key);
    }

    // --------------------------------------------------------------- B5b --
    section('B5b index maintenance cost on upsert (20k rows, key in all runs)');
    // NOTE: this is NOT a "before the change" comparison. The DB was created
    // with the v53 schema, so `natural_name` is written in every variant; the
    // delta below is the cost of the two new INDEXES only. The cost of the
    // column itself cannot be measured on this schema.
    const kB5Rows = 20000;
    Future<void> dropNaturalIdx() async {
      await db.customStatement('DROP INDEX IF EXISTS idx_scope_natural_path');
      await db.customStatement(
          'DROP INDEX IF EXISTS idx_scope_parent_natural_path');
    }

    Future<void> createS1() => db.customStatement(
        'CREATE INDEX IF NOT EXISTS idx_scope_natural_path '
        'ON media_nodes(data_scope_id, natural_name, path)');
    Future<void> createS2() => db.customStatement(
        'CREATE INDEX IF NOT EXISTS idx_scope_parent_natural_path '
        'ON media_nodes(data_scope_id, parent_path, natural_name, path)');

    Future<int> b5Run() async {
      sw = Stopwatch()..start();
      await db.customStatement('BEGIN');
      await upsertBatch(0, kB5Rows, withKey: true);
      await db.customStatement('COMMIT');
      return sw.elapsedMilliseconds;
    }

    // Warm-up pass first so the three measured numbers share a warm cache.
    await dropNaturalIdx();
    await b5Run();
    await createS1();
    await b5Run();
    await createS2();
    await b5Run();

    await dropNaturalIdx();
    final tNone = await b5Run();
    await createS1();
    final tS1 = await b5Run();
    await createS2();
    final tS2 = await b5Run();
    final pctS1 = ((tS1 - tNone) * 100 / tNone).round();
    final pctS2 = ((tS2 - tNone) * 100 / tNone).round();
    out('20k upsert: no natural idx=$tNone ms  S1=$tS1 ms (+$pctS1%)  '
        'S1+S2=$tS2 ms (+$pctS2%)');

    // ---------------------------------------------------------------- B6 --
    section('B6 derived base order (500k): build() plain / grouped / DESC');
    // Informational: failures here must not abort the run.
    try {
      await DbModule.init(db);
      sw = Stopwatch()..start();
      final order = await SharedMediaOrder.build(
        DbModule.nodeRepository,
        storageId: 'st1',
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.asc,
        pathGroupFirst: false,
        mediaTypes: const [MediaType.video],
      );
      out('build() plain ASC   (keyset): ${sw.elapsedMilliseconds} ms  '
          'nodes=${order.length}');
      sw.reset();
      final orderGrouped = await SharedMediaOrder.build(
        DbModule.nodeRepository,
        storageId: 'st1',
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.asc,
        pathGroupFirst: true,
        mediaTypes: const [MediaType.video],
      );
      out('build() grouped ASC (keyset): ${sw.elapsedMilliseconds} ms  '
          'nodes=${orderGrouped.length}');
      sw.reset();
      final orderGroupedDesc = await SharedMediaOrder.build(
        DbModule.nodeRepository,
        storageId: 'st1',
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.desc,
        pathGroupFirst: true,
        mediaTypes: const [MediaType.video],
      );
      out('build() grouped DESC (2-phase keyset): '
          '${sw.elapsedMilliseconds} ms  nodes=${orderGroupedDesc.length}');
      sw.reset();

      // Reference: the raw keyset walk (no NULL-group handling, ASC only).
      Future<(int, int)> keyset({required bool grouped}) async {
        final t = Stopwatch()..start();
        var total = 0;
        var k = '';
        var p = '';
        var g = '';
        while (true) {
          final rows = await db.customSelect(
            grouped
                ? "SELECT parent_path, natural_name, path FROM media_nodes "
                    "WHERE data_scope_id=?1 AND node_kind='file' "
                    "AND media_type='video' "
                    'AND (parent_path > ?2 OR (parent_path = ?2 AND '
                    '(natural_name > ?3 OR (natural_name = ?3 AND path > ?4)))) '
                    'ORDER BY parent_path, natural_name, path LIMIT 20000'
                : "SELECT natural_name, path FROM media_nodes "
                    "WHERE data_scope_id=?1 AND node_kind='file' "
                    "AND media_type='video' "
                    'AND (natural_name > ?2 OR '
                    '(natural_name = ?2 AND path > ?3)) '
                    'ORDER BY natural_name, path LIMIT 20000',
            variables: grouped
                ? [
                    Variable.withString('st1'),
                    Variable.withString(g),
                    Variable.withString(k),
                    Variable.withString(p),
                  ]
                : [
                    Variable.withString('st1'),
                    Variable.withString(k),
                    Variable.withString(p),
                  ],
          ).get();
          if (rows.isEmpty) break;
          total += rows.length;
          final last = rows.last;
          k = last.read<String>('natural_name');
          p = last.read<String>('path');
          if (grouped) g = last.read<String>('parent_path');
          if (rows.length < 20000) break;
        }
        return (total, t.elapsedMilliseconds);
      }

      final (nPlain, tPlain) = await keyset(grouped: false);
      out('keyset walk (plain, cold after the grouped build): '
          '$tPlain ms  nodes=$nPlain');
      final (nPlain2, tPlain2) = await keyset(grouped: false);
      out('keyset walk (plain, warm repeat): $tPlain2 ms  nodes=$nPlain2');
      final (nGrouped, tGrouped) = await keyset(grouped: true);
      out('keyset walk (grouped, needs an index on parent_path): '
          '$tGrouped ms  nodes=$nGrouped');
    } catch (e, st) {
      out('B6 failed (informational only): $e');
      out('$st');
    }

    // ---------------------------------------------------------------- B7 --
    section('B7 Dart comparator cost (500k names)');
    final shuffled = List<String>.of(names);
    final rnd = Random(42);
    for (var i = shuffled.length - 1; i > 0; i--) {
      final j = rnd.nextInt(i + 1);
      final t = shuffled[i];
      shuffled[i] = shuffled[j];
      shuffled[j] = t;
    }

    final rss0 = ProcessInfo.currentRss;
    sw = Stopwatch()..start();
    final d0 = List<String>.of(shuffled)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    out('D0 current toLowerCase: ${sw.elapsedMilliseconds} ms');

    sw.reset();
    final d1 = List<String>.of(shuffled)..sort(_legacyVmCompare);
    out('D1 legacy vmNaturalCompare: ${sw.elapsedMilliseconds} ms');

    sw.reset();
    final decorated = [
      for (final n in shuffled) (naturalSortKey(n), n)
    ];
    decorated.sort((a, b) => a.$1.compareTo(b.$1));
    final d2 = [for (final e in decorated) e.$2];
    out('D2 decorate-sort: ${sw.elapsedMilliseconds} ms  '
        '(keys+sort)');
    out('rss delta during B7: ${_mb(ProcessInfo.currentRss - rss0)} MB');
    out('sanity: d0/d1/d2 lengths ${d0.length}/${d1.length}/${d2.length}');

    await db.close();

    // ---------------------------------------------------------------- B8 --
    section('B8 paging correctness fixtures');
    final fixFile = File('${root.path}${Platform.pathSeparator}fixtures.db');
    final fdb = AppDatabase(NativeDatabase(fixFile));
    await fdb.customSelect('SELECT 1').get();
    // The v53 schema ALREADY ships the column and both natural indexes; an
    // unconditional ALTER/CREATE would fail ("duplicate column name").
    final fixColumns =
        await fdb.customSelect('PRAGMA table_info(media_nodes)').get();
    if (!fixColumns.any((r) => r.read<String>('name') == 'natural_name')) {
      await fdb.customStatement(
          "ALTER TABLE media_nodes ADD COLUMN natural_name TEXT NOT NULL DEFAULT ''");
      await fdb.customStatement('CREATE INDEX idx_scope_natural_path '
          'ON media_nodes(data_scope_id, natural_name, path)');
    }

    const explicit = <String>[
      '1.mkv', '2.mkv', '10.mkv', '20.mkv',
      'ep2.mp4', 'ep10.mp4', 'EP2.MKV',
      'a1.mkv', 'a01.mkv', 'a001.mkv', 'a.mkv', 'A.mkv',
      '007.mkv', '7.mkv', '12345678901234.mkv', '99999999999999999999.mkv',
      '进击的巨人 第2集.mkv', '进击的巨人 第10集.mkv',
      '.hidden', ' space.mkv', 'a b.mkv', 'ab.mkv',
    ];

    final fixture = <(String dir, String name)>[
      for (final n in explicit) ('F0', n),
      // duplicate basenames in other folders: the path tail must break ties
      for (final n in explicit.take(6)) ('F1', n),
      for (var i = 0; i < 2000; i++) ('F${2 + i % 20}', 'n$i.mkv'),
    ];

    for (var i = 0; i < fixture.length; i += 200) {
      final buf = StringBuffer('INSERT INTO media_nodes (storage_id, '
          'data_scope_id, path, parent_path, path_depth, name, normalized_name, '
          'natural_name, node_kind, media_type, is_present) VALUES ');
      var first = true;
      for (var k = i; k < min(i + 200, fixture.length); k++) {
        final (dir, name) = fixture[k];
        if (!first) buf.write(',');
        first = false;
        buf.write("('st1','st1','$dir/${_esc(name)}','$dir',2,"
            "'${_esc(name)}','${_esc(name.toLowerCase())}',"
            "'${_esc(naturalSortKey(name))}','file','video',1)");
      }
      await fdb.customStatement(buf.toString());
    }

    // 1) key compare ordering vs the retired vmNaturalCompare (known
    //    divergence: case-only ties, where the key returns 0).
    var diverged = 0;
    var caseTies = 0;
    for (final a in explicit) {
      for (final b in explicit) {
        final k = _sign(naturalCompare(a, b));
        final v = _sign(_legacyVmCompare(a, b));
        if (k == 0 && v != 0) {
          caseTies++;
        } else if (k != v) {
          diverged++;
          out('DIVERGE: "$a" vs "$b" key=$k vm=$v');
        }
      }
    }
    out('key vs vmNaturalCompare: diverged=$diverged caseTies=$caseTies');

    // 2) SQL page walk must equal the Dart key+path order.
    final expected = [
      for (final e in fixture) e,
    ]..sort((a, b) {
        final c = naturalSortKey(a.$2).compareTo(naturalSortKey(b.$2));
        if (c != 0) return c;
        return '${a.$1}/${a.$2}'.compareTo('${b.$1}/${b.$2}');
      });

    final actual = <(String, String)>[];
    for (var page = 0; page * kPage < fixture.length; page++) {
      final rows = await fdb.customSelect(
        "SELECT parent_path, name FROM media_nodes WHERE data_scope_id=?1 "
        "AND node_kind='file' ORDER BY natural_name, path "
        'LIMIT $kPage OFFSET ?2',
        variables: [
          Variable.withString('st1'),
          Variable.withInt(page * kPage),
        ],
      ).get();
      for (final r in rows) {
        actual.add((r.read<String>('parent_path'), r.read<String>('name')));
      }
    }
    var mismatch = 0;
    for (var i = 0; i < min(actual.length, expected.length); i++) {
      if (actual[i] != expected[i]) {
        if (mismatch < 10) {
          out('ORDER MISMATCH @$i: sql=${actual[i]} dart=${expected[i]}');
        }
        mismatch++;
      }
    }
    out('sql rows=${actual.length} dart rows=${expected.length} '
        'mismatches=$mismatch');

    // 3) page seams strictly increasing.
    var seamViolations = 0;
    final totalPages = (fixture.length / kPage).ceil();
    for (var page = 0; page + 1 < totalPages; page++) {
      final tail = expected[min((page + 1) * kPage, expected.length) - 1];
      final headIndex = min((page + 2) * kPage, expected.length);
      if (headIndex >= expected.length) break;
      final head = expected[headIndex];
      final c = naturalSortKey(tail.$2).compareTo(naturalSortKey(head.$2));
      if (c > 0 ||
          (c == 0 &&
              '${tail.$1}/${tail.$2}'.compareTo('${head.$1}/${head.$2}') >= 0)) {
        seamViolations++;
      }
    }
    out('page seams: $totalPages pages, violations=$seamViolations');

    await fdb.close();

    // ------------------------------------------------------------ verdict --
    section('DONE');
    out('Copy this output into the PR / commit message.');

    expect(mismatch, 0);
    expect(diverged, 0);
    expect(seamViolations, 0);
  }, timeout: const Timeout(Duration(minutes: 45)));
}
