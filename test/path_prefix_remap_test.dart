import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/services/path_prefix_remap_service.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

import 'helpers/sqlite3_loader.dart';

/// `PathPrefixRemapService` must move every stored path that begins with a
/// storage's old base path to its new one — across all eight path tables — while
/// leaving rows outside the prefix (and whole-storage / NULL rows) untouched.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });

  tearDownAll(() async {
    await db.close();
  });

  const tables = [
    'media_nodes',
    'scan_states',
    'scan_queue',
    'scenario_sources',
    'scenario_explicit_items',
    'scenario_excludes',
    'video_tag_members',
    'media_lib_sources',
  ];

  setUp(() async {
    for (final t in tables) {
      await db.customStatement('DELETE FROM $t');
    }
  });

  Future<void> ins(String sql, List<String> vars) => db.customInsert(
        sql,
        variables: [for (final v in vars) Variable.withString(v)],
      );

  Future<String?> pathOf(String table, {String where = ''}) async {
    final rows = await db
        .customSelect('SELECT path FROM $table ${where.isEmpty ? '' : 'WHERE $where'}')
        .get();
    return rows.isEmpty ? null : rows.first.read<String>('path');
  }

  test('canRemap rejects same/empty bases', () {
    expect(PathPrefixRemapService.canRemap('D:', 'E:'), isTrue);
    expect(PathPrefixRemapService.canRemap('D:', 'D:'), isFalse);
    expect(PathPrefixRemapService.canRemap('', 'E:'), isFalse);
    expect(PathPrefixRemapService.canRemap('D:', ''), isFalse);
  });

  test('remaps media_nodes path + parent_path, including the root node',
      () async {
    await ins(
      'INSERT INTO media_nodes (storage_id, data_scope_id, path, parent_path, name, node_kind) '
      'VALUES (?,?,?,?,?,?)',
      ['sid', 'sid', 'D:/Movies/a.mp4', 'D:/Movies', 'a.mp4', 'file'],
    );
    await ins(
      'INSERT INTO media_nodes (storage_id, data_scope_id, path, parent_path, name, node_kind) '
      'VALUES (?,?,?,?,?,?)',
      ['sid', 'sid', 'D:/Movies', 'D:', 'Movies', 'directory'],
    );
    await ins(
      'INSERT INTO media_nodes (storage_id, data_scope_id, path, parent_path, name, node_kind) '
      'VALUES (?,?,?,NULL,?,?)',
      ['sid', 'sid', 'D:', 'D:', 'directory'],
    );
    // Outside the prefix — must not move.
    await ins(
      'INSERT INTO media_nodes (storage_id, data_scope_id, path, parent_path, name, node_kind) '
      'VALUES (?,?,?,?,?,?)',
      ['sid', 'sid', 'C:/Other/x.mp4', 'C:/Other', 'x.mp4', 'file'],
    );

    await const PathPrefixRemapService()
        .remap(storageId: 'sid', oldBase: 'D:', newBase: 'E:');

    final file = await db
        .customSelect(
            "SELECT path, parent_path FROM media_nodes WHERE name = 'a.mp4'")
        .getSingle();
    expect(file.read<String>('path'), 'E:/Movies/a.mp4');
    expect(file.read<String>('parent_path'), 'E:/Movies');

    final dir = await db
        .customSelect(
            "SELECT path, parent_path FROM media_nodes WHERE name = 'Movies'")
        .getSingle();
    expect(dir.read<String>('path'), 'E:/Movies');
    expect(dir.read<String>('parent_path'), 'E:');

    final root = await db
        .customSelect(
            "SELECT path, parent_path FROM media_nodes WHERE name = 'D:'")
        .getSingle();
    expect(root.read<String>('path'), 'E:');
    expect(root.read<String?>('parent_path'), isNull);

    expect(
      await pathOf('media_nodes', where: "name = 'x.mp4'"),
      'C:/Other/x.mp4',
    );
  });

  test('a legacy empty parent_path stays at the root, not the new base',
      () async {
    // Pre-normalization scans stored a storage-root child's parent as an EMPTY
    // string (see `_rootParent` in media_nodes_dao). A drive-letter remap must
    // not rewrite it into the new base: the row would stop being a root child.
    await ins(
      'INSERT INTO media_nodes (storage_id, data_scope_id, path, parent_path, name, node_kind) '
      'VALUES (?,?,?,?,?,?)',
      ['sid', 'sid', 'D:/Movies/a.mp4', '', 'a.mp4', 'file'],
    );

    await const PathPrefixRemapService()
        .remap(storageId: 'sid', oldBase: 'D:', newBase: 'E:');

    final row = await db
        .customSelect(
            "SELECT path, parent_path FROM media_nodes WHERE name = 'a.mp4'")
        .getSingle();
    expect(row.read<String>('path'), 'E:/Movies/a.mp4');
    expect(row.read<String>('parent_path'), '',
        reason: 'an empty parent is the storage root, never the new base');
  });

  test('remaps the scan tables', () async {    await ins(
      'INSERT INTO scan_states (storage_id, data_scope_id, path, status) VALUES (?,?,?,?)',
      ['sid', 'sid', 'D:/Movies', '2'],
    );
    await ins(
      'INSERT INTO scan_queue (storage_id, data_scope_id, path, depth) VALUES (?,?,?,?)',
      ['sid', 'sid', 'D:/Movies', '1'],
    );

    await const PathPrefixRemapService()
        .remap(storageId: 'sid', oldBase: 'D:', newBase: 'E:');

    expect(await pathOf('scan_states'), 'E:/Movies');
    expect(await pathOf('scan_queue'), 'E:/Movies');
  });

  test('remaps scenario / tag / library tables and leaves whole-storage rows',
      () async {
    await ins(
      'INSERT INTO scenario_sources (scenario_id, storage_id, path) VALUES (?,?,?)',
      ['sc', 'sid', 'D:/Movies'],
    );
    await ins(
      'INSERT INTO scenario_sources (scenario_id, storage_id, path) VALUES (?,?,?)',
      ['sc', 'sid', ''],
    );
    await ins(
      'INSERT INTO scenario_explicit_items (scenario_id, storage_id, path) VALUES (?,?,?)',
      ['sc', 'sid', 'D:/Movies/a.mp4'],
    );
    await ins(
      'INSERT INTO scenario_excludes (scenario_id, kind, storage_id, path) VALUES (?,?,?,?)',
      ['sc', 'media', 'sid', 'D:/Movies/a.mp4'],
    );
    await ins(
      'INSERT INTO video_tag_members (tag_id, storage_id, path) VALUES (?,?,?)',
      ['1', 'sid', 'D:/Movies/a.mp4'],
    );
    await ins(
      'INSERT INTO media_lib_sources (library_id, storage_id, path) VALUES (?,?,?)',
      ['lib', 'sid', 'D:/Movies'],
    );
    await ins(
      'INSERT INTO media_lib_sources (library_id, storage_id, path) VALUES (?,?,NULL)',
      ['lib', 'sid'],
    );

    await const PathPrefixRemapService()
        .remap(storageId: 'sid', oldBase: 'D:', newBase: 'E:');

    expect(
      await pathOf('scenario_sources', where: "path <> ''"),
      'E:/Movies',
    );
    expect(
      await pathOf('scenario_sources', where: "path = ''"),
      '',
      reason: 'whole-storage source stays empty',
    );
    expect(await pathOf('scenario_explicit_items'), 'E:/Movies/a.mp4');
    expect(await pathOf('scenario_excludes'), 'E:/Movies/a.mp4');
    expect(await pathOf('video_tag_members'), 'E:/Movies/a.mp4');
    expect(await pathOf('media_lib_sources', where: 'path IS NOT NULL'),
        'E:/Movies');
  });

  test('UPDATE OR REPLACE collapses a stale destination row', () async {
    await ins(
      'INSERT INTO media_nodes (storage_id, data_scope_id, path, parent_path, name, node_kind) '
      'VALUES (?,?,?,?,?,?)',
      ['sid', 'sid', 'D:/Movies/a.mp4', 'D:/Movies', 'a.mp4', 'file'],
    );
    await ins(
      'INSERT INTO media_nodes (storage_id, data_scope_id, path, parent_path, name, node_kind) '
      'VALUES (?,?,?,?,?,?)',
      ['sid', 'sid', 'E:/Movies/a.mp4', 'E:/Movies', 'stale.mp4', 'file'],
    );

    await const PathPrefixRemapService()
        .remap(storageId: 'sid', oldBase: 'D:', newBase: 'E:');

    final rows = await db
        .customSelect(
            "SELECT name FROM media_nodes WHERE path = 'E:/Movies/a.mp4'")
        .get();
    expect(rows, hasLength(1));
    expect(rows.single.read<String>('name'), 'a.mp4',
        reason: 'the moved row replaces the stale one');
  });

  test('remaps absolute local subtitle uris in subtitles_json', () async {
    await ins(
      'INSERT INTO media_nodes (storage_id, data_scope_id, path, parent_path, name, node_kind, subtitles_json) '
      'VALUES (?,?,?,?,?,?,?)',
      [
        'sid',
        'sid',
        'D:/Movies/a.mp4',
        'D:/Movies',
        'a.mp4',
        'file',
        // One Windows snapshot (backslashes), one unrelated drive and one SAF
        // document URI that must NOT be rewritten.
        r'[{"name":"a.srt","uri":"D:\\Movies\\a.srt"},'
            '{"name":"b.srt","uri":"C:/Other/b.srt"},'
            '{"name":"c.srt","uri":"content://x/y/c.srt"}]',
      ],
    );

    await const PathPrefixRemapService()
        .remap(storageId: 'sid', oldBase: 'D:', newBase: 'E:');

    final row = await db
        .customSelect("SELECT subtitles_json FROM media_nodes WHERE name = 'a.mp4'")
        .getSingle();
    final decoded =
        (jsonDecode(row.read<String>('subtitles_json')) as List).cast<Map>();
    final byName = {
      for (final s in decoded) s['name'] as String: s['uri'] as String,
    };
    expect(byName['a.srt'], r'E:\Movies\a.srt',
        reason: 'separator style and file name are preserved');
    expect(byName['b.srt'], 'C:/Other/b.srt');
    expect(byName['c.srt'], 'content://x/y/c.srt');
  });

  test('one unreadable subtitles_json does not abort the whole remap',
      () async {
    // A corrupt payload on one row must not stop the drive-letter rewrite for
    // every other row: the subtitle JSON is per-row data, and the remap runs in
    // one shared transaction across eight tables.
    await ins(
      'INSERT INTO media_nodes (storage_id, data_scope_id, path, parent_path, name, node_kind, subtitles_json) '
      'VALUES (?,?,?,?,?,?,?)',
      [
        'sid',
        'sid',
        'D:/Movies/a.mp4',
        'D:/Movies',
        'a.mp4',
        'file',
        r'[{"name":"a.srt","uri":"D:\\Movies\\a.srt"}]',
      ],
    );
    await ins(
      'INSERT INTO media_nodes (storage_id, data_scope_id, path, parent_path, name, node_kind, subtitles_json) '
      'VALUES (?,?,?,?,?,?,?)',
      ['sid', 'sid', 'D:/Movies/bad.mp4', 'D:/Movies', 'bad.mp4', 'file', 'not json'],
    );

    await const PathPrefixRemapService()
        .remap(storageId: 'sid', oldBase: 'D:', newBase: 'E:');

    final good = await db
        .customSelect(
            "SELECT subtitles_json FROM media_nodes WHERE name = 'a.mp4'")
        .getSingle();
    final decoded =
        (jsonDecode(good.read<String>('subtitles_json')) as List).cast<Map>();
    expect(decoded.single['uri'], r'E:\Movies\a.srt',
        reason: 'the readable row is still remapped');
    final bad = await db
        .customSelect(
            "SELECT subtitles_json FROM media_nodes WHERE name = 'bad.mp4'")
        .getSingle();
    expect(bad.read<String>('subtitles_json'), 'not json',
        reason: 'the corrupt row is left exactly as it was');
  });

  test('same base is a no-op', () async {    await ins(
      'INSERT INTO media_nodes (storage_id, data_scope_id, path, parent_path, name, node_kind) '
      'VALUES (?,?,?,?,?,?)',
      ['sid', 'sid', 'D:/Movies/a.mp4', 'D:/Movies', 'a.mp4', 'file'],
    );
    await const PathPrefixRemapService()
        .remap(storageId: 'sid', oldBase: 'D:', newBase: 'D:');
    expect(await pathOf('media_nodes'), 'D:/Movies/a.mp4');
  });
}
